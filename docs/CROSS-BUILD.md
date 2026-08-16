# B04 agent cross-build

The first device artifact is a stripped, statically linked AArch64 musl ELF.
Building it is host-only: this step does not access ADB, the U60 filesystem,
the NAS or any host route/TUN setting.

The accepted tool versions are intentionally pinned:

- Rust 1.94.0 with the `aarch64-unknown-linux-musl` standard library;
- cargo-zigbuild 0.23.0;
- ziglang/Zig 0.16.0.

`scripts/build-b04-agent.sh` refuses inherited compiler, wrapper, Cargo profile,
target and linker overrides; ancestor/global Cargo configuration; missing target
libraries; different tool versions; dirty source; symlink output;
non-AArch64/non-static ELF output; and artifacts outside the 256 KiB to 12 MiB
size window. It cleans the target release profile before every build and then
removes only the two exact owner-controlled stale output names that some
cargo-zigbuild/Cargo clean combinations retain; symlinks or foreign-owned files
fail closed before either name is removed. The already-open release directory
must be owned by the current user and not group/other writable, and both file
identities are rechecked as a set immediately before unlink. It uses the locked
Cargo graph, disables incremental compilation, remaps the repository
path and sets `SOURCE_DATE_EPOCH` from the current Git commit. The tracked Cargo
alias deliberately contains no host-specific linker path; cargo-zigbuild owns
the linker selection. The publisher validates that the repository-local alias
is exactly the locked release-mode cargo-zigbuild recipe for the AArch64 musl
target; a missing or modified alias fails before a receipt can be created.

The Zig Python environment may be isolated outside Git. Point both `PATH` and
`CARGO_ZIGBUILD_PYTHON_PATH` at that environment, while selecting a rustup
toolchain containing the target standard library, then run:

```sh
scripts/build-b04-agent.sh
```

The command creates an exclusive mode-`0600` build receipt next to the binary,
then verifies it before returning. The receipt binds the binary to the full Git
commit and tree, the clean-build recipe, the hashes and versions of the actual
Rust/Cargo/cargo-zigbuild/Python/Zig executables, and byte-verified records for
every tracked Rust/Cargo input plus the build/publication boundary scripts. It
contains no host path or device secret. The command also prints the local
artifact size and public hashes; those values remain host build evidence only.

The receipt can be checked without the NAS:

```sh
python3 scripts/publish-b04-agent-build.py --verify-receipt
```

With the same pinned tool environment, publish and independently hash-check the
already receipt-bound binary through the shared reviewed SMB boundary:

```sh
python3 scripts/publish-b04-agent-build.py \
  --output-root /Volumes/backups/U60-Pro
```

The publisher opens the receipt and binary once, validates and copies from those
same file descriptors, and re-hashes the NAS files through the already-open
result directory. It refuses receipt/source/tool drift, path replacement,
symlinked/non-static/non-AArch64/unstripped artifacts, an unapproved NAS mount,
unsafe file mode, hash mismatch or an invalid final marker. Existing or
incomplete build results are never overwritten or deleted. A successful
cross-build or NAS publication does not authorize a canary, certificate
creation, device directory creation, upload, execution or persistence.
