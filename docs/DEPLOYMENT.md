# Deployment — unlock, install, update

## Current owner-device operating and recovery modes

The accepted normal boot is stock ECM USB Ethernet. In this state USB ADB is
absent by design; the native App and Agent use management-LAN HTTPS on `9443`,
the stock Web UI remains available, and recovery administration uses LAN-only,
key-only root SSH on `2222`. macOS interface numbers can change, so select the
interface reported as the ZTE mobile-broadband adapter and verify that only the
management-subnet route uses it. A TUN exclusion for `192.168.0.0/24` prevents
the proxy from intercepting that subnet but does not create the physical Wi-Fi
or ECM link.

Two exact device-local recovery policies are retained as root-owned mode-`0600`
regular files:

- `/data/u60/recovery/rc.local.ecm` — accepted normal ECM boot.
- `/data/u60/recovery/rc.local.debug-before-ecm` — accepted DEBUG boot with root
  USB ADB.

The safe maintenance transition is:

1. While in ECM, authenticate over one of the independently verified SSH keys.
2. Revalidate exact HK B04, current release/service ownership, current
   `/etc/rc.local`, both recovery-file types/modes/hashes and `sh -n` syntax.
3. Atomically install the exact DEBUG copy as `/etc/rc.local`, preserving
   root:root mode `0775`; read it back and revalidate before reboot.
4. Reboot and re-enumerate USB. Expect root ADB and no usable Mac ECM interface.
5. Perform only the separately authorized ADB maintenance operation.
6. Through root ADB, repeat the same gates and atomically restore the exact ECM
   copy; reboot, then require ADB to be absent and ECM, Web, Agent and SSH to be
   reachable again.

Do not substitute a live `usb_op` write, the stock USB setter, a broad text
deletion, or an assumed one-reboot auto-revert. The chosen policy persists until
the reviewed opposite transition is completed. No helper that weakens these
gates is installed. FOTA automatic update remains off and is not part of either
transition.

## Pre-canary recovery baseline

Before the first device write, capture the retained root-ADB and boot-path
baseline directly to the approved NAS share:

```sh
python3 scripts/capture-b04-canary-baseline.py \
  --output-root /Volumes/backups/U60-Pro
```

The command refuses any firmware other than exact HK B04, a non-root or
ambiguous ADB transport, any directory entry (including a dangling symlink) at
`/data/u60`, a running `zte-agent`, a non-`en0` default route, TUN drift, or an
unapproved NAS mount. Known dormant upstream artifacts at `/data/zte-agent` and
`/data/local/tmp/start_zte_agent.sh` are inventoried by type, public metadata and
SHA-256 when regular, then rechecked for drift; they are never executed,
overwritten or removed. The command saves the current `/etc/rc.local` bytes and
public metadata, writes an owner-only manifest, and publishes
`baseline.complete` last. It does not write to the device. A canary must not
begin without an exactly verified completion marker.

## Stopped LAN-canary redeploy baseline

Do not rerun the first-canary command after a nonpersistent LAN canary has
stopped: its immutable release directory under `/data/u60/releases/` is a
retained recovery artifact, not debris to remove. Before redeploying it, record
the narrower read-only baseline below. It requires the exact approved release,
no `zte-agent` process and absent `current`/`previous` links; it rechecks those
facts before and after the capture, retains an owner-only `rc.local` backup and
publishes hash-bound evidence completion-last to the approved NAS share.

```sh
U60_B04_READ_ONLY_PROBE=I_CONFIRMED_B04_AND_ROOT_RECOVERY \
  python3 scripts/capture-b04-lan-redeploy-baseline.py \
  --expected-release 9b334dd65f32d8ef375d04026c197e467d6f42a44c7cf53df4c5803e49e58fb9
```

It does not write to the device, remove old releases, create a release link or
alter the Mac route/TUN configuration. A successful result is the prerequisite
for the subsequent `lan-canary` command, not evidence of a running service.

## Reviewed B04 V1 deployment path

The V1 path is implemented by three separate boundaries:

- `scripts/prepare-b04-v1-release.py` creates one deterministic NAS release;
  its directory name is the SHA-256 of `release.sha256` and every payload file
  is physical, size-bounded and checksum-bound.
- `device/b04-v1/` contains fixed BusyBox-compatible launchers for TLS canary,
  stable agent and key-only Dropbear. Mutable PKI, auth state and SSH host/key
  state remain outside the immutable release.
