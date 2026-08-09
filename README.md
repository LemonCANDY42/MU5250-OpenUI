# MU5250-OpenUI

A custom control plane for the ZTE U60 Pro (MU5250) 5G modem: a Rust agent
on the device exposing a JSON API (`http://192.168.0.1:9090`), a React
dashboard served from the device (`http://192.168.0.1:8080`), and tooling to
unlock, provision and update both.

Credit: based on [jesther-ai/open-u60-pro](https://github.com/jesther-ai/open-u60-pro).

## Quick start

Locked firmware (HK B04+, CN B28+) — the full sequence:

```sh
python3 scripts/zunlock.py     # 1. unlock → adbd (config backup/restore route)
bash setup.sh                  # 2. build + install the agent (build-from-source)
bash scripts/zharden.sh        # 3. SSH, rc.local cleanup, dashboard :8080, FOTA off
bash deploy-dashboard.sh       # 4. build + push the web UI
```

Full instructions, requirements (backup-key suffix), updates and post-FOTA
recovery: **[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)**.

## Repository structure

```
agent/          Rust agent (runs on the modem, port 9090)
web-app/        React dashboard (served from the modem, port 8080)
scripts/        unlock + hardening + recon tooling
  research/     quarantined exploit tools — see its README before touching
docs/           documentation (below)
setup.sh        first-time provisioning (unlock + agent install)
deploy.sh       agent updates over SSH
deploy-dashboard.sh   dashboard build + push
zte-script-ng.js      community-vetted reference of safe ubus calls
```

## Documentation

| Doc | Contents |
|---|---|
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | unlock, install, harden, update, post-FOTA recovery |
| [docs/AGENT.md](docs/AGENT.md) | agent architecture, endpoint reference, safety constraints |
| [docs/DASHBOARD.md](docs/DASHBOARD.md) | dashboard pages, source layout, dev + local demo |
| [docs/SAFETY.md](docs/SAFETY.md) | **read first** — brick-prevention rules, daemon sync barrier, recovery commands, safety audit |
| [docs/reference/](docs/reference/) | device reference material (rpcd ACL dump, USB mode findings) |

## Safety in one paragraph

This device was bricked once by going beyond the sanctioned path. The rules
that keep it alive: **shell/ssh/adb only** — no boot hooks outside
`/etc/rc.local`, no system-service modifications, never disable a
`zte_topsw_daemon.conf` daemon via init.d, stay out of partitions, and treat
`scripts/research/` as quarantined. Everything else — including what the
deploy path does and deliberately does not touch — is in
[docs/SAFETY.md](docs/SAFETY.md).

## Source of truth

If this README and the code ever disagree:

- `agent/src/server.rs` — HTTP routing table
- `agent/src/auth.rs` — auth and token behavior
- `web-app/src/App.tsx` — navigation groups mounted in the UI
- `web-app/src/data/api.ts` — client-side API bindings and payload shapes
