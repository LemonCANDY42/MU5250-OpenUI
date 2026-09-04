# Agent source baseline

The B04 V1 agent is a host-tested typed contract. Its final read-only canary,
all ten capability reads, browser challenge pairing and physical-iPhone Secure
Enclave pairing/authentication are device-tested. Daily writes still require
their staged B04 acceptance records before each live operation; the accepted
stable installation does not waive those gates.

## Compiled public surface

`openapi/u60-v1.yaml` is the contract authority. `agent/src/server.rs` routes
the read-only capability/status surface, four bounded daily operations and five
versioned authentication paths:

| Endpoint | Meaning |
|---|---|
| `GET /v1/device` | Normalized model, adapter target and best-effort firmware/hardware identity |
| `GET /v1/capabilities` | `available`, `degraded` or `unsupported` state plus reason/recovery metadata |
| `GET /v1/status/dashboard` | One partial-success snapshot containing the capability report, all available normalized status values, optional charging status and independent typed component failures |
| `GET /v1/status/clock` | Request-driven device clock trust state (`trusted` or `waiting_for_sync`); no time-setting or network side effect |
| `GET /v1/status/system` | Hostname, kernel, uptime and load average, with optional current CPU, memory and `/data` storage metrics |
| `GET /v1/status/battery` | Real fuel-gauge capacity, voltage, current, derived battery-side power, temperature and state, with optional stock display capacity, recognized protection mode, validated health, cycle, capacity-counter and kernel-estimate fields |
| `GET /v1/status/thermal` | Validated readings from the fixed B04 sensor map |
| `GET /v1/status/signal` | Normalized LTE/NR signal and serving-band state |
| `GET /v1/status/cellular` | Bounded WAN connection and address state |
| `GET /v1/status/traffic` | Current day, billing-cycle, power-on and total counters |
| `GET /v1/status/wifi` | Two fixed B04 radio sections with configured and optional active channel, bandwidth/power, security, station counts, optional guest state, composite stock multi-band state and optional request-peer link context |
| `GET /v1/lan/clients` | Bounded current DHCP lease list |
| `GET /v1/sms` | Bounded latest SMS page |
| `POST /v1/sms/send` | Validated recipient/message mapped to one fixed WMS operation |
| `POST /v1/device/reboot` | Advanced-session-only fixed stock B04 reboot call; no request body and no retry |
| `POST /v1/device/power-off` | Advanced-session-only fixed stock B04 power-off call; no request body and no retry |
| `GET /v1/charging` | Read-only battery capacity and stock charging-permission state; no public charging writes |
| `PUT /v1/traffic/cycle` | Set 1–31 reset day and enabled state with readback |
| `POST /v1/wifi/transaction` | Apply allowlisted primary/guest fields with a client-persisted transaction ID known before restart and 120-second rollback; stock master and multi-band state are read-only |
| `POST /v1/wifi/transaction/confirm` | Re-read the requested fields and commit only a matching pending Wi-Fi transaction |
| `POST /v1/auth/password/session` | Argon2id password login for a normal scoped session |
| `POST /v1/auth/password/advanced` | Password re-entry for a non-sliding five-minute advanced session |
| `POST /v1/auth/challenge` | Single-use P-256 signing challenge |
| `POST /v1/auth/challenge/verify` | Raw WebCrypto or Apple DER P-256 ECDSA/SHA-256 verification and key session |
| `POST /v1/auth/pair` | One-time maintenance nonce consumption and P-256 SPKI registration |

There are no routed `/api` paths. The old SHA login is gone. Read-only domain
routes require `read`; daily operations require `daily`; advanced-session creation also
requires an existing `admin` token before password re-entry. Sessions keep only
SHA-256 token digests in memory.

