#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

[ "$#" -eq 1 ] || fail "usage: run-agent.sh canary|stable"
mode=$1
require_release_root "$SCRIPT_DIR/.."
ensure_runtime_directories

case "$mode" in
    canary)
        bind=127.0.0.1:19443
        pid_file=$U60_RUNTIME/canary.pid
        log=$U60_LOGS/canary.log
        ;;
    stable)
        bind=192.168.0.1:9443
        pid_file=$U60_RUNTIME/agent.pid
        log=$U60_LOGS/agent.log
        ;;
    *) fail "agent mode must be canary or stable" ;;
esac

agent=$RELEASE_ROOT/zte-agent
web_root=$RELEASE_ROOT/web
[ -x "$agent" ] && [ ! -L "$agent" ] || fail "release agent is not executable"
[ -d "$web_root" ] && [ ! -L "$web_root" ] || fail "release web root is invalid"
[ -f "$U60_PKI/device-cert.pem" ] && [ ! -L "$U60_PKI/device-cert.pem" ] || fail "device certificate is missing"
[ -f "$U60_PKI/device-key.pem" ] && [ ! -L "$U60_PKI/device-key.pem" ] || fail "device leaf key is missing"

if validated_pid_exe "$pid_file" "$agent"; then
    printf '%s\n' "u60-v1: $mode agent already running as PID $VALIDATED_PID"
    exit 0
fi
rm -f "$pid_file"
rotate_log "$log"

U60_TLS_CERT_PEM=$U60_PKI/device-cert.pem \
U60_TLS_KEY_PEM=$U60_PKI/device-key.pem \
U60_BIND=$bind \
U60_STATE_DIR=$U60_STATE \
nohup "$agent" serve --web-root "$web_root" >>"$log" 2>&1 </dev/null &
pid=$!
write_pid_file "$pid_file" "$pid"
sleep 1
if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pid_file"
    fail "$mode agent exited during startup"
fi
printf '%s\n' "u60-v1: started $mode agent release $RELEASE_ID"
