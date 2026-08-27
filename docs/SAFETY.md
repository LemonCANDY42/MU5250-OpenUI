# Safety — how to not brick the U60 Pro

Hard-won rules for this device. Read before running anything against the
modem with ADB/SSH access. The device was bricked once already (July 2026)
by going beyond the sanctioned path; everything below is the reason it
cannot happen again.

## Golden rules

1. **Shell/ssh/adb only.** No boot hooks outside `/etc/rc.local`. No
   firewall includes/hooks, no init.d service changes, no uci changes to
   system services. A boot-time hook that stalls or whose target moves can
   wedge the device before any recovery interface exists. (The
   `firewall.zte_recovery` bootstrap, withdrawn in commit `a41f89c`, is the
   canonical example of what NOT to reintroduce.)
2. **Never disable a daemon listed in `zte_topsw_daemon.conf` via
   `/etc/init.d/<name> disable`** — see the sync barrier below.
3. **Stay out of partitions.** No `dd`, `mtd`, `fw_setenv`, `/dev/block`,
   QFPROM/fuse writes, `abctl --set_active` (mixed-slot boots can brick).
   There is no recovery from these without a flasher.
4. **Config backup/restore is the only sanctioned privileged path**
   (`scripts/zunlock.py`, `scripts/zbackup.py`). Always `--dry-run` first;
   restore runs as root and extracts whatever it validates.
5. **Exploit/injection tooling lives in `scripts/research/` and stays
   there.** It is quarantined for a reason — see its README.
6. **Do not use this branch to change FOTA state.** A surprise firmware update
   can change the recovery assumptions, but FOTA control is permanently outside
   the integrated public API. Record and manage the owner's existing setting
   only through a separately approved maintenance procedure.
7. **Never write the USB composition node (`usb_op`) live** — set it via
   rc.local + reboot. Live writes (`0` or `2` after `1`) kill the gadget
   until the next reboot.

## CRITICAL: ZTE daemon sync barrier

`zte_topsw_daemon` is the master daemon. It reads
`/etc/config/zte_topsw_daemon.conf` and **waits for ALL listed daemons to
register** before releasing the boot sequence.

If you disable a daemon.conf daemon via init.d, the device will:

- stick on the ZTE boot logo (UI never renders)
- never connect WAN (mobile data call never initiated)
- leave the touchscreen dead (mtdev2tuio bridge never starts)

…while all other daemons appear to run fine, which makes the root cause
very hard to diagnose.

**Daemons in daemon.conf (NEVER disable via init.d, NEVER kill casually):**

```
zte_topsw_mc, zte_router, zte_topsw_data, zte_topsw_nwinfo,
zte_topsw_mdm, zte_topsw_sleep_faw, zte_topsw_apn, zte_topsw_wms,
zte_topsw_key, zte_topsw_led, zte_topsw_tr098db, zte_dm,
zte_topsw_fota_result, zte_topsw_devui, zte_topsw_wlan, zte_smart_manage
```

**Safe to disable via init.d (NOT in daemon.conf):**

```
zte_topsw_diag, zte_topsw_samba, zte_topsw_nfc, zte_topsw_get_brand,
zte_topsw_jwxk_query, zte_topsw_tr069_sub, zte_mqtt_sdk_st,
zte_topsw_dua, zte-topsw-tunnel
```

The private integrated agent exposes **no process-killing endpoint**. The lists
above are retained only as historical recovery evidence. Do not turn them into
an allowlist: even a process once considered expendable may participate in a
different B04 lifecycle or be restarted by procd.

If a daemon.conf daemon truly must be disabled, comment it out in
`/etc/config/zte_topsw_daemon.conf` (prefix `#`) — never via init.d.

### Overlay whiteouts

`/etc/init.d/<name> disable` creates **whiteout character devices** in
`/zteoverlay/etc-upper_a/rc.d/` that silently delete the ROM symlinks.
Invisible in normal `ls /etc/rc.d/`, persistent across reboots.

- Check: `ls -la /zteoverlay/etc-upper_a/rc.d/ | grep '^c'`
- Fix: `rm /zteoverlay/etc-upper_a/rc.d/<whiteout_file>`

### Verify sync status after boot

```sh
ubus call zwrt_topsw_daemon.sync get_sync_info '{}'
# Should return: "noSyncModuleName": "sync success"
```

## Recovery commands

**Display stuck on logo:**

```sh
sh /usr/bin/mtdev2tuio.sh                                      # touchscreen bridge
kill -9 $(pidof zte_topsw_devui); /usr/bin/zte_topsw_devui &   # restart UI
```

