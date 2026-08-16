# Private B04 platform architecture

This document owns the target boundaries for the private HK B04 integration.
It distinguishes implemented source behavior, immediate canary acceptance and
later stable-install acceptance.

## Product boundary

The platform is for one owner-operated MU5250. Daily operation must remain
local, lightweight and independent of NAS or cloud availability. NAS is only a
backup and diagnostic-export target.

The public client contract is a versioned, strongly typed `/v1` API. Clients
never submit an AT command, ubus object or method, UCI key, shell command,
process signal, filesystem path or vendor JSON blob. Unsupported B04 behavior
is represented by capability state, not by a button that fails at runtime.

The following surfaces are permanently excluded:

- raw AT, ubus, UCI or shell execution;
- process-killing or firmware "debloat" actions;
- factory reset, firmware flashing and FOTA control.

An operation that can only be implemented through AT may be added internally
only as a compile-time enum mapped to one complete fixed command, fixed timeout
and dedicated parser. The first release defines no such client operation.

## Layers

```text
iOS / web / future Android
          |
      OpenAPI 3.1
          |
      /v1 domain API
          |
   B04Adapter boundary
          |
ubus/UCI | proc/sysfs | SQLite | fixed internal operations
```

`B04Adapter` owns every firmware-specific identifier and representation. The
domain API owns units, nullability, error semantics and capability state.
OpenAPI is the single source for generated Swift and TypeScript models.
TypeScript generation is isolated in `tools/openapi`, locked by its own package
lock and consumed by the compiled web contract fixture. The iOS target uses a
symlink to that exact contract with Apple's pinned Swift OpenAPI Generator;
SwiftPM's full transitive resolution is committed. The target compiles only the
new `SecureApp`, resources and one presentation-only upstream component. Legacy
handwritten `/api`, raw-AT, USB and router-write code is not in its build graph.
Both client artifact gates reject drift.

Each capability reports one of `available`, `degraded` or `unsupported`, with a
reason and recovery requirement where applicable. Source support and real B04
acceptance are separate facts: a capability is not considered available until
the exact adapter path has passed the single-device acceptance gate.

## V1 acceptance boundary

V1 ends only when the public integration branch and the single HK B04 device
have completed the following four stages. A host-only implementation or a
loopback canary is evidence for a stage, not completion of V1.

1. **Host-only safety baseline**: remove raw AT and process-killing surfaces;
   introduce the adapter boundary, read-only `/v1` identity/capability/status
   contract, fixtures, tests and CI. The public branch starts from current MU
   upstream plus repository hygiene; hardened work is selectively ported from a
   clean base instead of merging the private branch history.
2. **Read-only B04 probe**: with root ADB retained, record capability evidence
   and a redacted hash manifest directly to the approved NAS backup share. The
   fixed source list and host-network invariants are specified in
   [READ-ONLY-PROBE.md](READ-ONLY-PROBE.md); source validation alone is not live
   device acceptance. V1 read-only scope includes device identity, dashboard,
   signal and cellular state, traffic, battery, thermal, Wi-Fi state, LAN
   clients and SMS listing.
3. **HTTPS, clients and daily operations**: the protocol, state model, TLS-only listener and
   offline [owner PKI tooling](PKI.md) are implemented. Real owner/leaf material
   was created through the separately authorized maintenance gate, and a
   loopback-only `19443` canary passed the immediate TLS, password-auth and five
   read-only endpoint gate. The owner-accepted device-process one-hour checkpoint
   also passed. The listener serves one canonical, symlink-free web build only
   when explicitly configured. V1 additionally requires real browser and
   physical-iPhone CA trust, key pairing and handshake acceptance. The web and
   iOS clients share generated `/v1` models and capability-driven UI. Daily
   writes are SMS send, charging threshold/pause/resume, traffic-cycle reset and
   transactional Wi-Fi with a persisted roughly 120-second confirmation window,
   reboot-safe rollback, applied-state readback and a dedicated recovery test.
   APN and network mode remain read-only.
4. **Stable owner install**: publish content-addressed releases under
   `/data/u60/releases/<content-hash>/`, switch one atomic symlink, retain one
   known-good rollback release and use one minimal startup entry without a new
   firewall or init hook. Updates remain manual and fail back to the previous
   release. Dropbear must listen only on the management address and port `2222`
   with `-s -g`; public-key success, password failure and two independent
   recovery keys are accepted while root USB ADB remains available. Final V1
   acceptance is a one-hour active soak covering polling, client reconnect,
   agent restart, failed-version rollback, bounded logs and unchanged USB, WAN,
   Wi-Fi, FOTA, boot and Mac route/TUN invariants. This owner-approved gate does
   not claim the earlier 24-hour RSS-growth target.

The following remain post-V1: true Apple Passkey/WebAuthn with an owner domain
and AASA, Android, Tailscale/DoH/speed-test/scheduler/USSD/STK plugins, and
high-risk APN, network-mode, band/cell, USB or FOTA writes. Useful MU and
open-u60-pro implementations may inform V1, but no upstream raw AT, arbitrary
ubus/UCI/shell, kill-bloat, factory-reset, firmware or process-control surface
is enabled merely because it exists upstream.

