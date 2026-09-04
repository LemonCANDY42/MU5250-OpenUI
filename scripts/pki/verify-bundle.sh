#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

[[ $# -eq 3 ]] || pki_die 'usage: verify-bundle.sh CSR_DIR BUNDLE_DIR CA_CERT'
CSR_DIR=$1
BUNDLE_DIR=$2
CA_CERT=$3
CSR="$CSR_DIR/device.csr.pem"
CERT="$BUNDLE_DIR/device-cert.pem"
CHAIN="$BUNDLE_DIR/device-chain.pem"
PIN="$BUNDLE_DIR/device-spki-pin.txt"
CSR_COMPLETION="$CSR_DIR/device-csr.complete"
BUNDLE_COMPLETION="$BUNDLE_DIR/device-bundle.complete"
CA_DIRECTORY=$(dirname -- "$CA_CERT")
CA_COMPLETION="$CA_DIRECTORY/owner-ca.complete"

pki_require_command openssl
pki_require_command python3
pki_validate_existing_private_directory "$CSR_DIR" 'device CSR directory'
pki_validate_existing_private_directory "$BUNDLE_DIR" 'device bundle directory'
pki_validate_existing_private_directory "$CA_DIRECTORY" 'CA directory'
pki_require_completion_marker \
  "$CSR_COMPLETION" "$PKI_DEVICE_CSR_COMPLETION" 'device CSR completion marker'
pki_require_completion_marker \
  "$BUNDLE_COMPLETION" "$PKI_DEVICE_BUNDLE_COMPLETION" 'device bundle completion marker'
pki_require_completion_marker \
  "$CA_COMPLETION" "$PKI_OWNER_CA_COMPLETION" 'owner CA completion marker'
pki_require_regular_file "$CSR" 'device CSR'
pki_require_regular_file "$CERT" 'device certificate'
pki_require_regular_file "$CHAIN" 'device chain'
pki_require_regular_file "$PIN" 'device SPKI pin'
pki_require_regular_file "$CA_CERT" 'owner CA certificate'

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/u60-pki-verify.XXXXXX")
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
CSR_PUBLIC="$TEMP_DIR/csr-public.pem"
CERT_PUBLIC="$TEMP_DIR/cert-public.pem"
CA_PUBLIC="$TEMP_DIR/ca-public.pem"
EXPECTED_CHAIN="$TEMP_DIR/expected-chain.pem"
EXPECTED_PIN="$TEMP_DIR/expected-pin.txt"
VALIDITY_DATES="$TEMP_DIR/validity-dates.txt"

openssl req -in "$CSR" -verify -noout >/dev/null 2>&1 ||
  pki_die 'device CSR self-signature is invalid'
[[ $(openssl req -in "$CSR" -subject -nameopt RFC2253 -noout) == 'subject=CN=u60.local' ]] ||
  pki_die 'device CSR subject is not fixed to CN=u60.local'
openssl req -in "$CSR" -pubkey -noout >"$CSR_PUBLIC"
openssl x509 -in "$CERT" -pubkey -noout >"$CERT_PUBLIC"
openssl x509 -in "$CA_CERT" -pubkey -noout >"$CA_PUBLIC"
pki_is_p256_public_key "$CSR_PUBLIC" || pki_die 'device CSR public key must be P-256'
pki_is_p256_public_key "$CERT_PUBLIC" || pki_die 'device certificate public key must be P-256'
pki_is_p256_public_key "$CA_PUBLIC" || pki_die 'owner CA certificate public key must be P-256'
cmp -s \
  <(openssl pkey -pubin -in "$CSR_PUBLIC" -outform DER 2>/dev/null) \
  <(openssl pkey -pubin -in "$CERT_PUBLIC" -outform DER 2>/dev/null) ||
  pki_die 'device CSR does not match device certificate'

openssl verify -CAfile "$CA_CERT" -purpose sslserver "$CERT" >/dev/null 2>&1 ||
  pki_die 'device certificate chain verification failed'
LC_ALL=C openssl x509 -in "$CERT" -noout -startdate -enddate \
  >"$VALIDITY_DATES" 2>/dev/null || pki_die 'cannot read device certificate validity dates'
if ! VALIDITY_SPAN_SECONDS=$(
  python3 - "$VALIDITY_DATES" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import re
import sys

MONTHS = {
    "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4,
    "May": 5, "Jun": 6, "Jul": 7, "Aug": 8,
    "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
}
PATTERN = re.compile(
    r"^(notBefore|notAfter)="
    r"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) +"
    r"([0-9]{1,2}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) ([0-9]{4}) GMT$"
)

values = {}
for line in Path(sys.argv[1]).read_text(encoding="ascii").splitlines():
    match = PATTERN.fullmatch(line)
    if match is None or match.group(1) in values:
        raise SystemExit(1)
    name, month, day, hour, minute, second, year = match.groups()
    values[name] = datetime(
        int(year), MONTHS[month], int(day), int(hour), int(minute), int(second),
        tzinfo=timezone.utc,
    )

if set(values) != {"notBefore", "notAfter"}:
    raise SystemExit(1)
span = int((values["notAfter"] - values["notBefore"]).total_seconds())
if span <= 0:
    raise SystemExit(1)
print(span)
PY
); then
  pki_die 'cannot parse device certificate validity dates'
fi
[[ "$VALIDITY_SPAN_SECONDS" =~ ^[0-9]+$ ]] ||
  pki_die 'device certificate validity span is invalid'
((VALIDITY_SPAN_SECONDS <= 825 * 86400)) ||
  pki_die 'device certificate total validity span exceeds the 825-day profile'
cat "$CERT" "$CA_CERT" >"$EXPECTED_CHAIN"
cmp -s "$EXPECTED_CHAIN" "$CHAIN" || pki_die 'device chain is not exactly leaf plus owner CA'

[[ $(openssl x509 -in "$CERT" -subject -nameopt RFC2253 -noout) == 'subject=CN=u60.local' ]] ||
  pki_die 'device certificate subject is not fixed to CN=u60.local'
SAN=$(openssl x509 -in "$CERT" -ext subjectAltName -noout | tr -d '[:space:]')
[[ "$SAN" == 'X509v3SubjectAlternativeName:DNS:u60.local,IPAddress:192.168.0.1' ]] ||
  pki_die 'device SAN set is invalid'
BASIC=$(openssl x509 -in "$CERT" -ext basicConstraints -noout | tr -d '[:space:]')
[[ "$BASIC" == 'X509v3BasicConstraints:criticalCA:FALSE' ]] ||
  pki_die 'device certificate must declare critical CA:false'
KEY_USAGE=$(openssl x509 -in "$CERT" -ext keyUsage -noout | tr -d '[:space:]')
[[ "$KEY_USAGE" == 'X509v3KeyUsage:criticalDigitalSignature' ]] ||
  pki_die 'device certificate key usage is invalid'
EKU=$(openssl x509 -in "$CERT" -ext extendedKeyUsage -noout | tr -d '[:space:]')
[[ "$EKU" == 'X509v3ExtendedKeyUsage:TLSWebServerAuthentication' ]] ||
  pki_die 'device certificate EKU is invalid'

pki_certificate_pin "$CERT" >"$EXPECTED_PIN"
cmp -s "$EXPECTED_PIN" "$PIN" || pki_die 'device SPKI pin mismatch'
IFS= read -r RECORDED_PIN <"$PIN" || pki_die 'device SPKI pin is empty'
[[ "$RECORDED_PIN" =~ ^sha256/[A-Za-z0-9+/]{43}=$ ]] || pki_die 'device SPKI pin format is invalid'

printf 'device certificate bundle verified\n'
