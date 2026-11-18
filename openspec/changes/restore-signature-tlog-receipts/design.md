# Design: transparency-log receipts in classic signatures

## Context

What was established while writing this change (read-only checks, 2026-11-17):

- **Every first-party classic `.sig` lacks a receipt, including v1.5.3 and earlier.** The `.sig`
  manifests for `wasm-plugin-alienvault-otx-threat-intel` at its v1.5.3 and v1.5.6 digests each
  hold one layer with only `dev.cosignproject.cosign/signature`. In v1.5.3 the receipt existed only
  in the Sigstore bundle referrers (`application/vnd.dev.sigstore.bundle.v0.3+json`) next to the
  artifact. The v1.5.6 digest has no bundle referrer. The set of receipt-less signatures is
  therefore every first-party digest published before the cutover, not only v1.5.4 to v1.5.6.
- **Wasm OCI digests change on every release** (0 of 16 unchanged from v1.5.5 to v1.5.6, even where
  `bundle_digest` is unchanged). A new release therefore signs new digests and does not reuse old
  receipt-less `.sig` tags.
- **Signatures are logged in public-good Rekor v1 today.** The v1.5.6 `SHA256SUMS.sigstore.json`
  shows a `hashedrekord` entry with log ID
  `c0d23d6ad406973f9559f3ba2d1ca01f84147d8ffc5b8445c224f98b9591801d`, an `inclusionPromise`
  (SET), an inclusion proof and an RFC 3161 timestamp.
- **The signers use cosign v3.0.3** (`scripts/install-cosign.sh`), and the web-ng image ships the
  same version (`MODULE.bazel` `cosign_linux_*`).
- **Demo admission runs Kyverno v1.17.1** (chart 3.7.1 in `carverauto/gitops`
  `k8s/kyverno/argocd-application.yaml`), and Kyverno v1.17.1 builds against cosign v3.0.4.
  `verify-serviceradar-images` has a `keys` attestor with no `rekor` block.

Established on 2026-11-18, after the amendment to a self-hosted log:

- **Public-good Rekor v1 cannot be scanned in full.** It grew by 4,166 entries in 13 seconds and by
  919 in 3 seconds (about 300 a second, 1.1 million an hour). `rekor_monitor` reads entries ten at
  a time, sequentially (`GetEntriesByIndexRange`). From a workstation, a 10-entry
  `POST /api/v1/log/entries/retrieve` took 9.8 to 26.8 seconds and about 55 KB; a single-entry
  `GET /api/v1/log/entries?logIndex=` took 3.2 to 7.9 seconds and about 5.5 KB. One hour of log is
  about 110,000 requests and 6 GB, which takes far longer than an hour at any interval.
- **ServiceRadar runs its own Rekor v1** at `https://rekor.serviceradar.cloud`
  (`carverauto/gitops` `k8s/sigstore`, Argo application `sigstore`): Trillian on MySQL, tree
  `7401445772329872027`, 46 entries on 2026-11-18. Rekor signs with the OpenBao Transit key
  `rekor`, in the same OpenBao that holds `cosign-release`. The gitops README records that the
  Rekor and Fulcio OpenBao tokens expire around 2026-12-01 (32-day cluster maximum TTL) unless
  reminted or moved to Kubernetes auth.
- **The self-hosted log's key** was read with
  `curl https://rekor.serviceradar.cloud/api/v1/log/publicKey` (also with `?treeID=7401445772329872027`,
  byte-identical) on 2026-11-18 17:04 UTC. It is an ECDSA P-256 key with log ID
  `a8839837a73a6b28ca5102be67a874e8f0aa324a694320fa08fd55f9167b12c9`. The live signed tree head
  (`GET /api/v1/log`, size 46) verifies under it with `openssl dgst -sha256 -verify`, and its
  signature's key hint is `a8839837`, the first four bytes of that log ID.
- **Demo already admits a `.sig` with the annotation.** `serviceradar-rtsp-replayer` runs in `demo`
  under `verify-serviceradar-images` (Enforce) with a `.sig` whose one layer carries a
  public-good receipt, and `serviceradar-cnpg` (whose digest is unchanged from v1.5.3 to v1.5.6)
  carries public-good receipts on two of its three layers. Both come from earlier manual
  `cosign sign` runs. Release verification therefore meets reused signatures with public-good
  receipts.

## Decision 1: Produce the receipt with cosign's legacy upload path, pinned to the self-hosted Rekor v1

**Amended 2026-11-18.** The pinned Rekor v1 URL is `https://rekor.serviceradar.cloud`, not
public-good Rekor. The mechanism below is unchanged. When that log is unreachable, rejects the
upload, or answers without a SET or with another log ID, signing fails and the release stops;
there is no fallback to another log. Re-read against cosign v3.1.4: `SignBlobCmd` always signs
through sigstore-go `cbundle.SignData`; with `--use-signing-config=false`,
`NewSigningConfigFromKeyOpts` builds a signing config holding `--rekor-url` as a Rekor v1 service,
and the legacy `--bundle` file is built from the protobuf entry by
`RekorBundleFromProtoTlogEntry` (SET from `inclusionPromise`, `logID` as hex). The outcome this
decision relies on holds.

