#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/u60-pairing-test.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT HUP INT TERM
BUNDLE="$TEST_ROOT/bundle"
mkdir -m 700 "$BUNDLE"
printf '%s\n' 'u60-device-bundle-complete-v1' >"$BUNDLE/device-bundle.complete"
printf '%s\n' 'sha256/BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=' >"$BUNDLE/device-spki-pin.txt"
NONCE='BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc'
EXPIRES=$(( $(date +%s) + 240 ))
GRANT=$(printf '{"pairing_nonce":"%s","expires_at":%s,"registration_path":"/v1/auth/pair"}\n' "$NONCE" "$EXPIRES")
PAYLOAD="$TEST_ROOT/payload.json"
printf '%s' "$GRANT" | python3 "$SCRIPT_DIR/build-pairing-payload.py" \
  "$BUNDLE" 'https://u60.local:19443' >"$PAYLOAD"
python3 - "$PAYLOAD" "$EXPIRES" <<'PY'
import datetime as dt
import json
import sys

value = json.load(open(sys.argv[1], encoding='utf-8'))
assert value['version'] == 1
assert value['base_url'] == 'https://u60.local:19443'
assert len(value['pairing_nonce']) == 43
assert value['spki_sha256'].startswith('sha256/')
expires_at = dt.datetime.fromisoformat(value['expires_at'].replace('Z', '+00:00'))
assert expires_at.timestamp() == int(sys.argv[2])
PY

LOCAL_NOW=$(date +%s)
HOST_NOW=$LOCAL_NOW
DEVICE_NOW=$(( LOCAL_NOW + 8 * 60 * 60 ))
DEVICE_EXPIRES=$(( DEVICE_NOW + 240 ))
SKEW_GRANT=$(printf '{"pairing_nonce":"%s","expires_at":%s,"registration_path":"/v1/auth/pair"}\n' \
  "$NONCE" "$DEVICE_EXPIRES")
SKEW_PAYLOAD="$TEST_ROOT/skew-payload.json"
printf '%s' "$SKEW_GRANT" | python3 "$SCRIPT_DIR/build-pairing-payload.py" \
  --host-now "$HOST_NOW" --device-now "$DEVICE_NOW" \
  "$BUNDLE" 'https://192.168.0.1:9443' >"$SKEW_PAYLOAD"
python3 - "$SKEW_PAYLOAD" "$HOST_NOW" <<'PY'
import datetime as dt
import json
import sys
import time

value = json.load(open(sys.argv[1], encoding='utf-8'))
expires_at = dt.datetime.fromisoformat(value['expires_at'].replace('Z', '+00:00'))
assert expires_at.timestamp() == int(sys.argv[2]) + 238
assert 0 < expires_at.timestamp() - time.time() <= 300
PY

if printf '%s' "$SKEW_GRANT" | python3 "$SCRIPT_DIR/build-pairing-payload.py" \
  "$BUNDLE" 'https://192.168.0.1:9443' >/dev/null 2>&1; then
  echo 'clock-skewed grant was accepted without explicit device epoch' >&2
  exit 1
fi
if printf '%s' "$SKEW_GRANT" | python3 "$SCRIPT_DIR/build-pairing-payload.py" \
  --device-now "$DEVICE_NOW" "$BUNDLE" 'https://192.168.0.1:9443' \
  >/dev/null 2>&1; then
  echo 'device clock sample was accepted without its host sample' >&2
  exit 1
fi
if printf '%s' "$SKEW_GRANT" | python3 "$SCRIPT_DIR/build-pairing-payload.py" \
  --host-now "$HOST_NOW" "$BUNDLE" 'https://192.168.0.1:9443' \
  >/dev/null 2>&1; then
  echo 'host clock sample was accepted without its device sample' >&2
  exit 1
fi

BOOL_EXPIRY_GRANT=$(printf '{"pairing_nonce":"%s","expires_at":true,"registration_path":"/v1/auth/pair"}\n' \
  "$NONCE")
if printf '%s' "$BOOL_EXPIRY_GRANT" | python3 "$SCRIPT_DIR/build-pairing-payload.py" \
  --host-now "$HOST_NOW" --device-now "$DEVICE_NOW" \
  "$BUNDLE" 'https://192.168.0.1:9443' >/dev/null 2>&1; then
  echo 'boolean pairing expiry was accepted as an integer' >&2
  exit 1
fi

FUTURE_HOST_NOW=$(( $(date +%s) + 60 ))
if printf '%s' "$SKEW_GRANT" | python3 "$SCRIPT_DIR/build-pairing-payload.py" \
  --host-now "$FUTURE_HOST_NOW" --device-now "$DEVICE_NOW" \
  "$BUNDLE" 'https://192.168.0.1:9443' >/dev/null 2>&1; then
  echo 'future host clock sample was accepted' >&2
  exit 1
fi

