#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TARGET=aarch64-unknown-linux-musl
BINARY="$ROOT/target/$TARGET/release/zte-agent"
EXPECTED_RUSTC="rustc 1.97.1 "
EXPECTED_CARGO="cargo 1.97.1 "
EXPECTED_ZIGBUILD="cargo-zigbuild 0.23.0"
EXPECTED_ZIG="0.16.0"

fail() {
  printf 'B04 cross-build refused: %s\n' "$1" >&2
  exit 1
}

REJECTED_ENVIRONMENT=(
  RUSTFLAGS CARGO_ENCODED_RUSTFLAGS RUSTC RUSTC_WRAPPER
  RUSTC_WORKSPACE_WRAPPER CARGO_BUILD_RUSTFLAGS CARGO_BUILD_RUSTC
  CARGO_BUILD_RUSTC_WRAPPER CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER
  CARGO_BUILD_TARGET CARGO_TARGET_DIR CARGO_BUILD_TARGET_DIR
  CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER
  CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS
  CC CFLAGS CXX CXXFLAGS AR RANLIB STRIP LDFLAGS
  CC_AARCH64_UNKNOWN_LINUX_MUSL CFLAGS_AARCH64_UNKNOWN_LINUX_MUSL
  CXX_AARCH64_UNKNOWN_LINUX_MUSL CXXFLAGS_AARCH64_UNKNOWN_LINUX_MUSL
  AR_AARCH64_UNKNOWN_LINUX_MUSL RANLIB_AARCH64_UNKNOWN_LINUX_MUSL
  STRIP_AARCH64_UNKNOWN_LINUX_MUSL
  CC_aarch64_unknown_linux_musl CFLAGS_aarch64_unknown_linux_musl
  CXX_aarch64_unknown_linux_musl CXXFLAGS_aarch64_unknown_linux_musl
  AR_aarch64_unknown_linux_musl RANLIB_aarch64_unknown_linux_musl
  STRIP_aarch64_unknown_linux_musl TARGET_CC TARGET_CXX TARGET_AR
  TARGET_RANLIB TARGET_STRIP RUSTC_BOOTSTRAP ZIG
)
for variable in "${REJECTED_ENVIRONMENT[@]}"; do
  [ -z "${!variable+x}" ] || fail "inherited build environment contains $variable"
done
while IFS='=' read -r variable _; do
  case "$variable" in
    CARGO_ZIGBUILD_PYTHON_PATH) ;;
    CARGO_ZIGBUILD_*)
      fail "inherited build environment contains $variable"
      ;;
    CARGO_ALIAS_* | CARGO_BUILD_* | CARGO_PROFILE_* | CARGO_TARGET_*)
      fail "inherited build environment contains $variable"
      ;;
  esac
done < <(env)

command -v cargo >/dev/null 2>&1 || fail "cargo is unavailable"
command -v rustc >/dev/null 2>&1 || fail "rustc is unavailable"
command -v cargo-zigbuild >/dev/null 2>&1 || fail "cargo-zigbuild is unavailable"
command -v file >/dev/null 2>&1 || fail "file is unavailable"
command -v shasum >/dev/null 2>&1 || fail "shasum is unavailable"

[ -n "${CARGO_ZIGBUILD_PYTHON_PATH:-}" ] ||
  fail "CARGO_ZIGBUILD_PYTHON_PATH must select the pinned ziglang environment"
[ -x "$CARGO_ZIGBUILD_PYTHON_PATH" ] ||
  fail "CARGO_ZIGBUILD_PYTHON_PATH is not executable"
case "$(rustc --version)" in
  "$EXPECTED_RUSTC"*) ;;
  *) fail "rustc must be exactly 1.97.1" ;;
esac
case "$(cargo --version)" in
  "$EXPECTED_CARGO"*) ;;
  *) fail "cargo must be exactly 1.97.1" ;;
esac
[ "$(cargo-zigbuild --version)" = "$EXPECTED_ZIGBUILD" ] ||
  fail "cargo-zigbuild must be exactly 0.23.0"
[ "$($CARGO_ZIGBUILD_PYTHON_PATH -m ziglang version)" = "$EXPECTED_ZIG" ] ||
  fail "ziglang must be exactly 0.16.0"

SYSROOT=$(rustc --print sysroot)
find "$SYSROOT/lib/rustlib/$TARGET/lib" -name 'libstd-*.rlib' -type f -print -quit |
  grep -q . || fail "the $TARGET Rust standard library is not installed"

cd "$ROOT"
git diff --quiet && git diff --cached --quiet ||
  fail "tracked Git state must be clean before the cross-build"
[ ! -e "${CARGO_HOME:-$HOME/.cargo}/config" ] ||
  fail "legacy global Cargo config is not accepted"
[ ! -e "${CARGO_HOME:-$HOME/.cargo}/config.toml" ] ||
  fail "global Cargo config is not accepted"
CONFIG_PARENT=$(dirname "$ROOT")
while [ "$CONFIG_PARENT" != "/" ]; do
  [ ! -e "$CONFIG_PARENT/.cargo/config" ] ||
    fail "ancestor Cargo config is not accepted: $CONFIG_PARENT/.cargo/config"
  [ ! -e "$CONFIG_PARENT/.cargo/config.toml" ] ||
    fail "ancestor Cargo config is not accepted: $CONFIG_PARENT/.cargo/config.toml"
  CONFIG_PARENT=$(dirname "$CONFIG_PARENT")
done

SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD)
export SOURCE_DATE_EPOCH CARGO_INCREMENTAL=0
export RUSTFLAGS="--remap-path-prefix=$ROOT=/src"
python3 "$ROOT/scripts/publish-b04-agent-build.py" --build-receipt
git diff --quiet && git diff --cached --quiet ||
  fail "tracked Git state changed during the cross-build"

[ -f "$BINARY" ] && [ ! -L "$BINARY" ] || fail "expected binary is missing or a symlink"
DESCRIPTION=$(file -b "$BINARY")
case "$DESCRIPTION" in
  "ELF 64-bit LSB executable, ARM aarch64,"*", statically linked, stripped") ;;
  *) fail "artifact is not a stripped, static AArch64 ELF executable: $DESCRIPTION" ;;
esac

SIZE=$(wc -c < "$BINARY" | tr -d ' ')
[ "$SIZE" -ge 262144 ] && [ "$SIZE" -le 12582912 ] ||
  fail "artifact size is outside the 256 KiB to 12 MiB acceptance window"
SHA256=$(shasum -a 256 "$BINARY" | awk '{print $1}')
python3 "$ROOT/scripts/publish-b04-agent-build.py" --verify-receipt
RECEIPT="$ROOT/target/$TARGET/release/B04-BUILD-RECEIPT.json"
RECEIPT_SHA256=$(shasum -a 256 "$RECEIPT" | awk '{print $1}')

printf 'target=%s\n' "$TARGET"
printf 'binary=%s\n' "$BINARY"
printf 'size=%s\n' "$SIZE"
printf 'sha256=%s\n' "$SHA256"
printf 'format=%s\n' "$DESCRIPTION"
printf 'receipt_sha256=%s\n' "$RECEIPT_SHA256"