`cosign_sign_blob_to_files` today runs `cosign sign-blob --tlog-upload=true --key ... --bundle`
with cosign v3.0.3 defaults. Under `--use-signing-config=true` (the default), cosign takes the log
URL from the TUF-delivered signing config. It signs through sigstore-go `cbundle.SignData` and
writes a protobuf bundle whatever `--new-bundle-format` says: the `ko.SigningConfig != nil` branch
of `SignBlobCmd` returns before the format flag is consulted. So `--new-bundle-format=false` alone
does **not** produce a legacy bundle in v3.0.3.

sigstore-go picks the highest Rekor API major version that the signing config offers and the
client supports (`root.SelectServices(..., sign.RekorAPIVersions, ...)`). If the public-good
signing config lists a Rekor v2 log, the signer starts writing Rekor v2 entries. A v2 entry has an
inclusion proof and a checkpoint but no SET, and the legacy annotation can only carry a SET.

The signer therefore runs:

```
cosign sign-blob --yes --use-signing-config=false --new-bundle-format=false \
  --rekor-url <pinned Rekor v1 URL> --tlog-upload=true --key <release key> \
  --bundle <legacy bundle> --output-signature <sig> <payload>
```

This takes the legacy branch: `UploadToTlog` to the named v1 log, then
`cbundle.EntryToBundle` into `LocalSignedPayload.rekorBundle`. GHSA-whqx-f9j3-ch6m uses the same
flags in its reproduction, which confirms the legacy bundle comes out of this path. The helper then
requires `rekorBundle.SignedEntryTimestamp` to be non-empty and `rekorBundle.Payload.logID` to
equal the pinned log ID; otherwise signing fails. The `--tlog-upload` flag is deprecated but still
honoured in v3.0.3. Pinning the cosign version (Decision 6) and the contract test in tasks.md cover
the risk that a later version drops it.

Alternative considered: keep the default signing-config path and convert the protobuf bundle's
`tlogEntries[0]` (`inclusionPromise.signedEntryTimestamp`, `logIndex`, `integratedTime`,
`logId.keyId` re-encoded as hex, `canonicalizedBody`) into a `RekorBundle`. Every field maps, but
the log stays whatever TUF names, so a move to Rekor v2 would break signing without warning.
Rejected.

## Decision 2: The annotation is `rekorBundle`, verbatim

cosign's `pkg/oci/static` writes `dev.sigstore.cosign/bundle` as `json.Marshal(bundle.RekorBundle)`,
and `RekorBundle` is `{SignedEntryTimestamp []byte, Payload {body, integratedTime, logIndex,
logID}}`. The legacy `sign-blob --bundle` output is
`LocalSignedPayload{base64Signature, cert, rekorBundle}`, and `rekorBundle` is the same struct. The
shared helper writes `jq -c .rekorBundle` of that file as the annotation value on the one
`simplesigning` layer, next to `dev.cosignproject.cosign/signature`. Nothing else in the `.sig`
manifest changes. The manifest still has one layer, the same media types and the same tag
(`sha256-<digest>.sig`).

The three copies of `attach_legacy_signature` in `sign-oci-publish.sh`,
`sign-native-addon-publish.sh` and `sign-wasm-plugin-publish.sh` differ only in cleanup. They
become one function in `cosign_common.sh`, so the annotation is written once.

Harbor promotion (`k8s/harbor/promote-artifacts.py` in `carverauto/gitops`) and
`scripts/reconcile-legacy-signature.py` read only the `dev.cosignproject.cosign/signature`
annotation and copy the `.sig` by digest, so an extra annotation passes through unchanged. The
reconcile path must keep its "verified existing signature is reused" rule: a re-run must not
re-sign, and it cannot replace an immutable tag.

## Decision 3: Kyverno verifies the self-hosted receipt offline with the pinned key

**Amended 2026-11-18. Requires a `carverauto/gitops` policy change that is live on demo before
the cutover release is cut.**

From the Kyverno v1.17.1 source (`pkg/engine/internal/imageverifier.go`): a `keys` attestor with no
`rekor` block sets `RekorURL=https://rekor.sigstore.dev` and `IgnoreTlog=false`, and
`pkg/cosign/cosign.go` loads the Rekor public keys from cosign's TUF client (`getRekorPubs` with an
empty key calls `cosign.GetRekorPubs`). With a `rekor` block, `url`, `pubkey` and `ignoreTlog` are
taken from it, and a non-empty `pubkey` replaces the TUF keys. There is no offline flag.

In cosign `verifySignature`, with `IgnoreTlog=false`, `VerifyBundle` runs first:

- annotation present and its log ID among the Rekor keys: the receipt is checked offline (signature,
  key, payload hash, SET). No network call.
- annotation present but its log ID unknown: `VerifyBundle` returns an error, there is no online
  fallback, and the image is denied.
- no annotation: cosign falls back to an online lookup at `RekorURL`.

The current policy (`k8s/kyverno/base/verify-serviceradar-images.yaml`: one `keys` attestor, no
`rekor` block) is therefore pointed at the online public-good log and trusts only the TUF
public-good keys. A cutover-release image, whose receipt names the self-hosted log, would be
**denied**. Pre-cutover images keep being admitted by the online public-good lookup or, for
`serviceradar-rtsp-replayer`, by its public-good annotation.

