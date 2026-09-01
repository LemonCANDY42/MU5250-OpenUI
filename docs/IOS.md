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
the independent device rollback worker. The listener keeps that worker
independent for crash-safe recovery while a bounded parent-side reaper waits
for its exit. The worker polls only the private transaction record and exits
promptly once confirmation clears or replaces that identifier, so completed
transactions do not retain workers for the full window or accumulate zombies. The
app creates and persists the
transaction identifier before requesting any Wi-Fi mutation, then resumes
automatic confirmation probes after transient disconnects, repeated network
switches, app foregrounding and process relaunch. Each probe uses a fresh pinned
HTTPS session so a connection from before the radio reload cannot count as
reconnection proof. Confirmation re-reads the requested fields before
cancelling rollback, refreshes the client status, and then shows an explicit
reconnection-and-verification success message. An expired key session receives
one bounded renewal and one confirmation retry. Explicit terminal server
responses clear the local pending record; transport, contract or still-armed
recovery ambiguity retains it until a later probe or the deadline. The charging screen is read-only;
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
Card content is clipped to the rounded card boundary throughout collapse
animations, and refresh keeps a stable toolbar layout by pulsing a fixed refresh
button instead of inserting and removing a separate progress item. The ten fixed
read-only capabilities and optional charging status are returned by one typed,
partial-success dashboard snapshot. The U60 performs the same fixed reads
locally and reports an independent failure for any unavailable component, so a
weak link incurs one HTTPS request window without making one bad sensor discard
the successful cards. The server responds within an 11-second collection
budget, below the client's 15-second transport timeout; values completed before
that boundary remain usable. Individual read routes remain for older clients and
focused diagnostics. The monitoring menu remains separate from the explicit
refresh button.
Card order, collapsed state, monitoring interval, graph range and per-series
chart visibility are remembered in device-local Keychain state. Manual refresh
remains the default to minimize device and radio load, with explicit two-second,
five-second, 15-second, 30-second and one-minute monitoring choices. Successful
status refreshes append a bounded, up-to-24-hour local telemetry history used
for battery, router-observed Wi-Fi RSSI, LTE/5G RSRP, multi-sensor thermal and
optional CPU/memory/storage usage charts. The dashboard groups the current
Wi-Fi and cellular signal readings in one Signal strength card, with separate
Wi-Fi and LTE/5G history charts inside that card. Configured channel policy, the
optional radio-observed current channel, other radio settings, feature state and
client-link rates remain in a separate Wi-Fi information card; provider,
network, band, aggregation, cell-lock and connection details remain in a
separate Cellular information card. History is retained at five-second spacing
for the latest hour, 30-second spacing through six hours and two-minute spacing
through 24 hours, capped at 2,000 samples. Each selected graph range uses the
same matching display granularity. Existing dense or older fixed-spacing history
is migrated into the tiered 24-hour window on load, and old
samples without the optional Wi-Fi signal or system percentages remain
decodable. Known connection loss and long sampling gaps start a new chart
segment, so the UI does not draw invented values through time when the phone was
away from the U60 network. Wi-Fi, LTE, 5G, thermal and system series can be shown or hidden
independently and their visibility is remembered; no background daemon or U60
write is involved.
Expected read-path connectivity failures from weak Wi-Fi, locking the phone or
leaving the U60 network retain the last successful dashboard instead of opening
a blocking alert. A compact status banner distinguishes weak and disconnected
paths. It occupies reserved space below each primary navigation toolbar and does
not intercept toolbar interaction, while bounded foreground retries use fresh
pinned HTTPS sessions and clear the banner after recovery. Retries pause outside
the foreground. A read that receives `401` renews the scoped session once with
the stored device key and retries that read once; it never extends the server's
one-hour idle or twelve-hour absolute session limits. Repeated automatic refresh
failures with the same explicit error do not repeatedly present a blocking
alert, and a successful snapshot resets that suppression. Trust, failed
reauthentication, response-contract and write-operation failures remain
explicit errors; the connectivity banner never turns an ambiguous write result
into an assumed success.
The agent reads normalized device identity before admitting at most one
aggregate snapshot for blocking work. An overlapping native refresh therefore
starts no second aggregate source pass, waits only within its own server budget
and receives the existing typed timeout shape if admission remains occupied.
The permit is not released merely because the earlier HTTP response reached its
budget.
Apple's public accessory-network API does not expose the current iPhone Wi-Fi
RSSI. The dashboard instead uses optional request context and labels RSSI and
link rates as U60 router observations only when the HTTPS peer uniquely matches
a DHCP lease and station. The RSSI appears in Signal strength while link rates
remain in Wi-Fi information. The Wi-Fi control status page uses that same
router-observed value and labels it as such; missing or ambiguous correlation
states that the U60 is not currently observing the client rather than implying
that no signal source exists. Missing context never fails Wi-Fi status. Radio aggregation, selection and
read-only cell-lock summaries are optional so new clients remain compatible
with earlier V1 agents. The battery card similarly shows optional validated
health, cycle, learned/design capacity and applicable kernel-estimate fields.
When both capacity fields are available, it derives battery health as learned
full capacity divided by design capacity without capping the result at 100%; it
keeps the kernel-reported condition as a separate status and omits the derived
percentage when either input is unavailable or invalid.
The required battery percentage remains the real kernel fuel-gauge value. When
the optional stock-device percentage differs, the card shows both the stock
device display percentage and the fuel-gauge percentage instead of silently
choosing one. A recognized long-charge protection mode adds a named status row
with a native, accessible information button explaining the expected 100% stock
display versus approximately 80% fuel-gauge behavior and the stock reconnect-
charger exit guidance. Older agents omit these optional fields and retain the
single-capacity presentation.
The signed charge counter is explicitly labeled as relative, never as remaining
capacity, and is not charted. Zero time-to-full at the charging/full boundary is
shown as complete; other kernel estimates are omitted beyond the 30-day
plausibility window.

