#!/usr/bin/env python3
"""Create, verify and publish one provenance-bound B04 agent build."""

from __future__ import annotations

import argparse
from datetime import UTC, datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
TARGET = "aarch64-unknown-linux-musl"
BINARY = ROOT / "target" / TARGET / "release" / "zte-agent"
RECEIPT = BINARY.with_name("B04-BUILD-RECEIPT.json")
BUILD_MARKER = b"u60-b04-agent-build-complete-v1\n"
EXPECTED_TOOL_VERSIONS = {
    "rustc": "rustc 1.94.0 (4a4ef493e 2026-03-02)",
    "cargo": "cargo 1.94.0 (85eff7c80 2026-01-15)",
    "cargo_zigbuild": "cargo-zigbuild 0.23.0",
    "zig": "0.16.0",
}
FIXED_BUILD_INPUTS = {
    ".cargo/config.toml",
    "Cargo.lock",
    "Cargo.toml",
    "agent/Cargo.toml",
    "scripts/build-b04-agent.sh",
    "scripts/probe-b04-readonly.py",
    "scripts/publish-b04-agent-build.py",
}
RECEIPT_TOP_LEVEL_KEYS = {
    "schema_version",
    "created_at_utc",
    "git",
    "target",
    "profile",
    "recipe",
    "binary",
    "toolchain",
    "source_files",
}
REJECTED_BUILD_ENVIRONMENT = {
    "AR",
    "AR_AARCH64_UNKNOWN_LINUX_MUSL",
    "AR_aarch64_unknown_linux_musl",
    "CC",
    "CC_AARCH64_UNKNOWN_LINUX_MUSL",
    "CC_aarch64_unknown_linux_musl",
    "CFLAGS",
    "CFLAGS_AARCH64_UNKNOWN_LINUX_MUSL",
    "CFLAGS_aarch64_unknown_linux_musl",
    "CXX",
    "CXX_AARCH64_UNKNOWN_LINUX_MUSL",
    "CXX_aarch64_unknown_linux_musl",
    "CXXFLAGS",
    "CXXFLAGS_AARCH64_UNKNOWN_LINUX_MUSL",
    "CXXFLAGS_aarch64_unknown_linux_musl",
    "LDFLAGS",
    "RANLIB",
    "RANLIB_AARCH64_UNKNOWN_LINUX_MUSL",
    "RANLIB_aarch64_unknown_linux_musl",
    "RUSTC",
    "RUSTC_BOOTSTRAP",
    "RUSTC_WORKSPACE_WRAPPER",
    "RUSTC_WRAPPER",
    "STRIP",
    "STRIP_AARCH64_UNKNOWN_LINUX_MUSL",
    "STRIP_aarch64_unknown_linux_musl",
    "TARGET_AR",
    "TARGET_CC",
    "TARGET_CXX",
    "TARGET_RANLIB",
    "TARGET_STRIP",
    "ZIG",
}


class BuildPublishError(RuntimeError):
    pass


def load_nas_boundary() -> Any:
    path = ROOT / "scripts" / "probe-b04-readonly.py"
    spec = importlib.util.spec_from_file_location("u60_probe_boundary", path)
    if spec is None or spec.loader is None:
        raise BuildPublishError("could not load the reviewed NAS publication boundary")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


NAS = load_nas_boundary()


def command_bytes(arguments: list[str], *, limit: int = 1_048_576) -> bytes:
    result = subprocess.run(
        arguments,
        cwd=ROOT,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
        check=False,
    )
    if len(result.stdout) > limit or len(result.stderr) > limit:
        raise BuildPublishError(f"bounded command output exceeded: {arguments[0]}")
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()[:240]
        raise BuildPublishError(f"command failed ({arguments[0]}): {detail}")
    return result.stdout


def command_output(arguments: list[str]) -> str:
    return command_bytes(arguments).decode("utf-8", "strict").strip()


def require_hex_sha(value: str, label: str) -> str:
    if len(value) != 40 or any(
        character not in "0123456789abcdef" for character in value
    ):
        raise BuildPublishError(f"{label} did not resolve to a full lowercase SHA-1")
    return value


def git_identity() -> dict[str, Any]:
    status = command_bytes(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"],
        limit=65_536,
    )
    if status:
        raise BuildPublishError(
            "Git worktree must be clean before receipt verification"
        )
    commit = require_hex_sha(command_output(["git", "rev-parse", "HEAD"]), "Git HEAD")
    tree = require_hex_sha(
        command_output(["git", "rev-parse", "HEAD^{tree}"]), "Git tree"
    )
    source_date_epoch = command_output(["git", "show", "-s", "--format=%ct", "HEAD"])
    if not source_date_epoch.isdigit():
        raise BuildPublishError("Git commit time was not an unsigned integer")
    return {
        "commit": commit,
        "tree": tree,
        "source_date_epoch": int(source_date_epoch),
    }