- `scripts/deploy-b04-v1.py` performs one explicitly selected device action,
  revalidates exact HK B04/root ADB plus Mac route/TUN and device USB invariants,
  and publishes a secret-free completion record to the approved NAS.

The deploy tool is an ADB maintenance tool. Run it only after the reviewed
ECM-to-DEBUG transition above; it is not expected to operate during normal ECM
boots and must never change USB mode implicitly.

The reviewed sequence is:

```sh
# Build a release only from a clean Git tree and receipt-bound agent build.
python3 scripts/prepare-b04-v1-release.py \
  --agent-build /Volumes/backups/U60-Pro/B04-agent-build-<id> \
  --dropbear /Volumes/backups/U60-Pro/toolchains/<build>/dropbearmulti \
  --dropbear-sha256 <operator-pinned-sha256>

# Each device mutation needs this one-command acknowledgement.
export U60_B04_V1_DEPLOY=I_CONFIRMED_STAGED_V1_WITH_ROOT_ADB_RECOVERY

# Loopback-only, nonpersistent canary first.
python3 scripts/deploy-b04-v1.py canary \
  --release /Volumes/backups/U60-Pro/releases/<content-hash> \
  --ca-cert /path/to/owner-ca.pem

# Physical-client gate: temporary LAN listener, still without release links or boot persistence.
python3 scripts/deploy-b04-v1.py lan-canary \
  --release /Volumes/backups/U60-Pro/releases/<content-hash> \
  --ca-cert /path/to/owner-ca.pem

# Stable activation remains nonpersistent until clients and daily writes pass.
python3 scripts/deploy-b04-v1.py activate \
  --release /Volumes/backups/U60-Pro/releases/<content-hash> \
  --ca-cert /path/to/owner-ca.pem

# SSH installation and verification are distinct gates.
python3 scripts/deploy-b04-v1.py install-ssh \
  --release /Volumes/backups/U60-Pro/releases/<content-hash> \
  --authorized-keys /path/to/exactly-two-public-keys
python3 scripts/deploy-b04-v1.py verify-ssh \
  --key-one /path/to/primary-private-key \
  --key-two /path/to/recovery-private-key

# Only after both services and both keys pass.
python3 scripts/deploy-b04-v1.py boot-hook
```

Updating SSH stops only the PID-file-owned Dropbear whose executable resolves
under an immutable V1 release, then starts the selected release. An absent or
foreign process fails closed; it never signals ADB or a stock service.

`lan-canary` is deliberately narrower than `activate`: it requires `current`
and `previous` to remain absent, stops the loopback canary, starts the exact
accepted release on `192.168.0.1:9443`, and proves the CA-verified `401`
authentication boundary from the host Mac. The check uses the accepted public
CA, the `u60.local` certificate name and the current management address, so TLS
date validation uses the trustworthy host clock without weakening certificate
or hostname verification. It does not set device time or create an ADB forward,
release symlink,
boot hook, firewall rule or service. A physical client must join the U60's own
Wi-Fi for this gate. Any failed TLS or evidence step stops the managed LAN
agent.

`activate` preserves the old `current` target as `previous`; a failed TLS health
check automatically restores it when available. Because stable HTTPS binds only
the management address, this health check uses the same host-side, full-CA,
hostname-verified request as `lan-canary`; it never relies on the device's
temporarily incorrect post-boot wall clock. Device-shell gates are delivered as
encoded scripts and must return an explicit remote status sentinel because this
B04 ADB transport does not propagate the remote shell exit code. Release-link
updates use BusyBox `mv -T` and exact post-write readback so an existing symlink
cannot be followed as a directory. `rollback` is also explicit.
The boot hook is exactly one backgrounded `start-current.sh` line in
`/etc/rc.local`, inserted before its single `exit 0` after byte backup and
syntax validation. The installed launcher hash, full `rc.local` bytes, metadata
and exact one-line count must all survive an independent readback before the
gate succeeds. No firewall/init hook, UCI service, USB/FOTA change or partition
action exists in this path. The background launcher waits up to two
minutes for the fixed management address and gives each service at most three
startup attempts with five-second spacing; it then exits and is not a watchdog.
Agent and Dropbear stdout/stderr go to `/dev/null`, so long-running services do
not create persistent process logs. Bounded security state and the one-shot
stability recorder remain the only service-owned persistent write paths.

