# U60 Pro B04 integration

Safety-first control-plane work for one owner-operated ZTE U60 Pro (MU5250) on
HK B04 firmware.

> **Current owner-device state:** the reviewed V1 release is persistently active
> through one bounded `/etc/rc.local` launcher. Stock ECM USB Ethernet is the
> normal boot mode; Agent HTTPS and key-only root SSH listen only on the management
> LAN. USB ADB is intentionally absent during normal use and is restored only for
> an explicitly authorized maintenance boot through the verified SSH-to-DEBUG
> recovery procedure. Legacy setup, deployment, USB-mode and hardening entry
> points remain fail-closed. Daily writes remain subject to their documented
> per-operation safety boundaries.

This branch directly descends from `dklasens/MU5250-OpenUI` at commit
`2209909`, including the MIT licence and upstream emulator-safety fixes. The
next local commit removes the accidentally tracked `.venv`; no environment is
vendored into this repository.
MU upstream added an MIT licence on 2026-08-16; the exact licence and imported
open-u60-pro attribution are retained here. See
[UPSTREAM-NOTICE.md](UPSTREAM-NOTICE.md).

## Implemented and accepted baseline

The source boundary below is host-tested. The accepted HK B04 installation has
also passed release-integrity, TLS, browser, physical-iPhone, persistence,
key-only SSH, reboot-resumption and stock-ECM checks. This acceptance does not
broaden the documented daily-mutation boundaries.

- `B04Adapter` contains firmware-specific reads and returns normalized domain
  types rather than vendor JSON.
- `openapi/u60-v1.yaml` defines ten read-only capabilities, four bounded daily
  management operations, two advanced-session-only fixed device lifecycle
  actions, plus password,
  pairing and challenge-based authentication under `/v1`.
- The TLS 1.3 listener can explicitly serve `web-app/dist` with
  `serve --web-root DIR`. The root is canonicalized, symlinks are rejected and
  only the entry document plus fixed assets are loaded; without the flag no web
  content is served.
- The lightweight dashboard consumes generated `/v1` types over relative,
  same-origin requests. Routine refresh uses one partial-success aggregate
  snapshot while retaining the individual typed read routes for compatibility
  and focused diagnostics. It exposes the complete typed status set and
  daily-scope controls only after authentication.
- Browser pairing uses a non-exportable WebCrypto P-256 private key stored with
  its public key and credential metadata in IndexedDB. Bearer tokens stay only
  in memory; the dashboard never persists password fallback input.
- The iOS target preserves open-u60-pro's imported history and a small native
  presentation component while compiling only the new generated `/v1` client.
  Physical iPhones use Secure Enclave P-256 signing, normal CA trust plus SPKI
  pinning, a device-local Keychain profile and an in-memory bearer token. The
  simulator fallback is explicitly test-only.
- An owner-signed physical-device build has been installed and launched on the
  owner's iPhone using a local-only bundle-identifier override. The public
  project keeps automatic signing and contains no team or device identifier.
  Owner-confirmed iPhone CA installation/full trust, Secure Enclave QR pairing
  and a live authenticated device session are accepted.
- A host-only pairing tool combines `pair-open` JSON received on stdin with a
  verified public certificate bundle and renders a mode-`0600` QR outside the
  repository. Real browser and physical-iPhone pairing windows have been accepted
  without persisting their nonces.
- Raw AT and process-killing routes, client bindings, mock fixtures and UI are
  removed. There is no generic AT, ubus, UCI or shell execution API.
- CI checks Rust, authentication/storage tests, the production dashboard
  artifact and public-route/OpenAPI method/status agreement. The artifact gate
  rejects legacy API paths, plaintext URLs, the old split-origin port and common
  token-persistence APIs.

Unsupported charging, Wi-Fi master and stock multi-band coordination writes are
not exposed. Remaining bounded daily writes retain their per-operation validation
and rollback rules; a stable installation is not permission to bypass them.

## Accepted persistent owner installation

The accepted content-addressed release is selected by atomic `current` and
`previous` links under `/data/u60`. One finite, backgrounded launcher starts one
Agent on management-LAN port `9443` and one hardened Dropbear on `2222`; it has
bounded retries, is not a watchdog and sends process output to `/dev/null`.
Persistent service state is bounded, normal polling does not append a process
log, and the stability recorder has a fixed size ceiling.

