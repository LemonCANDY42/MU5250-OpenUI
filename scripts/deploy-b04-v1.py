#!/usr/bin/env python3
"""Stage and operate the reviewed HK B04 V1 release through root USB ADB.

Every mutating command is exact-firmware gated, publishes a redacted invariant
record to the approved NAS, and leaves USB composition, FOTA and system service
configuration untouched. Boot persistence is a separate explicit subcommand.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
APPROVED_NAS_ROOT = Path("/Volumes/backups/U60-Pro")
APPROVED_RELEASE_ROOT = APPROVED_NAS_ROOT / "releases"
DEVICE_ROOT = "/data/u60"
START_CURRENT_SOURCE = ROOT / "device" / "b04-v1" / "start-current.sh"
BOOT_LINE = b"sh /data/u60/start-current.sh >/dev/null 2>&1 &\n"
HEX64 = re.compile(r"^[0-9a-f]{64}$")
COMPLETION_PREFIX = "u60-b04-v1-deploy-evidence-complete-v1:"
MAX_ADB_OUTPUT = 256 * 1024


class DeployError(RuntimeError):
    pass


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise DeployError(f"cannot load reviewed helper: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PROBE = load_module("u60_probe", ROOT / "scripts" / "probe-b04-readonly.py")
DEVICE_GATE = load_module("u60_device_gate", ROOT / "scripts" / "_device_gate.py")


def run(
    command: list[str],
    *,
    input_bytes: bytes | None = None,
    timeout: int = 30,
    limit: int = MAX_ADB_OUTPUT,
    check: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(
        command,
        input=input_bytes,
        stdin=subprocess.PIPE if input_bytes is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=timeout,
    )
    if len(result.stdout) > limit or len(result.stderr) > limit:
        raise DeployError(f"bounded output exceeded for {command[0]}")
    if check and result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()[:400]
        raise DeployError(
            f"command failed ({command[0]}): {detail or result.returncode}"
        )
    return result


def adb_shell(script: str, *, timeout: int = 20, limit: int = 16_384) -> str:
    result = run(["adb", "exec-out", "sh", "-c", script], timeout=timeout, limit=limit)
    return result.stdout.decode("utf-8", "strict").strip()


def adb_push(source: Path, destination: str, *, timeout: int = 120) -> None:
    run(["adb", "push", str(source), destination], timeout=timeout, limit=64 * 1024)


def sha256_bytes(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def require_local_release(path: Path) -> str:
    if path.parent != APPROVED_RELEASE_ROOT or path.is_symlink():
        raise DeployError(
            f"release must be a physical child of {APPROVED_RELEASE_ROOT}"
        )
    release_id = path.name
    if not HEX64.fullmatch(release_id):
        raise DeployError("release directory name is not a SHA-256 identifier")
    if not path.is_dir():
        raise DeployError("release directory is missing")
    checksum_path = path / "release.sha256"
    marker_path = path / "release.complete"
    if checksum_path.is_symlink() or marker_path.is_symlink():
        raise DeployError("release metadata must not be symlinked")
    if sha256_file(checksum_path) != release_id:
        raise DeployError("release identifier does not bind release.sha256")
    expected_marker = f"u60-b04-v1-release:{release_id}\n".encode()
    if marker_path.read_bytes() != expected_marker:
        raise DeployError("release completion marker is invalid")
    expected_files = {"release.sha256", "release.complete"}
    try:
        checksum_lines = checksum_path.read_text("ascii").splitlines()
    except UnicodeError as error:
        raise DeployError("release checksum list is not ASCII") from error
    for line in checksum_lines:
        digest, separator, relative = line.partition("  ")
        if (
            not separator
            or not HEX64.fullmatch(digest)
            or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", relative)
            or relative.startswith(".")
            or ".." in Path(relative).parts
        ):
            raise DeployError("release checksum list has an unsafe entry")
        expected_files.add(relative)
    actual_files: set[str] = set()
    for root, directories, files in os.walk(path, followlinks=False):
        root_path = Path(root)
        for name in directories:
            if (root_path / name).is_symlink():
                raise DeployError("release contains a symlinked directory")
        for name in files:
            candidate = root_path / name
            if candidate.is_symlink() or not candidate.is_file():
                raise DeployError("release contains a non-regular file")
            actual_files.add(candidate.relative_to(path).as_posix())
    if actual_files != expected_files:
        raise DeployError("release file set does not match its checksum list")
    result = run(
        ["sh", "-c", f"cd {shlex.quote(str(path))} && sha256sum -c release.sha256"],
        timeout=30,
        limit=64 * 1024,
    )
    if result.returncode != 0:
        raise DeployError("release checksum verification failed")
    return release_id


def read_usb_properties() -> dict[str, str]:
    return {
        name: adb_shell(f"getprop {shlex.quote(name)}", limit=1024)
        for name in (
            "sys.usb.config",
            "sys.usb.state",
            "persist.sys.usb.config",
            "persist.vendor.usb.config",
        )
    }


def read_rc_local() -> bytes:
    return run(
        ["adb", "exec-out", "cat", "/etc/rc.local"],
        timeout=10,
        limit=128 * 1024,
    ).stdout


def read_rc_metadata() -> dict[str, int]:
    value = adb_shell("stat -c '%a|%u|%g' /etc/rc.local", limit=128)
    fields = value.split("|")
    if len(fields) != 3:
        raise DeployError("rc.local metadata did not match the fixed schema")
    try:
        mode, uid, gid = int(fields[0], 8), int(fields[1]), int(fields[2])
    except ValueError as error:
        raise DeployError("rc.local metadata was not numeric") from error
    if (mode, uid, gid) != (0o775, 0, 0):
        raise DeployError(
            "rc.local metadata differs from the accepted B04 root:root 0775 baseline"
        )
    return {"mode": mode, "uid": uid, "gid": gid}


def read_release_links() -> dict[str, str | None]:
    result: dict[str, str | None] = {}
    for name in ("current", "previous"):
        value = adb_shell(
            f"if [ -L {DEVICE_ROOT}/{name} ]; then readlink {DEVICE_ROOT}/{name}; "
            "else printf absent; fi",
            limit=256,
        )
        result[name] = None if value == "absent" else value
    return result


def capture_invariants() -> dict[str, Any]:
    PROBE.verify_single_root_adb()
    firmware, _ = PROBE.read_identity()
    network = PROBE.route_and_tun_snapshot()
    if network["default_interface"] != "en0":
        raise DeployError("Mac default route is not Wi-Fi en0")
    rc_local = read_rc_local()
    return {
        "firmware": firmware,
        "root_adb": True,
        "network": network,
        "usb": read_usb_properties(),
        "rc_local_sha256": sha256_bytes(rc_local),
        "rc_local_metadata": read_rc_metadata(),
        "release_links": read_release_links(),
    }


def assert_invariants(
    before: dict[str, Any],
    after: dict[str, Any],
    *,
    allow_rc_local_change: bool = False,
    allow_release_link_change: bool = False,
) -> None:
    if before["firmware"] != after["firmware"] or not after["root_adb"]:
        raise DeployError("firmware or root ADB recovery invariant changed")
    if before["network"] != after["network"]:
        raise DeployError("Mac default route or TUN set changed")
    if before["usb"] != after["usb"]:
        raise DeployError("device USB properties changed")
    if (
        not allow_rc_local_change
        and before["rc_local_sha256"] != after["rc_local_sha256"]
    ):
        raise DeployError("rc.local changed outside the boot-hook operation")
    if (
        not allow_release_link_change
        and before["release_links"] != after["release_links"]
    ):
        raise DeployError("release links changed outside activation or rollback")


def verify_device_release_script(
    release_id: str, root: str, *, require_basename: bool = True
) -> str:
    quoted_root = shlex.quote(root)
    quoted_id = shlex.quote(release_id)
    basename_gate = (
        f'[ "$(basename "$d")" = {quoted_id} ]; ' if require_basename else ""
    )
    return (
        f'set -eu; d={quoted_root}; [ -d "$d" ] && [ ! -L "$d" ]; '
        + basename_gate
        + '[ "$(sha256sum "$d/release.sha256" | cut -d\' \' -f1)" = '
        f"{quoted_id} ]; "
        f'[ "$(sed -n \'1p\' "$d/release.complete")" = u60-b04-v1-release:{release_id} ]; '
        'cd "$d"; sha256sum -c release.sha256 >/dev/null'
    )


def install_release(local_release: Path, release_id: str) -> bool:
    destination = f"{DEVICE_ROOT}/releases/{release_id}"
    present = adb_shell(
        f"if [ -e {shlex.quote(destination)} ] || [ -L {shlex.quote(destination)} ]; "
        "then printf present; else printf absent; fi",
        limit=64,
    )
    if present == "present":
        adb_shell(verify_device_release_script(release_id, destination), timeout=45)
        return False
    staging = f"{DEVICE_ROOT}/.install-{release_id}"
    adb_shell(
        f"set -eu; umask 077; mkdir -p {DEVICE_ROOT}/releases {DEVICE_ROOT}/runtime "
        f"{DEVICE_ROOT}/logs; [ ! -e {staging} ] && [ ! -L {staging} ]; mkdir {staging}; "
        f"chmod 700 {DEVICE_ROOT} {DEVICE_ROOT}/releases {DEVICE_ROOT}/runtime "
        f"{DEVICE_ROOT}/logs {staging}"
    )
    try:
        for child in sorted(local_release.iterdir(), key=lambda item: item.name):
            if child.is_symlink():
                raise DeployError("release contains a symlink")
            adb_push(child, f"{staging}/")
        adb_shell(
            f"set -eu; find {staging} -type d -exec chmod 700 {{}} \\;; "
            f"find {staging} -type f -exec chmod 600 {{}} \\;; "
            f"chmod 700 {staging}/zte-agent {staging}/dropbearmulti {staging}/bin/*.sh; "
            + verify_device_release_script(release_id, staging, require_basename=False)
            + f"; mv {staging} {destination}",
            timeout=60,
        )
    except BaseException:
        adb_shell(f"rm -rf {staging}", timeout=30)
        raise
    adb_shell(verify_device_release_script(release_id, destination), timeout=45)
    return True


def stop_managed_agent(pid_name: str) -> None:
    if pid_name not in {"canary.pid", "agent.pid"}:
        raise DeployError("invalid managed PID name")
    pid_file = f"{DEVICE_ROOT}/runtime/{pid_name}"
    script = (
        f'set -eu; f={pid_file}; [ -f "$f" ] && [ ! -L "$f" ] || exit 0; '
        'p=$(sed -n \'1p\' "$f"); case "$p" in \'\'|*[!0-9]*) rm -f "$f"; exit 0;; esac; '
        '[ -d "/proc/$p" ] || { rm -f "$f"; exit 0; }; '
        'x=$(readlink "/proc/$p/exe" 2>/dev/null || true); case "$x" in '
        f"{DEVICE_ROOT}/releases/[0-9a-f]*/zte-agent|{DEVICE_ROOT}/canary-*/zte-agent) ;; "
        '*) exit 1;; esac; kill "$p"; i=0; while kill -0 "$p" 2>/dev/null; '
        'do i=$((i+1)); [ "$i" -lt 20 ] || exit 1; sleep 1; done; rm -f "$f"'
    )
    adb_shell(script, timeout=30)


def stop_legacy_canary_without_pid_file() -> None:
    script = (
        'set -eu; pids=$(pidof zte-agent 2>/dev/null || true); [ -n "$pids" ] || exit 0; '
        'count=0; chosen=; for p in $pids; do x=$(readlink "/proc/$p/exe" 2>/dev/null || true); '
        f'case "$x" in {DEVICE_ROOT}/canary-*/zte-agent) count=$((count+1)); chosen=$p;; esac; '
        'done; [ "$count" -le 1 ]; [ "$count" -eq 1 ] || exit 0; kill "$chosen"; '
        'i=0; while kill -0 "$chosen" 2>/dev/null; do i=$((i+1)); '
        '[ "$i" -lt 20 ] || exit 1; sleep 1; done'
    )
    adb_shell(script, timeout=30)


def assert_no_zte_agent_processes() -> None:
    if adb_shell("pidof zte-agent 2>/dev/null || true", limit=4096):
        raise DeployError("an unowned zte-agent process remains after managed stop")


def start_canary(release_id: str) -> None:
    stop_managed_agent("canary.pid")
    stop_legacy_canary_without_pid_file()
    adb_shell(
        f"{DEVICE_ROOT}/releases/{release_id}/bin/run-agent.sh canary",
        timeout=30,
    )
    run(["adb", "forward", "tcp:19443", "tcp:19443"], timeout=10, limit=4096)


def switch_current(release_id: str) -> None:
    release = f"{DEVICE_ROOT}/releases/{release_id}"
    adb_shell(verify_device_release_script(release_id, release), timeout=45)
    script = (
        f"set -eu; cd {DEVICE_ROOT}; rm -f current.next previous.next; "
        'if [ -L current ]; then old=$(readlink current); case "$old" in '
        f"{DEVICE_ROOT}/releases/[0-9a-f]*|releases/[0-9a-f]*) ;; *) exit 1;; esac; "
        'ln -s "$old" previous.next; mv -f previous.next previous; fi; '
        f"ln -s {release} current.next; mv -f current.next current"
    )
    adb_shell(script)


def rollback_current() -> str:
    previous = adb_shell(
        f"set -eu; cd {DEVICE_ROOT}; [ -L previous ]; readlink previous",
        limit=512,
    )
    release_id = previous.rstrip("/").split("/")[-1]
    if not HEX64.fullmatch(release_id):
        raise DeployError("previous release link is invalid")
    adb_shell(
        verify_device_release_script(release_id, f"{DEVICE_ROOT}/releases/{release_id}")
    )
    stop_managed_agent("agent.pid")
    adb_shell(
        f"set -eu; cd {DEVICE_ROOT}; rm -f current.next; "
        f"ln -s {DEVICE_ROOT}/releases/{release_id} current.next; mv -f current.next current; "
        f"{DEVICE_ROOT}/releases/{release_id}/bin/run-agent.sh stable",
        timeout=45,
    )
    return release_id


def verify_tls_unauthorized(port: int, ca_cert: Path) -> None:
    if ca_cert.is_symlink() or not ca_cert.is_file():
        raise DeployError("CA certificate must be a physical file")
    result = run(
        [
            "curl",
            "--silent",
            "--show-error",
            "--output",
            "/dev/null",
            "--write-out",
            "%{http_code}",
            "--cacert",
            str(ca_cert),
            "--resolve",
            f"u60.local:{port}:127.0.0.1",
            f"https://u60.local:{port}/v1/device",
        ],
        timeout=20,
        limit=4096,
    )
    if result.stdout != b"401":
        raise DeployError(
            "TLS health check did not return the expected authenticated boundary"
        )


def write_evidence(
    action: str,
    before: dict[str, Any],
    after: dict[str, Any],
    details: dict[str, Any],
    *,
    rc_backup: bytes | None = None,
    extra_files: dict[str, bytes] | None = None,
) -> Path:
    root_fd = PROBE.open_validated_output_root(APPROVED_NAS_ROOT)
    timestamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
    final_name = f"B04-v1-{action}-{timestamp}"
    staging_name = f".B04-v1-evidence-stage-{os.getpid()}-{os.urandom(8).hex()}"
    staging_fd: int | None = None
    final_published = False
    try:
        staging_fd = PROBE.create_private_result_directory(root_fd, staging_name)
        payload = {
            "schema_version": 1,
            "action": action,
            "captured_at_utc": datetime.now(UTC).replace(microsecond=0).isoformat(),
            "before": before,
            "after": after,
            "details": details,
            "secrets_recorded": False,
        }
        evidence_bytes = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()
        files = {"evidence.json": evidence_bytes}
        if rc_backup is not None:
            files["rc.local.before"] = rc_backup
        for name, content in sorted((extra_files or {}).items()):
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", name):
                raise DeployError("evidence filename is invalid")
            if name in files or name in {"EVIDENCE-MANIFEST.json", "evidence.complete"}:
                raise DeployError("evidence filename collides with reserved metadata")
            files[name] = content
        for name, content in sorted(files.items()):
            PROBE.atomic_write_at(staging_fd, name, content)
            if read_private_file_at(staging_fd, name) != content:
                raise DeployError("evidence file did not survive exact read-back")
        manifest = {
            "schema_version": 1,
            "action": action,
            "files": [
                {
                    "path": name,
                    "size": len(content),
                    "sha256": sha256_bytes(content),
                }
                for name, content in sorted(files.items())
            ],
        }
        manifest_bytes = (
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        ).encode()
        PROBE.atomic_write_at(staging_fd, "EVIDENCE-MANIFEST.json", manifest_bytes)
        if read_private_file_at(staging_fd, "EVIDENCE-MANIFEST.json") != manifest_bytes:
            raise DeployError("evidence manifest did not survive exact read-back")
        marker = f"{COMPLETION_PREFIX}{sha256_bytes(manifest_bytes)}\n".encode()
        os.fsync(staging_fd)
        os.close(staging_fd)
        staging_fd = None
        os.rename(staging_name, final_name, src_dir_fd=root_fd, dst_dir_fd=root_fd)
        final_published = True
        os.fsync(root_fd)
        final_fd = os.open(
            final_name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=root_fd,
        )
        try:
            if (
                read_private_file_at(final_fd, "EVIDENCE-MANIFEST.json")
                != manifest_bytes
            ):
                raise DeployError("published evidence manifest changed after rename")
            PROBE.atomic_write_at(final_fd, "evidence.complete", marker)
            os.fsync(final_fd)
            if read_private_file_at(final_fd, "evidence.complete") != marker:
                raise DeployError("published evidence marker changed after rename")
        finally:
            os.close(final_fd)
        return APPROVED_NAS_ROOT / final_name
    except BaseException:
        if final_published:
            try:
                final_fd = os.open(
                    final_name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=root_fd,
                )
                try:
                    os.unlink("evidence.complete", dir_fd=final_fd)
                    os.fsync(final_fd)
                finally:
                    os.close(final_fd)
            except FileNotFoundError:
                pass
        if staging_fd is not None:
            for name in os.listdir(staging_fd):
                try:
                    os.unlink(name, dir_fd=staging_fd)
                except FileNotFoundError:
                    pass
            os.close(staging_fd)
        try:
            os.rmdir(staging_name, dir_fd=root_fd)
        except FileNotFoundError:
            pass
        raise
    finally:
        os.close(root_fd)


def read_private_file_at(directory_fd: int, name: str) -> bytes:
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
        dir_fd=directory_fd,
    )
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) not in PROBE.PRIVATE_FILE_MODES
        ):
            raise DeployError("evidence file is not owner-only and regular")
        chunks: list[bytes] = []
        size = 0
        while True:
            chunk = os.read(descriptor, 64 * 1024)
            if not chunk:
                break
            size += len(chunk)
            if size > MAX_ADB_OUTPUT:
                raise DeployError("evidence file exceeded the bounded size")
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def build_rc_candidate(current: bytes) -> bytes:
    if BOOT_LINE in current:
        return current
    if b"/data/u60/start-current.sh" in current:
        raise DeployError(
            "rc.local contains an unrecognized U60 start-current reference"
        )
    lines = current.splitlines(keepends=True)
    exits = [index for index, line in enumerate(lines) if line.strip() == b"exit 0"]
    if len(exits) != 1:
        raise DeployError("rc.local does not have exactly one exit 0 insertion point")
    lines.insert(exits[0], BOOT_LINE)
    return b"".join(lines)


def install_boot_hook(before_rc: bytes, metadata: dict[str, int]) -> bool:
    candidate = build_rc_candidate(before_rc)
    if candidate == before_rc:
        return False
    start_digest = sha256_file(START_CURRENT_SOURCE)
    candidate_digest = sha256_bytes(candidate)
    with tempfile.TemporaryDirectory(prefix="u60-v1-boot-") as temporary:
        candidate_path = Path(temporary) / "rc.local.candidate"
        candidate_path.write_bytes(candidate)
        adb_push(START_CURRENT_SOURCE, f"{DEVICE_ROOT}/start-current.sh.new")
        adb_push(candidate_path, f"{DEVICE_ROOT}/runtime/rc.local.candidate")
    mode = format(metadata["mode"], "o")
    uid = metadata["uid"]
    gid = metadata["gid"]
    script = (
        f"set -eu; [ -L {DEVICE_ROOT}/current ]; "
        f'current=$(readlink {DEVICE_ROOT}/current); case "$current" in '
        f"{DEVICE_ROOT}/releases/[0-9a-f]*) release=$current;; "
        f"releases/[0-9a-f]*) release={DEVICE_ROOT}/$current;; *) exit 1;; esac; "
        f'rid=${{release##*/}}; [ "${{#rid}}" -eq 64 ]; '
        'case "$rid" in *[!0-9a-f]*) exit 1;; esac; '
        f"ap=$(sed -n '1p' {DEVICE_ROOT}/runtime/agent.pid); "
        f"dp=$(sed -n '1p' {DEVICE_ROOT}/runtime/dropbear.pid); "
        'case "$ap:$dp" in *[!0-9:]*|:*) exit 1;; esac; '
        '[ "$(readlink /proc/$ap/exe)" = "$release/zte-agent" ]; '
        '[ "$(readlink /proc/$dp/exe)" = "$release/dropbearmulti" ]; '
        f"[ -s {DEVICE_ROOT}/ssh/authorized_keys ]; "
        f"[ \"$(awk 'NF && $1 !~ /^#/ {{c++}} END {{print c+0}}' {DEVICE_ROOT}/ssh/authorized_keys)\" -eq 2 ]; "
        f"set -eu; [ \"$(sha256sum {DEVICE_ROOT}/start-current.sh.new | cut -d' ' -f1)\" = {start_digest} ]; "
        f"[ \"$(sha256sum {DEVICE_ROOT}/runtime/rc.local.candidate | cut -d' ' -f1)\" = {candidate_digest} ]; "
        f"sh -n {DEVICE_ROOT}/start-current.sh.new; sh -n {DEVICE_ROOT}/runtime/rc.local.candidate; "
        f"chmod 700 {DEVICE_ROOT}/start-current.sh.new; chmod 755 {DEVICE_ROOT}/runtime/rc.local.candidate; "
        f"mv -f {DEVICE_ROOT}/start-current.sh.new {DEVICE_ROOT}/start-current.sh; "
        f"cp {DEVICE_ROOT}/runtime/rc.local.candidate /etc/rc.local.u60-v1-new; "
        f"chown {uid}:{gid} /etc/rc.local.u60-v1-new; chmod {mode} /etc/rc.local.u60-v1-new; "
        "sh -n /etc/rc.local.u60-v1-new; mv -f /etc/rc.local.u60-v1-new /etc/rc.local; "
        f"rm -f {DEVICE_ROOT}/runtime/rc.local.candidate; "
        f"[ \"$(sha256sum /etc/rc.local | cut -d' ' -f1)\" = {candidate_digest} ]"
    )
    adb_shell(script, timeout=30)
    return True


def read_existing_authorized_keys() -> bytes | None:
    result = run(
        [
            "adb",
            "exec-out",
            "sh",
            "-c",
            f"if [ -f {DEVICE_ROOT}/ssh/authorized_keys ] && "
            f"[ ! -L {DEVICE_ROOT}/ssh/authorized_keys ]; then "
            f"cat {DEVICE_ROOT}/ssh/authorized_keys; else exit 3; fi",
        ],
        timeout=10,
        limit=64 * 1024,
        check=False,
    )
    if result.returncode == 3:
        return None
    if result.returncode != 0:
        raise DeployError("could not safely read the existing authorized_keys")
    return result.stdout


def validate_authorized_keys(path: Path) -> bytes:
    if path.is_symlink() or not path.is_file():
        raise DeployError("authorized_keys input must be a physical regular file")
    content = path.read_bytes()
    if len(content) > 32 * 1024 or b"PRIVATE KEY" in content or b"\x00" in content:
        raise DeployError("authorized_keys input is invalid")
    try:
        lines = [
            line.strip()
            for line in content.decode("ascii").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
    except UnicodeError as error:
        raise DeployError("authorized_keys must be ASCII") from error
    if len(lines) != 2:
        raise DeployError("authorized_keys must contain exactly two keys")
    blobs: set[str] = set()
    normalized: list[str] = []
    for line in lines:
        fields = line.split()
        if len(fields) < 2 or fields[0] not in {
            "ssh-ed25519",
            "ecdsa-sha2-nistp256",
        }:
            raise DeployError("only Ed25519 or P-256 public keys are accepted")
        if not re.fullmatch(r"[A-Za-z0-9+/=]{32,2048}", fields[1]):
            raise DeployError("authorized key payload is invalid")
        if fields[1] in blobs:
            raise DeployError("the two SSH keys must be independent")
        blobs.add(fields[1])
        normalized.append(f"{fields[0]} {fields[1]}")
    return ("\n".join(normalized) + "\n").encode("ascii")


def install_ssh(release_id: str, authorized_keys: bytes) -> dict[str, Any]:
    release = f"{DEVICE_ROOT}/releases/{release_id}"
    adb_shell(verify_device_release_script(release_id, release), timeout=45)
    with tempfile.TemporaryDirectory(prefix="u60-v1-ssh-") as temporary:
        local = Path(temporary) / "authorized_keys"
        local.write_bytes(authorized_keys)
        os.chmod(local, 0o600)
        adb_push(local, f"{DEVICE_ROOT}/runtime/authorized_keys.new")
    digest = sha256_bytes(authorized_keys)
    script = (
        f"set -eu; umask 077; mkdir -p {DEVICE_ROOT}/ssh; chmod 700 {DEVICE_ROOT}/ssh; "
        f"[ ! -L {DEVICE_ROOT}/ssh ]; [ ! -L {DEVICE_ROOT}/runtime/authorized_keys.new ]; "
        f"[ \"$(sha256sum {DEVICE_ROOT}/runtime/authorized_keys.new | cut -d' ' -f1)\" = {digest} ]; "
        f"chmod 600 {DEVICE_ROOT}/runtime/authorized_keys.new; "
        f"mv -f {DEVICE_ROOT}/runtime/authorized_keys.new {DEVICE_ROOT}/ssh/authorized_keys; "
        f"if [ ! -s {DEVICE_ROOT}/ssh/dropbear_ed25519_host_key ]; then "
        f"{release}/dropbearmulti dropbearkey -t ed25519 "
        f"-f {DEVICE_ROOT}/ssh/dropbear_ed25519_host_key >/dev/null; fi; "
        f"[ ! -L {DEVICE_ROOT}/ssh/dropbear_ed25519_host_key ]; "
        f"chmod 600 {DEVICE_ROOT}/ssh/authorized_keys "
        f"{DEVICE_ROOT}/ssh/dropbear_ed25519_host_key; "
        f"{release}/bin/run-dropbear.sh"
    )
    adb_shell(script, timeout=45)
    run(["adb", "forward", "tcp:2222", "tcp:2222"], timeout=10, limit=4096)
    public_host = adb_shell(
        f"{release}/dropbearmulti dropbearkey -y "
        f"-f {DEVICE_ROOT}/ssh/dropbear_ed25519_host_key | "
        "awk '/^ssh-ed25519 / {print $1 \" \" $2; exit}'",
        limit=4096,
    )
    if not public_host.startswith("ssh-ed25519 "):
        raise DeployError("Dropbear host key public readback failed")
    return {
        "release_id": release_id,
        "authorized_keys_sha256": digest,
        "host_public_key_sha256": sha256_bytes(public_host.encode()),
        "dropbear_started": True,
        "password_auth_flags": ["-s", "-g"],
    }


def command_install_ssh(
    arguments: argparse.Namespace,
) -> tuple[dict[str, Any], bytes | None]:
    release_id = require_local_release(arguments.release)
    install_release(arguments.release, release_id)
    authorized = validate_authorized_keys(arguments.authorized_keys)
    previous = read_existing_authorized_keys()
    return install_ssh(release_id, authorized), previous


def verify_one_ssh_key(key: Path, known_hosts: Path) -> None:
    if key.is_symlink() or not key.is_file():
        raise DeployError("SSH identity must be a physical file")
    result = run(
        [
            "ssh",
            "-p",
            "2222",
            "-i",
            str(key),
            "-o",
            "BatchMode=yes",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            f"UserKnownHostsFile={known_hosts}",
            "-o",
            "ConnectTimeout=8",
            "root@127.0.0.1",
            "printf u60-v1-ssh-ok",
        ],
        timeout=15,
        limit=16 * 1024,
    )
    if result.stdout != b"u60-v1-ssh-ok":
        raise DeployError("SSH key did not produce the fixed acceptance response")


def command_verify_ssh(arguments: argparse.Namespace) -> dict[str, Any]:
    run(["adb", "forward", "tcp:2222", "tcp:2222"], timeout=10, limit=4096)
    with tempfile.TemporaryDirectory(prefix="u60-v1-ssh-check-") as temporary:
        known_hosts = Path(temporary) / "known_hosts"
        scan = run(
            ["ssh-keyscan", "-p", "2222", "127.0.0.1"],
            timeout=15,
            limit=64 * 1024,
        )
        if b"ssh-ed25519" not in scan.stdout:
            raise DeployError("SSH host key scan did not return Ed25519")
        known_hosts.write_bytes(scan.stdout)
        os.chmod(known_hosts, 0o600)
        verify_one_ssh_key(arguments.key_one, known_hosts)
        verify_one_ssh_key(arguments.key_two, known_hosts)
        password = run(
            [
                "ssh",
                "-vv",
                "-p",
                "2222",
                "-o",
                "BatchMode=yes",
                "-o",
                "PubkeyAuthentication=no",
                "-o",
                "PreferredAuthentications=password,keyboard-interactive",
                "-o",
                "StrictHostKeyChecking=yes",
                "-o",
                f"UserKnownHostsFile={known_hosts}",
                "-o",
                "ConnectTimeout=8",
                "root@127.0.0.1",
                "true",
            ],
            timeout=15,
            limit=64 * 1024,
            check=False,
        )
        if password.returncode == 0:
            raise DeployError("password-only SSH unexpectedly succeeded")
        diagnostic = password.stderr.decode("utf-8", "replace")
        if "Authentications that can continue: publickey" not in diagnostic:
            raise DeployError("SSH server did not prove a public-key-only method list")
    return {
        "key_one_success": True,
        "key_two_success": True,
        "password_method_absent": True,
    }


def command_canary(arguments: argparse.Namespace) -> dict[str, Any]:
    release_id = require_local_release(arguments.release)
    installed = install_release(arguments.release, release_id)
    start_canary(release_id)
    verify_tls_unauthorized(19443, arguments.ca_cert)
    return {"release_id": release_id, "release_installed": installed, "tls_401": True}


def command_lan_canary(arguments: argparse.Namespace) -> dict[str, Any]:
    release_id = require_local_release(arguments.release)
    installed = install_release(arguments.release, release_id)
    stop_managed_agent("canary.pid")
    stop_managed_agent("agent.pid")
    stop_legacy_canary_without_pid_file()
    assert_no_zte_agent_processes()
    run(
        ["adb", "forward", "--remove", "tcp:19443"],
        timeout=10,
        limit=4096,
        check=False,
    )
    adb_shell(
        f"{DEVICE_ROOT}/releases/{release_id}/bin/run-agent.sh stable", timeout=30
    )
    run(["adb", "forward", "tcp:9443", "tcp:9443"], timeout=10, limit=4096)
    try:
        verify_tls_unauthorized(9443, arguments.ca_cert)
    except BaseException:
        stop_managed_agent("agent.pid")
        run(
            ["adb", "forward", "--remove", "tcp:9443"],
            timeout=10,
            limit=4096,
            check=False,
        )
        raise
    return {
        "release_id": release_id,
        "release_installed": installed,
        "lan_canary": True,
        "tls_401": True,
    }


def command_activate(arguments: argparse.Namespace) -> dict[str, Any]:
    release_id = require_local_release(arguments.release)
    installed = install_release(arguments.release, release_id)
    switch_current(release_id)
    stop_managed_agent("agent.pid")
    adb_shell(
        f"{DEVICE_ROOT}/releases/{release_id}/bin/run-agent.sh stable", timeout=30
    )
    run(["adb", "forward", "tcp:9443", "tcp:9443"], timeout=10, limit=4096)
    try:
        verify_tls_unauthorized(9443, arguments.ca_cert)
    except BaseException:
        stop_managed_agent("agent.pid")
        links = read_release_links()
        if links.get("previous") is not None:
            rollback_current()
        else:
            adb_shell(f"rm -f {DEVICE_ROOT}/current")
        raise
    return {"release_id": release_id, "release_installed": installed, "tls_401": True}


def command_rollback(_arguments: argparse.Namespace) -> dict[str, Any]:
    return {"release_id": rollback_current(), "rollback": True}


def command_boot_hook(
    _arguments: argparse.Namespace,
    before_rc: bytes,
    metadata: dict[str, int],
) -> dict[str, Any]:
    changed = install_boot_hook(before_rc, metadata)
    return {
        "boot_hook_changed": changed,
        "boot_line_count": read_rc_local().count(BOOT_LINE),
    }


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("canary", "lan-canary", "activate"):
        sub = subparsers.add_parser(name)
        sub.add_argument("--release", type=Path, required=True)
        sub.add_argument("--ca-cert", type=Path, required=True)
    subparsers.add_parser("rollback")
    subparsers.add_parser("boot-hook")
    ssh_parser = subparsers.add_parser("install-ssh")
    ssh_parser.add_argument("--release", type=Path, required=True)
    ssh_parser.add_argument("--authorized-keys", type=Path, required=True)
    verify_ssh = subparsers.add_parser("verify-ssh")
    verify_ssh.add_argument("--key-one", type=Path, required=True)
    verify_ssh.add_argument("--key-two", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    DEVICE_GATE.require_v1_deploy()
    arguments = parse_arguments()
    before: dict[str, Any] | None = None
    before_rc: bytes | None = None
    extra_files: dict[str, bytes] = {}
    try:
        before = capture_invariants()
        before_rc = read_rc_local()
        if arguments.command == "lan-canary" and before["release_links"] != {
            "current": None,
            "previous": None,
        }:
            raise DeployError("LAN canary requires absent current and previous links")
        if arguments.command == "canary":
            details = command_canary(arguments)
        elif arguments.command == "lan-canary":
            details = command_lan_canary(arguments)
        elif arguments.command == "activate":
            details = command_activate(arguments)
        elif arguments.command == "rollback":
            details = command_rollback(arguments)
        elif arguments.command == "install-ssh":
            details, prior_keys = command_install_ssh(arguments)
            if prior_keys is not None:
                extra_files["authorized_keys.before"] = prior_keys
        elif arguments.command == "verify-ssh":
            details = command_verify_ssh(arguments)
        else:
            details = command_boot_hook(
                arguments, before_rc, before["rc_local_metadata"]
            )
        after = capture_invariants()
        allow_rc_change = arguments.command == "boot-hook"
        allow_link_change = arguments.command in {"activate", "rollback"}
        assert_invariants(
            before,
            after,
            allow_rc_local_change=allow_rc_change,
            allow_release_link_change=allow_link_change,
        )
        evidence = write_evidence(
            arguments.command,
            before,
            after,
            details,
            rc_backup=before_rc if allow_rc_change else None,
            extra_files=extra_files,
        )
    except (
        DeployError,
        OSError,
        PROBE.ProbeError,
        subprocess.SubprocessError,
    ) as error:
        if arguments.command == "lan-canary":
            try:
                stop_managed_agent("agent.pid")
                run(
                    ["adb", "forward", "--remove", "tcp:9443"],
                    timeout=10,
                    limit=4096,
                    check=False,
                )
            except BaseException:
                pass
        print(f"V1 deployment refused: {error}", file=sys.stderr)
        return 1
    print(evidence)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
