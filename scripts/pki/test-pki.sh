#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/u60-pki-test.XXXXXX")
TEST_ROOT=$(cd -P -- "$TEST_ROOT" && pwd -P)
TEST_PASSPHRASE='u60-test-only-passphrase-2026'
WRONG_PASSPHRASE='u60-test-only-wrong-pass-2026'
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

expect_failure() {
  local label=$1
  shift
  local output="$TEST_ROOT/negative-output.txt"
  : >"$output"
  if "$@" >"$output" 2>&1; then
    printf 'test-pki: expected failure: %s\n' "$label" >&2
    exit 1
  fi
  if grep -Fq "$TEST_PASSPHRASE" "$output" || grep -Fq "$WRONG_PASSPHRASE" "$output"; then
    printf 'test-pki: passphrase leaked during: %s\n' "$label" >&2
    exit 1
  fi
  if grep -Eq -- '-----BEGIN .*PRIVATE KEY-----' "$output"; then
    printf 'test-pki: private key leaked during: %s\n' "$label" >&2
    exit 1
  fi
}

assert_no_stage() {
  local directory=$1
  if [[ -d "$directory" ]] &&
    find "$directory" -mindepth 1 -maxdepth 1 -name '.pki-stage.*' -print -quit |
      grep -q .; then
    printf 'test-pki: staging directory survived failure in %s\n' "$directory" >&2
    exit 1
  fi
}

run_generate_in_working_directory() {
  local working_directory=$1
  (
    cd -- "$working_directory"
    "$SCRIPT_DIR/generate-device-csr.sh" .
  )
}

CA_DIR="$TEST_ROOT/ca"
DEVICE_DIR="$TEST_ROOT/device"
"$SCRIPT_DIR/create-owner-ca.sh" "$CA_DIR" 3<<<"$TEST_PASSPHRASE" >/dev/null
"$SCRIPT_DIR/generate-device-csr.sh" "$DEVICE_DIR" >/dev/null
"$SCRIPT_DIR/sign-device-csr.sh" \
  "$CA_DIR" "$DEVICE_DIR/device.csr.pem" "$DEVICE_DIR" \
  3<<<"$TEST_PASSPHRASE" >/dev/null
"$SCRIPT_DIR/verify-bundle.sh" "$DEVICE_DIR" "$CA_DIR/owner-ca-cert.pem" >/dev/null
pki_require_completion_marker \
  "$CA_DIR/owner-ca.complete" "$PKI_OWNER_CA_COMPLETION" 'test owner CA marker'
pki_require_completion_marker \
  "$DEVICE_DIR/device-csr.complete" "$PKI_DEVICE_CSR_COMPLETION" 'test device CSR marker'
pki_require_completion_marker \
  "$DEVICE_DIR/device-bundle.complete" "$PKI_DEVICE_BUNDLE_COMPLETION" 'test device bundle marker'

ALTERNATE_FD_CA="$TEST_ROOT/alternate-fd-ca"
U60_CA_PASSPHRASE_FD=9 \
  "$SCRIPT_DIR/create-owner-ca.sh" "$ALTERNATE_FD_CA" \
  9<<<"$TEST_PASSPHRASE" >/dev/null
openssl x509 -in "$ALTERNATE_FD_CA/owner-ca-cert.pem" -outform DER |
  cmp -s - "$ALTERNATE_FD_CA/owner-ca-cert.der"

[[ $(pki_file_mode "$CA_DIR/owner-ca-key.pem") == '600' ]]
[[ $(pki_file_mode "$DEVICE_DIR/device-key.pem") == '600' ]]
grep -q '^-----BEGIN ENCRYPTED PRIVATE KEY-----$' "$CA_DIR/owner-ca-key.pem"
openssl asn1parse -in "$CA_DIR/owner-ca-key.pem" -inform PEM | grep -q ':aes-256-cbc'
openssl x509 -in "$CA_DIR/owner-ca-cert.pem" -outform DER |
  cmp -s - "$CA_DIR/owner-ca-cert.der"