def validate_build_environment(git: dict[str, Any]) -> None:
    expected = {
        "CARGO_INCREMENTAL": "0",
        "RUSTFLAGS": f"--remap-path-prefix={ROOT}=/src",
        "SOURCE_DATE_EPOCH": str(git["source_date_epoch"]),
    }
    for name, value in expected.items():
        if os.environ.get(name) != value:
            raise BuildPublishError(f"fresh build requires canonical {name}")
    for name in os.environ:
        rejected = name in REJECTED_BUILD_ENVIRONMENT or name in {
            "CARGO_ENCODED_RUSTFLAGS",
            "CARGO_BUILD_RUSTFLAGS",
            "CARGO_BUILD_RUSTC",
            "CARGO_BUILD_RUSTC_WRAPPER",
            "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER",
            "CARGO_BUILD_TARGET",
            "CARGO_BUILD_TARGET_DIR",
            "CARGO_TARGET_DIR",
        }
        rejected = rejected or (
            name.startswith("CARGO_ZIGBUILD_") and name != "CARGO_ZIGBUILD_PYTHON_PATH"
        )
        rejected = rejected or name.startswith(
            ("CARGO_ALIAS_", "CARGO_BUILD_", "CARGO_PROFILE_", "CARGO_TARGET_")
        )
        if rejected:
            raise BuildPublishError(f"fresh build environment contains {name}")

    cargo_home = Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo"))
    for filename in ("config", "config.toml"):
        if (cargo_home / filename).exists():
            raise BuildPublishError("global Cargo configuration is not accepted")
    parent = ROOT.parent
    while parent != parent.parent:
        for filename in ("config", "config.toml"):
            if (parent / ".cargo" / filename).exists():
                raise BuildPublishError("ancestor Cargo configuration is not accepted")
        parent = parent.parent


def run_fresh_build_command(arguments: list[str]) -> None:
    result = subprocess.run(
        arguments,
        cwd=ROOT,
        stdin=subprocess.DEVNULL,
        timeout=1800,
        check=False,
    )
    if result.returncode != 0:
        raise BuildPublishError(f"fresh build command failed: {' '.join(arguments)}")