**WAN not connecting:**

```sh
ubus call zwrt_qcmap_cli set_qcliiface '{"source_module":"zte_topsw_data","type":1,"enable":1,"sub_id":1}'
ubus call zwrt_qcmap_cli set_qcliiface '{"source_module":"zte_topsw_data","type":2,"enable":1,"sub_id":1}'
```

**Check data call status:**

```sh
ubus call zwrt_data get_wwaniface '{"source_module":"zte_topsw_data","cid":1}'
# Look for: "enable": 1, "connect_status": "connected"
```

## Firmware behavior gotchas

- **Airplane mode bug**: `nwinfo_set_mode ONLINE` does NOT recover the modem
  from low-power mode. Only fix: reboot.
- **Charging remains read-only**: B04 exposes the stock charging state, but its
  write-result and recovery semantics are not sufficiently proven. V1 does not
  call the charger `set` method, run a charging-policy enforcer, or expose a
  charging mutation route.
- **procd lifecycle**: signalling or stopping a managed service can cause a
  respawn or block firmware synchronization. The integrated platform performs
  neither operation.
- **rc.local discipline**: stock rc.local contains a flash-protect block that
  READS `usb_op` — never delete that block (`sed '/usb_op/d'` breaks the
  script's syntax and kills ALL rc.local actions next boot). Always `sh -n
  /etc/rc.local` after any edit.
- **Reported IMEI is mutable in some firmware/service paths.** It is not a safe
  regional-update mechanism and is not authoritative device identity. The
  integrated platform neither exposes nor modifies it.
- **eSIM**: no eUICC chip; not feasible.

## Reviewed V1 deploy path

`setup.sh`, `deploy.sh`, `deploy-dashboard.sh` and `scripts/zharden.sh` are
historical upstream scripts and now exit before device access. The old flow
would have:

- push `/data/zte-agent` + `/data/local/tmp/start_zte_agent.sh`
- push dashboard static files to `/data/www`
- append `sh /data/local/tmp/start_*.sh` lines to `/etc/rc.local`
  (idempotent, grep-guarded, syntax-checked with `sh -n`)
- install dropbear to `/data/bin` (zharden) with key auth on port 2222
- add a second uhttpd instance on :8080 for the dashboard (uci `uhttpd.dashboard`)
- disable FOTA auto-update (`zwrt_zte_dm set_update_mode`)

Those historical actions remain disabled. The reviewed V1 path uses only
`/data/u60/releases/<sha256>/`, `current`/`previous` atomic links and mutable
`state`, `pki`, `ssh`, `runtime` and bounded `logs` directories. A canary binds
only loopback `19443`; stable HTTPS binds only the management address at `9443`;
Dropbear binds only that address at `2222` with password/PAM and forwarding
compiled out plus runtime `-s -g -j -k`.

`scripts/deploy-b04-v1.py` keeps release install, canary, stable activation,
SSH, rollback and the single `rc.local` line as separate gates. It rechecks
exact firmware, root ADB, Mac default route/TUN, device USB properties and
`rc.local`, and writes the scoped result to the approved NAS. It does not touch
the dormant `/data/zte-agent` paths. The boot entry is permitted only after a
current release, stable agent PID, Dropbear PID and exactly two public keys are
present; it adds no init/firewall/UCI hook. Root ADB is never removed.

This implementation still requires live acceptance. The owner reduced the
final observation to a one-hour active gate; that result must not be represented
as the original 24-hour RSS-growth target.

The compiled secure service additionally has one bounded, read-only stability
recorder. It samples fixed kernel/process counters every ten minutes, performs
no vendor call or device mutation, and stores only sanitized aggregate records
in `/data/u60/state/stability-monitor-v1.jsonl`. The file is mode `0600`, has a
1 MiB hard limit and permanently stops after the first seven-day window (or
earlier if the limit is reached). Its atomic state file preserves the original
deadline across agent replacement, restart and device reboot. Corrupt/missing
authoritative state with a nonempty log disables the recorder rather than
silently starting a new observation. This persistence does not install a boot
hook and does not weaken the separate stable-install gate.

## Known-good ubus surface

`zte-script-ng.js` (repo root) is the community-vetted reference of ubus
calls that are safe on this firmware: `zte_nwinfo_api` (netinfo/netselect/
bandlock/cell lock), `zwrt_wlan set` (txpower/country/maxassoc), `uci get`,
and read-only status objects. New agent features should prefer these objects
and methods; anything outside that surface deserves extra scrutiny.

---

# Historical upstream safety audit — 2026-08-09

Scope: every commit (`git log --all`), the working tree, and the deploy
path. Goal: confirm nothing in this repo can brick the device when ADB is
regained and this is deployed again.

This audit predates the B04 V1 integration. Its findings are retained as
device-recovery evidence, not as approval to bypass the disabled deploy guards.

## 1. Deploy path

| Surface | What it does | Verdict |
|---|---|---|
| `setup.sh` | historical unlock + agent push + rc.local edit | disabled in this branch |
| `deploy.sh` | historical SSH binary replacement | disabled in this branch |
| `deploy-dashboard.sh` | historical dashboard copy to `/data/www` | disabled in this branch |
| `scripts/zharden.sh` | historical Dropbear/uhttpd/FOTA/rc.local changes | disabled; does not establish key-only SSH |
| `scripts/zunlock.py` / `zbackup.py` | config backup patch + restore (the unlock itself) | highest-risk by nature, but gated: `--dry-run`, explicit confirm, sha256 upload verification, payload auto-discovered from the device's own rc.local |

## 2. Current private agent behavior

- The compiled agent performs no boot-time migration or device mutation.
- Its default listener is host-only `127.0.0.1:19090`; this is a test default,
  not the future device port.
- `B04Adapter` reads only the fixed `/usr/zte_web/web/version` identity file
  plus fixed proc/sysfs paths. No public request can select an object, method,
  command, key or path.
- Legacy TTL, USB, routing and logger modules remain only as dormant provenance
  files and are not in the compiled module graph. Wi-Fi and SMS are exposed only
  through their typed, allowlisted V1 operations; charging is read-only and the
  historical charging-policy implementation has been removed.

## 3. Findings acted on (2026-08-09)

1. **Exploit tooling quarantined.** `zacs.py` (rogue TR-069 ACS with
   SetParameterValues), `zrce.py`, `zinj.py`, `zdns.py`, `zstrings.py`,
   `zgap.py` (fac_reset/fac_reboot/FOTA probes), `zadb.py`, `zhidden.py`,
   `zwrite.py` moved to `scripts/research/` with a warning README. They
   never ran as part of deploy, but they are the class of tool that bricked
   the device and should not sit next to sanctioned tools.
2. **Safety docs consolidated into this file** (device rules + audit).
3. **v2.1 upstream regressions rejected** during the feature port (below).
4. **setup.sh unlock modernized**: the dead `zwrt_bsp.usb set {mode:debug}`
   path replaced with the backup/restore route; the broken in-setup dropbear
   install (404 URL + unusable opkg) removed in favor of `zharden.sh`.

## 4. v2.1 features ported, and what was deliberately NOT ported

The upstream snapshot contained charge control, USB powerbank, SMS
SQLite-delete fallback, raw AT-port discovery and Wi-Fi UCI behavior. In the
B04 V1 integration the charger write path is rejected; other functionality is
accepted only when represented by a typed `/v1` capability and after its own
backup, readback and recovery gate.

**Rejected from v2.1 (safety regressions):**

| v2.1 change | Why rejected |
|---|---|
| any kill-bloat/process-killing API | process lifecycle is not a stable device contract; the public capability is permanently absent |
| unrestricted or allowlisted raw AT terminal | string allowlists are not a safe semantic boundary; the route and AT transport module were removed |
| any plaintext LAN listener or generic destructive endpoint | current source binds only to loopback for host tests and exposes no writes; the device canary must use pinned HTTPS |

Scheduler, DoH, SMS forwarding and Tailscale are outside the compiled private
agent. They are not fallback services and must not be added to the core runtime.

## 5. Secrets / sensitive data

- `back_parameter` (encrypted config backup), `adb-lock-investigation.md`
  (contains the backup-key suffix, IMEI and sticker credentials), `logs/`,
  `loopdebug-capture/` are **gitignored and never committed** — verified
  across all history. Keep it that way.
- No real IMEI, passwords, session tokens or backup-key material may enter any
  commit. Synthetic mock identifiers are test data only.
- `scripts/research/` tools are env-parameterized (no embedded credentials).

## 6. Residual source risks

- `zunlock.py` and config restore are inherently privileged recovery tools;
  neither participates in normal runtime or deployment.
- Dormant upstream mutation modules remain for provenance and reference. The
  route-contract test and minimal compiled module graph prevent them from
  becoming public behavior accidentally.
- Every `scripts/research/` executable fails closed before a socket, listener
  or queue side effect unless the privileged-research one-command
  acknowledgement is present. The acknowledgement is an audit gate, not a
  safety claim; the quarantine rules still apply.