[[ $(pki_file_mode "$CA_DIR/owner-ca-cert.der") == '644' ]]
[[ ! -e "$DEVICE_DIR/owner-ca-key.pem" && ! -L "$DEVICE_DIR/owner-ca-key.pem" ]]
openssl x509 -in "$DEVICE_DIR/device-cert.pem" -checkend $((824 * 86400)) -noout >/dev/null
if openssl x509 -in "$DEVICE_DIR/device-cert.pem" -checkend $((826 * 86400)) -noout >/dev/null; then
  printf 'test-pki: leaf validity exceeds the 825-day default\n' >&2
  exit 1
fi

BACKDATED_DIR="$TEST_ROOT/backdated-validity"
BACKDATED_CA_STATE="$TEST_ROOT/backdated-ca-state"
BACKDATED_CONFIG="$TEST_ROOT/backdated-ca.cnf"
cp -R "$DEVICE_DIR" "$BACKDATED_DIR"
mkdir -m 700 "$BACKDATED_CA_STATE" "$BACKDATED_CA_STATE/newcerts"
: >"$BACKDATED_CA_STATE/index.txt"
printf '1000\n' >"$BACKDATED_CA_STATE/serial"
read -r BACKDATED_START BACKDATED_END < <(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone

start = datetime.now(timezone.utc) - timedelta(days=2)
end = start + timedelta(days=826)
print(start.strftime("%y%m%d%H%M%SZ"), end.strftime("%y%m%d%H%M%SZ"))
PY
)
{
  printf '%s\n' '[ca]'
  printf '%s\n' 'default_ca=u60_ca'
  printf '%s\n' '[u60_ca]'
  printf 'database=%s\n' "$BACKDATED_CA_STATE/index.txt"
  printf 'new_certs_dir=%s\n' "$BACKDATED_CA_STATE/newcerts"
  printf 'serial=%s\n' "$BACKDATED_CA_STATE/serial"
  printf '%s\n' 'default_md=sha256'
  printf '%s\n' 'default_days=825'
  printf '%s\n' 'policy=u60_policy'
  printf '%s\n' 'x509_extensions=u60_server'
  printf '%s\n' 'copy_extensions=none'
  printf '%s\n' 'unique_subject=no'
  printf '%s\n' '[u60_policy]'
  printf '%s\n' 'commonName=supplied'
  printf '%s\n' '[u60_server]'
  printf '%s\n' 'basicConstraints=critical,CA:false'
  printf '%s\n' 'keyUsage=critical,digitalSignature'
  printf '%s\n' 'extendedKeyUsage=serverAuth'
  printf '%s\n' 'subjectAltName=DNS:u60.local,IP:192.168.0.1'
  printf '%s\n' 'subjectKeyIdentifier=hash'
  printf '%s\n' 'authorityKeyIdentifier=keyid,issuer'
} >"$BACKDATED_CONFIG"
openssl ca \
  -batch -notext \
  -config "$BACKDATED_CONFIG" \
  -in "$BACKDATED_DIR/device.csr.pem" \
  -cert "$CA_DIR/owner-ca-cert.pem" \
  -keyfile "$CA_DIR/owner-ca-key.pem" \
  -passin fd:9 \
  -startdate "$BACKDATED_START" \
  -enddate "$BACKDATED_END" \
  -extensions u60_server \
  -out "$BACKDATED_DIR/device-cert.pem" \
  9<<<"$TEST_PASSPHRASE" >/dev/null 2>&1
cat "$BACKDATED_DIR/device-cert.pem" "$CA_DIR/owner-ca-cert.pem" \
  >"$BACKDATED_DIR/device-chain.pem"
pki_certificate_pin "$BACKDATED_DIR/device-cert.pem" \
  >"$BACKDATED_DIR/device-spki-pin.txt"
openssl verify \
  -CAfile "$CA_DIR/owner-ca-cert.pem" -purpose sslserver \
  "$BACKDATED_DIR/device-cert.pem" >/dev/null
if openssl x509 \
  -in "$BACKDATED_DIR/device-cert.pem" \
  -checkend $((825 * 86400)) -noout >/dev/null 2>&1; then
  printf 'test-pki: backdated certificate still has 825 days remaining\n' >&2
  exit 1
