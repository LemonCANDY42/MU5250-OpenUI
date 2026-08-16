# EMULATION.md — Running the stock firmware in QEMU for agent/dashboard testing

The stock MU5250 (U60 Pro) firmware rootfs (`firmware/slota/system_a.img.gz`,
OpenWrt 23.05.4 / SDX75 / aarch64-musl) boots under QEMU on Apple Silicon.
The emulated device runs the real ZTE daemons, registers the real ubus object
tree, and accepts the repo's `zte-agent` — so the dashboard can be exercised
end-to-end without hardware.

## Quick start

```sh
bash scripts/emulate.sh          # build payload, boot VM, auto-install, verify
bash scripts/emulate.sh status   # VM + agent reachability
bash scripts/emulate.sh stop     # stop VM
```

Once up:

| What | Where |
|---|---|
| zte-agent API (emulated) | `http://127.0.0.1:9090` (password `emu-test-password`) |
| Project dashboard | `cd web-app && npm run dev` → `http://127.0.0.1:5173` (auto-targets `:9090`) |
| Stock ZTE web UI | `http://127.0.0.1:9080` (see "Stock web UI fidelity" below) |
| Guest serial shell | `cd firmware/emulation && python3 console.py run "ubus list"` |

## How it works

```
Host (macOS)                          QEMU guest (ARM64, HVF)
────────────                          ────────────────────────
vite dev :5173 ──► 127.0.0.1:9090 ──► zte-agent (aarch64 musl)
                                          │  ubus call / uci / AT
                                          ▼
                     real firmware userland: ubusd, rpcd, netifd, procd,
                     zte_topsw_* daemons (zwrt_apn_object, zwrt_router.api,
                     zwrt_zte_mdm.api, zwrt_bsp.*, zwrt_wlan, zwrt_wms, ...)
                                          │
                     stubs (rpcd plugins) ──┤ zte_nwinfo_api  ← replays a real
                                          │ zwrt_bsp.thermal   device capture
                                          ▼
                     fakemodem (pty /dev/at_mdm0, /dev/smd7, ...) — answers
                     the agent's AT command set with X75-style responses
```

- **Kernel**: stock device kernel (5.15.170-perf, Qualcomm) can't run on QEMU
  `virt`; we boot an OpenWrt 23.05.4 **armsr** kernel (5.15, virtio_blk + ext4
  built in) and mount the *unmodified* extracted ext4 rootfs from
  `system_a.img`. Userland ABI matches (aarch64, musl, OpenWrt 23.05.4).
- **Rootfs patches** (applied once to the QEMU copy only, stock dumps stay
  pristine):
  - remove `S03create-firmwarelinks-ab.init` / `S03user_permissions.init` /
    `S04partition-symlinks.init` — they `while[1]`-wait (or hard-reboot) for
    the eMMC bootdevice that QEMU doesn't have;
  - `inittab` askconsole → passwordless `/bin/ash` on the serial console;
  - minimal `/etc/config/network` (lo + eth0) — ZTE boot scripts regenerate
    the full qcmap network config anyway;
  - `S99emu-payload` init hook: mounts the payload drive (`/dev/vdb`) and runs
    its `install.sh`.
- **Payload drive** (`firmware/emulation/payload.img`, ext4): the
  cross-compiled `zte-agent`, `fakemodem`, rpcd stubs and replay data.
  Installed exactly like a real deploy (`/data/zte-agent`,
  `/data/local/tmp/start_zte_agent.sh`) except `ZTE_AGENT_BIND=0.0.0.0:9090`
  so QEMU user-mode hostfwd can reach it.

## What works / what doesn't

Works (against the *real* firmware binaries):

- `network.interface.zte_wan/zte_wan6`, `system`, `luci-rpc`, `zwrt_apn_object`,
  `zwrt_router.api`, `zwrt_zte_mdm.api`, `zwrt_wlan`, `zwrt_wms`,
  `zwrt_bsp.{battery,charger,usb,powerbank,led,key,pm,...}` — 117 ubus objects
- agent login + all read paths; AT console over the fake modem
  (`/api/at/port` reports `/dev/at_mdm0`, `AT+CSQ` round-trips)
- band/cell-lock write paths (accepted by the `zte_nwinfo_api` stub, state kept
  in `/tmp/zte_nwinfo_state` in the guest)

Stubbed or absent (hardware-dependent):

- `zte_nwinfo_api` — real daemon waits on QRTR/QMI (modem); rpcd stub replays
  `loopdebug-capture/netinfo-live.log` (a real device capture, 42 fields).
  `nwinfo_get_lte_nbr_contents`/scan-style methods return generic success.
- `zwrt_bsp.thermal` — real daemon exits without `/sys/class/thermal/*`; stub
  returns `{"cpu_temp": 42}`. Battery/charger values come back as `-2`
  (firmware's own "unavailable" sentinel) since QEMU has no power-supply sysfs.
- The stock `zwrt_wms` still registers without modem hardware and remains
  available for read-only comparison. Agent/dashboard SMS tests use the
  separate emulator-only `zte_agent_emu_wms` object, selected through
  `ZTE_AGENT_WMS_OBJECT`; it implements the same list/send/status/tag/delete
  payloads without shadowing or changing the stock daemon.
- Wi-Fi radios — no cfg80211 hardware in the VM.

## Stock web UI fidelity

uhttpd + `zte_web` from the firmware run and serve port 80/443 (hostfwd 9080/9443).
On a real device the web assets live on a separate `ztedata` UBIFS volume
mounted at `/usr/zte_web` — **that volume is not part of the firmware dump**,
so the emulated docroot is seeded from the partial capture in
`logs/b04-webui/` (missing `js/lib/require/require.js`, `theme/`, `svg_img/`
→ SPA never bootstraps → blank page).

To get the full stock UI, pull the asset tree from a live device and reboot
the emulator:

```sh
# on the device (adb/ssh root shell):
tar czf /tmp/ztedata.tgz -C / usr/zte_web/web
# on the host:
mkdir -p firmware/emulation/ztedata && tar xzf ztedata.tgz -C firmware/emulation/ztedata --strip-components=3 2>/dev/null || tar xzf ztedata.tgz -C firmware/emulation/ztedata
bash scripts/emulate.sh   # payload rebuild picks up ztedata/ automatically
```

## Regenerating pieces

- Kernel: `curl -LO https://downloads.openwrt.org/releases/23.05.4/targets/armsr/armv8/openwrt-23.05.4-armsr-armv8-generic-kernel.bin` → `firmware/emulation/openwrt-armsr-kernel.bin`
- Rootfs: `gunzip -kc firmware/slota/system_a.img.gz > rootfs-a.img` then
  re-apply the patches listed above (see git history for
  `firmware/emulation/patch/` and the debugfs command files).
- fakemodem: `firmware/emulation/fakemodem/` (standalone Rust bin, same
  `aarch64-unknown-linux-musl` toolchain as the agent).