def purge_owned_regular_outputs_at(
    directory_fd: int, filenames: tuple[str, ...]
) -> None:
    directory = os.fstat(directory_fd)
    if (
        not stat.S_ISDIR(directory.st_mode)
        or directory.st_uid != os.getuid()
        or stat.S_IMODE(directory.st_mode) & 0o022
    ):
        raise BuildPublishError("build output directory is not exclusively writable")
    existing: dict[str, tuple[int, int, int, int]] = {}
    for filename in filenames:
        try:
            metadata = os.stat(filename, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise BuildPublishError(
                "stale build output is not an owner-controlled file"
            )
        existing[filename] = (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_uid,
            stat.S_IFMT(metadata.st_mode),
        )
    for filename, expected in existing.items():
        metadata = os.stat(filename, dir_fd=directory_fd, follow_symlinks=False)
        observed = (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_uid,
            stat.S_IFMT(metadata.st_mode),
        )
        if observed != expected:
            raise BuildPublishError("stale build output changed before purge")
    for filename in existing:
        os.unlink(filename, dir_fd=directory_fd)
    if existing:
        os.fsync(directory_fd)


def purge_stale_build_outputs() -> None:
    if not BINARY.parent.exists():
        return
    ensure_physical_local_path(BINARY.parent)
    directory_fd = os.open(
        BINARY.parent,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
    )
    try:
        purge_owned_regular_outputs_at(directory_fd, (BINARY.name, RECEIPT.name))
    finally:
        os.close(directory_fd)


def tracked_build_input_paths(commit: str) -> list[str]:
    tracked = command_output(
        ["git", "ls-tree", "-r", "--name-only", commit]
    ).splitlines()
    paths = set(FIXED_BUILD_INPUTS)
    paths.update(path for path in tracked if path.endswith(".rs"))
    paths.update(path for path in tracked if path.endswith("Cargo.toml"))
    missing = paths.difference(tracked)
    if missing:
        raise BuildPublishError(
            f"required build input is not tracked: {sorted(missing)[0]}"
        )
    return sorted(paths)


def source_records(commit: str) -> list[dict[str, str]]:
    records = []
    for relative in tracked_build_input_paths(commit):
        path = ROOT / relative
        if path.is_symlink() or not path.is_file():
            raise BuildPublishError(f"build input is missing or a symlink: {relative}")
        local = path.read_bytes()
        committed = command_bytes(["git", "show", f"{commit}:{relative}"])
        if committed != local:
            raise BuildPublishError(f"build input does not match Git HEAD: {relative}")
        records.append({"path": relative, "sha256": hashlib.sha256(local).hexdigest()})
    return records


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def physical_executable(command: str) -> Path:
    selected = shutil.which(command)
    if not selected:
        raise BuildPublishError(f"required executable is unavailable: {command}")
    resolved = Path(selected).resolve(strict=True)
    metadata = resolved.stat()
    if not stat.S_ISREG(metadata.st_mode) or not os.access(resolved, os.X_OK):
        raise BuildPublishError(
            f"required executable is not a regular executable: {command}"
        )
    return resolved


def executable_identity(name: str, path: Path, version: str) -> dict[str, str]:
    return {"name": name, "version": version, "sha256": sha256_path(path)}


def tool_identities() -> dict[str, dict[str, str]]:
    python_selected = os.environ.get("CARGO_ZIGBUILD_PYTHON_PATH")
    if not python_selected or not os.path.isabs(python_selected):
        raise BuildPublishError(
            "CARGO_ZIGBUILD_PYTHON_PATH must be an absolute executable path"
        )
    python_command = Path(python_selected)
    if not python_command.is_file() or not os.access(python_command, os.X_OK):
        raise BuildPublishError(
            "CARGO_ZIGBUILD_PYTHON_PATH is not an executable Python entry point"
        )
    python_path = python_command.resolve(strict=True)
    runtime_path = Path(sys.executable).resolve(strict=True)
    if python_path != runtime_path or not os.access(python_path, os.X_OK):
        raise BuildPublishError(
            "publisher must run with the selected CARGO_ZIGBUILD_PYTHON_PATH runtime"
        )

    rustc = physical_executable("rustc")
    cargo = physical_executable("cargo")
    cargo_zigbuild = physical_executable("cargo-zigbuild")
    observed_versions = {
        "rustc": command_output([str(rustc), "--version"]),
        "cargo": command_output([str(cargo), "--version"]),
        "cargo_zigbuild": command_output([str(cargo_zigbuild), "--version"]),
        "zig": command_output([str(python_command), "-m", "ziglang", "version"]),
    }
    if observed_versions != EXPECTED_TOOL_VERSIONS:
        raise BuildPublishError(
            "cross-build tool versions do not match the pinned recipe"
        )

    zig_path_text = command_output(
        [
            str(python_command),
            "-c",
            (
                "import pathlib,ziglang; "
                "print(pathlib.Path(ziglang.__file__).with_name('zig').resolve())"
            ),
        ]
    )
    zig_path = Path(zig_path_text).resolve(strict=True)
    if not stat.S_ISREG(zig_path.stat().st_mode) or not os.access(zig_path, os.X_OK):
        raise BuildPublishError("ziglang did not resolve to a regular Zig executable")

    return {
        "rustc": executable_identity("rustc", rustc, observed_versions["rustc"]),
        "cargo": executable_identity("cargo", cargo, observed_versions["cargo"]),
        "cargo_zigbuild": executable_identity(
            "cargo-zigbuild", cargo_zigbuild, observed_versions["cargo_zigbuild"]
        ),
        "python": executable_identity(
            "python", python_path, f"Python {platform.python_version()}"
        ),
        "zig": executable_identity("zig", zig_path, observed_versions["zig"]),
    }


def ensure_physical_local_path(path: Path) -> None:
    try:
        relative = path.relative_to(ROOT)
    except ValueError as error:
        raise BuildPublishError("local artifact path escaped the repository") from error
    current = ROOT
    if current.is_symlink():
        raise BuildPublishError("repository root must not be a symlink")
    for component in relative.parts:
        current = current / component
        if current.is_symlink():
            raise BuildPublishError("local artifact path contains a symlink")


def open_local_regular(path: Path, *, owner_mode: int | None = None) -> int:
    ensure_physical_local_path(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
        os.close(descriptor)
        raise BuildPublishError(
            "local artifact is not an owner-controlled regular file"
        )
    if owner_mode is not None and stat.S_IMODE(metadata.st_mode) != owner_mode:
        os.close(descriptor)
        raise BuildPublishError(f"local artifact must have mode {owner_mode:04o}")
    return descriptor


def fd_fingerprint(descriptor: int) -> tuple[int, int, int, int, int, int, int]:
    metadata = os.fstat(descriptor)
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_uid,
        stat.S_IFMT(metadata.st_mode),
    )


def pread_exact(descriptor: int, size: int, offset: int) -> bytes:
    result = bytearray()
    while len(result) < size:
        chunk = os.pread(descriptor, size - len(result), offset + len(result))
        if not chunk:
            break
        result.extend(chunk)
    return bytes(result)


def sha256_fd(descriptor: int) -> str:
    digest = hashlib.sha256()
    offset = 0
    while True:
        chunk = os.pread(descriptor, 1024 * 1024, offset)
        if not chunk:
            return digest.hexdigest()
        digest.update(chunk)
        offset += len(chunk)


def verify_static_aarch64_elf_fd(descriptor: int) -> dict[str, Any]:
    size = os.fstat(descriptor).st_size
    if not 262_144 <= size <= 12_582_912:
        raise BuildPublishError("binary size is outside the 256 KiB to 12 MiB window")
    header = pread_exact(descriptor, 64, 0)
    if len(header) != 64 or header[:4] != b"\x7fELF":
        raise BuildPublishError("binary is not ELF")
    if header[4:6] != b"\x02\x01" or header[6] != 1:
        raise BuildPublishError("binary is not ELF64 little-endian version 1")
    object_type, machine = struct.unpack_from("<HH", header, 16)
    if object_type != 2 or machine != 183:
        raise BuildPublishError("binary is not an AArch64 ET_EXEC artifact")
    program_offset = struct.unpack_from("<Q", header, 32)[0]
    section_offset = struct.unpack_from("<Q", header, 40)[0]
    program_entry_size, program_count = struct.unpack_from("<HH", header, 54)
    section_entry_size, section_count = struct.unpack_from("<HH", header, 58)
    if program_entry_size < 56 or program_count == 0:
        raise BuildPublishError("ELF program-header table is invalid")
    if program_offset + program_entry_size * program_count > size:
        raise BuildPublishError("ELF program-header table exceeds the binary")
    for index in range(program_count):
        entry = pread_exact(descriptor, 4, program_offset + index * program_entry_size)
        if len(entry) != 4:
            raise BuildPublishError("ELF program-header entry is truncated")
        if struct.unpack("<I", entry)[0] in {2, 3}:
            raise BuildPublishError("ELF contains a dynamic segment or interpreter")
    if section_count:
        if (
            section_entry_size < 64
            or section_offset + section_entry_size * section_count > size
        ):
            raise BuildPublishError("ELF section-header table is invalid")
        for index in range(section_count):
            entry = pread_exact(
                descriptor, 4, section_offset + index * section_entry_size + 4
            )
            if len(entry) != 4:
                raise BuildPublishError("ELF section-header entry is truncated")
            if struct.unpack("<I", entry)[0] == 2:
                raise BuildPublishError("ELF still contains a static symbol table")
    return {
        "class": "elf64",
        "endianness": "little",
        "machine": "aarch64",
        "linkage": "static",
        "stripped": True,
    }


def binary_facts(descriptor: int) -> dict[str, Any]:
    before = fd_fingerprint(descriptor)
    elf = verify_static_aarch64_elf_fd(descriptor)
    digest = sha256_fd(descriptor)
    if fd_fingerprint(descriptor) != before:
        raise BuildPublishError("binary changed while it was being inspected")
    return {"path": "zte-agent", "size": before[2], "sha256": digest, "elf": elf}


def portable_receipt(
    *,
    created_at: str,
    git: dict[str, Any],
    binary: dict[str, Any],
    tools: dict[str, dict[str, str]],
    sources: list[dict[str, str]],
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "created_at_utc": created_at,
        "git": {"commit": git["commit"], "tree": git["tree"]},
        "target": TARGET,
        "profile": "release",
        "recipe": {
            "command": ["cargo", "build-b04"],
            "locked": True,
            "clean_target_profile_first": True,
            "cargo_incremental": "0",
            "source_date_epoch": git["source_date_epoch"],
            "rustflags": "--remap-path-prefix=<repository-root>=/src",
        },
        "binary": binary,
        "toolchain": tools,
        "source_files": sources,
    }


def assert_no_host_paths(document: dict[str, Any]) -> None:
    encoded = json.dumps(document, sort_keys=True)
    forbidden = {str(ROOT), str(Path.home())}
    if any(value and value in encoded for value in forbidden):
        raise BuildPublishError("build metadata contains a host-specific path")


def validate_created_at(value: Any) -> None:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise BuildPublishError("receipt creation time is not canonical UTC")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise BuildPublishError("receipt creation time is invalid") from error
    if parsed.tzinfo != UTC:
        raise BuildPublishError("receipt creation time is not UTC")


def validate_receipt_document(observed: Any, expected: dict[str, Any]) -> None:
    if not isinstance(observed, dict) or set(observed) != RECEIPT_TOP_LEVEL_KEYS:
        raise BuildPublishError("receipt top-level contract is invalid")
    validate_created_at(observed["created_at_utc"])
    candidate = dict(expected)
    candidate["created_at_utc"] = observed["created_at_utc"]
    if observed != candidate:
        raise BuildPublishError(
            "receipt does not match the current clean build identity"
        )
    assert_no_host_paths(observed)


def receipt_bytes(document: dict[str, Any]) -> bytes:
    assert_no_host_paths(document)
    return (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()


def write_exclusive_receipt_at(parent_fd: int, filename: str, content: bytes) -> None:
    descriptor: int | None = None
    created = False
    try:
        descriptor = os.open(
            filename,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=parent_fd,
        )
        created = True
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) != 0o600
        ):
            raise BuildPublishError("local build receipt is not owner-only mode 0600")
        offset = 0
        while offset < len(content):
            offset += os.write(descriptor, content[offset:])
        os.fsync(descriptor)
        os.fsync(parent_fd)
    except BaseException:
        if descriptor is not None:
            os.close(descriptor)
            descriptor = None
        if created:
            try:
                os.unlink(filename, dir_fd=parent_fd)
            except FileNotFoundError:
                pass
        raise
    finally:
        if descriptor is not None:
            os.close(descriptor)


