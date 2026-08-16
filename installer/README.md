# MU5250 one-click installer

GUI app (Tkinter) that deploys the full stack on a ZTE U60 Pro (MU5250) —
unlock, agent, SSH hardening, dashboard — using the pre-built artifacts
from this repo's GitHub releases. No Rust or Node toolchain required.

## Run from source

```sh
python3 installer/app.py
```

Needs a Python with a **modern Tk** and `cryptography`:

- macOS: the Apple-shipped system Python (`/usr/bin/python3`, Tk 8.5) renders
  ttk widgets invisible in dark mode — do not use it. Use Homebrew:
  `brew install python@3.13 python-tk@3.13 && /opt/homebrew/bin/python3.13 -m pip install --break-system-packages cryptography`
  then `/opt/homebrew/bin/python3.13 installer/app.py`.
- Windows/Linux: python.org / distro Pythons ship a fine Tk.

Requires `adb` for the unlock flow (Android platform-tools), unless you run
a packaged build — those bundle adb. After hardening, everything goes over
SSH and adb is no longer needed.

## What it does

| Step | Source of truth |
|---|---|
| Detect device state (web :80 / agent :9090 / ssh :2222 / adb) | — |
| Unlock (locked firmware only) | `scripts/zunlock.py` (`run_unlock`) |
| Agent | `setup.sh` steps 3–8, ported to `installer/deploy.py` |
| SSH hardening | `scripts/zharden.sh`, ported to `installer/deploy.py` |
| Dashboard | `deploy-dashboard.sh`, but pushing the release tarball instead of a local npm build |

Artifacts (`zte-agent`, `dashboard-dist.tar.gz`) are downloaded from the
latest GitHub release and verified against `sha256sums.txt` before they
touch the device.

## Inputs

- **Device address** — default `192.168.0.1`.
- **Router admin password** — only used for the unlock step (login to the
  stock web UI).
- **Backup-key suffix** — prompted at runtime, never stored, never embedded
  in the app. Obtain it from the community or a rooted unit
  (see `docs/DEPLOYMENT.md`).
- **Agent password** — your choice; this becomes the dashboard login.
- **Agent PIN** — optional 6-digit second factor.

## Safety

Same rules as the shell flow (`docs/SAFETY.md`): shell/ssh/adb only, no
boot hooks outside `/etc/rc.local`, idempotent steps. The restore upload
(the only step that reboots the device) always goes through a confirmation
dialog, and the unlock dry-run checkbox prepares everything without
uploading.

## Packaged builds (CI)

`.github/workflows/installer.yml` builds PyInstaller bundles on tag push
(macOS / Windows / Linux) and attaches them to the release. Packaging
notes:

- `zunlock.py` is bundled via `--paths scripts` (imported as a module).
- `cryptography` provides the backup crypto (pure-Python 3DES, byte-
  compatible with `openssl enc -des-ede3-cbc -md sha256`) so no openssl
  binary is needed on Windows.
- adb is NOT bundled yet — CI downloads platform-tools per OS into
  `installer/assets/platform-tools/` at build time; `deploy.find_adb()`
  prefers the bundled copy, then PATH.

### Windows note

After unlock, Windows may need a USB driver for the ZTE device in adb mode
(use Zadig with the WinUSB driver, or Google's USB driver). macOS/Linux
work out of the box.