fi
expect_failure 'backdated leaf total validity over 825 days' \
  "$SCRIPT_DIR/verify-bundle.sh" "$BACKDATED_DIR" "$CA_DIR/owner-ca-cert.pem"
grep -Fq 'total validity span exceeds the 825-day profile' "$TEST_ROOT/negative-output.txt"

WRONG_OUTPUT="$TEST_ROOT/wrong-pass-output"
mkdir -m 700 "$WRONG_OUTPUT"
expect_failure 'wrong CA passphrase' \
  "$SCRIPT_DIR/sign-device-csr.sh" "$CA_DIR" "$DEVICE_DIR/device.csr.pem" "$WRONG_OUTPUT" \
  3<<<"$WRONG_PASSPHRASE"
[[ ! -e "$WRONG_OUTPUT/device-cert.pem" ]]
[[ ! -e "$WRONG_OUTPUT/device-chain.pem" ]]
[[ ! -e "$WRONG_OUTPUT/device-spki-pin.txt" ]]
assert_no_stage "$WRONG_OUTPUT"

RSA_DIR="$TEST_ROOT/rsa"
mkdir -m 700 "$RSA_DIR"
openssl req -new -newkey rsa:2048 -noenc \
  -subj '/CN=u60.local' \
  -keyout "$RSA_DIR/key.pem" \
  -out "$RSA_DIR/request.pem" >/dev/null 2>&1
printf '%s\n' "$PKI_DEVICE_CSR_COMPLETION" >"$RSA_DIR/device-csr.complete"
expect_failure 'non-P-256 CSR' \
  "$SCRIPT_DIR/sign-device-csr.sh" "$CA_DIR" "$RSA_DIR/request.pem" "$RSA_DIR" \
  3<<<"$TEST_PASSPHRASE"
[[ ! -e "$RSA_DIR/device-cert.pem" ]]
[[ ! -e "$RSA_DIR/device-chain.pem" ]]
[[ ! -e "$RSA_DIR/device-spki-pin.txt" ]]
assert_no_stage "$RSA_DIR"

SWAPPED_DIR="$TEST_ROOT/swapped-device"
cp -R "$DEVICE_DIR" "$SWAPPED_DIR"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
  -out "$SWAPPED_DIR/replacement-key.pem"
chmod 600 "$SWAPPED_DIR/replacement-key.pem"
mv "$SWAPPED_DIR/replacement-key.pem" "$SWAPPED_DIR/device-key.pem"
expect_failure 'device key replaced after CSR issuance' \
  "$SCRIPT_DIR/verify-bundle.sh" "$SWAPPED_DIR" "$CA_DIR/owner-ca-cert.pem"

LINK_TARGET="$TEST_ROOT/link-target"
mkdir -m 700 "$LINK_TARGET"
ln -s "$LINK_TARGET" "$TEST_ROOT/linked-output"
expect_failure 'symlink CA output' \
  "$SCRIPT_DIR/create-owner-ca.sh" "$TEST_ROOT/linked-output" \
  3<<<"$TEST_PASSPHRASE"
expect_failure 'symlink device output' \
  "$SCRIPT_DIR/generate-device-csr.sh" "$TEST_ROOT/linked-output"
expect_failure 'symlink signed-bundle output' \
  "$SCRIPT_DIR/sign-device-csr.sh" \
  "$CA_DIR" "$DEVICE_DIR/device.csr.pem" "$TEST_ROOT/linked-output" \
  3<<<"$TEST_PASSPHRASE"

LINKED_CA="$TEST_ROOT/linked-ca"
LINKED_CA_OUTPUT="$TEST_ROOT/linked-ca-output"
ln -s "$CA_DIR" "$LINKED_CA"
mkdir -m 700 "$LINKED_CA_OUTPUT"
expect_failure 'symlink CA directory' \
  "$SCRIPT_DIR/sign-device-csr.sh" \
  "$LINKED_CA" "$DEVICE_DIR/device.csr.pem" "$LINKED_CA_OUTPUT" \
  3<<<"$TEST_PASSPHRASE"
