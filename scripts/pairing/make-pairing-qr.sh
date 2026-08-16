#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
[[ $# -eq 3 ]] || { echo 'usage: make-pairing-qr.sh DEVICE_BUNDLE BASE_URL OUTPUT.png' >&2; exit 2; }
command -v python3 >/dev/null || { echo 'python3 is required' >&2; exit 1; }
command -v swift >/dev/null || { echo 'Swift is required on the owner Mac' >&2; exit 1; }

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/u60-pairing.XXXXXX")
trap 'rm -rf -- "$TEMP_DIR"' EXIT HUP INT TERM
PAYLOAD="$TEMP_DIR/pairing.json"
python3 "$SCRIPT_DIR/build-pairing-payload.py" "$1" "$2" >"$PAYLOAD"
swift "$SCRIPT_DIR/render-pairing-qr.swift" "$3" <"$PAYLOAD"
echo "pairing QR created at $3; it expires with the five-minute maintenance window"