A release containing the built-in stability monitor starts its one and only
seven-day window when that release first starts successfully. Its private state
and JSONL log live in `/data/u60/state`, outside immutable release directories,
so release replacement and service restart do not reset the window. Device-off
time is intentionally counted and is represented as a sampling gap; reboot is
recorded when the service next runs. Automatic post-reboot sampling exists only
after the separately gated stable activation and minimal boot hook are accepted.
A LAN canary is nonpersistent and therefore cannot by itself prove reboot
resumption. The monitor adds no deploy authorization and must not be used to
bypass any canary, recovery, SSH or boot gate.

The rest of this document is historical unlock/recovery context. Do not follow
the old deployment commands below on the B04 V1 branch: `setup.sh`, `deploy.sh`,
`deploy-dashboard.sh` and `scripts/zharden.sh` exit before device access.

Everything needed to go from a locked U60 Pro to the full stack (agent +
dashboard + SSH), and to keep it there. Read [SAFETY.md](SAFETY.md) first.

## Historical flow at a glance

The following block describes the disabled upstream flow:

```sh
python3 scripts/zunlock.py     # 1. unlock → adbd        (locked firmware only)
bash setup.sh                  # 2. build + install the agent (choose build-from-source)
bash scripts/zharden.sh        # 3. SSH, rc.local cleanup, dashboard :8080, FOTA off
bash deploy-dashboard.sh       # 4. build + push the web UI
```

End state (persists across reboots):

| Service | Where | Notes |
|---|---|---|
| USB-C tethering | USB-C, ECM (stock composition) | survives reboots (no usb_op write) |
| Stock web UI | `http://192.168.0.1:80` / `:443` | untouched |
| Dashboard | `http://192.168.0.1:8080` | uhttpd `dashboard` instance → `/data/www` |
| Agent API | `http://192.168.0.1:9090` | password = your choice at setup |
| SSH | `ssh -p 2222 root@192.168.0.1` | installed a key, but did not actually disable password login |
| ADB | historical upstream behavior | Do not reproduce with a live sysfs write; use the reviewed recovery-copy transition above. |

---

## 1. Unlock (locked firmware: HK B04+, CN B28+)

Newer MU5250 firmware removed the web-accessible USB-debug toggle
(`zwrt_bsp.usb.set`) — on B04 the method is deleted from the daemon itself,
so no web trick can re-enable ADB. (CN B27 and earlier still have it — if
your device is that old, `setup.sh` can enable ADB directly and you can skip
this section.)

What still works is the **config backup/restore path**: the backup is an
openssl-encrypted tar of the system config, and the restore process runs as
root and extracts whatever you give it. `scripts/zunlock.py` uses that to
plant one line in `etc/rc.local` that re-enables the USB debug composition
(adbd) at boot.

The script is fully self-contained (Python 3 stdlib + `openssl` CLI) and
contains **no secrets**: the backup-key suffix is an input, the device IMEI
is read from the device, and the USB-debug sysfs path is discovered from the
device's own stock `rc.local` inside the backup.

### Requirements

- The router's **admin password** (you set it — it's your web UI login)
- The **backup-key suffix** for this device family (see below)
- A computer on the device's network (WiFi or USB), Python 3, openssl
- `adb` installed for afterwards (`brew install android-platform-tools`)

### The backup-key suffix

The backup encryption password is `<device IMEI><suffix>` — the IMEI is
per-device (the script reads it itself), the suffix is a fixed string shared
across this ZTE platform generation. It is deliberately **not** published
here, at the request of the researchers who shared it (publishing it gets it
killed in the next firmware). To obtain it:

- ask the community
- extract it yourself from a rooted SDX75-era ZTE MBB unit: the web server
  binary (`zte_web`) builds the backup password in memory; the suffix is
  visible in its strings near the backup/restore code paths

Pass it via `--suffix`, the `ZTE_BACKUP_SUFFIX` env var, or the interactive
(hidden) prompt. It never touches this repo.

### Usage

```sh
python3 scripts/zunlock.py --dry-run     # everything except the upload (safe)
python3 scripts/zunlock.py               # full run, asks before restoring
```

`setup.sh` runs both stages automatically when it detects a locked device
(no SSH, no ADB) — it prompts for the suffix, does the dry run first, then
the real unlock with `zunlock.py`'s own consent gate.

What happens on a full run:

1. logs into the web UI, requests a fresh config backup, downloads it
2. decrypts it (`openssl enc -d -des-ede3-cbc -md sha256`)
3. inserts the USB-debug line into `etc/rc.local` (right after the shebang,
   path discovered from the stock file), preserving file modes/ownership
