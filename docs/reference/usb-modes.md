# USB Modes — ZTE U60 Pro

## Accepted HK B04 state (2026-09-04)

The owner device now boots in the stock **ECM** composition. This is the normal,
recoverable state: macOS receives a ZTE USB Ethernet interface, the management
route reaches `192.168.0.1`, and stock Web, Agent HTTPS and LAN-only key-only SSH
remain available. USB ADB is absent by design.

The previously unlocked **DEBUG** composition is also verified. It exposes root
ADB but did not provide a usable macOS USB Ethernet interface. DEBUG is therefore
an explicit maintenance boot, not a daily connectivity mode. Exact root-only
DEBUG and ECM `rc.local` copies are retained on the device, and switching either
direction requires validation, atomic replacement and reboot. It does not
auto-revert after one boot. See [../DEPLOYMENT.md](../DEPLOYMENT.md).

No ADB+ECM custom composite has been accepted. Never write `usb_op` live or call
the stock USB setter as a probe: either can immediately remove the active USB
transport. The current App/Agent intentionally exposes no USB-mode control.

Findings from probing the live device (firmware as shipped, 2026-05-28). These contradict what the dashboard's "USB Mode" section implies, so worth keeping for reference.

## What the dashboard offers

`web-app/src/pages/SettingsPage.tsx` (`UsbModeSection`) presents four buttons:

- **RNDIS** — Microsoft USB networking. Windows-native, requires unmaintained drivers on macOS.
- **ECM** (CDC-ECM) — Driver-free on macOS / Linux / modern Windows.
- **NCM** (CDC-NCM) — Driver-free on the same platforms, much higher throughput ceiling than ECM.
- **DEBUG** — Inferred to be ADB / serial console rather than a tethering mode.

Each button posts `{"mode": "<name>"}` to `PUT /api/usb/mode`, which forwards verbatim to `ubus call zwrt_bsp.usb set`.

## What the firmware actually supports via the stock switch

Only **ECM** and **RNDIS** are exposed by ZTE's normal USB mode switch. Evidence:

- `/lib/modules/ipa/` contains exactly two accelerated USB networking modules:
  ```
  ecmipam.ko
  rndisipam.ko
  ```
  No `ncmipam.ko` or equivalent GSI/IPA NCM module ships with this firmware.
- `dmesg` at boot:
  ```
  [ZTE_USB] functions ecm_gsi,mass_storage
  ```
  The composite device only enumerates ECM (+ mass storage), regardless of the "mode" requested via the dashboard.
- After clicking **NCM** in the historical dashboard and rebooting, the device
  came up with `ecm0` as the active interface. No `ncm0` interface was created;
  the firmware silently fell back to ECM.
- Live configfs does contain a generic NCM gadget function:
  ```
  /sys/kernel/config/usb_gadget/g1/functions/ncm.0
  ```
  But the active composition links `gsi.ecm`, and `/sbin/usb/compositions/usb_switch` has cases for `ecm`, `rndis_gsi`, and related functions, not `ncm`.

So:

| Dashboard button | What happens |
|---|---|
| RNDIS | Real — uses `rndisipam.ko`, creates an RNDIS gadget. |
| ECM | Real — uses `ecmipam.ko`, creates `ecm0`. |
| NCM | Stock path falls back to ECM. Generic `ncm.0` exists, but needs a custom experimental composition and bridge setup. |
| DEBUG | Verified root-ADB maintenance composition; it did not yield usable macOS USB Ethernet. |

## Why NCM matters (and why this limitation is annoying)

NCM batches multiple Ethernet frames per USB transfer (NTB), ECM does one per transfer. Practical ceiling differences:

| Link rate | ECM | NCM |
|---|---|---|
| < 200 Mbps | Fine | Fine |
| 200–400 Mbps | Starts bottlenecking on slower CPUs | Smooth |
| 400 Mbps – 1 Gbps | Caps / high CPU | Handles cleanly |
| > 1 Gbps (5G NR peaks) | Won't deliver | Required |

For typical 5G NR throughput (300–800 Mbps), NCM would meaningfully outperform ECM if the generic gadget path can be bridged cleanly. The 5G capability of this modem is wasted over ECM at the high end. An accelerated NCM equivalent to `ecmipam.ko`/`rndisipam.ko` would require firmware/kernel work, but a non-accelerated configfs NCM proof-of-concept is possible.

## Detecting the *current* mode reliably

`ubus call zwrt_bsp.usb list` returns:
```json
{ "mode": "user", "typec_cc": "cc2", "connect": 1, "usb2rj45": 0 }
```

The `mode` field reads `"user"` regardless of which function is active — it is a permission/owner state, not the USB function. Don't trust it for "what mode am I in."

Reliable detection from the device side: check which interface exists under `/sys/class/net/`:

- `ecm0` present → ECM active
- `rndis0` present → RNDIS active
- `ncm.0` linked in `/sys/kernel/config/usb_gadget/g1/configs/c.1/` plus a live NCM netdev (`ncm0` or `usb0`) → experimental NCM active

From the Mac side: `route -n get 192.168.0.1` shows the interface, and `networksetup -listallhardwareports` will identify it as "ZTE Mobile Broadband" regardless of mode — so the Mac side doesn't distinguish them either.

## Implications for the dashboard

- The "active mode" indicator should read active configfs links and kernel-side interface presence, not the ubus `mode` field.
- NCM should be labeled experimental: configfs support exists, but stock ZTE mode switching does not expose it.
- Historical NCM persistence code is not part of the accepted V1 control plane;
  the current App/Agent exposes no USB-mode mutation.
- DEBUG is a verified ADB maintenance mode, not a tethering option.
- Best default for Mac USB-C users: ECM. It's the most reliable driver-free option here.

## Aside: don't use `usb_mode_set` as a probe

Calling `ubus call zwrt_bsp.usb set {"mode": "..."}` in a loop to detect supported modes will switch the USB function and drop any USB-tethered connection (as happened during this investigation). Probe the kernel side instead.
