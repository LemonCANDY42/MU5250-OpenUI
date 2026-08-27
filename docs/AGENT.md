# Agent source baseline

The B04 V1 agent is a host-tested typed contract. Its final read-only canary,
all ten capability reads, browser challenge pairing and physical-iPhone Secure
Enclave pairing/authentication are device-tested. Daily writes still require
staged B04 acceptance records before stable installation.

## Compiled public surface

`openapi/u60-v1.yaml` is the contract authority. `agent/src/server.rs` routes
ten read-only capabilities, four bounded daily operations and five versioned
authentication paths:

| Endpoint | Meaning |
|---|---|
| `GET /v1/device` | Normalized model, adapter target and best-effort firmware/hardware identity |
| `GET /v1/capabilities` | `available`, `degraded` or `unsupported` state plus reason/recovery metadata |
| `GET /v1/status/system` | Hostname, kernel, uptime and load average, with optional current CPU, memory and `/data` storage metrics |
| `GET /v1/status/battery` | Normalized capacity, voltage, current, derived battery-side power, temperature and state, with optional validated health, cycle, capacity-counter and kernel-estimate fields |
| `GET /v1/status/thermal` | Validated readings from the fixed B04 sensor map |
| `GET /v1/status/signal` | Normalized LTE/NR signal and serving-band state |
| `GET /v1/status/cellular` | Bounded WAN connection and address state |
| `GET /v1/status/traffic` | Current day, billing-cycle, power-on and total counters |
| `GET /v1/status/wifi` | Two fixed B04 radio sections, channel/bandwidth/power, security, station counts, optional guest state and optional request-peer link context |
| `GET /v1/lan/clients` | Bounded current DHCP lease list |
| `GET /v1/sms` | Bounded latest SMS page |
| `POST /v1/sms/send` | Validated recipient/message mapped to one fixed WMS operation |
| `GET /v1/charging` | Read-only battery capacity and stock charging-permission state; no public charging writes |
| `PUT /v1/traffic/cycle` | Set 1–31 reset day and enabled state with readback |
| `POST /v1/wifi/transaction` | Apply allowlisted primary/guest fields with a client-persisted transaction ID known before restart and 120-second rollback |
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

Every other legacy `/api` endpoint is deliberately dormant. In particular,
there is no routed raw AT console, process killer, reboot/shutdown, Wi-Fi/APN
mutation, cell/band lock, USB mutation, TTL write or generic vendor-call
surface.

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
clients, so restarting the server cannot reset a current lockout. A detected
backward wall-clock jump cannot extend volatile sessions or challenges because
their deadlines use the process-independent monotonic clock. Pairing records
bind the Linux boot UUID to a `CLOCK_BOOTTIME` deadline; reboot, a missing or
mismatched boot identity, and monotonic rollback all fail closed.

Audit persistence is intentionally best-effort after the authoritative auth
state commit: an audit storage failure emits only redacted diagnostics and never
turns a successfully committed password, pairing or credential mutation into a
reported failure. Maintenance operations are CLI-only:

- `zte-agent password-set` reads the password from stdin;
- `zte-agent pair-open` emits one five-minute registration payload;
- `zte-agent credential-list` lists non-secret metadata;
- `zte-agent credential-revoke ID` revokes a client key.

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
2 MiB RSS growth over 24 hours and bounded local logs. No source-only build can
prove those values. They are measured only during the later `19443` canary.

Legacy `setup.sh`, `deploy.sh`, `deploy-dashboard.sh` and
`scripts/zharden.sh` exit before any device access. Do not bypass those guards;
the reviewed replacement is `scripts/deploy-b04-v1.py`. It accepts only one
content-addressed release from the approved NAS, verifies it again on-device,
keeps canary/stable/SSH/boot persistence as separate commands, records scoped
invariants and refuses any firmware other than exact HK B04 with root ADB.
Source implementation is not real-device acceptance; each command retains its
own live gate and evidence record.