The policy changes as follows (`count: 1`, two `keys` entries with the same release key):

1. **Receipt entry:** a `keys` attestor with the release key, `rekor.pubkey` set to the pinned
   self-hosted key (`docs/sigstore/rekor.pub`), `ignoreTlog: false`, and no `rekor.url`. An image
   whose signature carries a self-hosted receipt is verified offline against the pinned key.
2. **Pre-cutover entry (transition only):** today's configuration, the public-good default. It
   admits an image whose signature predates the cutover through the existing online public-good
   lookup or its public-good annotation, exactly as now, until it is removed.

The Kyverno v1.17.1 limit, stated plainly: the Rekor `url` field defaults to
`https://rekor.sigstore.dev` when unset (CRD default), and Kyverno has no offline switch. An image
**without** a receipt therefore makes the receipt entry do an online public-good lookup. That
lookup can never pass the receipt entry, because the entry verifies only against the pinned
self-hosted key. So no admission call ever reaches the self-hosted Rekor, and an image with a
self-hosted receipt is verified offline. An image with neither a self-hosted receipt nor a
public-good record is denied by both entries, which is today's bar.

**Removal of the transition entry.** Entry 2 is removed once every image admitted in demo carries
a self-hosted receipt. This is checked against the running images, not assumed: an image whose
digest does not change (for example `serviceradar-cnpg`, unchanged since v1.5.3) keeps its
pre-cutover signature until it is rebuilt. After removal no admitted image causes any Rekor
lookup; only an image without a receipt, which is denied, still triggers the public-good lookup
described above.

**Ordering.** The policy change SHALL be live on demo before the cutover release (Decision 9) is
cut, because the current policy denies a self-hosted receipt and the two-entry policy denies
nothing the current one admits. A `carverauto/gitops` PR implementing it is drafted with this
work; a person merges and applies it. The release gate (Decision 4) checks the same receipt
offline before promotion.

Rejected: `ignoreTlog: true`. It would admit an image signed with the release key but logged
nowhere.

## Decision 4: Verify receipts offline with a pinned Rekor key, never with TUF

**Amended 2026-11-18.** Key selection by log ID now has two sources (Decision 5). Import, and a
signature created in the current run, accept only `docs/sigstore/rekor-keys/` (the self-hosted
log); a created signature whose receipt names any other log fails. A **reused** signature whose
receipt names the public-good log is verified in receipt-required mode against
`docs/sigstore/pre-cutover-rekor-keys/`; that set is never shipped and never accepted at import. A
reused signature whose receipt names a log in neither set fails. A verifier never calls a Rekor:
both modes run offline, and a test proves that no request reaches a Rekor URL during verification.

There are exactly two command shapes.

**(a) Receipt-required mode.** Used by `CosignVerifier` for every first-party Wasm plugin or
native add-on digest that is not on the frozen allowlist (Decision 9), and by release verification
for every signature created in the current run and every reused signature that carries a receipt:

```
SIGSTORE_REKOR_PUBLIC_KEY=<pinned Rekor key file> \
cosign verify --new-bundle-format=false --offline=true --key <release key> \
  --timeout 60s <repo>@<digest>
```

with no `--trusted-root` and no `--insecure-ignore-tlog` flag. This mode is not conditional on a
receipt being present: a missing receipt fails closed. Both `CosignVerifier` and release
verification read `logID` from the annotation, select the matching key file (Decision 5) and pass
it as `SIGSTORE_REKOR_PUBLIC_KEY`, so a receipt under an older accepted log still verifies,
including a post-cutover signature reused after a Rekor rotation. The key is selected from:

- at import: only the image copy of `docs/sigstore/rekor-keys/`;
- in release verification, for a signature created in the run: only `docs/sigstore/rekor-keys/`;
- in release verification, for a reused signature: `docs/sigstore/rekor-keys/`, or
  `docs/sigstore/pre-cutover-rekor-keys/` when the receipt names the public-good log.

A missing annotation, or a log ID with no file in the sets allowed for that case, fails before
cosign runs.

**(b) Key-only mode.** Used by `CosignVerifier` only for digests on the frozen pre-cutover
allowlist, which then records `absent_allowlisted`, and by release verification only for a
reused signature that carries no receipt, which can only be pre-cutover. A digest whose signature
carries a receipt is always verified in receipt-required mode and recorded as `verified`, never in
key-only mode and never as `absent_allowlisted`. It is #6778's command unchanged: `--insecure-ignore-tlog=true`, no Rekor
key, no `SIGSTORE_REKOR_PUBLIC_KEY`.

Both run with no `--trusted-root` and an isolated `HOME`, `XDG_*` and `SIGSTORE_CACHE_DIR`, as #6778 already
sets up. Why this path:

- With `SIGSTORE_REKOR_PUBLIC_KEY` set, `SetTrustedMaterial` skips TUF and `GetRekorPubs` reads only
  the file. A key-based verify does not load CT log keys. No Sigstore endpoint is contacted.
- `--offline=true` makes a missing annotation fail at once ("offline verification failed") instead
  of falling back to an online lookup. The flag is deprecated, so the verifier is also covered by a
  test that fails if a later cosign starts looking up online or accepts a missing receipt.