[[ ! -e "$LINKED_CA_OUTPUT/device-cert.pem" ]]

REPOSITORY_OUTPUT="$SCRIPT_DIR/.pki-test-forbidden-output"
[[ ! -e "$REPOSITORY_OUTPUT" && ! -L "$REPOSITORY_OUTPUT" ]]
expect_failure 'repository private-key output' \
  "$SCRIPT_DIR/generate-device-csr.sh" "$REPOSITORY_OUTPUT"
[[ ! -e "$REPOSITORY_OUTPUT" && ! -L "$REPOSITORY_OUTPUT" ]]

ROOT_MODE=$(pki_file_mode /)
expect_failure 'filesystem-root private-key output' \
  "$SCRIPT_DIR/generate-device-csr.sh" /
[[ $(pki_file_mode /) == "$ROOT_MODE" ]]

FAKE_HOME="$TEST_ROOT/fake-home"
mkdir -m 700 "$FAKE_HOME"
expect_failure 'user-home private-key output' \
  bash -c '
    set -euo pipefail
    source "$1"
    PKI_CURRENT_USER_HOME=$2
    pki_assert_private_directory_boundary "$2" "output directory"
  ' bash "$SCRIPT_DIR/_lib.sh" "$FAKE_HOME"
[[ $(pki_file_mode "$FAKE_HOME") == '700' ]]

WORKING_OUTPUT="$TEST_ROOT/working-output"
mkdir -m 700 "$WORKING_OUTPUT"
expect_failure 'current-working-directory private-key output' \
  run_generate_in_working_directory "$WORKING_OUTPUT"
[[ ! -e "$WORKING_OUTPUT/device-key.pem" ]]

REAL_PARENT="$TEST_ROOT/real-parent"
LINKED_PARENT="$TEST_ROOT/linked-parent"
mkdir -m 700 "$REAL_PARENT"
ln -s "$REAL_PARENT" "$LINKED_PARENT"
expect_failure 'symlink path component' \
  "$SCRIPT_DIR/generate-device-csr.sh" "$LINKED_PARENT/device-output"
[[ ! -e "$REAL_PARENT/device-output" ]]

INSECURE_OUTPUT="$TEST_ROOT/insecure-output"
mkdir -m 755 "$INSECURE_OUTPUT"
INSECURE_OUTPUT_MODE=$(pki_file_mode "$INSECURE_OUTPUT")
[[ "$INSECURE_OUTPUT_MODE" == '755' ]]
expect_failure 'existing output mode is not 0700' \
  "$SCRIPT_DIR/generate-device-csr.sh" "$INSECURE_OUTPUT"
[[ $(pki_file_mode "$INSECURE_OUTPUT") == "$INSECURE_OUTPUT_MODE" ]]
[[ ! -e "$INSECURE_OUTPUT/device-key.pem" ]]

OWNER_MISMATCH_OUTPUT="$TEST_ROOT/owner-mismatch-output"
mkdir -m 700 "$OWNER_MISMATCH_OUTPUT"
OWNER_MISMATCH_MODE=$(pki_file_mode "$OWNER_MISMATCH_OUTPUT")
MOCK_OTHER_UID=$(( $(id -u) + 1 ))
expect_failure 'existing output is owned by another user' \
  bash -c '
    set -euo pipefail
    source "$1"
    MOCK_UID=$2
    pki_file_uid() {
      printf "%s\n" "$MOCK_UID"
    }
    pki_prepare_output_dir "$3" no
    : >"$3/unexpected-artifact"
  ' bash "$SCRIPT_DIR/_lib.sh" "$MOCK_OTHER_UID" "$OWNER_MISMATCH_OUTPUT"
[[ $(pki_file_mode "$OWNER_MISMATCH_OUTPUT") == "$OWNER_MISMATCH_MODE" ]]
[[ ! -e "$OWNER_MISMATCH_OUTPUT/unexpected-artifact" ]]
assert_no_stage "$OWNER_MISMATCH_OUTPUT"