DELAYED_HOST_NOW=$(( HOST_NOW - 10 ))
DELAYED_DEVICE_NOW=$(( DEVICE_NOW - 10 ))
DELAYED_DEVICE_EXPIRES=$(( DELAYED_DEVICE_NOW + 240 ))
DELAYED_GRANT=$(printf '{"pairing_nonce":"%s","expires_at":%s,"registration_path":"/v1/auth/pair"}\n' \
  "$NONCE" "$DELAYED_DEVICE_EXPIRES")
DELAYED_PAYLOAD="$TEST_ROOT/delayed-payload.json"
printf '%s' "$DELAYED_GRANT" | python3 "$SCRIPT_DIR/build-pairing-payload.py" \
  --host-now "$DELAYED_HOST_NOW" --device-now "$DELAYED_DEVICE_NOW" \
  "$BUNDLE" 'https://192.168.0.1:9443' >"$DELAYED_PAYLOAD"
python3 - "$SKEW_PAYLOAD" "$DELAYED_PAYLOAD" <<'PY'
import datetime as dt
import json
import sys

def expiry(path):
    value = json.load(open(path, encoding='utf-8'))
    return dt.datetime.fromisoformat(value['expires_at'].replace('Z', '+00:00')).timestamp()

assert expiry(sys.argv[2]) == expiry(sys.argv[1]) - 10
PY

if printf '%s' "$SKEW_GRANT" | python3 "$SCRIPT_DIR/build-pairing-payload.py" \
  --host-now "$HOST_NOW" --device-now '1.5' \
  "$BUNDLE" 'https://192.168.0.1:9443' >/dev/null 2>&1; then
  echo 'non-integer device epoch was accepted' >&2
  exit 1
fi
if printf '%s' "$SKEW_GRANT" | python3 "$SCRIPT_DIR/build-pairing-payload.py" \
  --host-now '1.5' --device-now "$DEVICE_NOW" \
  "$BUNDLE" 'https://192.168.0.1:9443' >/dev/null 2>&1; then
  echo 'non-integer host epoch was accepted' >&2
  exit 1
fi
if printf '%s' "$SKEW_GRANT" | "$SCRIPT_DIR/make-pairing-qr.sh" \
  "$BUNDLE" 'https://192.168.0.1:9443' "$TEST_ROOT/single-sample.png" \
  "$DEVICE_NOW" \
  >/dev/null 2>&1; then
  echo 'QR helper accepted only one clock sample' >&2
  exit 1
fi
if printf '%s' "$SKEW_GRANT" | "$SCRIPT_DIR/make-pairing-qr.sh" \
  "$BUNDLE" 'https://192.168.0.1:9443' "$TEST_ROOT/invalid-host-epoch.png" \
  '1.5' "$DEVICE_NOW" >/dev/null 2>&1; then
  echo 'QR helper accepted a non-decimal host epoch' >&2
  exit 1
fi
if printf '%s' "$SKEW_GRANT" | "$SCRIPT_DIR/make-pairing-qr.sh" \
  "$BUNDLE" 'https://192.168.0.1:9443' "$TEST_ROOT/invalid-device-epoch.png" \
  "$HOST_NOW" '1.5' >/dev/null 2>&1; then
  echo 'QR helper accepted a non-decimal device epoch' >&2
  exit 1
fi
for DEVICE_OFFSET in 2 600; do
  DEVICE_RELATIVE_GRANT=$(printf '{"pairing_nonce":"%s","expires_at":%s,"registration_path":"/v1/auth/pair"}\n' \
    "$NONCE" "$(( DEVICE_NOW + DEVICE_OFFSET ))")
  if printf '%s' "$DEVICE_RELATIVE_GRANT" | python3 "$SCRIPT_DIR/build-pairing-payload.py" \
    --host-now "$HOST_NOW" --device-now "$DEVICE_NOW" \
    "$BUNDLE" 'https://192.168.0.1:9443' >/dev/null 2>&1; then
    echo "invalid device-relative pairing window was accepted: $DEVICE_OFFSET" >&2
    exit 1
  fi
done

IP_PAYLOAD="$TEST_ROOT/ip-payload.json"
printf '%s' "$GRANT" | python3 "$SCRIPT_DIR/build-pairing-payload.py" \
  "$BUNDLE" 'https://192.168.0.1:9443' >"$IP_PAYLOAD"
python3 - "$IP_PAYLOAD" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding='utf-8'))
assert value['base_url'] == 'https://192.168.0.1:9443'
PY

for rejected_url in \
  'https://192.168.0.1:19443' \
  'https://192.168.0.2:9443' \
  'http://192.168.0.1:9443'; do
  if printf '%s' "$GRANT" | python3 "$SCRIPT_DIR/build-pairing-payload.py" \
    "$BUNDLE" "$rejected_url" >/dev/null 2>&1; then
    echo "unsafe pairing URL was accepted: $rejected_url" >&2
    exit 1
  fi
done

