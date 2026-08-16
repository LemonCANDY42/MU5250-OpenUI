#!/usr/bin/env python3
"""Record one redacted, read-only HK B04 capability probe through root ADB."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import stat
import subprocess
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
APPROVED_OUTPUT_ROOT = Path("/Volumes/backups/U60-Pro")
FIRMWARE_TARGET = "BD_XCBZHKMU5250V1.0.0B04"
WEB_VERSION_FILE = "/usr/zte_web/web/version"
SUPPORTED_WEB_VERSION = "WEB_XCBZHKU60PROV1.0.0B04"
COMPLETION_MARKER = b"u60-b04-capability-probe-complete-v1\n"
PRIVATE_FILE_MODES = {0o600, 0o700}
BATTERY_STATES = {
    "Unknown": "unknown",
    "Charging": "charging",
    "Discharging": "discharging",
    "Not charging": "not_charging",
    "Full": "full",
}
BATTERY_FILES = {
    "state": "/sys/class/power_supply/battery/status",
    "capacity_percent": "/sys/class/power_supply/battery/capacity",
    "voltage_uv": "/sys/class/power_supply/battery/voltage_now",
    "current_ua": "/sys/class/power_supply/battery/current_now",
    "temperature_tenths_c": "/sys/class/power_supply/battery/temp",
}
THERMAL_FILES = {
    "cpu_0": "/sys/class/thermal/thermal_zone16/temp",
    "cpu_1": "/sys/class/thermal/thermal_zone17/temp",
    "cpu_2": "/sys/class/thermal/thermal_zone18/temp",
    "cpu_3": "/sys/class/thermal/thermal_zone19/temp",
    "modem": "/sys/class/thermal/thermal_zone22/temp",
    "battery": "/sys/class/thermal/thermal_zone39/temp",
    "usb": "/sys/class/thermal/thermal_zone38/temp",
}
SYSTEM_FILES = {
    "hostname": "/proc/sys/kernel/hostname",
    "uptime": "/proc/uptime",
    "load_average": "/proc/loadavg",
    "kernel": "/proc/version",
}
ROOT_ID_ADB_ARGUMENTS = ["id", "-u"]
SENSITIVE_MARKER = re.compile(
    r"imei|imsi|iccid|eid|msisdn|serial|password|passphrase|credential|secret|token|bearer",
    re.I,
)
DEVICE_IDENTIFIER = re.compile(r"(?<!\d)\d{15,20}(?!\d)")
ALLOWED_PUBLISHED_KEYS = {
    "action",
    "adapter",
    "battery",
    "battery_status",
    "capabilities",
    "capacity_percent",
    "captured_at_utc",
    "current_ma",
    "default_interface",
    "default_route_unchanged",
    "device",
    "device_identity",
    "device_writes_performed",
    "evidence",
    "files",
    "firmware_target",
    "firmware_file",
    "firmware_version",
    "git_commit",
    "hardware_version",
    "host_network_after",
    "host_network_before",
    "hostname_present",
    "kernel_present",
    "load_average",
    "manufacturer",
    "model",
    "path",
    "procfs",
    "reason",
    "recovery",
    "required",
    "root_adb_confirmed",
    "safety",
    "schema_version",
    "sensor",
    "sha256",
    "size",
    "source",
    "sources",
    "state_category",
    "status",
    "system",
    "system_status",
    "sysfs",
    "temperature_c",
    "thermal",
    "thermal_status",
    "transport",
    "tun_interfaces",
    "tun_set_unchanged",
    "uptime_seconds",
    "voltage_mv",
}


class ProbeError(RuntimeError):
    pass


def run_checked(command: list[str], *, timeout: int = 10, limit: int = 65_536) -> bytes:
    result = subprocess.run(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if len(result.stdout) > limit or len(result.stderr) > limit:
        raise ProbeError(f"bounded command output exceeded for {command[0]}")
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()[:240]
        raise ProbeError(
            f"read-only command failed ({command[0]}): {detail or result.returncode}"
        )
    return result.stdout


def adb(
    arguments: list[str],
    *,
    allow_missing: bool = False,
    limit: int = 8_192,
    strip_output: bool = True,
) -> str | None:
    result = subprocess.run(
        ["adb", "exec-out", *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
        check=False,
    )
    if len(result.stdout) > limit or len(result.stderr) > limit:
        raise ProbeError("bounded ADB output exceeded")
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        missing = "no such file" in detail.lower() or "can't open" in detail.lower()
        if allow_missing and missing:
            return None
        raise ProbeError(f"fixed ADB read failed: {detail[:240] or result.returncode}")
    decoded = result.stdout.decode("utf-8", "strict")
    return decoded.strip() if strip_output else decoded


def verify_single_root_adb() -> None:
    output = run_checked(["adb", "devices"], limit=8_192).decode("utf-8", "strict")
    entries = []
    for line in output.splitlines()[1:]:
        fields = line.split()
        if len(fields) >= 2:
            entries.append(fields[1])
    if entries != ["device"]:
        raise ProbeError("exactly one authorized ADB device is required")
    if adb(ROOT_ID_ADB_ARGUMENTS) != "0":
        raise ProbeError("the retained ADB recovery channel is not root")


def parse_web_firmware_identity(content: str) -> str | None:
    lf = (
        f"software_version={SUPPORTED_WEB_VERSION}\n"
        f"inner_software_version={SUPPORTED_WEB_VERSION}"
    )
    crlf = (
        f"software_version={SUPPORTED_WEB_VERSION}\r\n"
        f"inner_software_version={SUPPORTED_WEB_VERSION}"
    )
    return FIRMWARE_TARGET if content in {lf, f"{lf}\n", crlf, f"{crlf}\r\n"} else None


def read_identity() -> tuple[str, str | None]:
    raw = adb(["cat", WEB_VERSION_FILE], limit=4_096, strip_output=False)
    firmware = parse_web_firmware_identity(raw or "")
    if firmware != FIRMWARE_TARGET:
        raise ProbeError(
            "fixed web-version file did not prove the exact supported HK B04 build"
        )
    return firmware, None


def parse_int(value: str | None) -> int | None:
    try:
        return int(value) if value is not None else None
    except ValueError:
        return None


def normalize_system(values: dict[str, str | None]) -> dict[str, Any] | None:
    hostname_present = bool((values["hostname"] or "").strip())
    kernel_present = bool((values["kernel"] or "").strip())
    try:
        uptime_value = float((values["uptime"] or "").split()[0])
        uptime = (
            int(uptime_value)
            if math.isfinite(uptime_value) and uptime_value >= 0
            else 0
        )
    except (ValueError, IndexError):
        uptime = 0
    loads = []
    for item in (values["load_average"] or "").split()[:3]:
        try:
            candidate = float(item)
        except ValueError:
            continue
        if math.isfinite(candidate) and candidate >= 0:
            loads.append(candidate)
    loads = (loads + [0.0, 0.0, 0.0])[:3]
    if not hostname_present or not kernel_present:
        return None
    return {
        "hostname_present": True,
        "uptime_seconds": uptime,
        "load_average": loads,
        "kernel_present": True,
    }


def read_system() -> dict[str, Any] | None:
    values = {
        name: adb(["cat", path], allow_missing=True)
        for name, path in SYSTEM_FILES.items()
    }
    return normalize_system(values)


def normalize_battery(values: dict[str, str | None]) -> dict[str, Any] | None:
    state = values["state"]
    capacity = parse_int(values["capacity_percent"])
    voltage_uv = parse_int(values["voltage_uv"])
    current_ua = parse_int(values["current_ua"])
    temperature = parse_int(values["temperature_tenths_c"])
    if (
        state is None
        or capacity is None
        or not 0 <= capacity <= 100
        or voltage_uv is None
        or voltage_uv <= 0
        or current_ua is None
        or temperature is None
        or not -400 <= temperature <= 1_500
    ):
        return None
    return {
        "state_category": BATTERY_STATES.get(state.strip(), "other"),
        "capacity_percent": capacity,
        "voltage_mv": voltage_uv // 1_000,
        "current_ma": current_ua // 1_000,
        "temperature_c": temperature / 10,
    }


def read_battery() -> dict[str, Any] | None:
    values = {
        name: adb(["cat", path], allow_missing=True)
        for name, path in BATTERY_FILES.items()
    }
    return normalize_battery(values)


def read_thermal() -> dict[str, float]:
    readings: dict[str, float] = {}
    for sensor, path in THERMAL_FILES.items():
        value = parse_int(adb(["cat", path], allow_missing=True))
        if value is not None and -40_000 < value < 150_000:
            readings[sensor] = value / 1_000
    return readings


def capability(
    status: str, reason: str | None = None, action: str | None = None
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "status": status,
        "recovery": {"required": action is not None},
    }
    if reason is not None:
        result["reason"] = reason
    if action is not None:
        result["recovery"]["action"] = action
    return result


def build_probe_result(
    firmware: str,
    hardware: str | None,
    system: dict[str, Any] | None,
    battery: dict[str, Any] | None,
    thermal: dict[str, float],
    captured_at: str,
) -> dict[str, Any]:
    capabilities = {
        "device_identity": capability("available"),
        "system_status": capability("available")
        if system
        else capability(
            "degraded",
            "one or more fixed procfs fields were unavailable",
            "inspect the fixed B04 procfs sources",
        ),
        "battery_status": capability("available")
        if battery
        else capability(
            "degraded",
            "fixed battery sysfs was incomplete or invalid",
            "inspect the fixed B04 battery sources",
        ),
        "thermal_status": capability("available")
        if thermal
        else capability(
            "degraded",
            "no fixed thermal sensor returned a valid reading",
            "inspect the fixed B04 thermal sources",
        ),
    }
    return {
        "schema_version": 1,
        "captured_at_utc": captured_at,
        "transport": "usb_root_adb_read_only",
        "device": {
            "manufacturer": "ZTE",
            "model": "MU5250",
            "adapter": "zte-mu5250-hk-b04",
            "firmware_target": "BD_XCBZHKMU5250V1.0.0B04",
            "firmware_version": firmware,
            "hardware_version": hardware,
        },
        "capabilities": capabilities,
        "status": {
            "system": system,
            "battery": battery,
            "thermal": [
                {"sensor": key, "temperature_c": thermal[key]}
                for key in sorted(thermal)
            ],
        },
    }


def route_and_tun_snapshot() -> dict[str, Any]:
    route = run_checked(["route", "-n", "get", "default"], limit=8_192).decode(
        "utf-8", "strict"
    )
    interface = re.search(r"^\s*interface:\s*(\S+)", route, re.MULTILINE)
    gateway = re.search(r"^\s*gateway:\s*(\S+)", route, re.MULTILINE)
    names = (
        run_checked(["ifconfig", "-l"], limit=8_192).decode("utf-8", "strict").split()
    )
    if interface is None or gateway is None:
        raise ProbeError("could not establish the Mac default route")
    return {
        "default_interface": interface.group(1),
        "default_gateway": gateway.group(1),
        "tun_interfaces": sorted(
            name for name in names if re.fullmatch(r"utun\d+", name)
        ),
    }


def ensure_network_unchanged(before: dict[str, Any], after: dict[str, Any]) -> None:
    if after != before:
        raise ProbeError(
            "default-route or TUN state changed during the read-only probe"
        )


def public_network_snapshot(snapshot: dict[str, Any]) -> dict[str, Any]:
    interface = snapshot.get("default_interface")
    tun_interfaces = snapshot.get("tun_interfaces")
    if (
        interface != "en0"
        or not isinstance(tun_interfaces, list)
        or any(re.fullmatch(r"utun\d+", name) is None for name in tun_interfaces)
    ):
        raise ProbeError("host network snapshot did not match the publish allowlist")
    return {"default_interface": interface, "tun_interfaces": tun_interfaces}


def assert_redacted(value: Any) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key not in ALLOWED_PUBLISHED_KEYS or SENSITIVE_MARKER.search(key):
                raise ProbeError(f"redaction boundary rejected key: {key}")
            assert_redacted(child)
    elif isinstance(value, list):
        for child in value:
            assert_redacted(child)
    elif isinstance(value, str):
        if DEVICE_IDENTIFIER.search(value):
            raise ProbeError("redaction boundary rejected a device identifier")
        if SENSITIVE_MARKER.search(value):
            raise ProbeError("redaction boundary rejected a sensitive value marker")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_write_at(directory_fd: int, filename: str, data: bytes) -> None:
    descriptor = os.open(
        filename,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
        0o600,
        dir_fd=directory_fd,
    )
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) not in PRIVATE_FILE_MODES
        ):
            try:
                os.unlink(filename, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
            raise ProbeError("result file did not retain an approved owner-only mode")
        offset = 0
        while offset < len(data):
            offset += os.write(descriptor, data[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def completion_marker_is_valid(directory_fd: int) -> bool:
    try:
        descriptor = os.open(
            "probe.complete",
            os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=directory_fd,
        )
    except OSError:
        return False
    try:
        metadata = os.fstat(descriptor)
        content = os.read(descriptor, len(COMPLETION_MARKER) + 1)
        return (
            stat.S_ISREG(metadata.st_mode)
            and metadata.st_uid == os.getuid()
            and stat.S_IMODE(metadata.st_mode) in PRIVATE_FILE_MODES
            and content == COMPLETION_MARKER
        )
    finally:
        os.close(descriptor)


def write_completion_marker(directory_fd: int) -> None:
    try:
        atomic_write_at(directory_fd, "probe.complete", COMPLETION_MARKER)
        os.fsync(directory_fd)
        if not completion_marker_is_valid(directory_fd):
            raise ProbeError("completion marker did not survive exact read-back")
    except BaseException:
        try:
            os.unlink("probe.complete", dir_fd=directory_fd)
        except FileNotFoundError:
            pass
        raise


def approved_mount_source(mount_output: str) -> bool:
    for line in mount_output.splitlines():
        if " on /Volumes/backups (smbfs," not in line:
            continue
        source = line.split(" on /Volumes/backups (", 1)[0]
        return (
            re.fullmatch(
                r"//[^/@\s]+@Marshmallow\._smb\._tcp\.local/backups",
                source,
            )
            is not None
        )
    return False


def resolve_physical_self(path: Path, expected: Path) -> Path:
    if path != expected:
        raise ProbeError(f"output root must be exactly {expected}")
    if path.is_symlink():
        raise ProbeError("approved output root must not be a symlink")
    resolved = path.resolve(strict=True)
    if resolved != expected:
        raise ProbeError("approved output root did not resolve physically to itself")
    return resolved


def open_validated_output_root(path: Path) -> int:
    resolved = resolve_physical_self(path, APPROVED_OUTPUT_ROOT)
    mount_output = run_checked(["mount"], limit=65_536).decode("utf-8", "strict")
    if not approved_mount_source(mount_output):
        raise ProbeError("mounted SMB server/share is not the approved backups share")
    descriptor = os.open(
        resolved,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
    )
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        os.close(descriptor)
        raise ProbeError("approved output root must be owner-controlled mode 0700")
    return descriptor


def create_private_result_directory(directory_fd: int, result_name: str) -> int:
    os.mkdir(result_name, mode=0o700, dir_fd=directory_fd)
    result_fd = os.open(
        result_name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        dir_fd=directory_fd,
    )
    metadata = os.fstat(result_fd)
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
        os.close(result_fd)
        raise ProbeError(
            "NAS did not preserve private mode 0700 on the result directory"
        )
    return result_fd


def publish_probe(
    output_root_fd: int, result: dict[str, Any], safety: dict[str, Any]
) -> Path:
    captured = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    final_name = f"B04-capability-probe-{captured}"
    result_fd = create_private_result_directory(output_root_fd, final_name)
    try:
        result_bytes = (json.dumps(result, indent=2, sort_keys=True) + "\n").encode()
        atomic_write_at(result_fd, "capabilities.json", result_bytes)
        source_files = [
            ROOT / "agent" / "src" / "adapter.rs",
            ROOT / "openapi" / "u60-v1.yaml",
            Path(__file__).resolve(),
        ]
        manifest = {
            "schema_version": 1,
            "captured_at_utc": result["captured_at_utc"],
            "evidence": {
                "path": "capabilities.json",
                "size": len(result_bytes),
                "sha256": hashlib.sha256(result_bytes).hexdigest(),
            },
            "source": {
                "git_commit": run_checked(["git", "rev-parse", "HEAD"])
                .decode()
                .strip(),
                "files": [
                    {
                        "path": str(path.relative_to(ROOT)),
                        "sha256": sha256_file(path),
                    }
                    for path in source_files
                ],
            },
            "safety": safety,
        }
        assert_redacted(manifest)
        atomic_write_at(
            result_fd,
            "MANIFEST.json",
            (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode(),
        )
        os.fsync(result_fd)
        write_completion_marker(result_fd)
    finally:
        os.close(result_fd)
    return APPROVED_OUTPUT_ROOT / final_name


def run_probe(output_root: Path) -> Path:
    before = route_and_tun_snapshot()
    if before["default_interface"] != "en0":
        raise ProbeError("Mac default route is not the expected Wi-Fi interface en0")
    output_root_fd = open_validated_output_root(output_root)
    try:
        verify_single_root_adb()
        firmware, hardware = read_identity()
        captured_at = datetime.now(UTC).isoformat().replace("+00:00", "Z")
        result = build_probe_result(
            firmware,
            hardware,
            read_system(),
            read_battery(),
            read_thermal(),
            captured_at,
        )
        assert_redacted(result)
        after = route_and_tun_snapshot()
        ensure_network_unchanged(before, after)
        safety = {
            "root_adb_confirmed": True,
            "default_route_unchanged": True,
            "tun_set_unchanged": True,
            "host_network_before": public_network_snapshot(before),
            "host_network_after": public_network_snapshot(after),
            "device_writes_performed": False,
            "sources": {
                "firmware_file": WEB_VERSION_FILE,
                "procfs": sorted(SYSTEM_FILES.values()),
                "sysfs": sorted([*BATTERY_FILES.values(), *THERMAL_FILES.values()]),
            },
        }
        assert_redacted(safety)
        return publish_probe(output_root_fd, result, safety)
    finally:
        os.close(output_root_fd)


def self_test() -> None:
    valid_web_version = (
        "software_version=WEB_XCBZHKU60PROV1.0.0B04\r\n"
        "inner_software_version=WEB_XCBZHKU60PROV1.0.0B04\r\n"
    )
    assert parse_web_firmware_identity(valid_web_version) == FIRMWARE_TARGET
    for invalid_web_version in (
        "software_version=WEB_XCBZHKU60PROV1.0.0B04\n"
        "inner_software_version=WEB_XCBZHKU60PROV1.0.0B03\n",
        "software_version=WEB_XCBZHKU60PROV1.0.0B04\n",
        "software_version=WEB_XCBZHKU60PROV1.0.0B04\n"
        "software_version=WEB_XCBZHKU60PROV1.0.0B04\n"
        "inner_software_version=WEB_XCBZHKU60PROV1.0.0B04\n",
        "software_version=WEB_XCBZHKU60PROV1.0.0B04\n"
        "inner_software_version=WEB_XCBZHKU60PROV1.0.0B04\n"
        "unexpected=value\n",
        " software_version=WEB_XCBZHKU60PROV1.0.0B04\n"
        "inner_software_version=WEB_XCBZHKU60PROV1.0.0B04\n",
        "software_version=WEB_XCBZHKU60PROV1.0.0B04 \n"
        "inner_software_version=WEB_XCBZHKU60PROV1.0.0B04\n",
        "software_version=WEB_XCBZHKU60PROV1.0.0B04\r"
        "inner_software_version=WEB_XCBZHKU60PROV1.0.0B04",
        "software_version=WEB_XCBZHKU60PROV1.0.0B04\r\n"
        "inner_software_version=WEB_XCBZHKU60PROV1.0.0B04\n",
        "software_version=WEB_XCBZHKU60PROV1.0.0B04\n"
        "inner_software_version=WEB_XCBZHKU60PROV1.0.0B04\n\n",
    ):
        assert parse_web_firmware_identity(invalid_web_version) is None
    result = build_probe_result(
        FIRMWARE_TARGET,
        None,
        {
            "hostname_present": True,
            "uptime_seconds": 1,
            "load_average": [0.0, 0.0, 0.0],
            "kernel_present": True,
        },
        None,
        {"cpu_0": 34.5},
        "2026-01-01T00:00:00Z",
    )
    encoded = json.dumps(result)
    assert "credential-value" not in encoded and "0" * 15 not in encoded
    assert result["capabilities"]["battery_status"]["status"] == "degraded"
    assert_redacted(result)
    try:
        assert_redacted({"imei": "redacted"})
    except ProbeError:
        pass
    else:
        raise AssertionError("sensitive key was accepted")
    for bad_value in ("1" * 19, "credential-value", "passphrase-hidden"):
        try:
            assert_redacted({"hardware_version": bad_value})
        except ProbeError:
            pass
        else:
            raise AssertionError("sensitive value in an allowed field was accepted")
    try:
        assert_redacted({"eid": "redacted"})
    except ProbeError:
        pass
    else:
        raise AssertionError("SIM identifier alias was accepted")

    system = normalize_system(
        {"hostname": "u60", "kernel": "Linux", "uptime": None, "load_average": None}
    )
    assert system is not None
    assert system["uptime_seconds"] == 0 and system["load_average"] == [0.0, 0.0, 0.0]
    battery = normalize_battery(
        {
            "state": "",
            "capacity_percent": "80",
            "voltage_uv": "4000000",
            "current_ua": "0",
            "temperature_tenths_c": "250",
        }
    )
    assert battery is not None and battery["state_category"] == "other"

    expected_identity_arguments = ["cat", WEB_VERSION_FILE]
    assert WEB_VERSION_FILE == "/usr/zte_web/web/version"
    assert ROOT_ID_ADB_ARGUMENTS == ["id", "-u"]
    assert SYSTEM_FILES == {
        "hostname": "/proc/sys/kernel/hostname",
        "uptime": "/proc/uptime",
        "load_average": "/proc/loadavg",
        "kernel": "/proc/version",
    }
    assert BATTERY_FILES == {
        "state": "/sys/class/power_supply/battery/status",
        "capacity_percent": "/sys/class/power_supply/battery/capacity",
        "voltage_uv": "/sys/class/power_supply/battery/voltage_now",
        "current_ua": "/sys/class/power_supply/battery/current_now",
        "temperature_tenths_c": "/sys/class/power_supply/battery/temp",
    }
    assert THERMAL_FILES == {
        "cpu_0": "/sys/class/thermal/thermal_zone16/temp",
        "cpu_1": "/sys/class/thermal/thermal_zone17/temp",
        "cpu_2": "/sys/class/thermal/thermal_zone18/temp",
        "cpu_3": "/sys/class/thermal/thermal_zone19/temp",
        "modem": "/sys/class/thermal/thermal_zone22/temp",
        "battery": "/sys/class/thermal/thermal_zone39/temp",
        "usb": "/sys/class/thermal/thermal_zone38/temp",
    }

    observed_adb_arguments: list[list[str]] = []
    source_values = {
        "/proc/sys/kernel/hostname": "u60",
        "/proc/uptime": "1.0 0.0",
        "/proc/loadavg": "0.0 0.0 0.0 1/1 1",
        "/proc/version": "Linux version fixed",
        "/sys/class/power_supply/battery/status": "Charging",
        "/sys/class/power_supply/battery/capacity": "80",
        "/sys/class/power_supply/battery/voltage_now": "4000000",
        "/sys/class/power_supply/battery/current_now": "0",
        "/sys/class/power_supply/battery/temp": "250",
        **{path: "35000" for path in THERMAL_FILES.values()},
    }

    def fake_adb(
        arguments: list[str],
        *,
        allow_missing: bool = False,
        limit: int = 8_192,
        strip_output: bool = True,
    ) -> str | None:
        del allow_missing, limit
        observed_adb_arguments.append(arguments)
        if arguments == expected_identity_arguments:
            assert not strip_output
            return valid_web_version
        assert strip_output
        if len(arguments) == 2 and arguments[0] == "cat":
            return source_values[arguments[1]]
        raise AssertionError(f"unexpected ADB argv: {arguments!r}")

    real_adb = globals()["adb"]
    globals()["adb"] = fake_adb
    try:
        assert read_identity() == (FIRMWARE_TARGET, None)
        assert read_system() is not None
        assert read_battery() is not None
        assert len(read_thermal()) == len(THERMAL_FILES)
    finally:
        globals()["adb"] = real_adb
    expected_observed = [
        expected_identity_arguments,
        *[["cat", path] for path in SYSTEM_FILES.values()],
        *[["cat", path] for path in BATTERY_FILES.values()],
        *[["cat", path] for path in THERMAL_FILES.values()],
    ]
    assert observed_adb_arguments == expected_observed
    good_mount = (
        "//owner@Marshmallow._smb._tcp.local/backups on /Volumes/backups (smbfs, nodev)"
    )
    assert approved_mount_source(good_mount)
    assert not approved_mount_source(
        "//owner@Other._smb._tcp.local/backups on /Volumes/backups (smbfs, nodev)"
    )
    assert not approved_mount_source(
        "//owner@Marshmallow._smb._tcp.local/backups on /Volumes/backups (apfs, local)"
    )
    assert not approved_mount_source(
        "not-a-mount@Marshmallow._smb._tcp.local/backups on /Volumes/backups (smbfs, nodev)"
    )
    network = {
        "default_interface": "en0",
        "default_gateway": "192.0.2.1",
        "tun_interfaces": ["utun0", "utun1024"],
    }
    ensure_network_unchanged(network, dict(network))
    changed = {**network, "tun_interfaces": ["utun0"]}
    try:
        ensure_network_unchanged(network, changed)
    except ProbeError:
        pass
    else:
        raise AssertionError("TUN drift was accepted")

    with tempfile.TemporaryDirectory() as directory:
        directory_path = Path(directory)
        physical = directory_path / "physical"
        physical.mkdir(mode=0o700)
        link = directory_path / "linked-root"
        link.symlink_to(physical, target_is_directory=True)
        try:
            resolve_physical_self(link, link)
        except ProbeError:
            pass
        else:
            raise AssertionError("symlink output root was accepted")

        directory_fd = os.open(
            physical,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
        try:
            atomic_write_at(directory_fd, "evidence.json", b"{}\n")
            assert stat.S_IMODE((physical / "evidence.json").stat().st_mode) == 0o600
            try:
                atomic_write_at(directory_fd, "evidence.json", b"replacement")
            except FileExistsError:
                pass
            else:
                raise AssertionError("exclusive evidence publication was bypassed")

            result_fd = create_private_result_directory(directory_fd, "result")
            assert stat.S_IMODE(os.fstat(result_fd).st_mode) == 0o700
            os.close(result_fd)
            try:
                create_private_result_directory(directory_fd, "result")
            except FileExistsError:
                pass
            else:
                raise AssertionError("exclusive result-directory creation was bypassed")

            marker_fd = create_private_result_directory(directory_fd, "marker-result")
            real_write = os.write

            def partial_marker_write(descriptor: int, data: bytes) -> int:
                if data == COMPLETION_MARKER:
                    real_write(descriptor, data[:5])
                    raise OSError("injected partial marker write")
                return real_write(descriptor, data)

            os.write = partial_marker_write
            try:
                try:
                    write_completion_marker(marker_fd)
                except OSError:
                    pass
                else:
                    raise AssertionError("partial completion-marker write was accepted")
            finally:
                os.write = real_write
            assert not completion_marker_is_valid(marker_fd)
            assert not (physical / "marker-result" / "probe.complete").exists()

            real_fsync = os.fsync

            def fail_result_directory_fsync(descriptor: int) -> None:
                if descriptor == marker_fd:
                    raise OSError("injected result-directory fsync failure")
                real_fsync(descriptor)

            os.fsync = fail_result_directory_fsync
            try:
                try:
                    write_completion_marker(marker_fd)
                except OSError:
                    pass
                else:
                    raise AssertionError(
                        "completion marker survived failed directory fsync"
                    )
            finally:
                os.fsync = real_fsync
            assert not completion_marker_is_valid(marker_fd)
            assert not (physical / "marker-result" / "probe.complete").exists()

            write_completion_marker(marker_fd)
            assert completion_marker_is_valid(marker_fd)
            os.chmod(physical / "marker-result" / "probe.complete", 0o700)
            assert completion_marker_is_valid(marker_fd)
            os.chmod(physical / "marker-result" / "probe.complete", 0o640)
            assert not completion_marker_is_valid(marker_fd)
            os.close(marker_fd)

            detached = directory_path / "detached"
            physical.rename(detached)
            physical.mkdir(mode=0o700)
            atomic_write_at(directory_fd, "fd-anchored.json", b"anchored\n")
            assert (detached / "fd-anchored.json").is_file()
            assert not (physical / "fd-anchored.json").exists()
        finally:
            os.close(directory_fd)
    print("B04 read-only probe self-test passed")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--output-root", type=Path)
    arguments = parser.parse_args()
    if arguments.self_test:
        if arguments.output_root is not None:
            parser.error("--self-test cannot be combined with --output-root")
        self_test()
        return
    if arguments.output_root is None:
        parser.error("--output-root is required for a live read-only probe")
    try:
        destination = run_probe(arguments.output_root)
    except (OSError, ProbeError, subprocess.TimeoutExpired, UnicodeError) as error:
        print(f"B04 read-only probe refused: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    print(f"read-only B04 capability evidence published: {destination}")


if __name__ == "__main__":
    main()