- The legacy (`RekorPubKeys`) branch of `VerifyBundle` binds the receipt to the artifact: it
  compares the logged signature and public key and checks that the logged hash equals the payload
  hash. In cosign up to v3.0.3, the trusted-root branch checked only the SET
  (GHSA-whqx-f9j3-ch6m), so a SET for any unrelated entry would pass. The advisory's own
  workaround is this env-key path. The cosign upgrade (Decision 6) closes the gap in both branches.

Release verification never classifies a signature by whether a receipt is present. The signer
records in the signing ledger, per digest, whether it created a new signature or reused an existing
one (Decision 2). The release verification scripts (`verify-oci-publish.sh`,
`verify-wasm-plugin-publish.sh`, `verify-native-addon-publish.sh`) read that record:

- a digest in the created set is verified in receipt-required mode, so a current-run signature
  published without its receipt fails;
- a digest in the reused set is verified in receipt-required mode if its signature carries a
  receipt, and in key-only mode if it does not. A reused signature without a receipt can only
  predate the cutover release (Decision 2), whether for an image, a native add-on or a Wasm plugin,
  and is exempt from the receipt check, as today;
- a digest in neither set fails closed. Kyverno remains the admission gate for images. The import allowlist (Decision 9) covers only
Wasm plugin and native add-on digests and is not consulted by release verification.

## Decision 5: The pinned Rekor key and how it is updated

**Amended 2026-11-18** for the self-hosted log.

- **Source of truth:** `docs/sigstore/rekor-keys/` holds the full accepted key set, one PEM file
  per accepted Rekor v1 log ID, named `<logID>.pub`. It holds the self-hosted log's key
  (`a8839837...12c9`). `docs/sigstore/rekor.pub` is the key of the log the signer writes to,
  byte-identical to that log's file in the set.
- **Pre-cutover receipts:** the public-good key (`c0d23d6a...801d`) is not accepted for new
  receipts or at import. Accepting it would let someone with the release key log a signature in the
  public log, which the monitor does not watch, and import it. It is kept in
  `docs/sigstore/pre-cutover-rekor-keys/` and used only by release verification for a **reused**
  signature whose receipt names it (the manual-signing receipts in Context). It is not shipped in
  the web-ng image.
- **Image copy:** the web-ng image carries the whole `docs/sigstore/rekor-keys/` set at a fixed
  path. There is no runtime override: no operator-supplied mounted file, setting or environment
  variable replaces the pinned keys. A `build/contracts` test keeps the image copy of every key in
  the set byte-identical to the committed set, and `docs/sigstore/rekor.pub` byte-identical to one
  member of it.
- **Initial value:** the key is read from the self-hosted log's `GET /api/v1/log/publicKey`
  endpoint and accepted only when the log's current signed tree head verifies under it and names
  it by key hint. The commit records the URL, the time, the tree ID and the tree size it was
  checked against (Context).
- **Update process:** the monitor workflow (Decision 7) compares the key the log serves with the
  pinned one on every run and alerts on a difference. A key change follows a reviewed PR that adds
  the new key to `docs/sigstore/rekor-keys/`, keeps every key an accepted receipt names, and points
  `docs/sigstore/rekor.pub` at the new key. The change ships in the next release.
- **Air-gapped installs** get a new key only by upgrading. A receipt verifies against the key that
  was pinned when it was issued, so a rotation affects only newly signed releases, which reach an
  install together with the web-ng release that carries the new key.

## Decision 6: Upgrade cosign in signer and image together

v3.0.3 is affected by GHSA-whqx-f9j3-ch6m (fixed in 3.0.4; see Decision 4), GHSA-wfqv-66vq-46rm
(3.0.5), GHSA-w6c6-c85g-mmv6 (3.0.6) and GHSA-fx35-mq7g-6g98 (3.1.3; for `verify-blob` on legacy
bundles, a `cert` field holding a bare public key replaces the `--key` the caller passed). Our
`.sig` path uses `cosign verify`, which GHSA-fx35 does not affect. The release checksum uses a
protobuf bundle. Still, no script may verify a legacy bundle with `verify-blob` on an affected
version.

`scripts/install-cosign.sh` and the `cosign_linux_amd64`/`cosign_linux_arm64` archives in
`MODULE.bazel` move to the same release, at least v3.1.3. v3.1.4 (2026-10-20) is the latest
published release. Checksums are pinned as they are today. Decisions 1 and 4 are re-checked against
the chosen version's source before merge, because the flag behaviour above was read from v3.0.3
and v3.0.4.

## Decision 7: The monitor

**Amended 2026-11-18.** The monitor scans the self-hosted log, not public-good Rekor. That log holds
only ServiceRadar's entries (46 on 2026-11-18), so every run reads the whole log. The scan
interval is one hour. Open Question 1 is resolved by this change of log: the measurement in
Context shows the public log cannot be scanned in full. Where the text below says "Rekor v1" or
"the log", it means the self-hosted log.

**What runs.** `.github/workflows/rekor-signing-monitor.yml`, scheduled hourly on
`arc-runner-set`, with `permissions: contents: read, actions: read, issues: write`. It runs a
project-owned scanner, `build/ci/rekor_signing_monitor.py`. `rekor_monitor` from
`sigstore/rekor-monitor` is not used: it verifies checkpoints only through a TUF trusted root,
which does not list the self-hosted log. Each run:

