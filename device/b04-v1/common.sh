#!/bin/sh

# Fixed-path helpers for the single-owner HK B04 deployment. This file is
# copied into every immutable release and is never sourced from /etc.

set -eu

U60_ROOT=/data/u60
U60_RELEASES=$U60_ROOT/releases
U60_RUNTIME=$U60_ROOT/runtime
U60_STATE=$U60_ROOT/state
U60_PKI=$U60_ROOT/pki
U60_SSH=$U60_ROOT/ssh

fail() {
    printf '%s\n' "u60-v1: $*" >&2
    exit 1
}

require_release_root() {
    candidate=$1
    [ -d "$candidate" ] || fail "release directory is missing"
    [ ! -L "$candidate" ] || fail "release directory must not be a symlink"
    physical=$(cd "$candidate" 2>/dev/null && pwd -P) || fail "release directory is not accessible"
    case "$physical" in
        "$U60_RELEASES"/[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
        *) fail "release directory is outside the fixed release root" ;;
    esac
    release_id=${physical##*/}
    [ "${#release_id}" -eq 64 ] || fail "release identifier must be 64 lowercase hex characters"
    case "$release_id" in *[!0-9a-f]*) fail "release identifier is invalid" ;; esac
    expected="u60-b04-v1-release:$release_id"
    [ -f "$physical/release.complete" ] && [ ! -L "$physical/release.complete" ] ||
        fail "release completion marker is missing"
    marker=$(sed -n '1p' "$physical/release.complete")
    [ "$marker" = "$expected" ] || fail "release completion marker does not match"
    [ -f "$physical/release.sha256" ] && [ ! -L "$physical/release.sha256" ] ||
        fail "release checksum list is missing"
    checksum_id=$(sha256sum "$physical/release.sha256" | cut -d' ' -f1) ||
        fail "release checksum list cannot be hashed"
    [ "$checksum_id" = "$release_id" ] || fail "release identifier does not match its checksum list"
    (cd "$physical" && sha256sum -c release.sha256 >/dev/null) ||
        fail "release checksum verification failed"
    RELEASE_ROOT=$physical
    RELEASE_ID=$release_id
}

ensure_runtime_directories() {
    umask 077
    for directory in "$U60_RUNTIME" "$U60_STATE"; do
        if [ -L "$directory" ]; then
            fail "$directory must not be a symlink"
        fi
        mkdir -p "$directory"
        chmod 700 "$directory"
    done
}

validated_pid_exe() {
    pid_file=$1
    expected_exe=$2
    [ -f "$pid_file" ] && [ ! -L "$pid_file" ] || return 1
    pid=$(sed -n '1p' "$pid_file")
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "/proc/$pid" ] || return 1
    actual=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
    [ "$actual" = "$expected_exe" ] || return 1
    VALIDATED_PID=$pid
    return 0
}

write_pid_file() {
    pid_file=$1
    pid=$2
    temporary="$pid_file.new.$$"
    [ ! -e "$temporary" ] && [ ! -L "$temporary" ] || fail "temporary PID path exists"
    printf '%s\n' "$pid" >"$temporary"
    chmod 600 "$temporary"
    mv -f "$temporary" "$pid_file"
}