The owner-device normal boot uses stock ECM USB Ethernet. macOS may assign a
different `enN` number after re-enumeration, so identify the ZTE interface and
confirm the route to `192.168.0.1` rather than hard-coding `en17`. The normal
paths are the native App/Agent, stock Web UI and key-only SSH. Root USB ADB is a
recoverable maintenance capability, not a continuously exposed interface; see
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) and
[docs/reference/usb-modes.md](docs/reference/usb-modes.md).

## Architecture and safety

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — target boundaries, slices,
  authentication direction and acceptance gates.
- [docs/SAFETY.md](docs/SAFETY.md) — device recovery rules and known brick
  hazards. Historical material is clearly marked where it describes dormant
  upstream code.
- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) — reviewed V1 deployment and
  SSH-to-DEBUG-to-ADB recovery path; the old upstream flow is clearly isolated.
- [docs/IOS.md](docs/IOS.md) — compiled target, generated contract, Secure
  Enclave, TLS pinning and five-minute QR pairing boundaries.
- [docs/READ-ONLY-PROBE.md](docs/READ-ONLY-PROBE.md) — exact USB ADB read
  allowlist, NAS evidence format and network/TUN invariants.
- [docs/CROSS-BUILD.md](docs/CROSS-BUILD.md) — pinned host-only AArch64 musl
  build recipe and artifact acceptance boundary.

The source keeps the ten-capability contract and adds optional contextual
router-observed client-link data to the existing Wi-Fi status, plus optional
radio aggregation, selection and read-only cell-lock summaries. The existing
system and battery endpoints also accept backward-compatible optional current
CPU/memory/`/data` storage metrics and independently validated battery
health/cycle/capacity/counter/kernel-estimate fields. These fields are
host-tested; the fixed sources have B04 read-only evidence, but the combined
release has not been deployed or accepted on physical clients.
SIM/APN and router-configuration summaries remain absent until their own
redaction and B04 gates pass.

The public contract source of truth is
[openapi/u60-v1.yaml](openapi/u60-v1.yaml). The routing source of truth is
`agent/src/server.rs`. New functionality must update both and pass
`scripts/check-api-contract.py`.

## Host-only verification

```sh
cargo fmt --all --check
cargo check --workspace --all-targets
cargo test --workspace --all-targets
cargo clippy --workspace --all-targets -- -D warnings
python3 scripts/check-api-contract.py
python3 scripts/check-device-gates.py
python3 scripts/probe-b04-readonly.py --self-test
python3 scripts/check-ios-boundary.py
scripts/pairing/test-pairing-tools.sh
bash -n scripts/build-b04-agent.sh
python3 scripts/publish-b04-agent-build.py --self-test
# After a clean pinned cross-build only:
python3 scripts/publish-b04-agent-build.py --verify-receipt

cd web-app
npm ci
npm ci --prefix ../tools/openapi
npm audit --audit-level=high
npm run check:api
npm run lint
npm test
npm run build
npm run check:artifact
```

These checks do not contact or modify the U60.

GitHub Actions is currently manual-only. The repository's account state
rejects every hosted job before checkout with a billing/spending-limit error;
automatic `push` and pull-request triggers therefore produced duplicate red
checks without running any test step. Restore automatic triggers only after the
account issue is resolved and one manual run actually enters its steps. Until
then, the local checks above remain the acceptance evidence.

## Repository layout

```text
agent/          Minimal Rust device agent and B04 adapter
openapi/        Versioned public API contract
web-app/        Same-origin typed dashboard and gated daily controls
clients/ios/    Imported history plus safe generated-contract iOS target
scripts/        Contract checks plus upstream recovery/research references
docs/           Architecture, safety and historical device notes
```

These host checks alone do not authorize a device write. The owner-device stable
installation and ECM/SSH recovery chain have separate recorded acceptance; the
older canary and one-hour process records remain historical evidence rather than
the current runtime description. Further device actions remain governed by the
architecture and local B04 handoff.
