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

## Native control hierarchy and localization

The authenticated Control tab uses native SwiftUI navigation rather than one
flat mutation form. Its landing page summarizes read-only charging state plus
Wi-Fi, traffic-cycle and SMS controls; each write operation owns a separate
detail screen and centered confirmation alert. The Wi-Fi screen mirrors the useful hierarchy of the imported MIT client
while keeping the V1 safety boundary: typed primary and guest fields only,
fixed channel/bandwidth/transmit-power choices, no raw UCI/ubus surface, no
prefilled password, and a visible two-minute reconnect confirmation backed by
the independent device rollback worker. The app creates and persists the
transaction identifier before requesting any Wi-Fi mutation, then resumes
automatic confirmation probes after transient disconnects, repeated network
switches, app foregrounding and process relaunch. Each probe uses a fresh pinned
HTTPS session so a connection from before the radio reload cannot count as
reconnection proof. Confirmation re-reads the requested fields before
cancelling rollback, refreshes the client status, and then shows an explicit
reconnection-and-verification success message. The charging screen is read-only;
V1 exposes no charger mutation because B04 write-result and recovery semantics
are not sufficiently proven. B04 exposes Wi-Fi 7 through its EHT
radio mode but no independent switch source, so the client reports that state
without presenting a nonfunctional toggle. The B04 capability source explicitly
reports MLO as unsupported and band steering as supported and enabled; those are
shown as read-only facts. The 5 GHz radio exposes fixed 20, 40, 80 and 160 MHz
widths rather than a combined automatic-width value.

The Wi-Fi detail uses a native segmented Status/Modify view so observed state is
not mixed with editable values. The authenticated dashboard uses collapsible
cards and a dedicated reorder sheet; unavailable cards retain their normal
position and remain reorderable instead of being appended as unowned errors.
Card order, collapsed state, monitoring interval, graph range and per-series
chart visibility are remembered in device-local Keychain state. Manual refresh
remains the default to minimize device and radio load, with explicit five-second,
15-second, 30-second, one-minute and five-minute monitoring choices. Successful
status refreshes append a bounded, up-to-seven-day local telemetry history used
for battery, LTE/5G RSRP and multi-sensor thermal charts. Signal and thermal
series can be shown or hidden independently; no background daemon or U60 write
is involved. The five-second display option still respects the history store's
bounded sampling window rather than growing the retained history without limit.
Apple's public accessory-network API does not expose the current iPhone Wi-Fi
RSSI, so the UI states that limitation rather than displaying an inferred or
router-side substitute.

English and Simplified Chinese resources cover this control hierarchy and its
confirmation, warning and recovery text. SwiftUI literals use the string table;
dynamic network names and device values remain data rather than localization
keys. One root-level error presenter owns operation failures so nested control
views cannot race to dismiss the same alert.

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

If the device clock differs from the Mac clock, capture `HOST_EPOCH` on the
owner Mac immediately before capturing `DEVICE_EPOCH` on the device. Capture
the device epoch and obtain the `pair-open` grant in the same USB-root-ADB
maintenance sequence, then pass both clock samples together. The grant remains
on stdin; the nonce must not be put in an argument or log:

```sh
scripts/pairing/make-pairing-qr.sh \
  /absolute/path/to/verified-device-bundle \
  https://192.168.0.1:9443 \
  /absolute/path/outside-the-repository/u60-pairing.png \
  "$HOST_EPOCH" \
  "$DEVICE_EPOCH"
```

The paired clock path subtracts host time elapsed since the samples and a small
safety margin from the device window. The QR therefore carries a conservative
local display deadline that can expire before the device grant. The backend's
boot-bound monotonic pairing window remains authoritative.

The tool requires the signed-bundle completion marker, reads only its public
SPKI pin, refuses output inside the repository, writes the QR at mode `0600`
through exclusive no-follow publication in a physically resolved output
directory, and never puts the nonce in an argument. The QR has a locally
bounded display lifetime of at most five minutes; the
backend's pairing window remains authoritative.

Before invoking the QR tool, the owner must verify the signed bundle with
`scripts/pki/verify-bundle.sh CSR_DIR BUNDLE_DIR CA_CERT`; the QR tool is not a
substitute for certificate verification.

## Current evidence boundary

Current evidence establishes XcodeGen generation, generated-contract simulator
tests, owner-signed physical-device build/install/launch, owner-CA full trust,
Secure Enclave QR pairing through a real maintenance window and a completed
authenticated physical-device session against the nonpersistent LAN canary.
Those accepted read/session gates do not authorize daily writes or persistent
installation. Each remaining mutation requires its own explicit owner approval,
device readback and recovery acceptance; stable activation, boot integration
and the final soak remain separate gates.