- reads every entry of the self-hosted log, recomputes the RFC 6962 Merkle root, and checks it
  against the log's signed tree head, which must verify under `docs/sigstore/rekor.pub`; a tree
  head that does not verify, or a recomputed root that does not match it, fails the run and
  alerts;
- requires the previous checkpoint to be a prefix of the log (same leaves up to its size, same
  root); only a `bootstrap=true` dispatch while no checkpoint exists skips this check. Every run
  other than a bootstrap dispatch, scheduled or manual, that finds no checkpoint artifact, a
  checkpoint that is not a prefix, a tree head that does not verify or a root that does not match
  fails, alerts and does not replace the checkpoint; a bootstrap dispatch while a checkpoint exists
  still applies the prefix check and, when the stored checkpoint is not a prefix, fails, alerts and
  keeps the stored artifact. Every failed run, bootstrap included, writes no checkpoint. The checkpoint artifact is retained 90 days,
  as long as the signing ledgers, and every successful run replaces it, carrying forward the
  per-entry decisions and the first checkpoint's integrated time; it expires only if the monitor
  stops for 90 days;
- checks that `GET /api/v1/log/publicKey` still serves `docs/sigstore/rekor.pub` (Decision 5);
- selects every release-key entry (public key `docs/cosign.pub`) in the whole log, including
  entries integrated before the first checkpoint, and judges each as below.

**Bootstrap.** The first checkpoint is seeded only by an explicit manual `workflow_dispatch` with
input `bootstrap=true`, started and reviewed by a person, never automatically. The bootstrap run
verifies the signed tree head under the pinned key, judges the whole log as every run does, and
writes the checkpoint only if it succeeds; a failed bootstrap writes nothing. Scheduled runs never bootstrap.

The rejected alternative is Rekor's `POST /api/v1/index/retrieve` search by public key. It is cheap,
but Rekor's OpenAPI marks it deprecated, experimental and "may be incomplete". A monitor that can
silently miss entries does not meet the AGENTS.md rule that a verification must be able to fail.

**What counts as expected.** Every signing run writes a signing ledger: one JSON line per
created signature, written **before** `cosign sign-blob` is called; this is the `sign` line. It holds the payload SHA-256, the
subject `repo@digest` (or the file name for `SHA256SUMS`), the workflow, the run ID and attempt, and
the time. After signing, a second line adds the returned `logIndex` and entry UUID. A digest whose
existing signature is reused gets one reused line instead, which is not a `sign` line, so the ledger records for
every digest whether its signature was created or reused in the run. The ledger is
uploaded with `if: always()` as a workflow artifact named per run attempt, retained 90 days, and
for tag runs it is also attached to the GitHub release.

The release-key signing workflows are every workflow that signs with `hashivault://cosign-release`:
`release.yml`, `publish-oci.yml`, `wasm-plugins.yml`, `native-addons.yml` and
`external-wasm-plugin.yml` (through `sign-wasm-plugin-publish.sh`). Each of them writes and uploads
the ledger.

A Rekor entry is pending while a run of any release-key signing workflow that was active at the
entry's `integratedTime` (started before it, and still running or ended after it) is in progress.
It is explained when it is a `hashedrekord` whose `data.hash` equals the payload SHA-256 of a
`sign` line in a published ledger of one of those runs, when the acknowledged-entries file lists it, or when the
monitor's checkpoint state already records it as explained by a ledger match an earlier run
found. An acknowledgement explains an entry only while the file lists it, so a retracted
acknowledgement restores detection. Because the
ledger is
uploaded only when the job ends, the monitor does not decide on an entry while a release-key
signing run that was active at its `integratedTime` is still in progress: the entry stays pending,
and no alert is raised. Once every such run has ended, the entry is explained by any of those
three, and unexplained otherwise. The monitor keeps each entry's state
in its checkpoint state: pending, explained with its reason (the ledger run or the
acknowledgement), or reported. Later scans re-evaluate pending and reported entries and every
entry explained by acknowledgement, so a stored acknowledgement decision never suppresses an alert
once the file no longer lists the entry; an entry
explained by a ledger stays explained after that run and its 90-day ledger artifact age out of the
lookback.

**False positives.**

- *Retries inside one run* (`cosign_sign_blob_to_files` retries on transient Rekor errors, and an
  upload whose response was lost leaves an entry): the payload is the same, so the payload hash is
  the same and every resulting entry is explained. Matching is on the payload hash, not the entry
  UUID, for this reason.
- *Workflow re-runs:* each attempt writes its own ledger. A re-run that reuses an existing `.sig`
  (Decision 2) signs nothing and logs nothing.
- *A run that died after uploading but before saving its ledger:* the ledger line was written
  before the upload. Only a runner that was destroyed outright loses the ledger. That entry
  alerts. A person checks it against the run's logs and adds it to
  `docs/sigstore/rekor-acknowledged-entries.json` (entry UUID, log index, run URL, reason) in a
  reviewed PR, and from then on the monitor treats it as explained.
- *Manual signing with the release key* (the `docs/agent-runbooks.md` demo path) produces entries
  outside any workflow. That runbook path is replaced by the in-cluster `publish-oci.yml` dispatch,
  or each manual signature must be acknowledged as above.