def build_and_write_receipt() -> str:
    git_before = git_identity()
    validate_build_environment(git_before)
    tools_before = tool_identities()
    sources_before = source_records(git_before["commit"])

    run_fresh_build_command(["cargo", "clean", "--target", TARGET, "--release"])
    purge_stale_build_outputs()
    if os.path.lexists(BINARY) or os.path.lexists(RECEIPT):
        raise BuildPublishError("cargo clean left a stale B04 binary or receipt")
    run_fresh_build_command(["cargo", "build-b04"])

    binary_fd = open_local_regular(BINARY)
    try:
        binary_fingerprint = fd_fingerprint(binary_fd)
        binary = binary_facts(binary_fd)
        git_after = git_identity()
        tools_after = tool_identities()
        sources_after = source_records(git_after["commit"])
        if git_after != git_before or tools_after != tools_before:
            raise BuildPublishError("source or tool identity changed during the build")
        if sources_after != sources_before:
            raise BuildPublishError("build inputs changed during the build")
        if fd_fingerprint(binary_fd) != binary_fingerprint:
            raise BuildPublishError("binary changed after the fresh build")
        created_at = (
            datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")
        )
        content = receipt_bytes(
            portable_receipt(
                created_at=created_at,
                git=git_before,
                binary=binary,
                tools=tools_before,
                sources=sources_before,
            )
        )
        ensure_physical_local_path(RECEIPT.parent)
        parent_fd = os.open(
            RECEIPT.parent,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
        try:
            write_exclusive_receipt_at(parent_fd, RECEIPT.name, content)
            if fd_fingerprint(binary_fd) != binary_fingerprint:
                os.unlink(RECEIPT.name, dir_fd=parent_fd)
                raise BuildPublishError(
                    "binary changed while the receipt was committed"
                )
        finally:
            os.close(parent_fd)
    finally:
        os.close(binary_fd)
    return hashlib.sha256(content).hexdigest()


def read_receipt_fd(descriptor: int) -> tuple[dict[str, Any], bytes]:
    size = os.fstat(descriptor).st_size
    if size <= 0 or size > 1_048_576:
        raise BuildPublishError("receipt size is outside the accepted window")
    content = pread_exact(descriptor, size, 0)
    if len(content) != size:
        raise BuildPublishError("receipt was truncated while reading")
    try:
        document = json.loads(content)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise BuildPublishError("receipt is not canonical JSON data") from error
    return document, content


def open_verified_bundle() -> tuple[int, int, dict[str, Any], str]:
    receipt_fd = open_local_regular(RECEIPT, owner_mode=0o600)
    binary_fd: int | None = None
    try:
        receipt_fingerprint = fd_fingerprint(receipt_fd)
        document, content = read_receipt_fd(receipt_fd)
        binary_fd = open_local_regular(BINARY)
        binary = binary_facts(binary_fd)
        git = git_identity()
        expected = portable_receipt(
            created_at="replaced-by-validator",
            git=git,
            binary=binary,
            tools=tool_identities(),
            sources=source_records(git["commit"]),
        )
        validate_receipt_document(document, expected)
        if fd_fingerprint(receipt_fd) != receipt_fingerprint:
            raise BuildPublishError("receipt changed while it was being verified")
        return receipt_fd, binary_fd, document, hashlib.sha256(content).hexdigest()
    except BaseException:
        if binary_fd is not None:
            os.close(binary_fd)
        os.close(receipt_fd)
        raise


def copy_fd_at(directory_fd: int, filename: str, source_fd: int) -> None:
    source_fingerprint = fd_fingerprint(source_fd)
    destination: int | None = None
    try:
        destination = os.open(
            filename,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=directory_fd,
        )
        metadata = os.fstat(destination)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) not in NAS.PRIVATE_FILE_MODES
        ):
            raise BuildPublishError("NAS did not preserve an owner-only file mode")
        offset = 0
        while offset < source_fingerprint[2]:
            chunk = os.pread(
                source_fd, min(1024 * 1024, source_fingerprint[2] - offset), offset
            )
            if not chunk:
                raise BuildPublishError("source artifact was truncated during copy")
            written = 0
            while written < len(chunk):
                written += os.write(destination, chunk[written:])
            offset += len(chunk)
        os.fsync(destination)
        if fd_fingerprint(source_fd) != source_fingerprint:
            raise BuildPublishError("source artifact changed during copy")
    except BaseException:
        if destination is not None:
            os.close(destination)
            destination = None
        try:
            os.unlink(filename, dir_fd=directory_fd)
        except FileNotFoundError:
            pass
        raise
    finally:
        if destination is not None:
            os.close(destination)