Daily error responses include typed recovery metadata. A successful rollback
or validation failure reports no recovery requirement; a still-armed Wi-Fi
transaction reports one. Status, code and recovery state come from typed
control flow rather than parsing the human-readable error message. Rollback
removes the pending record only after an exact old-value readback. Each Wi-Fi
transaction uses one consistent pre-apply configuration snapshot for invariant
checks and rollback values, then one exact post-apply snapshot. A begin-client retains its newly created local
confirmation only for a `503` that says recovery is required: a `409` conflict
cannot prove ownership of that client-generated identifier. The read-only
compatibility-named `band_steering_enabled` field represents the complete
observed multi-band invariant, not raw `lbd` alone: both settings sync flags
must be enabled and the primary network identities must match. It is not
accepted by `WifiTransactionRequest`; the I/O layer also rejects attempts to
write steering or either settings-sync field.
The B04 firmware completes Wi-Fi writes asynchronously. V1 therefore gives the
stock state machine its two-second grace period, polls only the typed
`zwrt_wlan report.load_status` until `idle`, and stops after 20 seconds per
settle phase. Applied or rollback readback happens only after the final settle.
These waits run on Tokio's blocking pool, so the single-thread HTTPS runtime can
continue serving independent requests; a disconnected client does not cancel
an already-started protected Wi-Fi operation. A one-slot admission gate stays
with that blocking operation until it ends, so overlapping Wi-Fi writes fail
closed instead of queuing additional hardware jobs or blocking more workers.

Every legacy `/api` endpoint is deliberately dormant. The two typed lifecycle
routes are the only destructive device actions: each maps to one fixed stock
B04 method after exact-firmware verification, requires a five-minute
`advanced` session, accepts no body and shares a non-queuing one-slot admission
gate. There is no routed raw AT console, process killer, generic lifecycle
action, Wi-Fi/APN mutation, cell/band lock, USB mutation, TTL write or generic
vendor-call surface.

## Adapter boundary

`agent/src/adapter.rs` owns the B04-specific object names, proc/sysfs paths and
parsing. Handlers receive only typed domain structures. Vendor JSON must never
cross into `/v1`, and clients must never provide a vendor object, command, key
or path.

Battery `power_mw` is a signed instantaneous battery-side value derived from
the fixed B04 `voltage_now` and `current_now` sources. The adapter deliberately
does not trust the PMIC's `power_now` node, matching the proven behavior of the
original MU5250 tooling. Its sign follows `current_ma`; it is neither USB input
power nor a wall-power measurement.

Battery extensions are independently best-effort and never make the required
battery status fail. Charge values are converted from the kernel's microamp-hour
units to integer milliamp-hours. `charge_full` is labeled learned full capacity,
`charge_full_design` is design capacity, and the signed `charge_counter` is
published only as a relative counter; it is not remaining capacity. Health is
limited to recognized Linux `power_supply` values, cycle count is bounded and
the ABI's zero/unavailable value is omitted. Unknown or malformed values are
omitted. Kernel time estimates are state-gated and limited to a 30-day
plausibility window so maximum-value sentinels and near-zero-current artefacts
are not presented as durations:
discharging may report time to empty, charging may report time to full, and full
may report only a completed zero time to full. Zero is a valid boundary value.

The adapter also makes one fixed, read-only stock device-manager query for the
optional B04 UI percentage and battery mode. Only a percentage from 0 through
100 is accepted, and only the proven mode value is normalized to
`long_charging`; unknown, malformed or unavailable stock data is omitted without
failing the required kernel fuel-gauge status. The kernel `capacity_percent`
remains authoritative for telemetry and runtime estimation, while
`device_ui_capacity_percent` explains why the stock screen or webpage can show
100% during protection when the real fuel-gauge value remains near 80%.

System metrics are likewise optional. CPU usage is derived without sleeping or
a background worker from consecutive aggregate `/proc/stat` samples, with
`iowait` treated as idle; the first sample and invalid/reset deltas are omitted.
Memory uses `MemTotal` and `MemAvailable` from `/proc/meminfo`. Storage is a
direct `statvfs` read of the fixed `/data` filesystem. Any individual optional
source failure leaves the required system status intact.

`/v1/status/wifi` never accepts an address or MAC from the client. Its optional
`current_client_link` context uses the handler-supplied HTTPS peer IPv4 address,
which must uniquely match one current DHCP lease and exactly one fixed
`wlan0`/`wlan2` station entry. Only the `router_observed` label, band, signal,
rates, expected throughput and connection age leave the adapter. Unmatched,
loopback, IPv6 or ambiguous peers still receive normal Wi-Fi status with this
field absent; there is no standalone link endpoint or separate capability claim.

Capability reporting is fail-closed:

- a read that produces the complete normalized contract is `available`;
- a partial but safe read is `degraded`, with a reason and maintenance action;
- an absent B04 source is `unsupported`;
- source support does not become real-device acceptance until its exact path has
  passed the B04 probe gate.

