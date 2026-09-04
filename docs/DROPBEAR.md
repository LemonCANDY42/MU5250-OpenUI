# B04 V1 key-only Dropbear

V1 does not use the historical `scripts/zharden.sh` download. It builds
Dropbear 2026.94 from the official signed source release, pins the archive
SHA-256 and release-key fingerprint, and compiles only the server and key
generator into one static AArch64 musl binary.

The committed `device/dropbear/localoptions.h` compiles out password/PAM
authentication, local and remote TCP forwarding, agent forwarding and X11.
It also compiles out syslog, so the unsupported runtime flags `-s`, `-g` and
`-E` must not be passed. The runtime launcher supplies `-j -k`, binds only
`192.168.0.1:2222`, caps authentication attempts and idle time, and reads
exactly two owner-controlled public keys from `/data/u60/ssh/authorized_keys`.

Download the archive, detached signature and release key from the official
Dropbear release site, then build with the already pinned ziglang Python used by
the agent cross-build:

```sh
export DROPBEAR_ZIG_PYTHON=/absolute/path/to/pinned/ziglang/python3
scripts/build-b04-dropbear.sh \
  /path/to/dropbear-2026.94.tar.bz2 \
  /path/to/dropbear-2026.94.tar.bz2.asc \
  /path/to/dropbear-key-2015.asc \
  /Volumes/backups/U60-Pro/toolchains/dropbear-2026.94-b04
```

The output must still pass both device tests before persistence:

1. each of the two independent keys logs in successfully;
2. a password-only negotiation reports `publickey` as the sole available
   authentication method.

Root ADB remained available during the initial two-key and password-rejection
tests so SSH could not become the sole unverified recovery path. Host private
keys never enter the repository, release bundle or unencrypted NAS evidence.
LAN verification accepted the scanned Ed25519 host key only after it exactly
matched the public host key read from the same device over root ADB; it did not
route SSH through an ADB TCP forward. After that independent proof, the accepted
normal boot returned to stock ECM and USB ADB became absent by design. Key-only
SSH is now the daily recovery path; the exact DEBUG policy can restore root ADB
after an explicitly authorized reboot.