if command -v swift >/dev/null && [[ $(uname -s) == Darwin ]]; then
  LEGACY_QR="$TEST_ROOT/legacy-pairing.png"
  QR_MESSAGE=$(printf '%s' "$GRANT" | "$SCRIPT_DIR/make-pairing-qr.sh" \
    "$BUNDLE" 'https://192.168.0.1:9443' "$LEGACY_QR")
  [[ -s "$LEGACY_QR" ]]
  [[ $(stat -f '%Lp' "$LEGACY_QR") == 600 ]]
  [[ $QR_MESSAGE != *"$NONCE"* ]]

  SKEW_QR="$TEST_ROOT/skew-pairing.png"
  QR_MESSAGE=$(printf '%s' "$SKEW_GRANT" | "$SCRIPT_DIR/make-pairing-qr.sh" \
    "$BUNDLE" 'https://192.168.0.1:9443' "$SKEW_QR" \
    "$HOST_NOW" "$DEVICE_NOW")
  [[ -s "$SKEW_QR" ]]
  [[ $(stat -f '%Lp' "$SKEW_QR") == 600 ]]
  [[ $QR_MESSAGE != *"$NONCE"* ]]

  QR="$TEST_ROOT/pairing.png"
  (umask 022; swift "$SCRIPT_DIR/render-pairing-qr.swift" "$QR" <"$PAYLOAD")
  [[ -s "$QR" ]]
  [[ $(stat -f '%Lp' "$QR") == 600 ]]
  if swift "$SCRIPT_DIR/render-pairing-qr.swift" "$QR" <"$PAYLOAD" >/dev/null 2>&1; then
    echo 'existing QR output was overwritten' >&2
    exit 1
  fi
  if swift "$SCRIPT_DIR/render-pairing-qr.swift" \
    "$SCRIPT_DIR/forbidden-pairing.png" <"$PAYLOAD" >/dev/null 2>&1; then
    echo 'repository QR output was accepted' >&2
    exit 1
  fi
  [[ ! -e "$SCRIPT_DIR/forbidden-pairing.png" ]]

  SYMLINK_OUTPUT="$TEST_ROOT/existing-link.png"
  SYMLINK_TARGET="$TEST_ROOT/symlink-target"
  ln -s "$SYMLINK_TARGET" "$SYMLINK_OUTPUT"
  if swift "$SCRIPT_DIR/render-pairing-qr.swift" \
    "$SYMLINK_OUTPUT" <"$PAYLOAD" >/dev/null 2>&1; then
    echo 'preexisting QR symlink was accepted' >&2
    exit 1
  fi
  [[ -L "$SYMLINK_OUTPUT" ]]
  [[ ! -e "$SYMLINK_TARGET" ]]

  REPO_PARENT_LINK="$TEST_ROOT/repository-parent"
  ln -s "$SCRIPT_DIR" "$REPO_PARENT_LINK"
  if swift "$SCRIPT_DIR/render-pairing-qr.swift" \
    "$REPO_PARENT_LINK/forbidden-parent.png" <"$PAYLOAD" >/dev/null 2>&1; then
    echo 'symlink parent into repository was accepted' >&2
    exit 1
  fi
  [[ ! -e "$SCRIPT_DIR/forbidden-parent.png" ]]
fi

if printf '{}\n' | python3 "$SCRIPT_DIR/build-pairing-payload.py" \
  "$BUNDLE" 'https://u60.local:9443' >/dev/null 2>&1; then
  echo 'malformed grant was accepted' >&2
  exit 1
fi

BAD_BUNDLE="$TEST_ROOT/bad-bundle"
mkdir -m 700 "$BAD_BUNDLE"
printf '%s\n' 'wrong-marker' >"$BAD_BUNDLE/device-bundle.complete"
printf '%s\n' 'sha256/BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=' >"$BAD_BUNDLE/device-spki-pin.txt"
if printf '%s' "$GRANT" | python3 "$SCRIPT_DIR/build-pairing-payload.py" \
  "$BAD_BUNDLE" 'https://u60.local:9443' >/dev/null 2>&1; then
  echo 'invalid bundle marker was accepted' >&2
  exit 1
fi

EXPIRED=$(printf '{"pairing_nonce":"%s","expires_at":%s,"registration_path":"/v1/auth/pair"}\n' \
  "$NONCE" "$(( $(date +%s) - 1 ))")
if printf '%s' "$EXPIRED" | python3 "$SCRIPT_DIR/build-pairing-payload.py" \
  "$BUNDLE" 'https://u60.local:9443' >/dev/null 2>&1; then
  echo 'expired pairing grant was accepted' >&2
  exit 1
fi
OVERLONG=$(printf '{"pairing_nonce":"%s","expires_at":%s,"registration_path":"/v1/auth/pair"}\n' \
  "$NONCE" "$(( $(date +%s) + 600 ))")
if printf '%s' "$OVERLONG" | python3 "$SCRIPT_DIR/build-pairing-payload.py" \
  "$BUNDLE" 'https://u60.local:9443' >/dev/null 2>&1; then
  echo 'overlong pairing grant was accepted' >&2
  exit 1
fi
echo 'pairing tool tests passed'