**Alerts.** Each unexplained entry opens one GitHub issue labelled `security` and
`signing-monitor`, deduplicated by entry UUID. The issue holds the log index, UUID, integrated
time, payload hash and a link to the entry. Every scan re-checks the open `signing-monitor`
issues, and when a later scan finds an entry explained (its ledger became visible, or it was
acknowledged) the monitor closes that entry's issue with a comment naming the explaining run or
acknowledgement. The workflow also posts to Discord through the
existing `CI_FAILURE_DISCORD_WEBHOOK_URL` secret, as `build/ci/scheduled_job_watch.py` does.

**The monitor must be able to fail.**

- A run that fails (a tree head that does not verify under the pinned key or a recomputed root
  that does not match it, Rekor unreachable, checkpoint not a prefix of the log, checkpoint
  artifact missing on any run other than a bootstrap dispatch, bad config) fails the workflow,
  opens an issue, posts to Discord and writes no checkpoint; this includes a bootstrap dispatch.
- The daily scheduled job watch (`.github/workflows/scheduled-job-watch.yml`, ARC, Discord) also
  reports the monitor when its last successful run is older than three scan intervals (three hours
  at the hourly default). `build/ci/scheduled_job_watch.py` only reads BuildBuddy commit statuses
  for `WATCHED_JOBS`, and the monitor posts none, so the monitor is not added to `WATCHED_JOBS`. A
  separate lookup lists the GitHub Actions runs of `rekor-signing-monitor.yml` through the Actions
  API and finds the last successful one; `scheduled-job-watch.yml` gains `actions: read` for it. A
  monitor that stopped running is then noticed even if no run is left to report on itself.
- *Blindness canary:* every ledger line with a `logIndex` from a signing run that ended more than
  two scan intervals ago (two hours at the hourly default), whose entry was integrated after the first checkpoint's integrated time recorded once in
  monitor state, must
  have been seen by the monitor as a matching entry. The canary does not check ledger lines whose
  entry was integrated before that checkpoint; this lower bound applies only to the canary, and
  those entries are still read and judged on every run like any other. A ledger entry the monitor
  never saw means the monitor is blind (wrong release key, broken scan) or the receipt is bogus.
  Either way it alerts. Each release thereby proves the monitor works.

**Historical entries.** Every run, the bootstrap run included, reads and judges every release-key
entry in the whole log, including entries integrated before the first checkpoint. Each needs a
`sign` line in a ledger of a release-key signing run active at its `integratedTime`, a current entry in `docs/sigstore/rekor-acknowledged-entries.json`, or a ledger-match
decision already recorded in the monitor's checkpoint state, and alerts otherwise once no release-key
signing run active at its `integratedTime` is still in progress (the pending rule above).
Release-key entries made before the ledger existed (the manual signings in Context) have no ledger,
so they are listed in the acknowledged-entries file in the PR that enables the monitor, and that
pre-ledger history is recorded in `docs/sigstore/README.md`. The monitor keeps the integrated time
of its first checkpoint in its state; only the blindness canary uses it, as its lower bound.

## Decision 8: Record the receipt status on the imported package

Each imported package stores `transparency_receipt`: `verified` (with `log_index` and
`integrated_time`), or `absent_allowlisted`, in its import verification metadata. There are two
write paths:

- Wasm plugins: web-ng `first_party_importer.ex`, which already stores `cosign_verified`.
- Native add-ons: web-ng `native_addon_importer.ex` makes the cosign call and passes the receipt
  fields into `Core.import_entry_with_disposition`, and core
  `serviceradar/plugins/native_addon_importer.ex` writes them in `source_metadata/2`.

No UI change is part of this change.

## Decision 9: Pre-cutover Wasm plugins and native add-ons use a frozen digest allowlist

Decided by the product owner. The cutover release is v1.5.8 or later: the first release built from
a commit containing the signer change, so the first whose signer attaches receipts (migration
step 3). v1.5.7 was cut without the signer. Every first-party `.sig` published before the cutover
release lacks the annotation (see Context). Harbor tag immutability prevents adding one, since the
classic tag is addressed by digest.

The list of every first-party OCI digest in every `serviceradar-wasm-plugin-index.json` and
`serviceradar-native-addon-index.json` published up to and including v1.5.7 is generated (v1.5.6
lists 16 Wasm plugins; GitHub shows 50 releases, so on the order of a thousand digests at most) and
committed. Once the allowlist is frozen, no release may be cut from a commit without the signer
change: such a release would publish receipt-less digests the allowlist does not cover. It is frozen from those indexes only, shipped unchanged with the later verifier release
(migration step 4), and never regenerated once receipt-bearing releases exist, so no receipt-bearing
digest is on it. At import, those digests verify key-only and are
recorded as `absent_allowlisted`. A digest whose signature carries a valid receipt is verified in
receipt-required mode and recorded as `verified`, never key-only and never `absent_allowlisted`.
Every other first-party Wasm plugin or native add-on digest
requires a receipt from the cutover release on. A contract test fails if the list changes after the
cutover. It is safe because an attacker cannot produce new content under an allowlisted digest. It
costs one generated file, and it never grows. The list holds no image digests: images are admitted
by Kyverno, and release verification exempts reused pre-cutover signatures (Decision 4). Web-ng
releases before the cutover keep #6778 key-only behaviour and ignore the annotation.

