# Dashboard

The dashboard is a minimal, read-only TypeScript client for the generated
`/v1` contract. It is built as three small static artifacts and may be served by
the agent's existing TLS listener:

```sh
zte-agent serve --web-root /path/to/web-app/dist
```

Static hosting is opt-in. See [AGENT.md](AGENT.md) for canonical-directory,
symlink, asset allowlist and response-header rules. The source-only command
above is documentation, not authorization to run the agent on the U60.

## Product surface

After authentication the dashboard reads the capability report first. It then
requests only supported or degraded read endpoints and displays:

- normalized device identity;
- capability status and recovery metadata;
- system uptime, kernel and load average, plus optional current CPU, memory and fixed `/data` storage usage;
- battery state, capacity, voltage, current, derived instantaneous power and temperature, plus optional validated health, cycle, capacity and kernel-estimate details;
- validated thermal sensors.

An unsupported capability is shown explicitly and is not requested. A degraded
capability retains its reason and maintenance action. There are no raw commands,
firmware dictionaries or legacy endpoint bindings. The authenticated controls
remain limited to the typed V1 daily-operation surface; charging is read-only,
and Wi-Fi changes keep a client-generated confirmation identifier in IndexedDB
before mutation so a page reload can resume the bounded rollback handshake.
The battery card displays the magnitude of signed `power_mw`; the API retains
direction through the separate current and state fields. This is a battery-side
estimate derived from voltage and current, not USB or wall power.
Signal status may include bounded LTE/NR aggregation, network-selection and
read-only cell-lock summaries; the fields remain optional so this client can
read earlier V1 agents. The existing Wi-Fi card shows router-observed RSSI and
rates when the request peer has one unique DHCP-to-station correlation. An
unmatched or ambiguous peer leaves the optional context absent without failing
Wi-Fi status. New system and battery fields are optional so the dashboard still
accepts earlier V1 agents. The signed battery charge counter is labeled as a
relative kernel counter rather than remaining capacity, and applicable time
values are labeled as kernel estimates; a zero time-to-full at the charging/full
boundary is shown as complete, while estimates beyond the 30-day plausibility
window are omitted. When both normalized capacity fields are present, battery
health is displayed as learned full capacity divided by design capacity. The
derived percentage is not capped at 100%, because a learned threshold can be
higher than the nominal design threshold; missing or invalid inputs omit it.

## Browser authentication

The preferred local flow generates an ECDSA P-256 WebCrypto key pair with
`extractable=false`. The browser exports only the public SPKI for the existing
one-time pairing endpoint. IndexedDB stores the non-exportable private CryptoKey,
public CryptoKey, credential ID and label. A later login requests the exact
domain-separated challenge bytes, signs them with ECDSA/SHA-256 and exchanges
the single-use signature for a scoped session.

Raw 64-byte WebCrypto signatures are accepted directly; unambiguous canonical
DER output is strictly parsed and normalized. An exact 64-byte sequence is
inherently ambiguous, so the server tries both raw and DER interpretations and
accepts only one that verifies. Bearer tokens remain only in page memory and
logout clears them. Password recovery is a manual form fallback; the dashboard
does not persist it, while browser password-manager behavior remains separately
controlled by the browser and user.

## Verification

```sh
cd web-app
npm ci
npm ci --prefix ../tools/openapi
npm audit --audit-level=high
npm run lint
npm run check:api
npm test
npm run build
npm run check:artifact
```

The artifact gate scans the completed `dist/` tree for legacy API paths,
plaintext URLs, the old split-origin port and common token-persistence markers.
