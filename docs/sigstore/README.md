# Self-Hosted Sigstore Trust Material

This directory is the stable repository-owned location for ServiceRadar's
custom Sigstore trust material once keyless signing is enabled for releases.

Current state:

- OCI release signing uses a Cosign-compatible public key published at
  `docs/cosign.pub`.
- The intended long-term release signer is the OpenBao Transit-backed
  `hashivault://cosign-release` key exposed to GitHub Actions runner jobs.
- Full self-hosted keyless signing needs Actions OIDC that Fulcio can
  map into a certificate SAN. Use `scripts/inspect-actions-oidc.sh` to
  inspect the token before locking issuer policy.

Populate these files from the active Fulcio/Rekor deployment:

- `trusted-root.json`: preferred Cosign trusted-root document for keyless verification
- `fulcio-root.pem`: optional out-of-band Fulcio root certificate
- `ctfe.pub`: optional out-of-band CT log public key

The release and verification scripts prefer `trusted-root.json` when present.
The PEM/public-key files are fallback material for environments that are not yet
using a full trusted-root document.

## Pinned Rekor keys (transparency-log receipts)

Release signatures for images, native add-ons and Wasm plugins are logged in
ServiceRadar's self-hosted Rekor v1 log, `https://rekor.serviceradar.cloud`
(`carverauto/gitops` `k8s/sigstore`), and each classic `.sig` carries that log's
receipt (see "Transparency-log receipts and the signing ledger" in
[RELEASE_PUBLISHING.md](../RELEASE_PUBLISHING.md)). Verification never contacts
that log or any other Rekor: receipts are checked offline against these committed
keys, so no installation depends on the log being up.

- `rekor-keys/<logID>.pub`: every accepted Rekor v1 public key, one PEM file per
  log, named by the log ID (hex SHA-256 of the key's DER encoding). Release
  verification selects the file by the receipt's `logID` and passes it to cosign
  as `SIGSTORE_REKOR_PUBLIC_KEY`, so no TUF lookup and no online log lookup
  happens. A receipt whose log ID has no file here fails. The web-ng importer
  selects keys the same way, and the web-ng image ships this directory at
  `/usr/share/serviceradar/sigstore/rekor-keys`.
- `rekor.pub`: the key of the log the signer writes to now, byte-identical to
  its file in `rekor-keys/`. The signer refuses an upload response whose log ID
  is not this key's.
- `pre-cutover-rekor-keys/<logID>.pub`: the public-good Rekor key
  (`c0d23d6a...801d`). Some image signatures made by hand before the cutover
  carry public-good receipts, and release verification checks such a receipt
  on a **reused** signature against this key. It is never accepted for a new
  signature, is accepted for a reused one only when the receipt was integrated
  before the cutover pinned in `cutover.json` (the v1.5.8 tag time), and is not
  accepted at import or shipped in the web-ng image. The transparency-log
  monitor watches only the self-hosted log.

- `pre-cutover-first-party-digests.json`: the frozen list of first-party Wasm
  plugin and native add-on digests published through v1.5.7, before the cutover
  release. Only these import without a receipt (key-only), and release
  verification accepts a reused receipt-less Wasm plugin or native add-on
  signature only for these; the web-ng image ships it at
  `/usr/share/serviceradar/sigstore/`. It is never regenerated or
  extended.

`//build/contracts:rekor_key_consistency_test` checks that every file is named by
its log ID, that the pre-cutover keys are not accepted keys, that `rekor.pub`
is a member of the accepted set, that the web-ng image ships exactly
`rekor-keys/` and the allowlist, and pins the allowlist's sha256.

The self-hosted key `a8839837a73a6b28ca5102be67a874e8f0aa324a694320fa08fd55f9167b12c9`
was fetched on 2026-11-18 at 17:04 UTC with
`curl https://rekor.serviceradar.cloud/api/v1/log/publicKey` (the same bytes with
`?treeID=7401445772329872027`). It was accepted only after the log's signed tree
head from `GET /api/v1/log` (tree `7401445772329872027`, size 46) verified under it
with `openssl dgst -sha256 -verify` and named it by key hint (`a8839837`).

Updating the keys: when the self-hosted log's key changes (the monitor alerts
when `/api/v1/log/publicKey` no longer returns `rekor.pub`), fetch the new key the same
way, add it as `rekor-keys/<logID>.pub` in a reviewed PR, keep every key an
accepted receipt names, and point `rekor.pub` at the new key. Never drop a key
from `rekor-keys/` that a published receipt names: verification of that receipt
would then fail.

### The signing monitor