def hash_file_at(directory_fd: int, filename: str) -> tuple[int, str]:
    descriptor = os.open(
        filename,
        os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
        dir_fd=directory_fd,
    )
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) not in NAS.PRIVATE_FILE_MODES
        ):
            raise BuildPublishError("published artifact is not owner-only")
        before = fd_fingerprint(descriptor)
        digest = sha256_fd(descriptor)
        if fd_fingerprint(descriptor) != before:
            raise BuildPublishError("published artifact changed while hashing")
        return metadata.st_size, digest
    finally:
        os.close(descriptor)


def build_marker_is_valid(directory_fd: int) -> bool:
    try:
        descriptor = os.open(
            "build.complete",
            os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=directory_fd,
        )
    except OSError:
        return False
    try:
        metadata = os.fstat(descriptor)
        content = os.read(descriptor, len(BUILD_MARKER) + 1)
        return (
            stat.S_ISREG(metadata.st_mode)
            and metadata.st_uid == os.getuid()
            and stat.S_IMODE(metadata.st_mode) in NAS.PRIVATE_FILE_MODES
            and content == BUILD_MARKER
        )
    finally:
        os.close(descriptor)


def write_build_marker(directory_fd: int) -> None:
    try:
        NAS.atomic_write_at(directory_fd, "build.complete", BUILD_MARKER)
        os.fsync(directory_fd)
        if not build_marker_is_valid(directory_fd):
            raise BuildPublishError("build marker did not survive exact read-back")
    except BaseException:
        try:
            os.unlink("build.complete", dir_fd=directory_fd)
        except FileNotFoundError:
            pass
        raise