The dashboard snapshot is an efficiency surface, not a second source of truth.
It invokes the same fixed adapter methods as the individual read routes and
retains those routes for compatibility and focused diagnostics. One component
failure is recorded in `failures` and omitted from the snapshot without hiding
other successful values. Wi-Fi peer context still comes only from the actual
HTTPS request peer. The agent performs one serialized source pass on a blocking
worker, never calls the probing capability report first, and returns values
completed within one 11-second server budget. The normalized device identity is
read before a single permit is acquired asynchronously for the blocking
aggregate pass. That permit remains owned by the worker after an HTTP timeout
until the worker actually exits. An overlapping refresh therefore starts no
worker or aggregate source pass while waiting within its own budget. If admission
remains occupied, it receives the existing partial-success
shape with typed `snapshot_timeout` failures. Cancellation stops admitted work
before the next source. The single-thread async listener and stability monitor
therefore remain responsive without accumulating blocking tasks. The endpoint
reduces radio/TLS request fan-out without weakening per-component error semantics
or adding a background stream.

## Host-only HTTPS and maintenance state

The only listener is `axum-server` backed by rustls `>=0.23.5, <0.24`,
explicitly configured for ring and TLS 1.3. The default bind is
`127.0.0.1:19443`. `serve`
fails before opening agent state unless `U60_TLS_CERT_PEM` and
`U60_TLS_KEY_PEM` name parseable certificate and leaf-key PEM files. The agent
does not generate either file and has no plaintext fallback or permissive CORS;
an explicit browser `Origin` must match the HTTPS `Host`.

`zte-agent serve --web-root DIR` optionally enables the same TLS listener to
serve the dashboard. The root and every accepted asset are canonicalized before
state is opened, the root and its complete tree must contain no symlink, and
only `index.html`, fixed top-level metadata assets and allowlisted files below
`assets/` are loaded. Without `--web-root` no static response is available.
Unknown `/v1` paths always retain the typed JSON 404 and are never captured by a
web fallback. All responses carry a self-only CSP (including
`frame-ancestors 'none'`), `nosniff`, `Referrer-Policy: no-referrer` and frame
denial; there is still no CORS or plaintext listener.

Authentication state defaults to `/data/u60/state` and can be redirected with
`U60_STATE_DIR` for host tests. Directories are mode `0700`; state files are
published atomically at mode `0600`. An advisory `auth.lock` serializes the
complete pairing and credential read-modify-write transactions across the live
server and maintenance CLI. Password failure state is persisted under that lock,
uses hashed client identifiers, expires after one hour and is capped at 128
clients, so restarting the server cannot reset a current lockout. A shared,
request-driven `ClockTrust` compares wall time with the release
`SOURCE_DATE_EPOCH` and the persisted highest trusted time, allowing at most
five minutes of normal correction. A per-boot anchor in root-only tmpfs combines
wall time with `CLOCK_BOOTTIME`, so the same bound survives server, maintenance
CLI and rollback-child process boundaries without adding flash writes. It does
not set the clock, contact a time service, start a timer or poll. A persistent
trusted high-water mark is reloaded under a cross-process lock and atomically
advanced at most once per 24 hours. Corrupt trust state is preserved as evidence
and leaves only date-sensitive operations paused. Password login and lockout
accounting, new pairing and SMS sending then return typed
`503 clock_not_synchronized` with `Retry-After: 15`; existing key login, read
status, Wi-Fi, traffic and recovery remain available. Audit records retain raw
wall time and add its trust state; legacy records remain explicitly unknown
rather than being relabeled as trusted.

Volatile session and challenge deadlines use the process-independent monotonic
clock. Pairing records and pending Wi-Fi confirmation windows bind the Linux
boot UUID to a `CLOCK_BOOTTIME` deadline; reboot, a missing or mismatched boot
identity, and monotonic rollback all fail closed. Legacy pending Wi-Fi
transactions without that binding are still rolled back during service startup.

Audit persistence is intentionally best-effort after the authoritative auth
state commit: an audit storage failure emits only redacted diagnostics and never
turns a successfully committed password, pairing or credential mutation into a
reported failure. Maintenance operations are CLI-only:

