# U60 Pro B04 integration

Safety-first control-plane work for one owner-operated ZTE U60 Pro (MU5250) on
HK B04 firmware.

> **Do not install this branch persistently or enable write capabilities until
> the remaining V1 gates are recorded.** The accepted nonpersistent LAN canary
> is running on the U60 management address, with no `current`/`previous` link
> or boot hook. Its release checksum, TLS authentication boundary and unchanged
> recovery/network invariants were freshly revalidated before restart. Real
> Chrome WebCrypto pairing, all ten read-only capabilities, owner-confirmed iPhone
> CA trust, Secure Enclave QR pairing and an authenticated physical-iPhone session
> are accepted. Each daily write still requires its independent device gate.
> The original 24-hour RSS-growth target was replaced by the owner's one-hour V1 gate.
> The legacy setup, deployment and hardening entry points remain fail-closed.

This branch directly descends from `dklasens/MU5250-OpenUI` at commit
`2209909`, including the MIT licence and upstream emulator-safety fixes. The
next local commit removes the accidentally tracked `.venv`; no environment is
vendored into this repository.
MU upstream added an MIT licence on 2026-08-16; the exact licence and imported
open-u60-pro attribution are retained here. See
[UPSTREAM-NOTICE.md](UPSTREAM-NOTICE.md).

## Implemented and accepted baseline

The source boundary below is host-tested. All ten read-only paths have also
passed separately recorded HK B04 canary and browser gates; this does not
authorize daily mutations or a stable install.

- `B04Adapter` contains firmware-specific reads and returns normalized domain
  types rather than vendor JSON.
- `openapi/u60-v1.yaml` defines ten read-only capabilities, four bounded daily
  management operations, plus password,
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

The daily write source is host-tested but has not yet passed the per-operation
B04 backup, applied-state and rollback gates. Until those records exist, the
running device canary remains read-only.

## Accepted read-only canary release

The last accepted LAN-canary release was
`9b334dd65f32d8ef375d04026c197e467d6f42a44c7cf53df4c5803e49e58fb9`,
whose identifier binds its complete checksum list. It is installed under the
immutable `/data/u60/releases/` store and bound only to `192.168.0.1:9443`.
`current` and `previous` are still absent, so it is not a stable installation.
That nonpersistent process has since stopped and no LAN listener is currently
accepted as live; it will not restart after a reboot. The release is not
referenced by `rc.local`, init, firewall or a new system service.

Immediate acceptance proved the full device-side release checksum, TLS owner-CA
verification with unauthenticated `401`, root ADB retention and unchanged exact
firmware, USB properties, default route, nine-interface TUN set and `rc.local`.
The replaced intermediate canary exited, one release process remained on
loopback, and the new process used 2,780 KiB RSS with two threads. Secret-free,
hash-bound NAS evidence is in
`/Volumes/backups/U60-Pro/B04-v1-canary-20260816T151030269094Z`.

After the final process replacement, the browser's existing non-exportable
P-256 credential completed a fresh challenge login. Chrome reported all ten
capabilities as available; the Messages card rendered 20 bounded entries and
neither sender nor content fields retained long UCS-2/UTF-16 hexadecimal
payloads. No message content was stored in the repository or NAS evidence.

The one-hour device-process checkpoint completed after 3,756 seconds with one
thread, 2,164 KiB RSS (100 KiB above the start) and empty canary/audit logs. The
listener remained device-loopback-only, root ADB and firmware identity remained
available, and `rc.local`, USB properties and dormant legacy-agent hashes were
unchanged. The temporary Mac ADB forward disappeared during the observation, so
continuous client-path availability was not proven. The shortened gate cannot
establish the original 24-hour RSS-growth target. Its secret-free NAS evidence
is `/Volumes/backups/U60-Pro/B04-canary-one-hour-20260816T102444Z`; manifest
SHA-256 is
`f7cafc92e99af3643afaa3672772d2c514a2c29b71de300a81a05b3eda65dbda`.
No device write API, SSH service, stable release symlink or boot persistence is
enabled.

## Architecture and safety

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — target boundaries, slices,
  authentication direction and acceptance gates.
- [docs/SAFETY.md](docs/SAFETY.md) — device recovery rules and known brick
  hazards. Historical material is clearly marked where it describes dormant
  upstream code.
- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) — historical upstream deployment
  reference only; its old write path is disabled on this branch.
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

These host checks do not authorize a stable install or any device write API.
The running read-only canary passed the owner-approved one-hour device-process
gate, but not the original 24-hour leak target or a continuous Mac client-path
test. Further device actions remain governed by the architecture and local B04
handoff.