def publish(output_root: Path) -> Path:
    receipt_fd, binary_fd, receipt, receipt_sha = open_verified_bundle()
    output_root_fd: int | None = None
    try:
        output_root_fd = NAS.open_validated_output_root(output_root)
        captured_at = (
            datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")
        )
        manifest = {
            "schema_version": 1,
            "captured_at_utc": captured_at,
            "git": receipt["git"],
            "target": receipt["target"],
            "profile": receipt["profile"],
            "binary": receipt["binary"],
            "build_receipt": {
                "path": RECEIPT.name,
                "size": os.fstat(receipt_fd).st_size,
                "sha256": receipt_sha,
            },
        }
        assert_no_host_paths(manifest)
        manifest_bytes = (
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        ).encode()
        result_name = (
            f"B04-agent-build-{receipt['git']['commit'][:12]}-"
            f"{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}"
        )
        result_fd = NAS.create_private_result_directory(output_root_fd, result_name)
        try:
            copy_fd_at(result_fd, "zte-agent", binary_fd)
            copy_fd_at(result_fd, RECEIPT.name, receipt_fd)
            NAS.atomic_write_at(result_fd, "BUILD-MANIFEST.json", manifest_bytes)
            os.fsync(result_fd)
            binary_size, binary_sha = hash_file_at(result_fd, "zte-agent")
            receipt_size, published_receipt_sha = hash_file_at(result_fd, RECEIPT.name)
            manifest_size, manifest_sha = hash_file_at(result_fd, "BUILD-MANIFEST.json")
            if (binary_size, binary_sha) != (
                receipt["binary"]["size"],
                receipt["binary"]["sha256"],
            ):
                raise BuildPublishError("NAS binary did not match the build receipt")
            if (receipt_size, published_receipt_sha) != (
                manifest["build_receipt"]["size"],
                receipt_sha,
            ):
                raise BuildPublishError("NAS receipt did not match the local receipt")
            if (manifest_size, manifest_sha) != (
                len(manifest_bytes),
                hashlib.sha256(manifest_bytes).hexdigest(),
            ):
                raise BuildPublishError("NAS manifest did not survive exact read-back")
            write_build_marker(result_fd)
        finally:
            os.close(result_fd)
        return NAS.APPROVED_OUTPUT_ROOT / result_name
    finally:
        if output_root_fd is not None:
            os.close(output_root_fd)
        os.close(binary_fd)
        os.close(receipt_fd)