- `zte-agent password-set` reads the password from stdin;
- `zte-agent pair-open` emits one five-minute registration payload;
- `zte-agent credential-list` lists non-secret metadata;
- `zte-agent credential-revoke ID` revokes a client key.

The secure service also owns one deliberately finite stability observation.
Its first successful listener bind creates `stability-monitor-v1.json` and
appends one sanitized `stability-monitor-v1.jsonl` sample every ten minutes.
Both live under `U60_STATE_DIR`, are owner-only, and contain only aggregate
agent CPU/RSS/thread counts, system memory, `/data` capacity, uptime,
service-restart and device-reboot indicators. The raw boot UUID is never logged
or exposed; only a SHA-256 fingerprint is retained in private state so a later
start can report a reboot. There is no network endpoint for this diagnostic
data.

The observation is anchored to one fixed seven-day trusted-wall-clock window
and never starts over. Shutdown time remains part of that window, no missing
samples are fabricated, and the first service start after shutdown records the
restart and any detected reboot. While `ClockTrust` is waiting, no sample or
deadline progress is written; the next trusted sample resumes the existing
window without fabricating the gap. Reaching the deadline requires two samples
ten minutes apart; the completion marker is then persisted and all later starts
remain silent. The
JSONL file has a 1 MiB hard ceiling and reaching it also writes a permanent
completion marker. Normal samples are appended without a per-record filesystem
sync; state is atomically synced only at lifecycle boundaries.

There is no network credential-list or revoke endpoint. Passwords, private keys
and CA passphrases never enter command-line arguments or repository state. The
separate [host-only PKI tooling](PKI.md) must be given an explicit
out-of-repository directory, accepts the CA passphrase only through a file
descriptor and is not a server or maintenance-CLI endpoint.

The browser client generates ECDSA P-256 keys with the private key marked
non-exportable, exports only the public SPKI and stores the CryptoKey pair plus
credential ID/label in IndexedDB. It signs the exact base64url-decoded challenge
message. Canonical DER output is normalized when unambiguous; because a valid
DER sequence can itself be exactly 64 bytes, the server parses both raw and DER
candidates and accepts only an encoding that verifies. Bearer tokens exist only
in JavaScript memory, logout clears that memory, and the dashboard does not
persist the manually entered password. Browser password-manager policy remains
under browser/user control. This is local browser-key pairing, not Apple
Passkey.

## Contract checks

`scripts/check-api-contract.py` verifies that:

- every routed `/v1` path is in OpenAPI and vice versa;
- every routed HTTP method is declared and every current typed runtime status is
  represented;
- no `/api` path is routed;
- raw AT and process-killing surfaces are absent from server and dashboard;
- OpenAPI contains no generic command or shell surface.

`scripts/check-web-artifact.py` separately verifies that:

- the built dashboard contains no legacy API path, plaintext URL, old agent
  port or common persistent-token storage marker.

Rust tests also pin Argon2id parameters, restart-safe progressive per-address
lockout, session expiry/scope behavior, rollback-and-rebound clock behavior,
challenge consumption and raw/DER signatures, pairing expiry/replay,
cross-process pairing/credential serialization, degraded audit persistence,
state modes, same-origin behavior, static-path rejection, security headers and
HTTPS fail-closed startup. Vitest covers browser encoding, raw/DER signature
normalization, non-exportable IndexedDB keys, pairing/challenge/login and
in-memory-only token behavior.

## Resource and deployment state

The target is idle RSS at or below 12 MiB, average idle CPU below 1%, less than
2 MiB RSS growth over 24 hours and no long-running process log writes. Bounded
security state and the one-shot 1 MiB monitor remain persistent. No source-only build can
prove those values. They are measured only during the later `19443` canary.
The one-shot monitor described above supplies longer-running evidence only after
that release is explicitly deployed; adding it to source is not device evidence.

Legacy `setup.sh`, `deploy.sh`, `deploy-dashboard.sh` and
`scripts/zharden.sh` exit before any device access. Do not bypass those guards;
the reviewed replacement is `scripts/deploy-b04-v1.py`. It accepts only one
content-addressed release from the approved NAS, verifies it again on-device,
keeps canary/stable/SSH/boot persistence as separate commands, records scoped
invariants and refuses any firmware other than exact HK B04 with root ADB.
Source implementation is not real-device acceptance; each command retains its
own live gate and evidence record.
