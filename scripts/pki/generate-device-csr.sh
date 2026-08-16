#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

[[ $# -eq 1 ]] || pki_die 'usage: generate-device-csr.sh OUTPUT_DIR'
OUTPUT_DIR=$1

pki_require_command openssl
pki_prepare_output_dir "$OUTPUT_DIR" no
pki_assert_absent "$OUTPUT_DIR/device-key.pem"
pki_assert_absent "$OUTPUT_DIR/device.csr.pem"
pki_assert_absent "$OUTPUT_DIR/device-csr.complete"

PKI_STAGE_DIR=$(pki_new_stage_dir "$OUTPUT_DIR")
trap pki_cleanup_stage EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
KEY="$PKI_STAGE_DIR/device-key.pem"
CSR="$PKI_STAGE_DIR/device.csr.pem"
PUBLIC_KEY="$PKI_STAGE_DIR/device-public.pem"
COMPLETION="$PKI_STAGE_DIR/device-csr.complete"

openssl genpkey \
  -algorithm EC \
  -pkeyopt ec_paramgen_curve:P-256 \
  -out "$KEY"
chmod 600 "$KEY"
openssl req \
  -new -sha256 \
  -key "$KEY" \
  -subj '/CN=u60.local' \
  -addext 'subjectAltName=DNS:u60.local' \
  -addext 'keyUsage=critical,digitalSignature' \
  -out "$CSR"
chmod 644 "$CSR"

openssl req -in "$CSR" -verify -noout >/dev/null 2>&1
[[ $(openssl req -in "$CSR" -subject -nameopt RFC2253 -noout) == 'subject=CN=u60.local' ]] ||
  pki_die 'generated CSR has an unexpected subject'
openssl req -in "$CSR" -pubkey -noout >"$PUBLIC_KEY"
pki_is_p256_public_key "$PUBLIC_KEY" || pki_die 'generated CSR is not P-256'
printf '%s\n' "$PKI_DEVICE_CSR_COMPLETION" >"$COMPLETION"
chmod 644 "$COMPLETION"

pki_assert_absent "$OUTPUT_DIR/device-key.pem"
pki_assert_absent "$OUTPUT_DIR/device.csr.pem"
pki_assert_absent "$OUTPUT_DIR/device-csr.complete"
pki_publish_files \
  "$KEY" "$OUTPUT_DIR/device-key.pem" \
  "$CSR" "$OUTPUT_DIR/device.csr.pem" \
  "$COMPLETION" "$OUTPUT_DIR/device-csr.complete"
printf 'device key and CSR created in %s\n' "$OUTPUT_DIR"