### V1 feature selection from MU and open-u60-pro

V1 deliberately takes the mature, low-risk overlap instead of copying either
upstream feature list wholesale:

| Included V1 domain | Source value retained | Safety boundary |
| --- | --- | --- |
| Signal/cellular/dashboard | MU's compact device UI and open-u60-pro's richer normalized status | Read-only typed values; no raw AT or vendor JSON |
| Traffic/battery/thermal | Proven firmware sources and charge-policy semantics | Bounded reads; charge writes use fixed enum/state transitions |
| Wi-Fi/LAN | Useful settings and connected-client views | No arbitrary UCI; Wi-Fi changes are persisted transactions with timeout rollback |
| SMS | Listing and sending from both projects | Bounded pages; oversized content is UTF-8-safe truncated and flagged, malformed records are counted and omitted; no SQL fallback, bulk delete, forwarding plugin or arbitrary modem command |
| Web/iOS clients | MU information density plus open-u60-pro SwiftUI navigation | One OpenAPI contract, capability hiding, pinned HTTPS and public-key login |

SIM identifiers, raw process lists, APN credentials, DNS/firewall control,
network/band/cell lock, USB composition, FOTA, reboot/shutdown, arbitrary AT,
ubus/UCI/shell and external forwarding remain outside V1. Active radio type is
reported through normalized signal status; the configured APN is not exposed
until a separate redaction contract and B04 acceptance exist.

## Authentication target

The host-tested local protocol uses client-held public keys:

- iOS keys are generated in Secure Enclave when supported;
- web keys are non-exportable WebCrypto P-256 keys bound to that browser;
- the web dashboard stores those CryptoKeys and non-secret credential metadata
  in IndexedDB while keeping every bearer token only in page memory;
- a five-minute pairing window is opened only by the local maintenance CLI;
  later deployment must make that CLI reachable solely over USB root ADB or an
  already verified SSH connection;
- replay-resistant challenge signing creates scoped sessions.

A separate high-entropy management password is an HTTPS-only recovery path. It
is never the router password. Persistent state stores only an Argon2id verifier;
a normal session has a one-hour sliding and twelve-hour absolute expiry. An
advanced five-minute non-sliding token requires both an existing admin session
and password re-entry. Key sessions receive only `read` and `daily` scopes.
Progressive password lockout is persisted with hashed client identifiers and
bounded retention. A cross-process state lock makes each pairing and credential
read-modify-write operation indivisible between the server and maintenance CLI.
Volatile session and challenge deadlines use a monotonic clock, so an unobserved
wall-clock rollback and rebound cannot extend them. Persisted pairing binds its
monotonic deadline to the Linux boot UUID and fails closed after reboot or when
the boot identity is unavailable or mismatched. Wall time remains presentation
and audit metadata. Audit logging follows the authoritative state commit and is
best-effort, so a logging outage cannot misreport a committed auth mutation as
failed.

The server uses axum with rustls `>=0.23.5` (currently resolved to 0.23.43), ring
and TLS 1.3 only. Certificate and leaf-key PEM files must be supplied. The real
owner CA was created outside the repository, the leaf key was generated on the
U60, and the live loopback canary completed a CA-verified TLS handshake. The iOS
source performs system trust evaluation followed by an exact P-256 SPKI pin
check, but no system/iPhone trust or real iPhone pairing acceptance exists yet;
those remain distinct from the accepted command-line handshake.

Apple Passkey is a later, distinct WebAuthn layer. It requires an owner domain,
Associated Domains and an AASA file. The NAS is not an authentication runtime
dependency. Until those requirements exist, local Secure Enclave pairing must
not be described as a passkey.

## Device safety gates

No source-only test authorizes device deployment. Every device write requires:

1. exact firmware and root recovery-channel confirmation;
2. a scoped backup and SHA-256/size/mode/source manifest on the approved NAS
   backup share;
3. a reversible canary path that does not change the Mac default route or TUN;
4. applied-state and recovery verification;
5. an explicit record that no unexpected USB, WAN, Wi-Fi, FOTA, boot or route
state changed.

Historical scripts that contact the stock device UI are fail-closed by default.
They require a one-command local acknowledgement appropriate to read-only
probing, privileged vendor-RPC research or configuration restore. The restore
tool cannot skip its interactive confirmation in this B04 V1 branch.

Agent installation, SSH persistence and removal of persistent ADB are separate
gates. SSH may become key-only only after public-key success, password failure
and two independent recovery keys are verified while root ADB is still
available.

## Licensing and publication

See [../UPSTREAM-NOTICE.md](../UPSTREAM-NOTICE.md). MU upstream
added an MIT licence on 2026-08-16, and this repository retains that licence and
the imported open-u60-pro attribution. Public reuse is therefore permitted under
the retained terms. Repository visibility does not relax provenance,
secret-history, device-safety or acceptance rules.