Alternatives considered:

- **A. Version floor.** Require a receipt for index entries whose `release_tag` is at or after the
  cutover; accept key-only below it. Rejected: the floor trusts the `release_tag` field of an index
  fetched from GitHub, so an attacker who can write release assets and sign could publish under an
  old tag.
- **C. Re-publish.** Re-push affected artifacts under new digests with receipts. Rejected:
  same-digest re-signing is impossible, new digests under old version numbers confuse installs
  pinned to the old digests, and only recent releases are realistic candidates.
- **D. Key-only forever, receipt advisory.** Verify the receipt when present and record the result,
  but never require it. Rejected: against a key thief it adds no security, because a receipt that
  is never required is simply left off.

Third-party repositories are not affected: they use ed25519 upload signatures, not Cosign.

## Decision 10: Second line: the OpenBao audit log

The self-hosted Rekor signs SETs with the OpenBao Transit key `rekor`, in the same OpenBao as
`cosign-release`. Whoever can call both Transit keys can sign an artifact and forge a valid
receipt for an entry that was never logged; the monitor, which reads the log, cannot see it. The
second line does not depend on the log.

- **Audit device.** OpenBao gets a file (or socket) audit device that records every request,
  including `transit/sign/cosign-release`. The operator enables it; agents never do. **When every
  enabled audit device fails to write, OpenBao refuses the request**, so an unwritable audit sink
  stops release signing, Rekor and every other OpenBao client. The device's sink needs the same
  capacity monitoring and alerting as a database volume.
- **Watch.** A scheduled job reads the audit log and reports every `transit/sign/cosign-release`
  request that is not explained. A request is explained only by a `sign` line holding its input
  hash (Transit signs the payload digest) in a ledger of a release-key signing run active at the
  request's time; an older run's ledger does not explain a later call on the same hash. It reuses the monitor's pending rule: a request is pending while a release-key signing
  run active at its time is still in progress; once those runs have ended it is decided (explained
  only if a `sign` line, not a reused line, in a ledger of one of them holds its input hash,
  otherwise alerted). The watch keeps a position
  in its own state that advances only past decided records, and never re-examines a decided record,
  so a sign call decided while its ledger was retained is not re-examined after the ledger ages
  out. Alerts go where the monitor's alerts go.
- **Scope.** This change specifies the device and the watch; the watch is implemented once the
  device exists. Until then the audit log is not available and the forged-receipt case is
  undetected.

## Decision 11: Operator precondition on the release key

`bao read transit/keys/cosign-release` must show `exportable=false` and
`allow_plaintext_backup=false`. Either one set would let the key bytes leave OpenBao, after which
nothing in this change (log, monitor or audit log) sees a signature. This is an operator check,
recorded in `docs/sigstore/README.md` and repeated on every key change; agents do not run it.

## Threat model

**Assets.** The integrity of the Wasm plugins and native add-ons an installation imports and runs.
Images are covered too, for the monitor, but Kyverno remains their admission gate.

**What the receipt plus monitor adds.** From the cutover release on, receipts are required for every
first-party Wasm plugin and native add-on digest not on the frozen allowlist (Decision 9), so an
accepted artifact must have an append-only record in the self-hosted Rekor v1 log, made by the
holder of the release key. Without a receipt requirement, someone who can sign with the key can
produce an importable package that leaves no trace. With it they must log the signature, and
the monitor reports any logged signature not explained by a `sign` line in a ledger of a release-key signing run active at its
`integratedTime`, a current acknowledgement or a stored ledger-match decision, within about
one scan interval after the entry becomes decidable, that is, after every release-key signing run
that was active at its `integratedTime` has ended (Decision 7, pending rule). For an entry outside
any signing run that is about one scan interval (an hour at the hourly default). For an entry that
overlaps a long release run the worst case is the remaining run time plus one scan interval, a few
hours for `release.yml`. The log is also a record of everything the key signed, which bounds the
investigation after an incident. It is ServiceRadar's own log, not a public one.

**What it does not add.**

- *Prevention.* The verifier accepts a malicious artifact that carries a valid receipt. The monitor
  only shortens the time to detection. The response (revoking the key, pulling the release,
  telling installations) is outside this change.
- *A compromised run of our own signing workflow.* That run writes its own ledger, so its entries
  are explained. The monitor detects key use outside the signing workflows, not a poisoned build
  inside them.
- *Before enforcement.* While a missing receipt is accepted, an attacker omits it. Verifying a
  receipt only when one is present adds visibility, not security.
- *A forged receipt.* Someone who can use both the `rekor` and `cosign-release` Transit keys in the
  shared OpenBao can sign an artifact and a SET for an entry that was never logged. The log and
  the monitor cannot see that. The OpenBao audit log (Decision 10) is the second line for it.
- *Log-operator misbehaviour.* A SET is a signed promise of inclusion, not a proof. The monitor's
  consistency check catches a log that rewrites history. A log that signs a SET and never includes
  the entry is outside this threat model.
- *Downgrade.* Re-importing an older, validly signed artifact is not addressed here.