4. rebuilds the package exactly as the device does (inner tgz → md5 sidecar →
   outer tgz → re-encrypt) — passes the device's own restore-time md5 check
5. uploads it (`/cgi-bin/cgi-upload`, verifies the server's sha256 matches),
   triggers `device_restore_proc` — the device restores and reboots
6. ~60–90 s later: `adb devices` shows the unit (serial `0123456789ABCDEF`),
   root shell via `adb shell`

Your settings are preserved — the patched package is built from a backup
taken seconds earlier.

### Unlock safety notes

- The restore reboots the device and briefly interrupts connectivity (~90 s).
- The script verifies the upload hash before triggering anything; a mismatch
  aborts before any state change.
- Never write the USB composition node manually outside boot time (live
  writes can kill the gadget until reboot), and never experiment with A/B
  slot switching (`abctl --set_active`) — mixed-slot boots can brick the unit.

---

## 2. Agent install — `setup.sh`

```sh
bash setup.sh
```

- Prompts for the router admin password and the agent API password.
- **Choose "build from source"** (the default). The pre-built download is
  the upstream agent, which lacks this fork's endpoints and would leave
  parts of the dashboard empty.
- If the device is locked (no SSH, no ADB) it runs the unlock first (see
  above). If ADB is already up or SSH works, it deploys straight away.
- Pushes the agent to `/data/zte-agent`, creates the startup script with
  your password, adds the rc.local line, starts and verifies it.

## 3. Hardening — `scripts/zharden.sh`

```sh
bash scripts/zharden.sh
```

Idempotent — safe to re-run anytime. Installs dropbear to `/data/bin`
(opkg is unusable on this firmware), generates host keys, wires SSH into
rc.local, **removes the usb_op payload line** (so every boot returns to
stock ECM tethering), adds the dashboard uhttpd instance on :8080, and
disables FOTA auto-update.

## 4. Dashboard — `deploy-dashboard.sh`

```sh
bash deploy-dashboard.sh
```

Builds `web-app` (Vite) and streams `dist/` to `/data/www` over an SSH tar
pipe (the device has no sftp/scp). Also copies `index.html` → `mobile.html`
so ZTE's patched uhttpd serves the SPA to phone user-agents.

## Updating later

```sh
./deploy.sh              # agent (SSH; set ZTE_AGENT_PASSWORD / ZTE_AGENT_PIN)
./deploy-dashboard.sh    # dashboard
```

---

## Design rule: shell/ssh/adb only — no boot hooks outside rc.local

`zharden.sh` deliberately installs **no** boot-time hooks outside
`/etc/rc.local` and does not modify system services. An earlier approach
hooked boot through a `config include` section in the firewall service
(chosen because the UCI config dir survives FOTA) — that approach is
**deprecated and removed**: a hook inside a boot-critical service is a brick
risk. If it stalls or its target moves, the device can hang before any
recovery interface (ssh/adb/failsafe) is up, and recovery then requires
hardware access. See [SAFETY.md](SAFETY.md) for the incident history.

Trade-off accepted: `/etc/rc.local` is **not** preserved by FOTA, so a
firmware update wipes the service lines (the device itself still boots
cleanly to stock). Recovery after an update is simply re-running the
sequence above (~15 minutes). That is the right price for never risking the
boot path.

Notes:

- ADB is a bootstrap channel, not a good permanent interface on this
  firmware (its composition drops USB networking, and it only applies at
  boot) — SSH is the durable management channel.
- The rootfs is read-only except `/etc` and `/data`; `/data` survives FOTA,
  so binaries and web assets persist — only the rc.local lines need
  re-adding after an update.

## Post-FOTA recovery playbook

1. Verify the update landed and the device boots stock: ping, web UI up.
2. Re-run the sequence: `zunlock.py` (if ADB is gone) → `setup.sh` →
   `zharden.sh` → `deploy-dashboard.sh`.
3. Confirm FOTA auto-update is off again:
   `ssh -p 2222 root@192.168.0.1 'uci get zwrt_zte_dm.dm_update.dm_update_mode'` → `0`.
4. If the backup-key suffix ever stops working (ZTE rotated it): extract the
   new suffix from `strings /usr/sbin/zte_web` on any rooted unit.

## Credits

Backup-crypto details and the original payload hint: the
`amenekowo/mu5250_tweaking` community (with thanks — they asked that the key
material itself not be republished, and this tool honors that). B04
daemon/ACL analysis: community contributors on the issue tracker.
