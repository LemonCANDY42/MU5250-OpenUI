# B04 read-only capability probe

This gate records normalized evidence for the four first-slice capabilities. It
does not start the agent or use the device network interface. It requires the
retained USB root ADB channel and reads only the fixed web-version file plus the
fixed procfs/sysfs files already owned by `B04Adapter`.

The probe refuses to run unless all of these conditions hold:

- exactly one authorized root ADB device is present;
- `/usr/zte_web/web/version` contains exactly the expected ordered
  `software_version` and `inner_software_version` lines for HK B04, using only
  LF or CRLF line endings;
- the Mac default route is Wi-Fi `en0` before and after the probe;
- the complete `utun` interface set is unchanged;
- `/Volumes/backups/U60-Pro` physically resolves to itself, is owner-controlled
  mode 0700, and belongs to the approved `Marshmallow/backups` SMB mount.

The only live invocation is:

```sh
python3 scripts/probe-b04-readonly.py \
  --output-root /Volumes/backups/U60-Pro
```

It publishes a new `B04-capability-probe-<UTC>` directory containing normalized
`capabilities.json`, a hash-bound `MANIFEST.json` and a final `probe.complete`
marker. Publication is anchored to the already validated NAS directory file
descriptor. Because the approved macOS SMB mount does not support
`RENAME_EXCL`, it exclusively creates the final mode-0700 directory, creates
files by requesting mode 0600, and writes the completion marker last. The
approved SMB share exposes those files as owner-only mode 0700; publication
accepts only regular files owned by the current user with mode 0600 or 0700,
never group/other access. It never
opens, overwrites or deletes a pre-existing result directory. A failed
publication is deliberately left as a markerless directory and is never
reopened for cleanup; consumers must ignore every result without the completion
marker's exact fixed contents, regular-file type, current owner and approved
owner-only mode. Marker write,
read-back or final directory-sync failure removes only that marker through the
still-open original result FD. Consumers must also verify the manifest hashes;
marker existence alone is not sufficient. Raw vendor JSON, raw
hostname/kernel/battery-state text, the ADB serial,
IMEI, SIM identifiers, passwords, tokens and arbitrary device files are neither
stored nor printed. Published device strings are exact constants or strict
allowlist matches; the redaction guard rejects every unknown schema key,
sensitive key/value marker and any contiguous 15-to-20-digit identifier before
NAS publication.

The recorded values prove only that the current fixed read paths were readable
on this B04 snapshot. They do not prove agent cross-compilation, TLS, runtime
resource limits, client authentication or canary stability. The probe performs
no UCI commit, ubus setter, filesystem write, process signal, USB-mode change,
network route change or boot persistence.

Host-only validation is:

```sh
python3 scripts/probe-b04-readonly.py --self-test
```

The self-test covers the fixed ADB argument/path allowlist, adapter-equivalent
missing procfs and battery-state semantics, ICCID/credential-in-allowed-field
rejection, approved SMB-source parsing, route/TUN drift refusal, mode-0600
exclusive file creation and exclusive result-directory creation.
