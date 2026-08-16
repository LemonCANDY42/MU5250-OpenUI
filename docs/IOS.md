# iOS local-key client boundary

The imported open-u60-pro history is preserved under `clients/ios`, together
with its MIT notice. The application target deliberately compiles only
`SecureApp`, the upstream presentation-only `CardView`, resources and the new
unit tests. Legacy raw AT, ADB/USB, router-write and plaintext `/api` clients
remain available only as historical source and are not target members.

## Contract and transport

`openapi/u60-v1.yaml` remains the single contract source. The iOS target's
`SecureApp/openapi.yaml` is a repository symlink to that file. Apple's Swift
OpenAPI Generator 1.13.0 runs as an Xcode build plugin and generates both types
and client code; runtime, URLSession transport and HTTP Types versions are
directly pinned in `project.yml`, while the complete transitive resolution is
committed as `Package.resolved`. `scripts/check-ios-boundary.py` rejects a
copied or redirected schema, an unsafe target source, plaintext endpoint or an
ATS trust bypass.

Every request uses an ephemeral URLSession with no cookies or URL cache and a
bounded timeout. The session first performs normal Apple trust evaluation,
which requires the owner-installed local CA and the correct hostname. It then
computes SHA-256 over the leaf P-256 SubjectPublicKeyInfo and requires the exact
fingerprint received through the USB-maintenance pairing channel. The app does
not install a CA, inject a private trust anchor, weaken App Transport Security
or provide a trust-bypass mode. The `/v1` API has no redirect contract, so the
session refuses every HTTP redirect before a bearer token could be replayed to
plaintext, another host or another port.

Only `https://u60.local:9443`, its loopback-maintenance profile at port `19443`,
and the exact physical-client gate `https://192.168.0.1:9443` are accepted. The
fixed leaf covers both the name and management IP. The physical iPhone gate
uses the certificate-covered IP while the phone is joined directly to the U60
Wi-Fi, avoiding an unproven local-DNS dependency. `u60.local` remains the
preferred stable name and future RP-aligned endpoint.

## Local key and password fallback

On a physical iPhone the app creates a P-256 signing key in Secure Enclave and
stores only its enclave-wrapped representation in a non-synchronizing,
`WhenUnlockedThisDeviceOnly` Keychain item. The agent receives the public SPKI.
The simulator uses a software P-256 Keychain item only for host tests and labels
it as a simulator test key; it is not represented as a passkey.

The repository-local `.xcodebuildmcp/config.yaml` enables only the simulator and
physical-device workflows and keeps machine-specific device identifiers out of
Git. A Codex/XcodeBuildMCP session must be reloaded after this file is added or
changed before physical-device tools become available.

Credential metadata, certificate pin and endpoint are also device-local
Keychain records. Bearer tokens exist only in the in-memory `SessionVault` and
are cleared on sign-out. The dedicated management password is copied out of the
SwiftUI field, the field is cleared before the async request begins and the
value is never persisted. It must not be the stock router password.

Pairing and signed-out screens both provide an explicitly confirmed local
credential reset for a damaged or obsolete wrapped key. Reset attempts removal
of the metadata, pin/profile and signing key before reporting any error. This is
local recovery only: the corresponding public key must still be revoked on the
U60 through USB maintenance.

This local signing-key protocol is compatible with a later Apple Passkey layer
but is not WebAuthn. A real passkey still requires the owner's RP domain,
Associated Domains and an AASA file. That later feature must not remove the
offline local key or dedicated-password recovery paths.

## Pairing payload

The iOS scanner accepts only a strict, five-minute JSON payload:

```json
{
  "version": 1,
  "base_url": "https://u60.local:19443",
  "spki_sha256": "sha256/<base64 SHA-256 SPKI>",
  "pairing_nonce": "<base64url nonce>",
  "expires_at": "<UTC ISO-8601>"
}
```

The nonce itself comes from `zte-agent pair-open`, invoked only through USB
root ADB or already verified SSH. On the owner Mac, pipe that JSON on stdin to:

```sh
scripts/pairing/make-pairing-qr.sh \
  /absolute/path/to/verified-device-bundle \
  https://192.168.0.1:9443 \
  /absolute/path/outside-the-repository/u60-pairing.png
```

The tool requires the signed-bundle completion marker, reads only its public
SPKI pin, refuses output inside the repository, writes the QR at mode `0600`
through exclusive no-follow publication in a physically resolved output
directory, and never puts the nonce in an argument. The QR expires with the agent window.
The signed bundle must still pass `scripts/pki/verify-bundle.sh`; the QR tool is
not a substitute for certificate verification.

## Current evidence boundary

Current evidence establishes XcodeGen generation, build-plugin model
generation, a clean iOS simulator build and launch, unit tests for pairing
validation, local-key signing/storage and exact SPKI pin construction, plus an
owner-signed physical-device build, install and successful process launch. The
physical build used command-local team and bundle-identifier overrides; neither
identifier is committed to this public repository. It does not establish:

- Secure Enclave behavior on the owner's physical iPhone;
- installation or full trust of a real owner CA;
- a handshake with a real U60 certificate or live agent;
- QR pairing against a real maintenance window;
- a completed authenticated physical-device session.

Those remain later acceptance gates and do not authorize device changes.
