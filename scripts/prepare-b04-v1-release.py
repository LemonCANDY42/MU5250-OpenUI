#!/usr/bin/env python3
"""Build one immutable, content-addressed HK B04 V1 release on the NAS.

The output contains no certificate, credential, device identifier, private key,
backup material or live configuration. Mutable owner state stays under
``/data/u60/{state,pki,ssh}`` on the device.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
APPROVED_OUTPUT_ROOT = Path("/Volumes/backups/U60-Pro/releases")
WEB_ROOT = ROOT / "web-app" / "dist"
DEVICE_ROOT = ROOT / "device" / "b04-v1"
BUILD_MARKER = b"u60-b04-agent-build-complete-v1\n"
RELEASE_MARKER_PREFIX = "u60-b04-v1-release:"
SAFE_PATH = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_RELEASE_BYTES = 32 * 1024 * 1024
ACCEPTED_DROPBEAR_SHA256 = (
    "c59355b0ba621f105026b91988c17584c555c13cd5a1a485d66243a2f9b8debd"
)


class ReleaseError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def require_physical_file(path: Path, *, max_bytes: int = MAX_FILE_BYTES) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ReleaseError(f"required file is unavailable: {path}") from error
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        raise ReleaseError(f"required path is not a physical regular file: {path}")
    if metadata.st_size <= 0 or metadata.st_size > max_bytes:
        raise ReleaseError(f"required file size is outside the release bound: {path}")
    return metadata


def require_physical_directory(path: Path) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ReleaseError(f"required directory is unavailable: {path}") from error
    if not stat.S_ISDIR(metadata.st_mode) or path.is_symlink():
        raise ReleaseError(f"required directory is not physical: {path}")


def validate_output_root(path: Path) -> None:
    if path != APPROVED_OUTPUT_ROOT:
        raise ReleaseError(f"output root must be exactly {APPROVED_OUTPUT_ROOT}")
    approved_mount = APPROVED_OUTPUT_ROOT.parent
    require_physical_directory(approved_mount)
    mount = subprocess.run(
        ["mount"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=10,
        text=True,
    )
    marker = " on /Volumes/backups (smbfs,"
    sources = [
        line.split(marker, 1)[0]
        for line in mount.stdout.splitlines()
        if marker in line
    ]
    if mount.returncode != 0 or len(sources) != 1 or not re.fullmatch(
        r"//[^/@\s]+@Marshmallow\._smb\._tcp\.local/backups", sources[0]
    ):
        raise ReleaseError("approved NAS backups share is not mounted")
    path.mkdir(parents=False, exist_ok=True, mode=0o700)
    require_physical_directory(path)


def clean_git_identity() -> dict[str, str]:
    status = subprocess.run(
        ["git", "status", "--porcelain=v1"],
        cwd=ROOT,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=10,
        text=True,
    )
    if status.returncode != 0 or status.stdout:
        raise ReleaseError("control-plane worktree must be clean before release preparation")
    values: dict[str, str] = {}
    for name, revision in (("commit", "HEAD"), ("tree", "HEAD^{tree}")):
        result = subprocess.run(
            ["git", "rev-parse", "--verify", revision],
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=10,
            text=True,
        )
        value = result.stdout.strip()
        if result.returncode != 0 or re.fullmatch(r"[0-9a-f]{40}", value) is None:
            raise ReleaseError(f"could not resolve clean Git {name}")
        values[name] = value
    return values


def load_agent_build(directory: Path) -> dict[str, object]:
    require_physical_directory(directory)
    marker = directory / "build.complete"
    require_physical_file(marker, max_bytes=128)
    if marker.read_bytes() != BUILD_MARKER:
        raise ReleaseError("agent build completion marker is invalid")
    manifest_path = directory / "BUILD-MANIFEST.json"
    agent_path = directory / "zte-agent"
    require_physical_file(manifest_path, max_bytes=64 * 1024)
    metadata = require_physical_file(agent_path)
    try:
        manifest = json.loads(manifest_path.read_text("utf-8"))
        binary = manifest["binary"]
    except (KeyError, TypeError, ValueError, UnicodeError) as error:
        raise ReleaseError("agent build manifest is invalid") from error
    if (
        not isinstance(binary, dict)
        or binary.get("path") != "zte-agent"
        or binary.get("size") != metadata.st_size
        or binary.get("sha256") != sha256_file(agent_path)
        or manifest.get("target") != "aarch64-unknown-linux-musl"
        or manifest.get("profile") != "release"
    ):
        raise ReleaseError("agent build manifest does not bind the selected binary")
    elf = binary.get("elf")
    if not isinstance(elf, dict) or elf != {
        "class": "elf64",
        "endianness": "little",
        "linkage": "static",
        "machine": "aarch64",
        "stripped": True,
    }:
        raise ReleaseError("agent build is not the accepted static stripped AArch64 artifact")
    return manifest


def verify_dropbear(path: Path, expected_sha256: str) -> dict[str, object]:
    metadata = require_physical_file(path)
    if not HEX64.fullmatch(expected_sha256):
        raise ReleaseError("Dropbear expected SHA-256 must be 64 lowercase hex characters")
    if expected_sha256 != ACCEPTED_DROPBEAR_SHA256:
        raise ReleaseError("Dropbear is not the accepted B04 recovery artifact")
    digest = sha256_file(path)
    if digest != expected_sha256:
        raise ReleaseError("Dropbear SHA-256 does not match the accepted B04 recovery artifact")
    result = subprocess.run(
        ["file", "-b", str(path)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=10,
        text=True,
    )
    description = result.stdout.strip()
    if result.returncode != 0 or not all(
        token in description
        for token in ("ELF 64-bit", "ARM aarch64", "statically linked", "stripped")
    ):
        raise ReleaseError("Dropbear is not a static stripped AArch64 ELF")
    return {"sha256": digest, "size": metadata.st_size, "file": description}


def iter_web_files() -> list[tuple[Path, str]]:
    require_physical_directory(WEB_ROOT)
    files: list[tuple[Path, str]] = []
    for root, directories, names in os.walk(WEB_ROOT, followlinks=False):
        root_path = Path(root)
        for directory in directories:
            require_physical_directory(root_path / directory)
        for name in names:
            source = root_path / name
            require_physical_file(source, max_bytes=4 * 1024 * 1024)
            relative = source.relative_to(WEB_ROOT).as_posix()
            files.append((source, f"web/{relative}"))
    if not files or "web/index.html" not in {relative for _, relative in files}:
        raise ReleaseError("canonical web build is empty or missing index.html")
    return sorted(files, key=lambda item: item[1])


def validate_relative_path(value: str) -> None:
    path = PurePosixPath(value)
    if (
        not SAFE_PATH.fullmatch(value)
        or path.is_absolute()
        or ".." in path.parts
        or value.startswith(".")
        or "//" in value
    ):
        raise ReleaseError(f"release path is unsafe: {value!r}")


def copy_physical(source: Path, destination: Path, relative: str, mode: int) -> dict[str, object]:
    validate_relative_path(relative)
    metadata = require_physical_file(source)
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with source.open("rb") as reader, destination.open("xb") as writer:
        shutil.copyfileobj(reader, writer, 1024 * 1024)
        writer.flush()
        os.fsync(writer.fileno())
    os.chmod(destination, mode)
    copied = destination.stat()
    if copied.st_size != metadata.st_size:
        raise ReleaseError("release copy changed size")
    return {
        "path": relative,
        "sha256": sha256_file(destination),
        "size": copied.st_size,
        "mode": format(mode, "04o"),
    }


def write_new(path: Path, content: bytes, mode: int = 0o600) -> None:
    with path.open("xb") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(path, mode)


def verify_existing_release(
    directory: Path,
    release_id: str,
    checksum_bytes: bytes,
    marker: bytes,
) -> None:
    expected = {"release.sha256", "release.complete"}
    for line in checksum_bytes.decode("ascii").splitlines():
        digest, separator, relative = line.partition("  ")
        if not separator or not HEX64.fullmatch(digest):
            raise ReleaseError("release checksum list is malformed")
        validate_relative_path(relative)
        expected.add(relative)
    actual: set[str] = set()
    for root, directories, files in os.walk(directory, followlinks=False):
        root_path = Path(root)
        for name in directories:
            require_physical_directory(root_path / name)
        for name in files:
            path = root_path / name
            require_physical_file(path)
            actual.add(path.relative_to(directory).as_posix())
    if actual != expected:
        raise ReleaseError("existing release file set does not match its checksum list")
    if sha256_file(directory / "release.sha256") != release_id:
        raise ReleaseError("existing release ID is invalid")
    if (directory / "release.sha256").read_bytes() != checksum_bytes:
        raise ReleaseError("existing release checksum list differs")
    if (directory / "release.complete").read_bytes() != marker:
        raise ReleaseError("existing release completion marker differs")
    result = subprocess.run(
        ["sha256sum", "-c", "release.sha256"],
        cwd=directory,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=30,
    )
    if result.returncode != 0:
        raise ReleaseError("existing release payload failed checksum verification")


def build_release(
    agent_build: Path,
    dropbear: Path,
    dropbear_sha256: str,
    output_root: Path,
) -> Path:
    validate_output_root(output_root)
    control_plane_git = clean_git_identity()
    agent_manifest = load_agent_build(agent_build)
    dropbear_record = verify_dropbear(dropbear, dropbear_sha256)

    device_files = [
        (DEVICE_ROOT / "common.sh", "bin/common.sh"),
        (DEVICE_ROOT / "run-agent.sh", "bin/run-agent.sh"),
        (DEVICE_ROOT / "run-dropbear.sh", "bin/run-dropbear.sh"),
        (DEVICE_ROOT / "start-current.sh", "bin/start-current.sh"),
    ]
    for source, _ in device_files:
        require_physical_file(source, max_bytes=128 * 1024)

    staging: Path | None = Path(
        tempfile.mkdtemp(prefix=".u60-release-stage-", dir=output_root)
    )
    os.chmod(staging, 0o700)
    try:
        entries: list[dict[str, object]] = []
        entries.append(
            copy_physical(agent_build / "zte-agent", staging / "zte-agent", "zte-agent", 0o700)
        )
        entries.append(
            copy_physical(dropbear, staging / "dropbearmulti", "dropbearmulti", 0o700)
        )
        for source, relative in device_files:
            entries.append(copy_physical(source, staging / relative, relative, 0o700))
        for source, relative in iter_web_files():
            entries.append(copy_physical(source, staging / relative, relative, 0o600))

        total_bytes = sum(int(entry["size"]) for entry in entries)
        if total_bytes > MAX_RELEASE_BYTES:
            raise ReleaseError("release payload exceeded the fixed size bound")
        manifest = {
            "schema_version": 1,
            "product": "MU5250-OpenUI B04 V1",
            "agent_build": {
                "bundle": agent_build.name,
                "git": agent_manifest.get("git"),
                "target": agent_manifest.get("target"),
            },
            "control_plane": {"git": control_plane_git},
            "dropbear": {
                "version": "2026.94",
                **dropbear_record,
                "password_auth_compiled_out": True,
                "forwarding_compiled_out": True,
            },
            "entries": sorted(entries, key=lambda entry: str(entry["path"])),
        }
        manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
        write_new(staging / "release.manifest.json", manifest_bytes)

        checksum_paths = [Path(str(entry["path"])) for entry in entries]
        checksum_paths.append(Path("release.manifest.json"))
        checksum_lines = []
        for relative in sorted(checksum_paths, key=lambda path: path.as_posix()):
            checksum_lines.append(f"{sha256_file(staging / relative)}  {relative.as_posix()}\n")
        checksum_bytes = "".join(checksum_lines).encode("ascii")
        write_new(staging / "release.sha256", checksum_bytes)
        release_id = hashlib.sha256(checksum_bytes).hexdigest()
        destination = output_root / release_id
        marker = f"{RELEASE_MARKER_PREFIX}{release_id}\n".encode("ascii")
        write_new(staging / "release.complete", marker)

        if destination.exists() or destination.is_symlink():
            if destination.is_symlink() or not destination.is_dir():
                raise ReleaseError(f"release destination is not a physical directory: {destination}")
            verify_existing_release(destination, release_id, checksum_bytes, marker)
            shutil.rmtree(staging)
            staging = None
            return destination
        os.rename(staging, destination)
        staging = None
        return destination
    finally:
        if staging is not None and staging.exists():
            shutil.rmtree(staging)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent-build", type=Path, required=True)
    parser.add_argument("--dropbear", type=Path, required=True)
    parser.add_argument(
        "--dropbear-sha256",
        required=True,
        help="must equal the repository-pinned, real-device-accepted B04 artifact hash",
    )
    parser.add_argument("--output-root", type=Path, default=APPROVED_OUTPUT_ROOT)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        result = build_release(
            arguments.agent_build,
            arguments.dropbear,
            arguments.dropbear_sha256,
            arguments.output_root,
        )
    except (OSError, ReleaseError, subprocess.SubprocessError) as error:
        print(f"release preparation refused: {error}", file=os.sys.stderr)
        return 1
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
