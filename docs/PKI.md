# Owner PKI tooling boundary

This document defines the tooling and accepted runtime boundary for the private
`u60.local` TLS identity. The scripts themselves never install trust or contact
the device. A later, separately authorized maintenance gate created the real
owner CA outside the repository, generated the leaf key on the U60, signed the
CSR on the Mac, backed up the encrypted CA and started a loopback-only canary.

## Ownership and lifecycle

The offline owner Mac owns the root CA. `create-owner-ca.sh OUTPUT_DIR` creates an
AES-256-encrypted P-256 private key at mode `0600`, a ten-year self-signed PEM
root certificate, and a byte-equivalent public DER certificate. The DER copy is
for later manual Mac/iPhone installation; this tooling never installs it. The
CA output directory must be new or empty, must not be a symlink, and must be
outside the repository. The completed set is identified by
`owner-ca.complete`.

The device must eventually own its leaf private key. During a separately
authorized device-maintenance gate, `generate-device-csr.sh OUTPUT_DIR` is
intended to create the mode-`0600` P-256 leaf key and CSR in device-controlled
storage. Its subject and requested identity are fixed to `CN=u60.local`; callers
cannot provide a subject or SAN. This host-only workslice does not run that step
on the device and does not establish that the target firmware has the required
Bash/OpenSSL runtime. In particular, the current generator uses
`openssl req -addext`; support in the exact B04 OpenSSL build is an unpassed
probe gate, not an assumption or source-test result. The CSR must cross the
offline boundary together with its final `device-csr.complete` marker.

Only the public CSR set—the CSR plus its completion marker—crosses from the
device to the offline owner Mac; the leaf private key does not. On that Mac,
`sign-device-csr.sh CA_DIR CSR OUTPUT_DIR` verifies the CSR self-signature,
fixed subject and P-256 key before issuing a fixed 825-day server certificate:

- SAN: `DNS:u60.local` and `IP:192.168.0.1`;
- critical `CA:false` and critical `digitalSignature` key usage;
- `serverAuth` extended key usage.

The signing output is the leaf certificate, leaf-plus-root chain, and
`sha256/` base64 SHA-256 SPKI pin. The CA private key is never copied into the
device output. The final file is `device-bundle.complete`.
`verify-bundle.sh DEVICE_DIR CA_CERT` requires all three applicable completion
markers and checks the chain, current-time validity, no more than 825 days of
total `notAfter - notBefore` validity, exact identity and extensions, P-256
keys, leaf key/certificate match, mode `0600` leaf key, exact chain bytes and
exact SPKI pin before later deployment is considered. The host verifier uses
Python 3's standard library to parse fixed `LC_ALL=C` OpenSSL validity output;
date-parse failure is a hard verification failure.

Every CA, CSR and output directory is checked by physical path before any
mutation. `/`, the current working directory, the user home, the Git repository
and paths containing symlinks are rejected. An existing directory must already
be owned by the current user at mode `0700`; the scripts never repair its mode.
The signer also rejects equal or ancestor/descendant overlap between its CA and
output directories.

Each complete file is staged and published without overwrite. The artifact set
is deliberately not claimed to be multi-file crash-atomic: its constant
completion marker is published last, and consumers fail closed when that marker
is missing or invalid. A directory containing data files without the marker is
an incomplete set. Do not copy or use it. Because normal commands also refuse
overwrite, recover only after independently confirming the exact path and which
set is incomplete:

- quarantine an incomplete owner-CA or device-CSR directory and regenerate into
  a different empty mode-`0700` directory;
- if only signing publication was interrupted inside an otherwise complete CSR
  directory, retain `device-key.pem`, `device.csr.pem` and
  `device-csr.complete`; quarantine the incomplete certificate, chain, pin and
  bundle marker, then rerun signing into that cleaned mode-`0700` directory.

The tooling does not delete, repair or automatically recover an incomplete set.

The CA passphrase is read only from file descriptor 3, or from the numeric
descriptor selected by `U60_CA_PASSPHRASE_FD`. It is never accepted as an
argument or an environment value. Do not run these commands with shell tracing
enabled, and never place an output directory in this repository.

## Current acceptance boundary

`test-pki.sh` exercises the complete flow only under a temporary directory with
a fixed, explicitly test-only passphrase. It covers wrong-passphrase,
non-P-256, key/certificate mismatch, symlink, overwrite, permission, pin and
chain failures, overlong total certificate validity, unsafe physical paths and
missing completion markers, then removes every generated test artifact.

Real execution is now accepted only through the first read-only canary gate:

- the encrypted owner CA exists only outside the repository and has independent
  owner-only Mac, NAS and iCloud copies;
- the P-256 leaf key was generated on the U60 and never left it; the Mac signed
  only the public CSR, and exact chain, identity, extension and SPKI checks pass;
- the current canary serves TLS 1.3 at device loopback `127.0.0.1:19443`, reached
  only through a temporary USB ADB forward;
- a live client using the explicit owner root completed the TLS handshake and
  all five authenticated read-only requests; an unauthenticated request was
  rejected;
- no system trust entry or iPhone trust/pairing acceptance has run, so the iOS
  SPKI implementation remains source- and simulator-tested only;
- the secret-free immediate evidence is stored in
  `/Volumes/backups/U60-Pro/B04-canary-start-20260816T092824Z`.

The owner has replaced the planned 24-hour stability observation with a one-hour
fast gate; this cannot prove the original 24-hour RSS-growth target. iPhone
trust, browser/iOS key pairing and every write capability remain unaccepted.
The real private material, password and verifier must never be copied into this
repository or its evidence manifests.

Apple's [local-network TLS identity guidance](https://developer.apple.com/documentation/network/creating-an-identity-for-local-network-tls)
describes the identity/trust model. Apple's
[certificate validity requirements](https://support.apple.com/en-ca/102028)
state that the 398-day limit does not apply to certificates issued from a root
CA that a user or administrator added. The 825-day leaf profile therefore
depends on deliberate manual installation of this private owner root; it must
not be represented as publicly trusted.