def synthetic_elf(*, program_type: int = 1, machine: int = 183) -> bytes:
    image = bytearray(120)
    image[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHI", image, 16, 2, machine, 1)
    struct.pack_into("<Q", image, 32, 64)
    struct.pack_into("<HH", image, 52, 64, 56)
    struct.pack_into("<H", image, 56, 1)
    struct.pack_into("<HH", image, 58, 64, 0)
    struct.pack_into("<I", image, 64, program_type)
    return bytes(image)


def self_test() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        valid_content = synthetic_elf() + bytes(262_144)
        valid = root / "valid"
        valid.write_bytes(valid_content)
        valid_fd = os.open(valid, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            assert verify_static_aarch64_elf_fd(valid_fd)["linkage"] == "static"
        finally:
            os.close(valid_fd)
        for name, image in (
            ("dynamic", synthetic_elf(program_type=2)),
            ("interpreter", synthetic_elf(program_type=3)),
            ("wrong-machine", synthetic_elf(machine=62)),
        ):
            path = root / name
            path.write_bytes(image + bytes(262_144))
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
            try:
                try:
                    verify_static_aarch64_elf_fd(descriptor)
                except BuildPublishError:
                    pass
                else:
                    raise AssertionError(f"unsafe synthetic ELF was accepted: {name}")
            finally:
                os.close(descriptor)

        expected_receipt = {
            "schema_version": 1,
            "created_at_utc": "replaced-by-validator",
            "git": {"commit": "a" * 40, "tree": "b" * 40},
            "target": TARGET,
            "profile": "release",
            "recipe": {},
            "binary": {},
            "toolchain": {},
            "source_files": [],
        }
        observed_receipt = dict(expected_receipt)
        observed_receipt["created_at_utc"] = "2026-08-16T00:00:00Z"
        validate_receipt_document(observed_receipt, expected_receipt)
        mutated_receipt = dict(observed_receipt)
        mutated_receipt["target"] = "x86_64-unknown-linux-musl"
        try:
            validate_receipt_document(mutated_receipt, expected_receipt)
        except BuildPublishError:
            pass
        else:
            raise AssertionError("mutated receipt was accepted")

        receipt_directory = root / "receipt"
        receipt_directory.mkdir(mode=0o700)
        existing_receipt = receipt_directory / "existing.json"
        existing_receipt.write_bytes(b"existing receipt must survive\n")
        os.chmod(existing_receipt, 0o600)
        receipt_directory_fd = os.open(
            receipt_directory,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
        try:
            try:
                write_exclusive_receipt_at(
                    receipt_directory_fd, existing_receipt.name, b"replacement\n"
                )
            except FileExistsError:
                pass
            else:
                raise AssertionError("existing receipt was unexpectedly replaced")
            assert existing_receipt.read_bytes() == b"existing receipt must survive\n"
        finally:
            os.close(receipt_directory_fd)

        purge_directory = root / "purge"
        purge_directory.mkdir(mode=0o700)
        (purge_directory / "binary").write_bytes(b"old generated binary")
        (purge_directory / "receipt").write_bytes(b"old generated receipt")
        purge_directory_fd = os.open(
            purge_directory,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
        try:
            purge_owned_regular_outputs_at(purge_directory_fd, ("binary", "receipt"))
            assert not (purge_directory / "binary").exists()
            assert not (purge_directory / "receipt").exists()
            (purge_directory / "binary").write_bytes(b"must survive unsafe set")
            (purge_directory / "target").write_bytes(b"target")
            (purge_directory / "receipt").symlink_to("target")
            try:
                purge_owned_regular_outputs_at(
                    purge_directory_fd, ("binary", "receipt")
                )
            except BuildPublishError:
                pass
            else:
                raise AssertionError("symlinked stale output was accepted")
            assert (purge_directory / "binary").read_bytes() == (
                b"must survive unsafe set"
            )
            assert (purge_directory / "receipt").is_symlink()
        finally:
            os.close(purge_directory_fd)

        writable_directory = root / "writable-purge"
        writable_directory.mkdir(mode=0o700)
        os.chmod(writable_directory, 0o770)
        (writable_directory / "binary").write_bytes(b"must survive writable dir")
        writable_directory_fd = os.open(
            writable_directory,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
        try:
            try:
                purge_owned_regular_outputs_at(writable_directory_fd, ("binary",))
            except BuildPublishError:
                pass
            else:
                raise AssertionError("group-writable purge directory was accepted")
            assert (writable_directory / "binary").read_bytes() == (
                b"must survive writable dir"
            )
        finally:
            os.close(writable_directory_fd)

        source = root / "source"
        source.write_bytes(valid_content)
        source_fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        original_sha = sha256_fd(source_fd)
        moved = root / "moved"
        os.replace(source, moved)
        source.write_bytes(b"replacement pathname content")
        result = root / "result"
        result.mkdir(mode=0o700)
        result_fd = os.open(
            result, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
        )
        try:
            copy_fd_at(result_fd, "copied", source_fd)
            assert hash_file_at(result_fd, "copied") == (
                len(valid_content),
                original_sha,
            )
        finally:
            os.close(source_fd)

        try:
            real_write = os.write

            def partial_marker_write(descriptor: int, data: bytes) -> int:
                if data == BUILD_MARKER:
                    real_write(descriptor, data[:5])
                    raise OSError("injected partial marker write")
                return real_write(descriptor, data)

            os.write = partial_marker_write
            try:
                try:
                    write_build_marker(result_fd)
                except OSError:
                    pass
                else:
                    raise AssertionError("partial build marker was accepted")
            finally:
                os.write = real_write
            assert not build_marker_is_valid(result_fd)

            real_fsync = os.fsync

            def fail_result_directory_fsync(descriptor: int) -> None:
                if descriptor == result_fd:
                    raise OSError("injected result-directory fsync failure")
                real_fsync(descriptor)

            os.fsync = fail_result_directory_fsync
            try:
                try:
                    write_build_marker(result_fd)
                except OSError:
                    pass
                else:
                    raise AssertionError("build marker survived failed directory fsync")
            finally:
                os.fsync = real_fsync
            assert not build_marker_is_valid(result_fd)

            write_build_marker(result_fd)
            assert build_marker_is_valid(result_fd)
            os.chmod(result / "build.complete", 0o640)
            assert not build_marker_is_valid(result_fd)
        finally:
            os.close(result_fd)
    print("B04 agent build publisher self-test passed")


def verify_receipt() -> tuple[str, str]:
    receipt_fd, binary_fd, receipt, receipt_sha = open_verified_bundle()
    try:
        return receipt["binary"]["sha256"], receipt_sha
    finally:
        os.close(binary_fd)
        os.close(receipt_fd)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--self-test", action="store_true")
    modes.add_argument("--build-receipt", action="store_true")
    modes.add_argument("--verify-receipt", action="store_true")
    parser.add_argument("--output-root", type=Path)
    arguments = parser.parse_args()
    if arguments.self_test:
        if arguments.output_root is not None:
            parser.error("--self-test cannot be combined with --output-root")
        self_test()
        return
    if arguments.build_receipt:
        if arguments.output_root is not None:
            parser.error("--build-receipt cannot be combined with --output-root")
        try:
            digest = build_and_write_receipt()
        except (
            BuildPublishError,
            OSError,
            subprocess.TimeoutExpired,
            UnicodeError,
        ) as error:
            print(f"B04 receipt creation refused: {error}", file=sys.stderr)
            raise SystemExit(1) from error
        print(f"B04 build receipt created: sha256={digest}")
        return
    if arguments.verify_receipt:
        if arguments.output_root is not None:
            parser.error("--verify-receipt cannot be combined with --output-root")
        try:
            binary_sha, receipt_sha = verify_receipt()
        except (
            BuildPublishError,
            OSError,
            subprocess.TimeoutExpired,
            UnicodeError,
        ) as error:
            print(f"B04 receipt verification refused: {error}", file=sys.stderr)
            raise SystemExit(1) from error
        print(f"B04 build receipt verified: binary_sha256={binary_sha}")
        print(f"B04 build receipt verified: receipt_sha256={receipt_sha}")
        return
    if arguments.output_root is None:
        parser.error("--output-root is required for live build publication")
    try:
        destination = publish(arguments.output_root)
    except (
        BuildPublishError,
        NAS.ProbeError,
        OSError,
        subprocess.TimeoutExpired,
        UnicodeError,
    ) as error:
        print(f"B04 build publication refused: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    print(f"verified B04 agent build published: {destination}")


if __name__ == "__main__":
    main()