expect_failure 'CA and output are equal' \
  "$SCRIPT_DIR/sign-device-csr.sh" \
  "$CA_DIR" "$DEVICE_DIR/device.csr.pem" "$CA_DIR" \
  3<<<"$TEST_PASSPHRASE"
[[ ! -e "$CA_DIR/device-cert.pem" ]]

CA_DESCENDANT_OUTPUT="$CA_DIR/nested-output"
expect_failure 'output is below CA directory' \
  "$SCRIPT_DIR/sign-device-csr.sh" \
  "$CA_DIR" "$DEVICE_DIR/device.csr.pem" "$CA_DESCENDANT_OUTPUT" \
  3<<<"$TEST_PASSPHRASE"
[[ ! -e "$CA_DESCENDANT_OUTPUT" ]]

expect_failure 'output is above CA directory' \
  "$SCRIPT_DIR/sign-device-csr.sh" \
  "$CA_DIR" "$DEVICE_DIR/device.csr.pem" "$TEST_ROOT" \
  3<<<"$TEST_PASSPHRASE"
[[ ! -e "$TEST_ROOT/device-cert.pem" ]]

NONEMPTY="$TEST_ROOT/nonempty-ca"
mkdir -m 700 "$NONEMPTY"
: >"$NONEMPTY/existing"
expect_failure 'nonempty CA output' \
  "$SCRIPT_DIR/create-owner-ca.sh" "$NONEMPTY" \
  3<<<"$TEST_PASSPHRASE"
expect_failure 'owner CA overwrite' \
  "$SCRIPT_DIR/create-owner-ca.sh" "$CA_DIR" \
  3<<<"$TEST_PASSPHRASE"
expect_failure 'device key overwrite' "$SCRIPT_DIR/generate-device-csr.sh" "$DEVICE_DIR"
expect_failure 'signed bundle overwrite' \
  "$SCRIPT_DIR/sign-device-csr.sh" "$CA_DIR" "$DEVICE_DIR/device.csr.pem" "$DEVICE_DIR" \
  3<<<"$TEST_PASSPHRASE"

PARTIAL_OUTPUT="$TEST_ROOT/partial-output"
mkdir -m 700 "$PARTIAL_OUTPUT"
: >"$PARTIAL_OUTPUT/device-chain.pem"
expect_failure 'preexisting middle bundle artifact' \
  "$SCRIPT_DIR/sign-device-csr.sh" \
  "$CA_DIR" "$DEVICE_DIR/device.csr.pem" "$PARTIAL_OUTPUT" \
  3<<<"$TEST_PASSPHRASE"
[[ ! -e "$PARTIAL_OUTPUT/device-cert.pem" ]]
[[ ! -e "$PARTIAL_OUTPUT/device-spki-pin.txt" ]]
assert_no_stage "$PARTIAL_OUTPUT"

SYMLINK_BUNDLE="$TEST_ROOT/symlink-bundle"
mkdir -m 700 "$SYMLINK_BUNDLE"
ln -s "$TEST_ROOT/link-target-chain" "$SYMLINK_BUNDLE/device-chain.pem"
expect_failure 'symlink bundle artifact' \
  "$SCRIPT_DIR/sign-device-csr.sh" \
  "$CA_DIR" "$DEVICE_DIR/device.csr.pem" "$SYMLINK_BUNDLE" \
  3<<<"$TEST_PASSPHRASE"
[[ ! -e "$SYMLINK_BUNDLE/device-cert.pem" ]]
[[ ! -e "$SYMLINK_BUNDLE/device-spki-pin.txt" ]]
assert_no_stage "$SYMLINK_BUNDLE"

PARTIAL_CA="$TEST_ROOT/partial-ca"
PARTIAL_CA_OUTPUT="$TEST_ROOT/partial-ca-output"
mkdir -m 700 "$PARTIAL_CA" "$PARTIAL_CA_OUTPUT"
cp \
  "$CA_DIR/owner-ca-key.pem" \
  "$CA_DIR/owner-ca-cert.pem" \
  "$CA_DIR/owner-ca-cert.der" \
  "$PARTIAL_CA/"