**Concrete failure mode and likelihood.** The release key is an OpenBao Transit key, non-exportable,
behind a sign-only policy. Only jobs on the `serviceradar-signing` runner in the `release`
environment reach it. Theft of the key bytes is very unlikely. The realistic case is abuse of the
signing oracle: an OpenBao token or the runner's service-account credentials leak, or another job
gains the signing role, and is used to sign a malicious Wasm or add-on digest. To reach
installations, the attacker must also get the digest into a release index on GitHub. The
likelihood is low, and the impact is code execution on every agent that runs the plugin.

**Complexity cost.** One shared signer helper replaces three copies. The verifier gains a receipt
mode, a pinned key and an allowlist. The pinned cosign version moves in two places. Two
consistency tests, a ledger in five workflows, one new scheduled workflow and a check in the
existing job watcher are added. Operationally, a release now cannot sign while the self-hosted
Rekor or its OpenBao token is unavailable (Risks), and the monitor's alerts need an owner.

## Risks

Added 2026-11-18 for the self-hosted log:

- **Losing the Trillian database.** Verification of receipts already issued does not break: a
  receipt is verified offline against the pinned key and never looks the entry up. It does end the
  audit trail: the monitor can no longer prove what the key signed, and a new tree means a new log
  ID and a reviewed key change. The Trillian MySQL database therefore needs backups with tested
  restores, like any other system of record. Backup and restore test are operator-owned; agents do
  not run them.
- **Shared OpenBao.** The Rekor signing key and `cosign-release` live in one OpenBao. Compromise
  of OpenBao (or of a token allowed to use both keys) can produce a signature and a valid receipt
  without a log entry. That residual risk is why the OpenBao audit log (Decision 10) is the second
  line.
- **Self-hosted availability.** Release signing depends on the self-hosted Rekor and its OpenBao
  token. The token recorded in Context expires around 2026-12-01 unless reminted or moved to
  Kubernetes auth; after that, releases fail closed until it is fixed. Reminting the token or
  moving Rekor to Kubernetes auth is operator-owned; agents do not run it. Customers never depend
  on this log: verification is offline.
- **No public record.** Unlike public-good Rekor, only ServiceRadar runs this log, so it is not a
  third-party-auditable history.

The original risks follow.

- **Public-good Rekor v1 freeze.** Release signing no longer writes to public-good Rekor, so a
  freeze there does not affect it. Reused pre-cutover public-good receipts keep verifying offline
  against `docs/sigstore/pre-cutover-rekor-keys/` (Decision 4).
- **Deprecated flags.** `--tlog-upload` and `--offline` are deprecated in cosign v3. The cosign
  version is pinned, and contract tests fail if a pinned-version bump changes the behaviour.
- **Admission regression.** A malformed annotation denies an image at admission (Decision 3). The
  release verification gate runs the same check first.
- **Monitor noise.** Unexplained-entry alerts that turn out to be benign wear down attention. Keying
  the match on the payload hash and the acknowledgement file keep these rare.

## Migration plan

1. Upgrade cosign (signer and image), add `docs/sigstore/rekor-keys/` and `docs/sigstore/rekor.pub`,
   and add the consistency tests.
2. Change the demo Kyverno policy (Decision 3) so it trusts the pinned self-hosted key, keeping the
   pre-cutover entry. A `carverauto/gitops` PR is drafted with this work; a person merges and
   applies it. It must be live on demo before the cutover release is cut.
3. Ship the signer change (receipt annotation and ledger) and the receipt check in the release
   verification scripts. The first release built from a commit containing this signer is the
   cutover release, v1.5.8 or later; from then on every new signature carries a receipt. Generate
   and commit the frozen allowlist from the indexes published up to and including v1.5.7. From
   then on no release is cut from a commit without the signer.
4. Enable the monitor on the self-hosted log. Release N+1's ledger is the first end-to-end
   canary.
5. Ship the verifier change with the frozen pre-cutover allowlist from step 3, unchanged and not
   regenerated (Decision 9).
   Until it ships, #6778's key-only verification remains in force.
6. Enable the OpenBao audit device (operator) and then the audit watch (Decision 10).
7. Remove the pre-cutover Kyverno entry (Decision 3) once every image admitted in demo carries a
   self-hosted receipt, checked against the running images (an unchanged digest such as
   `serviceradar-cnpg` keeps its pre-cutover signature until rebuilt). After that no admitted
   image causes any Rekor lookup.

Rollback: the verifier change can be reverted to #6778's key-only mode on its own. A key-only
verifier (`--insecure-ignore-tlog=true`) never reads the annotation, so already-published
annotated `.sig` signatures stay valid for it. Kyverno with the amended policy verifies the
annotation offline (Decision 3), and the release gate has already checked it. Rolling the signer
back to public-good Rekor is not a rollback: new receipts would then name a log the shipped
verifier does not accept.

## Open questions

### Open Question 1: Is an hourly full-log scan affordable on ARC?

Resolved 2026-11-18: not for public-good Rekor (Context). The product owner moved the log to the
self-hosted Rekor, which a full scan covers cheaply.

### Open Question 2: Where do signing-monitor alerts go?

Resolved: one GitHub issue per unexplained entry, plus the existing
`CI_FAILURE_DISCORD_WEBHOOK_URL`.

### Open Question 3: Which cosign version?

Resolved: v3.1.4 in the signer and the image together, v3.1.3 the floor.

