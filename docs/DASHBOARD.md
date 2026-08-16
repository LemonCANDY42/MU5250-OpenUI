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
- system uptime, kernel and load average;
- battery state, capacity, voltage, current and temperature;
- validated thermal sensors.

An unsupported capability is shown explicitly and is not requested. A degraded
capability retains its reason and maintenance action. There are no raw commands,
firmware dictionaries, device mutations or legacy endpoint bindings.

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
