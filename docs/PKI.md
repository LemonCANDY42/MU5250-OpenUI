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
`verify-bundle.sh CSR_DIR BUNDLE_DIR CA_CERT` requires the public CSR and its
marker in `CSR_DIR`, the signed certificate artifacts and their marker in
`BUNDLE_DIR`, and the owner CA marker alongside `CA_CERT`. It never reads or
copies a device private key. It verifies the CSR self-signature and fixed
subject, compares the CSR public key with the leaf certificate public key, and
checks the chain, current-time validity, no more than 825 days of total
`notAfter - notBefore` validity, exact identity and extensions, P-256 keys,
exact chain bytes and exact SPKI pin before later deployment is considered. The
host verifier uses Python 3's standard library to parse fixed `LC_ALL=C`
OpenSSL validity output; date-parse failure is a hard verification failure.

Successful host verification deliberately does not establish that the private
key deployed on the U60 matches the accepted leaf certificate: the host has no
device private key with which to make that comparison. That proof belongs to
the post-deploy live TLS gate. The gate must verify that the certificate served
by the device equals the accepted leaf certificate and then complete an
owner-CA-authenticated TLS handshake. Serving that exact certificate while
completing the handshake proves possession of its corresponding private key.

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
- if only signing publication was interrupted, retain the completed CSR set and
  quarantine the incomplete certificate, chain, pin and bundle marker from the
  signing output directory; rerun signing into a different empty mode-`0700`
  output directory.

The tooling does not delete, repair or automatically recover an incomplete set.

The CA passphrase is read only from file descriptor 3, or from the numeric
descriptor selected by `U60_CA_PASSPHRASE_FD`. It is never accepted as an
argument or an environment value. Do not run these commands with shell tracing
enabled, and never place an output directory in this repository.

## Current acceptance boundary

`test-pki.sh` exercises the complete flow only under a temporary directory with
a fixed, explicitly test-only passphrase. It covers wrong-passphrase,
non-P-256, CSR/certificate mismatch, public-CSR-only host verification, symlink,
overwrite, permission, pin and chain failures, overlong total certificate
validity, unsafe physical paths and missing completion markers, then removes
every generated test artifact.

Real execution is accepted through the nonpersistent LAN and physical-iPhone
authentication gates:

- the encrypted owner CA exists only outside the repository and has independent
  owner-only Mac, NAS and iCloud copies;
- the P-256 leaf key was generated on the U60 and never left it; the Mac signed
  only the public CSR, and exact chain, identity, extension and SPKI checks pass;
- the accepted persistent Agent serves TLS 1.3 on the certificate-covered
  management address and rejects unauthenticated requests;
- the owner iPhone has the exact public CA installed with full trust and still
  requires the exact leaf SPKI pin after normal Apple trust evaluation;
- a Secure Enclave P-256 credential was registered through a five-minute QR
  window and completed a live challenge-authenticated session;
- the secret-free immediate evidence is stored in
  `/Volumes/backups/U60-Pro/B04-canary-start-20260816T092824Z`.

Browser and iPhone key pairing, persistent installation and owner-operated reboot
resumption are accepted. Every later device write remains separately gated; the
stable installation does not broaden authorization or weaken TLS/key boundaries.
The real private material, password and verifier must never be copied into this
repository or its evidence manifests.

Apple's [local-network TLS identity guidance](https://developer.apple.com/documentation/network/creating-an-identity-for-local-network-tls)
describes the identity/trust model. Apple's
[certificate validity requirements](https://support.apple.com/en-ca/102028)
state that the 398-day limit does not apply to certificates issued from a root
CA that a user or administrator added. The 825-day leaf profile therefore
depends on deliberate manual installation of this private owner root; it must
not be represented as publicly trusted.