While the battery is discharging, the native app also derives two local runtime
estimates without adding any agent endpoint, background sampler or Web feature.
It uses only the real fuel-gauge battery percentage, learned full capacity (falling back
to design capacity) and signed instantaneous current already returned by V1.
The first preliminary result can appear after at least one minute and three
continuous discharge samples. During this early window, samples use ten-second
median buckets and a two-minute recency weighting so a two-second refresh does
not carry more weight than a slower refresh. After five minutes the estimate is
established using 30-second median buckets, at least six populated buckets and a
ten-minute recency weighting. In both stages the bucket median rejects short
spikes, the time-weighted recent rate produces the typical estimate, and the
90th-percentile rate produces the shorter conservative estimate. Both reserve
five percentage points rather than extrapolating to displayed zero. A fresh
latest sample and no gap longer than three minutes are always required;
charging, state changes, connectivity discontinuities and stale history suppress
the estimate instead of joining or inventing samples. Existing local history
remains decodable because the additional battery sample fields are optional.

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

Physical-device signing must take `DEVELOPMENT_TEAM` from Xcode's selected
developer team or from a verified provisioning profile `TeamIdentifier`. The
parenthesized ten-character suffix displayed in an `Apple Development`
certificate name is an account/certificate identifier and must not be inferred
to be the team identifier. Before installation, verify the built app's signed
`com.apple.developer.team-identifier` and exact paired
`application-identifier`; a successful build of a differently signed or default
bundle is not physical-client acceptance.

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
The current source exposes the saved 2.4/5 GHz primary AP switches only when
the stock multi-band state permits independent control. It keeps all ten power
percentages while labeling the device's documented 40, 80 and 100 percent
presets as short, medium and long range. Per-band changes use the existing
reconnect-confirmed rollback transaction. The stock Wi-Fi master and
multi-band controls are intentionally absent after physical-device behavior
proved they could not be made deterministic through this control plane. Their
state remains observable; while stock multi-band mode is active, 5 GHz identity
follows 2.4 GHz and the independent AP toggles are disabled. An
explicit terminal rollback response clears the device-local pending record and
refreshes the form immediately; only an ambiguous response loss or typed
pending-recovery response continues the confirmation loop. The 5 GHz identity
fields are read-only in the form while multi-band integration is enabled.
Source and simulator
acceptance do not establish live Wi-Fi behavior. Physical-device readback and
recovery acceptance, stable activation, boot integration and the final soak
remain separate gates.
