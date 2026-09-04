#!/bin/sh

# The only persistent entry point. It resolves one fixed symlink and then runs
# release-owned launchers. No init, firewall, UCI, USB or FOTA action occurs.

set -eu
umask 077

U60_ROOT=/data/u60
current=$U60_ROOT/current
[ -L "$current" ] || exit 1
target=$(readlink "$current") || exit 1
case "$target" in
    "$U60_ROOT"/releases/[0-9a-f]*) release=$target ;;
    releases/[0-9a-f]*) release=$U60_ROOT/$target ;;
    *) exit 1 ;;
esac
release_id=${release##*/}
[ "${#release_id}" -eq 64 ] || exit 1
case "$release_id" in *[!0-9a-f]*) exit 1 ;; esac
[ -x "$release/bin/run-agent.sh" ] || exit 1
[ -x "$release/bin/run-dropbear.sh" ] || exit 1

# rc.local may run before the fixed management address is attached. Wait for
# at most two minutes without writing persistent state or blocking boot.
boot_wait_remaining=24
while ! ip -4 addr show 2>/dev/null | grep -q 'inet 192\.168\.0\.1/'; do
    [ "$boot_wait_remaining" -gt 0 ] || exit 1
    boot_wait_remaining=$((boot_wait_remaining - 1))
    sleep 5
done

# A transient early-boot failure gets two more chances. This is deliberately
# finite: the launcher is not a watchdog and cannot form a restart/write loop.
start_with_retry() {
    start_attempts=3
    while ! "$@"; do
        start_attempts=$((start_attempts - 1))
        [ "$start_attempts" -gt 0 ] || return 1
        sleep 5
    done
}

start_with_retry "$release/bin/run-agent.sh" stable
start_with_retry "$release/bin/run-dropbear.sh"
