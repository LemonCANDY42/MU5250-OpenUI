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

Routine dashboard refresh uses one partial-success HTTPS snapshot rather than
client-side fan-out. This is deliberately a request/response aggregation layer:
it reuses the same adapter reads, preserves typed per-component failures and
keeps the individual routes stable. Each response reads normalized device
identity before asynchronously acquiring one permit for the blocking aggregate
pass, which stays with that worker until it exits, including after an HTTP
timeout. The pass does not pre-probe the same sources and has an 11-second total
response budget. Overlapping refreshes wait within their own budget without
creating blocking aggregate work; unfinished aggregate reads or admission become
typed timeouts instead of accumulating blocking-pool tasks. MQTT is not
part of this local snapshot
path because a broker, persistent connection, reconnection state and iOS
background lifecycle would add state and recovery cost without improving the
underlying weak Wi-Fi link. A future event stream would require a distinct,
measured continuous-event use case rather than replacing this bounded pull.

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
   signal and cellular state, traffic, battery, thermal, Wi-Fi state including
   optional bounded active-radio channel observations, LAN
   clients and SMS listing.
3. **HTTPS, clients and daily operations**: the protocol, state model, TLS-only listener and
   offline [owner PKI tooling](PKI.md) are implemented. Real owner/leaf material
   was created through the separately authorized maintenance gate, and a
   loopback-only `19443` canary passed the immediate TLS, password-auth and five
   read-only endpoint gate. The owner-accepted device-process one-hour checkpoint
   also passed. The listener serves one canonical, symlink-free web build only
   when explicitly configured. Real browser WebCrypto pairing, challenge login
   and all ten read-only capabilities now have B04 acceptance. Owner-confirmed
   physical-iPhone CA installation/full trust, Secure Enclave key pairing and an
   authenticated handshake are also accepted. The
   web and iOS clients share generated `/v1` models and capability-driven UI. Daily
   writes are SMS send, traffic-cycle reset, the stock Wi-Fi master switch, and
   transactional Wi-Fi primary/guest settings. The master operation delegates to
   the firmware's own switch and leaves the saved 2.4/5 GHz primary-AP states
   untouched, so the device UI remains the recovery control after a deliberate
   disconnect. Independent primary-AP and stock band-steering changes use fixed
   B04 field paths, require at least one saved primary AP, and reject incompatible
   band-steering combinations. Every disconnecting transaction has strict
   channel/bandwidth/power allowlists, a client-generated identifier persisted
   and an independent rollback worker armed before mutation, a roughly
   120-second confirmation window, reconnect retries across transient network
   and foreground changes, reboot-safe rollback, applied-state readback and
   dedicated recovery tests.
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
| Signal/cellular/dashboard | MU's compact device UI and open-u60-pro's richer normalized status | Optional bounded CA/network-selection/cell-lock summaries are read-only only; no cell-lock writes, raw AT or vendor JSON |
| Traffic/battery/thermal/system | Proven firmware and kernel sources | Bounded reads; optional battery extensions are unit-normalized, sentinel-filtered and state-gated; CPU is consecutive-snapshot only; memory and storage use fixed direct reads; charging is read-only |
| Wi-Fi/LAN | Useful settings and connected-client views | A request peer may be uniquely correlated to DHCP plus fixed station data for router-observed link telemetry; no arbitrary UCI; Wi-Fi changes are persisted transactions with timeout rollback |
| SMS | Listing and sending from both projects | Strict UTF-16/UCS-2 hex decoding (including surrogate pairs), bounded pages, UTF-8-safe flagged truncation and explicit malformed-record counts; no SQL fallback, bulk delete, forwarding plugin or arbitrary modem command |
| Web/iOS clients | MU information density plus open-u60-pro SwiftUI navigation | One OpenAPI contract, capability hiding, pinned HTTPS and public-key login |

SIM identifiers, raw process lists, APN credentials, DNS/LAN/firewall/NAT/UPnP/VPN/QoS/domain-filter summaries,
network/band/cell-lock writes, USB composition, FOTA, reboot/shutdown, arbitrary AT,
ubus/UCI/shell and external forwarding remain outside V1. Active radio type is
reported through normalized signal status; the configured APN is not exposed
until a separate redaction contract and B04 acceptance exist. Historical getter
presence is not enough: every router-summary domain must pass an independent
fixed-source, privacy and bounded-schema gate.

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
U60, and the live canary completed a CA-verified TLS handshake. The owner iPhone
has the exact CA installed with full trust; the iOS client completed system trust,
the exact P-256 SPKI pin check, Secure Enclave QR pairing and a key-authenticated
session against the nonpersistent LAN canary.

The browser boundary has separate real-device evidence: a non-exportable P-256
credential survived an agent release replacement, completed a new single-use
challenge login and loaded ten available B04 capabilities. Browser and iPhone
credentials remain separate client-held keys.

The server process contains one non-API diagnostic worker for a single seven-day
observation. It uses the existing single-thread Tokio runtime, samples fixed
`/proc` and `/data` sources every ten minutes, and writes owner-only state plus a
bounded JSONL stream under `/data/u60/state`. A persisted start/deadline and
completion marker make it one-shot across service and device restarts. Power-off
gaps count as elapsed calendar time but produce no synthetic data. Device reboot
correlation uses a private hash of the kernel boot identity; neither the identity
nor its hash enters the log. Two post-deadline observations protect against one
forward clock jump, while rollback clears a premature deadline candidate. A
1 MiB ceiling is an independent fail-closed stop condition. The worker never
invokes B04 configuration operations and its failure cannot stop the HTTPS
control plane.

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
