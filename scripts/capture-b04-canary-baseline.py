#!/usr/bin/env python3
"""Capture the immutable pre-canary HK B04 recovery baseline through root ADB."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import shlex
import stat
import subprocess
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
PROBE_PATH = ROOT / "scripts" / "probe-b04-readonly.py"
APPROVED_OUTPUT_ROOT = Path("/Volumes/backups/U60-Pro")
RC_LOCAL_PATH = "/etc/rc.local"
COMPLETION_FILENAME = "baseline.complete"
COMPLETION_MARKER = b"u60-b04-canary-baseline-complete-v1\n"
MAX_RC_LOCAL_BYTES = 128 * 1024
USB_PROPERTY_NAMES = (
    "sys.usb.config",
    "sys.usb.state",
    "persist.sys.usb.config",
    "persist.vendor.usb.config",
)
PLANNED_CANARY_ROOT = "/data/u60"
LEGACY_AGENT_PATHS = (
    "/data/zte-agent",
    "/data/local/tmp/start_zte_agent.sh",
)


class BaselineError(RuntimeError):
    pass


def load_probe() -> Any:
    spec = importlib.util.spec_from_file_location("u60_probe_b04_readonly", PROBE_PATH)
    if spec is None or spec.loader is None:
        raise BaselineError("could not load the reviewed B04 probe boundary")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PROBE = load_probe()


def adb_bytes(arguments: list[str], *, limit: int) -> bytes:
    result = subprocess.run(
        ["adb", "exec-out", *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
        check=False,
    )
    if len(result.stdout) > limit or len(result.stderr) > 8_192:
        raise BaselineError("bounded ADB baseline output exceeded")
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()[:240]
        raise BaselineError(f"fixed ADB baseline read failed: {detail or result.returncode}")
    return result.stdout


def adb_text(arguments: list[str], *, limit: int = 8_192) -> str:
    return adb_bytes(arguments, limit=limit).decode("utf-8", "strict").strip()


def read_presence(script: str, expected: set[str]) -> str:
    value = adb_text(["sh", "-c", script], limit=64)
    if value not in expected:
        raise BaselineError("device presence check returned an unexpected marker")
    return value


def path_entry_state(path: str) -> str:
    quoted = shlex.quote(path)
    return read_presence(
        f"if [ -e {quoted} ] || [ -L {quoted} ]; "
        "then printf present; else printf absent; fi",
        {"present", "absent"},
    )


def ensure_canary_root_empty_and_agent_stopped() -> None:
    if path_entry_state(PLANNED_CANARY_ROOT) != "absent":
        raise BaselineError(
            f"{PLANNED_CANARY_ROOT} already has a directory entry; "
            "refusing a first-canary baseline"
        )
    if read_presence(
        "if pidof zte-agent >/dev/null 2>&1; then printf running; else printf absent; fi",
        {"running", "absent"},
    ) != "absent":
        raise BaselineError("a pre-existing zte-agent process was detected")


def parse_legacy_path_inventory(path: str, value: str) -> dict[str, Any]:
    fields = value.split("|")
    if fields == ["absent"]:
        return {"path": path, "state": "absent"}
    if fields in (["symlink"], ["other"]):
        return {"path": path, "state": fields[0]}
    if len(fields) != 7 or fields[0] != "regular":
        raise BaselineError("legacy agent inventory did not match the fixed schema")
    try:
        mode = int(fields[1], 8)
        uid, gid, size, modified_epoch = map(int, fields[2:6])
    except ValueError as error:
        raise BaselineError("legacy agent metadata was not numeric") from error
    digest = fields[6]
    if (
        min(uid, gid, size, modified_epoch) < 0
        or size > 64 * 1024 * 1024
        or len(digest) != 64
        or any(character not in "0123456789abcdef" for character in digest)
    ):
        raise BaselineError("legacy agent inventory exceeded its fixed bounds")
    return {
        "path": path,
        "state": "regular",
        "mode": mode,
        "uid": uid,
        "gid": gid,
        "size": size,
        "modified_epoch": modified_epoch,
        "sha256": digest,
    }


def read_legacy_path_inventory(path: str) -> dict[str, Any]:
    quoted = shlex.quote(path)
    script = (
        f"p={quoted}; "
        "if [ -L \"$p\" ]; then printf symlink; "
        "elif [ -f \"$p\" ]; then "
        "m=$(stat -c '%a|%u|%g|%s|%Y' \"$p\") || exit 1; "
        "h=$(sha256sum \"$p\" | cut -d' ' -f1) || exit 1; "
        "printf 'regular|%s|%s' \"$m\" \"$h\"; "
        "elif [ -e \"$p\" ]; then printf other; else printf absent; fi"
    )
    return parse_legacy_path_inventory(path, adb_text(["sh", "-c", script], limit=512))


def read_legacy_inventory() -> list[dict[str, Any]]:
    return [read_legacy_path_inventory(path) for path in LEGACY_AGENT_PATHS]


def build_recovery_record(
    rc_local: bytes,
    rc_metadata: dict[str, int],
    rc_sha256: str,
    usb_properties: dict[str, str],
    legacy_inventory: list[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "root_adb_confirmed": True,
        "data_u60_before": "absent",
        "zte_agent_process_before": "absent",
        "legacy_agent": {
            "process_running": False,
            "paths": legacy_inventory,
            "rc_local_references": {
                path: path.encode() in rc_local for path in LEGACY_AGENT_PATHS
            },
            "preservation_required": True,
        },
        "rc_local": {
            "path": RC_LOCAL_PATH,
            "backup": "rc.local.pre-canary",
            "sha256": rc_sha256,
            **rc_metadata,
        },
        "usb_properties": usb_properties,
    }


def parse_rc_stat(value: str) -> dict[str, int]:
    fields = value.split("|")
    if len(fields) != 6:
        raise BaselineError("rc.local stat output did not match the fixed schema")
    try:
        file_type, mode, uid, gid, size, modified_epoch = (
            int(fields[0], 16),
            int(fields[1], 8),
            int(fields[2]),
            int(fields[3]),
            int(fields[4]),
            int(fields[5]),
        )
    except ValueError as error:
        raise BaselineError("rc.local stat output was not numeric") from error
    if file_type & 0o170000 != 0o100000 or min(uid, gid, size, modified_epoch) < 0:
        raise BaselineError("rc.local is not a bounded regular file")
    if size > MAX_RC_LOCAL_BYTES:
        raise BaselineError("rc.local exceeded the baseline size limit")
    return {
        "mode": mode,
        "uid": uid,
        "gid": gid,
        "size": size,
        "modified_epoch": modified_epoch,
    }


def read_rc_local() -> tuple[bytes, dict[str, int]]:
    metadata = parse_rc_stat(
        adb_text(
            ["stat", "-c", "%f|%a|%u|%g|%s|%Y", RC_LOCAL_PATH],
            limit=256,
        )
    )
    content = adb_bytes(["cat", RC_LOCAL_PATH], limit=MAX_RC_LOCAL_BYTES)
    if len(content) != metadata["size"]:
        raise BaselineError("rc.local changed size during the baseline read")
    return content, metadata


def read_usb_properties() -> dict[str, str]:
    result: dict[str, str] = {}
    for name in USB_PROPERTY_NAMES:
        value = adb_text(["getprop", name], limit=1_024)
        if len(value) > 256:
            raise BaselineError("USB property exceeded the bounded schema")
        result[name] = value
    return result


def sha256_bytes(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def read_exact_at(directory_fd: int, filename: str, expected: bytes) -> None:
    descriptor = os.open(
        filename,
        os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
        dir_fd=directory_fd,
    )
    try:
        metadata = os.fstat(descriptor)
        content = b""
        while len(content) <= len(expected):
            chunk = os.read(descriptor, len(expected) + 1 - len(content))
            if not chunk:
                break
            content += chunk
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) not in PROBE.PRIVATE_FILE_MODES
            or content != expected
        ):
            raise BaselineError(f"{filename} did not survive exact owner-only read-back")
    finally:
        os.close(descriptor)


def publish_baseline(
    output_root_fd: int,
    rc_local: bytes,
    manifest: dict[str, Any],
) -> Path:
    captured = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    result_name = f"B04-canary-baseline-{captured}"
    result_fd = PROBE.create_private_result_directory(output_root_fd, result_name)
    try:
        manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
        PROBE.atomic_write_at(result_fd, "rc.local.pre-canary", rc_local)
        PROBE.atomic_write_at(result_fd, "BASELINE-MANIFEST.json", manifest_bytes)
        read_exact_at(result_fd, "rc.local.pre-canary", rc_local)
        read_exact_at(result_fd, "BASELINE-MANIFEST.json", manifest_bytes)
        os.fsync(result_fd)
        try:
            PROBE.atomic_write_at(result_fd, COMPLETION_FILENAME, COMPLETION_MARKER)
            os.fsync(result_fd)
            read_exact_at(result_fd, COMPLETION_FILENAME, COMPLETION_MARKER)
        except BaseException:
            try:
                os.unlink(COMPLETION_FILENAME, dir_fd=result_fd)
            except FileNotFoundError:
                pass
            raise
    finally:
        os.close(result_fd)
    return APPROVED_OUTPUT_ROOT / result_name


def capture(output_root: Path) -> Path:
    before_network = PROBE.route_and_tun_snapshot()
    if before_network["default_interface"] != "en0":
        raise BaselineError("Mac default route is not the expected Wi-Fi interface en0")
    output_root_fd = PROBE.open_validated_output_root(output_root)
    try:
        PROBE.verify_single_root_adb()
        firmware, _ = PROBE.read_identity()
        ensure_canary_root_empty_and_agent_stopped()

        legacy_inventory = read_legacy_inventory()
        rc_local, rc_metadata = read_rc_local()
        rc_sha256 = sha256_bytes(rc_local)
        usb_properties = read_usb_properties()
        live_rc_after, live_rc_metadata_after = read_rc_local()
        if live_rc_after != rc_local or live_rc_metadata_after != rc_metadata:
            raise BaselineError("rc.local changed during the baseline capture")
        if read_legacy_inventory() != legacy_inventory:
            raise BaselineError("legacy agent inventory changed during baseline capture")

        after_network = PROBE.route_and_tun_snapshot()
        PROBE.ensure_network_unchanged(before_network, after_network)
        manifest = {
            "schema_version": 1,
            "captured_at_utc": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
            "firmware": firmware,
            "repo_commit": PROBE.run_checked(["git", "rev-parse", "HEAD"])
            .decode("ascii", "strict")
            .strip(),
            "recovery": build_recovery_record(
                rc_local,
                rc_metadata,
                rc_sha256,
                usb_properties,
                legacy_inventory,
            ),
            "host_network_before": PROBE.public_network_snapshot(before_network),
            "host_network_after": PROBE.public_network_snapshot(after_network),
            "safety": {
                "device_writes_performed": False,
                "rc_local_unchanged_during_capture": True,
                "default_route_unchanged": True,
                "tun_set_unchanged": True,
                "no_boot_or_firewall_path_touched": True,
            },
        }
        return publish_baseline(output_root_fd, rc_local, manifest)
    finally:
        os.close(output_root_fd)


def self_test() -> None:
    parsed = parse_rc_stat("81fd|775|0|0|1690|1780489255")
    assert parsed == {
        "mode": 0o775,
        "uid": 0,
        "gid": 0,
        "size": 1690,
        "modified_epoch": 1780489255,
    }
    for invalid in (
        "a|b",
        "41ed|755|0|0|10|1",
        f"81fd|775|0|0|{MAX_RC_LOCAL_BYTES + 1}|1",
    ):
        try:
            parse_rc_stat(invalid)
        except BaselineError:
            pass
        else:
            raise AssertionError(f"invalid rc.local stat was accepted: {invalid}")

    observed_presence_scripts: list[str] = []
    real_read_presence = globals()["read_presence"]

    def fake_read_presence(script: str, expected: set[str]) -> str:
        assert expected in ({"present", "absent"}, {"running", "absent"})
        observed_presence_scripts.append(script)
        return "absent"

    globals()["read_presence"] = fake_read_presence
    try:
        ensure_canary_root_empty_and_agent_stopped()
    finally:
        globals()["read_presence"] = real_read_presence
    assert len(observed_presence_scripts) == 2
    assert "[ -e " in observed_presence_scripts[0]
    assert "[ -L " in observed_presence_scripts[0]

    for blocked_index in range(len(observed_presence_scripts)):
        call_index = 0

        def blocked_presence(script: str, expected: set[str]) -> str:
            nonlocal call_index
            del script
            value = "present" if call_index == blocked_index else "absent"
            if expected == {"running", "absent"} and value == "present":
                value = "running"
            call_index += 1
            return value

        globals()["read_presence"] = blocked_presence
        try:
            try:
                ensure_canary_root_empty_and_agent_stopped()
            except BaselineError:
                pass
            else:
                raise AssertionError(
                    f"pre-existing device target at index {blocked_index} was accepted"
                )
        finally:
            globals()["read_presence"] = real_read_presence

    digest = "a" * 64
    assert parse_legacy_path_inventory("/data/zte-agent", "absent") == {
        "path": "/data/zte-agent",
        "state": "absent",
    }
    regular = parse_legacy_path_inventory(
        "/data/zte-agent", f"regular|777|0|0|2363648|1|{digest}"
    )
    assert regular["state"] == "regular" and regular["sha256"] == digest
    for state in ("symlink", "other"):
        assert parse_legacy_path_inventory("/data/zte-agent", state)["state"] == state
    for invalid in ("regular", "regular|777|0|0|1|1|not-a-hash"):
        try:
            parse_legacy_path_inventory("/data/zte-agent", invalid)
        except BaselineError:
            pass
        else:
            raise AssertionError("invalid legacy agent inventory was accepted")

    recovery = build_recovery_record(
        b"#!/bin/sh\nexit 0\n",
        {"mode": 0o775, "uid": 0, "gid": 0, "size": 17, "modified_epoch": 1},
        "b" * 64,
        {name: "" for name in USB_PROPERTY_NAMES},
        [regular, {"path": LEGACY_AGENT_PATHS[1], "state": "absent"}],
    )
    assert "zte_agent_before" not in recovery
    assert recovery["zte_agent_process_before"] == "absent"
    assert recovery["legacy_agent"]["paths"][0]["state"] == "regular"
    assert recovery["legacy_agent"]["preservation_required"] is True

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        result_fd = os.open(
            root,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
        try:
            PROBE.atomic_write_at(result_fd, "exact", b"expected\n")
            read_exact_at(result_fd, "exact", b"expected\n")
            try:
                read_exact_at(result_fd, "exact", b"different\n")
            except BaselineError:
                pass
            else:
                raise AssertionError("mismatched baseline file was accepted")
        finally:
            os.close(result_fd)
    print("B04 canary baseline self-test passed")


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
        parser.error("--output-root is required for a live baseline capture")
    try:
        destination = capture(arguments.output_root)
    except (
        BaselineError,
        OSError,
        PROBE.ProbeError,
        subprocess.TimeoutExpired,
        UnicodeError,
    ) as error:
        print(f"B04 canary baseline refused: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    print(f"pre-canary B04 recovery baseline published: {destination}")


if __name__ == "__main__":
    main()