expect_failure 'owner CA files without completion marker' \
  "$SCRIPT_DIR/sign-device-csr.sh" \
  "$PARTIAL_CA" "$DEVICE_DIR/device.csr.pem" "$PARTIAL_CA_OUTPUT" \
  3<<<"$TEST_PASSPHRASE"
[[ ! -e "$PARTIAL_CA_OUTPUT/device-cert.pem" ]]
assert_no_stage "$PARTIAL_CA_OUTPUT"

PARTIAL_CSR="$TEST_ROOT/partial-csr"
PARTIAL_CSR_OUTPUT="$TEST_ROOT/partial-csr-output"
mkdir -m 700 "$PARTIAL_CSR" "$PARTIAL_CSR_OUTPUT"
cp "$DEVICE_DIR/device-key.pem" "$DEVICE_DIR/device.csr.pem" "$PARTIAL_CSR/"
expect_failure 'device CSR files without completion marker' \
  "$SCRIPT_DIR/sign-device-csr.sh" \
  "$CA_DIR" "$PARTIAL_CSR/device.csr.pem" "$PARTIAL_CSR_OUTPUT" \
  3<<<"$TEST_PASSPHRASE"
[[ ! -e "$PARTIAL_CSR_OUTPUT/device-cert.pem" ]]
assert_no_stage "$PARTIAL_CSR_OUTPUT"

PARTIAL_BUNDLE="$TEST_ROOT/partial-bundle"
mkdir -m 700 "$PARTIAL_BUNDLE"
cp \
  "$DEVICE_DIR/device-key.pem" \
  "$DEVICE_DIR/device.csr.pem" \
  "$DEVICE_DIR/device-csr.complete" \
  "$DEVICE_DIR/device-cert.pem" \
  "$DEVICE_DIR/device-chain.pem" \
  "$DEVICE_DIR/device-spki-pin.txt" \
  "$PARTIAL_BUNDLE/"
expect_failure 'signed bundle files without completion marker' \
  "$SCRIPT_DIR/verify-bundle.sh" "$PARTIAL_BUNDLE" "$CA_DIR/owner-ca-cert.pem"
grep -Fq 'device bundle completion marker' "$TEST_ROOT/negative-output.txt"

TAMPERED_DIR="$TEST_ROOT/tampered-chain"
cp -R "$DEVICE_DIR" "$TAMPERED_DIR"
printf '\n' >>"$TAMPERED_DIR/device-chain.pem"
expect_failure 'tampered chain' \
  "$SCRIPT_DIR/verify-bundle.sh" "$TAMPERED_DIR" "$CA_DIR/owner-ca-cert.pem"

TAMPERED_PIN="$TEST_ROOT/tampered-pin"
cp -R "$DEVICE_DIR" "$TAMPERED_PIN"
printf 'sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n' >"$TAMPERED_PIN/device-spki-pin.txt"
expect_failure 'tampered pin' \
  "$SCRIPT_DIR/verify-bundle.sh" "$TAMPERED_PIN" "$CA_DIR/owner-ca-cert.pem"

INSECURE_KEY="$TEST_ROOT/insecure-key"
cp -R "$DEVICE_DIR" "$INSECURE_KEY"
chmod 644 "$INSECURE_KEY/device-key.pem"
expect_failure 'insecure device-key permissions' \
  "$SCRIPT_DIR/verify-bundle.sh" "$INSECURE_KEY" "$CA_DIR/owner-ca-cert.pem"

SYMLINK_FILE_DIR="$TEST_ROOT/symlink-file"
mkdir -m 700 "$SYMLINK_FILE_DIR"
ln -s "$TEST_ROOT/link-target-key" "$SYMLINK_FILE_DIR/device-key.pem"
expect_failure 'symlink device-key destination' \
  "$SCRIPT_DIR/generate-device-csr.sh" "$SYMLINK_FILE_DIR"
[[ ! -e "$SYMLINK_FILE_DIR/device.csr.pem" ]]
assert_no_stage "$SYMLINK_FILE_DIR"

printf 'PKI tests passed\n'
