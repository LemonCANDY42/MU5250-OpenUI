#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

[[ $# -eq 1 ]] || pki_die 'usage: create-owner-ca.sh OUTPUT_DIR'
OUTPUT_DIR=$1

pki_require_command openssl
pki_prepare_output_dir "$OUTPUT_DIR" yes
pki_assert_absent "$OUTPUT_DIR/owner-ca-key.pem"
pki_assert_absent "$OUTPUT_DIR/owner-ca-cert.pem"
pki_assert_absent "$OUTPUT_DIR/owner-ca-cert.der"
pki_assert_absent "$OUTPUT_DIR/owner-ca.complete"
pki_read_ca_passphrase

PKI_STAGE_DIR=$(pki_new_stage_dir "$OUTPUT_DIR")
trap pki_cleanup_stage EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
KEY="$PKI_STAGE_DIR/owner-ca-key.pem"
CERT="$PKI_STAGE_DIR/owner-ca-cert.pem"
CERT_DER="$PKI_STAGE_DIR/owner-ca-cert.der"
PUBLIC_KEY="$PKI_STAGE_DIR/owner-ca-public.pem"
COMPLETION="$PKI_STAGE_DIR/owner-ca.complete"

pki_openssl_with_passphrase genpkey \
  -algorithm EC \
  -pkeyopt ec_paramgen_curve:P-256 \
  -aes-256-cbc \
  -pass stdin \
  -out "$KEY"
chmod 600 "$KEY"

pki_openssl_with_passphrase req \
  -new -x509 -sha256 -days 3650 \
  -key "$KEY" -passin stdin \
  -subj '/CN=U60 Private Owner Root CA' \
  -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -addext 'subjectKeyIdentifier=hash' \
  -out "$CERT"
chmod 644 "$CERT"
openssl x509 -in "$CERT" -outform DER -out "$CERT_DER"
chmod 644 "$CERT_DER"

grep -q '^-----BEGIN ENCRYPTED PRIVATE KEY-----$' "$KEY" ||
  pki_die 'owner CA private key was not written as encrypted PKCS#8'
pki_openssl_with_passphrase pkey -in "$KEY" -passin stdin -check -noout >/dev/null
openssl verify -CAfile "$CERT" "$CERT" >/dev/null
openssl x509 -in "$CERT" -pubkey -noout >"$PUBLIC_KEY"
pki_is_p256_public_key "$PUBLIC_KEY" || pki_die 'owner CA certificate is not P-256'
openssl x509 -in "$CERT" -outform DER | cmp -s - "$CERT_DER" ||
  pki_die 'owner CA DER certificate does not match the PEM certificate'
printf '%s\n' "$PKI_OWNER_CA_COMPLETION" >"$COMPLETION"
chmod 644 "$COMPLETION"

pki_assert_absent "$OUTPUT_DIR/owner-ca-key.pem"
pki_assert_absent "$OUTPUT_DIR/owner-ca-cert.pem"
pki_assert_absent "$OUTPUT_DIR/owner-ca-cert.der"
pki_assert_absent "$OUTPUT_DIR/owner-ca.complete"
pki_publish_files \
  "$KEY" "$OUTPUT_DIR/owner-ca-key.pem" \
  "$CERT" "$OUTPUT_DIR/owner-ca-cert.pem" \
  "$CERT_DER" "$OUTPUT_DIR/owner-ca-cert.der" \
  "$COMPLETION" "$OUTPUT_DIR/owner-ca.complete"
printf 'owner CA created in %s\n' "$OUTPUT_DIR"
