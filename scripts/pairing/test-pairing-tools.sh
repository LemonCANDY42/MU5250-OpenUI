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
python3 - "$PAYLOAD" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding='utf-8'))
assert value['version'] == 1
assert value['base_url'] == 'https://u60.local:19443'
assert len(value['pairing_nonce']) == 43
assert value['spki_sha256'].startswith('sha256/')
PY

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
echo 'pairing tool tests passed'
