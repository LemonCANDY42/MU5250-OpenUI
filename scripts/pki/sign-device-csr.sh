#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

[[ $# -eq 3 ]] || pki_die 'usage: sign-device-csr.sh CA_DIR CSR OUTPUT_DIR'
CA_DIR=$1
CSR=$2
OUTPUT_DIR=$3
CA_KEY="$CA_DIR/owner-ca-key.pem"
CA_CERT="$CA_DIR/owner-ca-cert.pem"
CA_COMPLETION="$CA_DIR/owner-ca.complete"
CSR_DIR=$(dirname -- "$CSR")
CSR_COMPLETION="$CSR_DIR/device-csr.complete"

pki_require_command openssl
pki_validate_existing_private_directory "$CA_DIR" 'CA directory'
CA_DIR_PHYSICAL=$PKI_VALIDATED_DIRECTORY
pki_validate_existing_private_directory "$CSR_DIR" 'CSR directory'
pki_validate_output_directory "$OUTPUT_DIR" 'output directory'
OUTPUT_DIR_PHYSICAL=$PKI_VALIDATED_DIRECTORY
pki_require_disjoint_directories \
  "$CA_DIR_PHYSICAL" "$OUTPUT_DIR_PHYSICAL" 'CA and signing output directories'
pki_require_completion_marker \
  "$CA_COMPLETION" "$PKI_OWNER_CA_COMPLETION" 'owner CA completion marker'
pki_require_completion_marker \
  "$CSR_COMPLETION" "$PKI_DEVICE_CSR_COMPLETION" 'device CSR completion marker'
pki_require_regular_file "$CA_KEY" 'owner CA key'
pki_require_regular_file "$CA_CERT" 'owner CA certificate'
pki_require_regular_file "$CSR" 'device CSR'
[[ $(pki_file_mode "$CA_KEY") == '600' ]] || pki_die 'owner CA key mode must be 0600'
grep -q '^-----BEGIN ENCRYPTED PRIVATE KEY-----$' "$CA_KEY" ||
  pki_die 'owner CA key must be encrypted PKCS#8'
pki_prepare_output_dir "$OUTPUT_DIR" no
pki_assert_absent "$OUTPUT_DIR/device-cert.pem"
pki_assert_absent "$OUTPUT_DIR/device-chain.pem"
pki_assert_absent "$OUTPUT_DIR/device-spki-pin.txt"
pki_assert_absent "$OUTPUT_DIR/device-bundle.complete"

openssl req -in "$CSR" -verify -noout >/dev/null 2>&1 || pki_die 'CSR self-signature is invalid'
[[ $(openssl req -in "$CSR" -subject -nameopt RFC2253 -noout) == 'subject=CN=u60.local' ]] ||
  pki_die 'CSR subject must be exactly CN=u60.local'

PKI_STAGE_DIR=$(pki_new_stage_dir "$OUTPUT_DIR")
trap pki_cleanup_stage EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
CSR_PUBLIC_KEY="$PKI_STAGE_DIR/csr-public.pem"
CA_KEY_PUBLIC="$PKI_STAGE_DIR/ca-key-public.pem"
CA_CERT_PUBLIC="$PKI_STAGE_DIR/ca-cert-public.pem"
EXTENSIONS="$PKI_STAGE_DIR/device-extensions.cnf"
CERT="$PKI_STAGE_DIR/device-cert.pem"
CHAIN="$PKI_STAGE_DIR/device-chain.pem"
PIN="$PKI_STAGE_DIR/device-spki-pin.txt"
COMPLETION="$PKI_STAGE_DIR/device-bundle.complete"
SIGNING_ERRORS="$PKI_STAGE_DIR/signing-errors.txt"

openssl req -in "$CSR" -pubkey -noout >"$CSR_PUBLIC_KEY"
pki_is_p256_public_key "$CSR_PUBLIC_KEY" || pki_die 'CSR public key must be P-256'
openssl x509 -in "$CA_CERT" -pubkey -noout >"$CA_CERT_PUBLIC"
pki_is_p256_public_key "$CA_CERT_PUBLIC" || pki_die 'owner CA certificate must be P-256'
openssl verify -CAfile "$CA_CERT" "$CA_CERT" >/dev/null 2>&1 ||
  pki_die 'owner CA certificate must be self-signed and currently valid'
pki_read_ca_passphrase
pki_openssl_with_passphrase pkey \
  -in "$CA_KEY" -passin stdin -pubout -out "$CA_KEY_PUBLIC" 2>/dev/null ||
  pki_die 'cannot decrypt owner CA key with the supplied passphrase'
cmp -s \
  <(openssl pkey -pubin -in "$CA_KEY_PUBLIC" -outform DER 2>/dev/null) \
  <(openssl pkey -pubin -in "$CA_CERT_PUBLIC" -outform DER 2>/dev/null) ||
  pki_die 'owner CA key does not match owner CA certificate'

cat >"$EXTENSIONS" <<'EOF'
[u60_server]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:u60.local,IP:192.168.0.1
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

SERIAL=$(openssl rand -hex 16)
if ! pki_openssl_with_passphrase x509 \
  -req -sha256 -days 825 \
  -in "$CSR" \
  -CA "$CA_CERT" \
  -CAkey "$CA_KEY" \
  -passin stdin \
  -set_serial "0x$SERIAL" \
  -extfile "$EXTENSIONS" \
  -extensions u60_server \
  -out "$CERT" 2>"$SIGNING_ERRORS"; then
  pki_die 'failed to sign device CSR'
fi
chmod 644 "$CERT"

cat "$CERT" "$CA_CERT" >"$CHAIN"
pki_certificate_pin "$CERT" >"$PIN"
chmod 644 "$CHAIN" "$PIN"
openssl verify -CAfile "$CA_CERT" -purpose sslserver "$CERT" >/dev/null
printf '%s\n' "$PKI_DEVICE_BUNDLE_COMPLETION" >"$COMPLETION"
chmod 644 "$COMPLETION"

pki_assert_absent "$OUTPUT_DIR/device-cert.pem"
pki_assert_absent "$OUTPUT_DIR/device-chain.pem"
pki_assert_absent "$OUTPUT_DIR/device-spki-pin.txt"
pki_assert_absent "$OUTPUT_DIR/device-bundle.complete"
pki_publish_files \
  "$CERT" "$OUTPUT_DIR/device-cert.pem" \
  "$CHAIN" "$OUTPUT_DIR/device-chain.pem" \
  "$PIN" "$OUTPUT_DIR/device-spki-pin.txt" \
  "$COMPLETION" "$OUTPUT_DIR/device-bundle.complete"
printf 'device certificate bundle created in %s\n' "$OUTPUT_DIR"
