#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

[ "$#" -eq 0 ] || fail "run-dropbear.sh accepts no arguments"
require_release_root "$SCRIPT_DIR/.."
ensure_runtime_directories

dropbear=$RELEASE_ROOT/dropbearmulti
pid_file=$U60_RUNTIME/dropbear.pid
log=$U60_LOGS/dropbear.log
authorized=$U60_SSH/authorized_keys
host_key=$U60_SSH/dropbear_ed25519_host_key

[ -x "$dropbear" ] && [ ! -L "$dropbear" ] || fail "release Dropbear is not executable"
[ -d "$U60_SSH" ] && [ ! -L "$U60_SSH" ] || fail "SSH state directory is missing"
[ -s "$host_key" ] && [ ! -L "$host_key" ] || fail "Dropbear host key is missing"
[ -s "$authorized" ] && [ ! -L "$authorized" ] || fail "authorized_keys is missing"
chmod 700 "$U60_SSH"
chmod 600 "$host_key" "$authorized"
key_count=$(awk 'NF && $1 !~ /^#/ { count++ } END { print count + 0 }' "$authorized")
[ "$key_count" -eq 2 ] || fail "authorized_keys must contain exactly two non-comment keys"

if validated_pid_exe "$pid_file" "$dropbear"; then
    printf '%s\n' "u60-v1: Dropbear already running as PID $VALIDATED_PID"
    exit 0
fi
rm -f "$pid_file"
rotate_log "$log"

nohup "$dropbear" dropbear \
    -F -E -s -g -j -k -m \
    -p 192.168.0.1:2222 \
    -P "$pid_file" \
    -D "$U60_SSH" \
    -r "$host_key" \
    -T 3 -K 30 -I 600 \
    >>"$log" 2>&1 </dev/null &
pid=$!
sleep 1
if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pid_file"
    fail "Dropbear exited during startup"
fi
[ -f "$pid_file" ] || write_pid_file "$pid_file" "$pid"
printf '%s\n' "u60-v1: started key-only Dropbear release $RELEASE_ID"