`.github/workflows/rekor-signing-monitor.yml` runs every hour on `arc-runner-set`
(`build/ci/rekor_signing_monitor.py`). The log holds only ServiceRadar's entries, so each run
reads all of them (46 entries, about 280 KB, one second on 2026-11-18), recomputes the RFC 6962
root, and checks it against the signed tree head, which must verify under `rekor.pub`. The
previous run's checkpoint (kept as the `rekor-signing-monitor-state` artifact) must be a prefix
of the log, and `/api/v1/log/publicKey` must still return `rekor.pub`. Every entry in the log
signed by the release key, including those integrated before the first checkpoint, is then
decided against the signing ledgers of the release-key signing workflows that were running when
it was integrated:

- pending while such a run is still in progress;
- explained when its payload hash is in one of their ledgers, or it is listed in
  `rekor-acknowledged-entries.json`;
- otherwise unexplained: one GitHub issue (`security`, `signing-monitor`; the monitor creates
  the `signing-monitor` label if it is missing) per entry UUID and a post to
  `CI_FAILURE_DISCORD_WEBHOOK_URL`, retried every run until Discord accepts it. The issue is
  closed when a later run finds the entry explained.

The blindness canary opens an issue when a signing ledger records an entry in this log (its
`logged` line names this log's ID) that was integrated after the first checkpoint's time, kept
in the checkpoint, from a run that ended more than two hours ago, and that entry is not among
the entries seen. Every signing run created since the first checkpoint, within the 90-day ledger
retention, is checked after it ends until every entry it ledgered is seen (again if a re-run ends
later), so a monitor outage is caught up on the next successful run. Each unseen entry is kept in
the checkpoint, named on the open canary issue (or a new one, if it was closed) and posted to
Discord every run until it appears in the log or its log index is listed in
`rekor-acknowledged-entries.json`; the issue gets a comment as each named entry resolves and is
closed once all of them have. A run that cannot vouch for the log (unreachable, a
signature or root mismatch, a rewritten or replaced tree, a changed key, a missing checkpoint)
fails, opens an issue and posts to Discord. Only a checkpoint from a successful scheduled or
dispatched run on `staging` is used. The daily scheduled job watch reports the monitor when its
last successful scan (such a run that kept its checkpoint; a self-test keeps none) is older than
three hours.

Every run judges every release-key entry in the log, including those made before the first
monitor run, and keeps each decision in its checkpoint. The first run is dispatched by hand with `bootstrap: true`,
and a dispatch with `self_test: true` proves the alert path. Acknowledge a benign entry (for
example a signature made by hand) in `rekor-acknowledged-entries.json` in a reviewed PR, with
its UUID, log index, the run or event that made it, and why it is benign.

The release checksum (`SHA256SUMS.sigstore.json`) is still logged through the public-good
signing config, not the self-hosted log, so it is outside this monitor; the OpenBao audit watch
covers every release-key signing call regardless of log.

### Operating the self-hosted log

- **Release key precondition (operator check, agents do not run it).**
  `bao read transit/keys/cosign-release` must show `exportable=false` and
  `allow_plaintext_backup=false`. Either one set lets the key bytes leave
  OpenBao, after which no log, monitor or audit record sees a signature. Check
  it after every change to the key.
- **Availability.** Release signing fails closed when the self-hosted Rekor or
  its OpenBao Transit token is unavailable. The Rekor OpenBao token has a
  32-day maximum TTL; remint it, or move Rekor to Kubernetes auth, before it
  expires.
- **Trillian database.** Losing the log's Trillian MySQL database does not break
  verification of receipts already issued, which is offline. It ends the audit
  trail, and a new tree is a new log ID and a reviewed key change. Back the
  database up and test restores.
- **Shared OpenBao.** The Rekor signing key (`transit/keys/rekor`) and
  `cosign-release` live in the same OpenBao, so someone who can use both could
  forge a receipt for an entry that was never logged. The OpenBao audit log is
  the second line: an audit device, enabled by the operator, records every
  `transit/sign/cosign-release` request, and a watch reports requests no signing
  ledger accounts for. OpenBao refuses requests when no enabled audit device
  can write, so the audit sink needs capacity monitoring.

## Issuer design note

Fulcio does not accept arbitrary OIDC claim shapes blindly. The issuer you trust
for keyless signing needs to emit claims that Fulcio can map into a certificate
SAN and that you can later constrain with Cosign verification policy.

Before locking the issuer choice, inspect the workflow token claims with:

```bash
./scripts/inspect-actions-oidc.sh | jq .
```

If the raw GitHub Actions token does not map cleanly to the Fulcio issuer mode
you choose, use Authentik or another federation layer to mint a Fulcio-friendly
subject instead of hardcoding policy around an incompatible token shape.

## CI/CD configuration

GitHub Actions workflows and local helpers support these variables for
self-hosted keyless signing:

- `SIGSTORE_FULCIO_URL`
- `SIGSTORE_REKOR_URL`
- `SIGSTORE_OIDC_ISSUER`
- `SIGSTORE_OIDC_CLIENT_ID`
- `SIGSTORE_OIDC_AUDIENCE`
- `SIGSTORE_TRUSTED_ROOT` or `SIGSTORE_TRUSTED_ROOT_FILE`
- `SIGSTORE_ROOT_PEM` or `SIGSTORE_ROOT_FILE`
- `SIGSTORE_CT_LOG_PUBLIC_KEY` or `SIGSTORE_CT_LOG_PUBLIC_KEY_FILE`
- `SIGSTORE_REKOR_PUBLIC_KEY_PEM` or `SIGSTORE_REKOR_PUBLIC_KEY_FILE`
- `COSIGN_CERTIFICATE_IDENTITY` or `COSIGN_CERTIFICATE_IDENTITY_REGEXP`
- `COSIGN_CERTIFICATE_OIDC_ISSUER` or `COSIGN_CERTIFICATE_OIDC_ISSUER_REGEXP`

In GitHub Actions, `id-token: write` must be granted to the job so the runner
can mint an OIDC token for Cosign.

## OpenBao signing boundary

GitHub Actions runners only need OpenBao access for Transit operations in a
release publish: Wasm upload signatures, OCI signing, release `SHA256SUMS`
signing, and signature verification. They must not receive general OpenBao access or reusable signing
key material.

Current hardening requirements:

- Release jobs use the OpenBao Transit-backed `hashivault://cosign-release` key
  for signing. The matching public key is the one used by Kyverno admission in
  the `demo` namespace.
- CI workflows must authenticate to OpenBao immediately before each Transit
  use (Wasm upload signatures, signing, and verification), after compilation
  has finished. The release checksum signer
  (`scripts/sign-release-checksums.sh`) logs in itself, after the packages
  are built. The token TTL covers that Transit phase only. The token must
  stay in the current shell step and must not be written to `GITHUB_ENV`.
- GitHub Actions workflows must not expose `COSIGN_PRIVATE_KEY` or
  `COSIGN_PASSWORD` as job-wide environment variables. CI signing uses the
  centrally managed OpenBao key.
- The OpenBao role used by runners should be bound to a dedicated signing
  runner service account, preferably in a protected signing environment, not a
  shared runner service account that executes arbitrary jobs.
- The OpenBao policy should be sign-only for the release key. It should not
  allow key read/export/update/delete, arbitrary Transit paths, or KV access.
- The token TTL should be as short as practical for one Transit phase, and the
  role should bind service account name, namespace, and audience where OpenBao
  supports it.

A runner compromise during a signing job can still sign whatever that job can
push to the registry. Treat the signer and registry credentials as one trust
boundary: protect branch/tag publishing, keep release environments approval
gated, and prefer a dedicated signing runner over a general runner pool.

## Verifying published images

Every published image carries one classic Cosign `.sig` signature, which every
Cosign version checks by default, so no extra format flags are needed. Verify a
released or immutable tag with the public key in
[docs/cosign.pub](../cosign.pub):

```bash
cosign verify \
  --key docs/cosign.pub \
  registry.carverauto.dev/serviceradar/serviceradar-core-elx:v<version>
```

For an exact build, prefer the immutable `sha-<commit>` tag:

```bash
cosign verify \
  --key docs/cosign.pub \
  registry.carverauto.dev/serviceradar/serviceradar-core-elx:sha-<commit>
```

Successful verification proves the image was signed with the ServiceRadar
release key and that the signature published in Harbor matches the requested
image. A sigstore-bundle (OCI referrer) signature without the classic `.sig` is
not a valid ServiceRadar signature: cluster admission reads only the classic
`.sig` and rejects such an image.

Until the custom Sigstore stack is active for releases, `docs/cosign.pub`
remains the verification path. Once keyless signing is enabled, verify against
the published trusted root and an issuer/identity constraint instead:

```bash
cosign verify \
  --trusted-root docs/sigstore/trusted-root.json \
  --certificate-identity-regexp '<issuer-specific SAN regex>' \
  --certificate-oidc-issuer https://issuer.example.com \
  registry.carverauto.dev/serviceradar/serviceradar-core-elx:sha-<commit>
```
