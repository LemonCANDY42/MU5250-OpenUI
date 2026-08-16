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

"$release/bin/run-agent.sh" stable
"$release/bin/run-dropbear.sh"
