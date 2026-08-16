#!/bin/sh

# Reproducibly build the deliberately small, key-only Dropbear used by B04 V1.
# Source archive, detached signature and release key are operator-provided so
# this script never turns a network download into implicit build authority.

set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
EXPECTED_ARCHIVE_SHA256=e098034a843699200c8c977a991fff73159735bf795d5f72ef672c41a6b1ae81
EXPECTED_SIGNING_FINGERPRINT=F7347EF2EE2E07A267628CA944931494F29C6773
VERSION=2026.94

if [ "$#" -ne 4 ]; then
    printf '%s\n' \
        "usage: build-b04-dropbear.sh ARCHIVE SIGNATURE RELEASE_KEY OUTPUT_DIR" >&2
    exit 64
fi

archive=$1
signature=$2
release_key=$3
output=$4
zig_python=${DROPBEAR_ZIG_PYTHON:-}
llvm_strip=${DROPBEAR_LLVM_STRIP:-/opt/homebrew/opt/llvm/bin/llvm-strip}

for input in "$archive" "$signature" "$release_key"; do
    [ -f "$input" ] && [ ! -L "$input" ] || {
        printf 'refusing non-physical input: %s\n' "$input" >&2
        exit 1
    }
done
[ -n "$zig_python" ] && [ -x "$zig_python" ] && [ ! -L "$zig_python" ] || {
    printf '%s\n' "DROPBEAR_ZIG_PYTHON must name the pinned ziglang Python" >&2
    exit 1
}
[ -x "$llvm_strip" ] && [ ! -L "$llvm_strip" ] || {
    printf '%s\n' "DROPBEAR_LLVM_STRIP must name a physical llvm-strip" >&2
    exit 1
}
[ ! -e "$output" ] && [ ! -L "$output" ] || {
    printf '%s\n' "output directory must not already exist" >&2
    exit 1
}

actual_archive_sha=$(sha256sum "$archive" | cut -d' ' -f1)
[ "$actual_archive_sha" = "$EXPECTED_ARCHIVE_SHA256" ] || {
    printf '%s\n' "Dropbear archive SHA-256 mismatch" >&2
    exit 1
}

temporary=$(mktemp -d "${TMPDIR:-/tmp}/u60-dropbear.XXXXXX")
cleanup() {
    rm -rf "$temporary"
}
trap cleanup EXIT HUP INT TERM
chmod 700 "$temporary"
export GNUPGHOME=$temporary/gnupg
mkdir "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
gpg --batch --quiet --import "$release_key"
fingerprints=$(gpg --batch --with-colons --fingerprint | awk -F: '$1 == "fpr" {print $10}')
printf '%s\n' "$fingerprints" | grep -qx "$EXPECTED_SIGNING_FINGERPRINT" || {
    printf '%s\n' "Dropbear release key fingerprint mismatch" >&2
    exit 1
}
gpg --batch --verify "$signature" "$archive"

tar -tjf "$archive" >"$temporary/archive.list"
awk -v prefix="dropbear-$VERSION/" '
    $0 !~ ("^" prefix) || $0 ~ /(^|\/)\.\.($|\/)/ || $0 ~ /^\// { bad=1 }
    END { exit bad ? 1 : 0 }
' "$temporary/archive.list" || {
    printf '%s\n' "Dropbear archive member policy failed" >&2
    exit 1
}
tar -xjf "$archive" -C "$temporary"
source_dir=$temporary/dropbear-$VERSION
cp "$ROOT/device/dropbear/localoptions.h" "$source_dir/localoptions.h"

(
    cd "$source_dir"
    CC="$zig_python -m ziglang cc -target aarch64-linux-musl" \
    CFLAGS="-Os -fstack-protector-strong -D_FORTIFY_SOURCE=2" \
    LDFLAGS="-static -Wl,-z,relro,-z,now" \
        ./configure \
            --host=aarch64-linux-musl \
            --enable-static \
            --disable-zlib \
            --disable-syslog \
            --disable-shadow \
            --disable-lastlog \
            --disable-utmp \
            --disable-utmpx \
            --disable-wtmp \
            --disable-wtmpx
    make -j2 PROGRAMS="dropbear dropbearkey" MULTI=1
    "$llvm_strip" --strip-all dropbearmulti
)

description=$(file -b "$source_dir/dropbearmulti")
case "$description" in
    *"ELF 64-bit"*"ARM aarch64"*"statically linked"*"stripped"*) ;;
    *) printf '%s\n' "Dropbear output is not a static stripped AArch64 ELF" >&2; exit 1 ;;
esac

mkdir "$output"
chmod 700 "$output"
cp "$source_dir/dropbearmulti" "$output/dropbearmulti"
chmod 700 "$output/dropbearmulti"
binary_sha=$(sha256sum "$output/dropbearmulti" | cut -d' ' -f1)
printf '%s\n' \
    "dropbear_version=$VERSION" \
    "archive_sha256=$EXPECTED_ARCHIVE_SHA256" \
    "signing_fingerprint=$EXPECTED_SIGNING_FINGERPRINT" \
    "binary_sha256=$binary_sha" \
    "target=aarch64-linux-musl" \
    "password_auth=compiled-out" \
    "tcp_forwarding=compiled-out" \
    >"$output/BUILD-MANIFEST.txt"
chmod 600 "$output/BUILD-MANIFEST.txt"
printf '%s\n' "u60-b04-dropbear-build-complete-v1" >"$output/build.complete"
chmod 600 "$output/build.complete"
printf '%s\n' "$output"
