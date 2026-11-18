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

## Decision 1: Produce the receipt with cosign's legacy upload path, pinned to Rekor v1

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

## Decision 3: Kyverno keeps working without a policy change, and stops depending on online lookups

From the Kyverno v1.17.1 source (`pkg/engine/internal/imageverifier.go`): a `keys` attestor with no
`rekor` block sets `RekorURL=https://rekor.sigstore.dev` and `IgnoreTlog=false`.
`pkg/cosign/cosign.go` then builds a Rekor client and loads the Rekor public keys from cosign's TUF
client (`cosign.GetRekorPubs`). It sets no `TrustedMaterial`.

In cosign v3.0.4 `verifySignature` (`pkg/cosign/verify.go`), with `IgnoreTlog=false` it calls
`VerifyBundle` first:

- no annotation: `VerifyBundle` returns `false, nil`, and cosign falls back to an **online** Rekor
  lookup (`tlogValidateEntry`). That is what demo admission does for every image today, inside a
  30-second webhook timeout.
- annotation present: cosign compares the logged signature and public key, verifies the SET against
  the TUF Rekor key and checks the payload hash, all offline. It records "Existence of the claims in
  the transparency log was verified offline".

The annotation therefore removes a network dependency from admission. It does add a new failure
mode: a present but malformed or mismatched annotation makes `VerifyBundle` return an error, with
no online fallback, and the image is denied. The release verification gate (Decision 4) runs the
same offline check before promotion to close that.

`docs/agent-runbooks.md` already documents manual demo signing with
`cosign sign --new-bundle-format=false --use-signing-config=false --tlog-upload=true`. That command
attaches this same annotation through cosign's own code, so annotated `.sig` signatures may already
have gone through demo admission. Whether they did is **unverified**: nothing here checked an
admitted digest.

## Decision 4: Verify receipts offline with a pinned Rekor key, never with TUF

There are exactly two command shapes.

**(a) Receipt-required mode.** Used by `CosignVerifier` for every first-party Wasm plugin or
native add-on digest that is not on the frozen allowlist (Decision 9), and by release verification
for every signature created in the current run:

```
SIGSTORE_REKOR_PUBLIC_KEY=<pinned Rekor key file> \
cosign verify --new-bundle-format=false --offline=true --key <release key> \
  --timeout 60s <repo>@<digest>
```

with no `--trusted-root` and no `--insecure-ignore-tlog` flag. This mode is not conditional on a
receipt being present: a missing receipt fails closed. Release verification uses
`docs/sigstore/rekor.pub`, since signatures created in the current run are on the current log.
`CosignVerifier` reads `logID` from the annotation, selects the matching key file from the retained
key set in the image (Decision 5) and passes it as `SIGSTORE_REKOR_PUBLIC_KEY`, so a receipt under
an older accepted log still verifies; a missing annotation or a log ID with no file in the set
fails before cosign runs.

**(b) Key-only mode.** Used by `CosignVerifier` only for digests on the frozen pre-cutover
allowlist, which then records `absent_allowlisted`, and by release verification only for reused
pre-cutover signatures. It is #6778's command unchanged: `--insecure-ignore-tlog=true`, no Rekor
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

The release verification scripts (`verify-oci-publish.sh`, `verify-wasm-plugin-publish.sh`,
`verify-native-addon-publish.sh`) switch `cosign_verify_legacy_signature` to the receipt-required
form for every signature created in the current run, and only for those. A signature reused from before the
cutover release (Decision 2), whether for an image, a native add-on or a Wasm plugin, carries no
receipt and is exempt from the receipt check in release verification: it is verified with the
key-only form, as today. Kyverno remains the admission gate for images. The import allowlist (Decision 9) covers only
Wasm plugin and native add-on digests and is not consulted by release verification.

## Decision 5: The pinned Rekor key and how it is updated

- **Source of truth:** `docs/sigstore/rekor-keys/` holds the full accepted key set, one PEM file
  per accepted Rekor v1 log ID, named `<logID>.pub`. At the start it holds one key, the public-good
  Rekor v1 key whose log ID is `c0d23d6a...801d`. `docs/sigstore/rekor.pub` is the key of the log
  the signer currently writes to, byte-identical to that log's file in the set.
  `cosign_export_trust_overrides` already exports `docs/sigstore/rekor.pub` as
  `SIGSTORE_REKOR_PUBLIC_KEY` when the file exists, so the signer and the release verifiers, which
  only verify signatures created in the current run against the current log, pick it up without
  new wiring. The signer's own post-upload check then uses the same key.
- **Image copy:** the web-ng image carries the whole `docs/sigstore/rekor-keys/` set at a fixed
  path. `runtime.exs` points `first_party_plugin_import` at it. There is no runtime override: no
  operator-supplied mounted file, setting or environment variable replaces the pinned keys. The keys
  change only through a reviewed change of `docs/sigstore/rekor-keys/` (and `docs/sigstore/rekor.pub`
  with it) that ships in a web-ng image. A `build/contracts` test keeps the image copy of every key
  in the set byte-identical to the committed set, and `docs/sigstore/rekor.pub` byte-identical to
  one member of it, as `first_party_plugin_cosign_key_consistency_test` does for `docs/cosign.pub`.
- **Initial value:** the key comes from Sigstore's signed TUF `trusted_root.json` (`tlogs` entry
  whose `logId` matches), not from a Rekor `/api/v1/log/publicKey` response. The commit records the
  TUF root version it was taken from.
- **Update process:** the monitor workflow (Decision 7) also fetches the current public-good
  `trusted_root.json` through TUF once a day. It compares the Rekor v1 `tlogs` entries with the
  pinned keys. It alerts when a new Rekor v1 key appears, the pinned key's `validFor.end` is set, or
  the pinned key is removed. A person then adds the new key to `docs/sigstore/rekor-keys/` in a
  reviewed PR, keeps every key whose log ID is still accepted, and points `docs/sigstore/rekor.pub`
  at the log the signer writes to from then on. The change ships in the next release. A rotation
  never drops a key that an accepted receipt names. `SIGSTORE_REKOR_PUBLIC_KEY` holds one PEM key,
  so `CosignVerifier` reads `logID` from the annotation, selects the matching key file from the
  set, and rejects a log ID with no file in the set before it runs cosign.
- **Air-gapped installs** get a new key only by upgrading. Sigstore keeps validity windows on old
  keys, so a receipt verified against the key that was valid at `integratedTime` stays valid after
  a rotation. A rotation therefore affects only newly signed releases, which reach an install
  together with the web-ng release that carries the new key.

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

**What runs.** `.github/workflows/rekor-signing-monitor.yml`, scheduled at a configured scan
interval, on
`arc-runner-set`, with `permissions: contents: read, actions: read, issues: write`. It runs
`rekor_monitor` from `sigstore/rekor-monitor`, built from a pinned commit with a verified checksum
(the project publishes no release tags). The scan interval is hourly unless the measurement in
Open Question 1 forces a longer one. Its config has
`monitoredValues.fingerprints: [<hex SHA-256 of the DER PKIX release public key>]`. The monitor
verifies log consistency from the previous checkpoint to the current one, and lists every new entry
whose key fingerprint matches. The reusable workflow `rekor-monitor` publishes is not used directly,
because a called workflow fixes its own `runs-on` and this one must run on ARC. The reusable
workflow keeps its checkpoint as a workflow artifact, and so does this one, with retention longer
than the schedule interval.

The rejected alternative is Rekor's `POST /api/v1/index/retrieve` search by public key. It is cheap,
but Rekor's OpenAPI marks it deprecated, experimental and "may be incomplete". A monitor that can
silently miss entries does not meet the AGENTS.md rule that a verification must be able to fail.

**What counts as expected.** Every signing run writes a signing ledger: one JSON line per
signature, written **before** `cosign sign-blob` is called. The line holds the payload SHA-256, the
subject `repo@digest` (or the file name for `SHA256SUMS`), the workflow, the run ID and attempt, and
the time. After signing, a second line adds the returned `logIndex` and entry UUID. The ledger is
uploaded with `if: always()` as a workflow artifact named per run attempt, retained 90 days, and
for tag runs it is also attached to the GitHub release.

The release-key signing workflows are every workflow that signs with `hashivault://cosign-release`:
`release.yml`, `publish-oci.yml`, `wasm-plugins.yml`, `native-addons.yml` and
`external-wasm-plugin.yml` (through `sign-wasm-plugin-publish.sh`). Each of them writes and uploads
the ledger.

A Rekor entry is explained when it is a `hashedrekord` whose `data.hash` equals a payload SHA-256
in the ledger of a run of any release-key signing workflow that was active at the entry's
`integratedTime` (started before it, and still running or ended after it). Because the ledger is
uploaded only when the job ends, the monitor does not decide on an entry while a release-key
signing run that was active at its `integratedTime` is still in progress: the entry stays pending,
and no alert is raised. Once every such run has ended, the entry is explained if one of their
ledgers holds its payload hash, and unexplained otherwise. A pending entry is kept in the
monitor's state, next to the checkpoint, so later scans re-evaluate it.

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
existing `CI_FAILURE_DISCORD_WEBHOOK_URL` secret, as `build/ci/scheduled_job_watch.py` does. Open
Question 2 asks whether security alerts should have their own channel.

**The monitor must be able to fail.**

- A run that fails (log inconsistency, Rekor unreachable, checkpoint artifact missing, bad config)
  fails the workflow, opens an issue and posts to Discord.
- The daily scheduled job watch (`.github/workflows/scheduled-job-watch.yml`, ARC, Discord) also
  reports the monitor when its last successful run is older than three scan intervals (three hours
  at the hourly default). `build/ci/scheduled_job_watch.py` only reads BuildBuddy commit statuses
  for `WATCHED_JOBS`, and the monitor posts none, so the monitor is not added to `WATCHED_JOBS`. A
  separate lookup lists the GitHub Actions runs of `rekor-signing-monitor.yml` through the Actions
  API and finds the last successful one; `scheduled-job-watch.yml` gains `actions: read` for it. A
  monitor that stopped running is then noticed even if no run is left to report on itself.
- *Blindness canary:* every ledger line with a `logIndex` from a signing run that ended more than
  two scan intervals ago (two hours at the hourly default), whose entry was integrated after the monitor's first retained checkpoint, must
  have been seen by the monitor as a matching entry. Entries integrated before that checkpoint
  were never in the monitor's scan range (see Historical entries) and are not checked. A ledger entry the monitor
  never saw means the monitor is blind (wrong fingerprint, broken scan) or the receipt is bogus.
  Either way it alerts. Each release thereby proves the monitor works.

**Historical entries.** `rekor-monitor` starts from the latest checkpoint. Entries made before the
first monitor run are not scanned. That is acceptable, because the ledger begins in the same
change; the gap is recorded in `docs/sigstore/README.md`. The monitor keeps the integrated time of
its first retained checkpoint in its state, and the blindness canary uses it as its lower bound.

**Unverified:** how long an hourly scan of public-good Rekor v1 takes on an ARC runner, and how
much it downloads. The first task measures it before the schedule is enabled. If an hourly scan
does not fit, the fallback is a less frequent scan with a longer window, not the index search.
A high scan cost never removes the scheduled release-key monitor; only the scan interval may grow,
with a correspondingly longer window.

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

Decided by the product owner. Every first-party `.sig` published before the cutover release lacks
the annotation (see Context). Harbor tag immutability prevents adding one, since the classic tag is
addressed by digest.

At the cutover, the list of every first-party OCI digest in every published
`serviceradar-wasm-plugin-index.json` and `serviceradar-native-addon-index.json` is generated
(v1.5.6 lists 16 Wasm plugins; GitHub shows 50 releases, so on the order of a thousand digests at
most), committed and shipped in the web-ng image. At import, those digests verify key-only and are
recorded as `absent_allowlisted`. Every other first-party Wasm plugin or native add-on digest
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

## Threat model

**Assets.** The integrity of the Wasm plugins and native add-ons an installation imports and runs.
Images are covered too, for the monitor and public verification, but Kyverno remains their
admission gate.

**What the receipt plus monitor adds.** From the cutover release on, receipts are required for every
first-party Wasm plugin and native add-on digest not on the frozen allowlist (Decision 9), so an
accepted artifact must have a public, append-only record in Rekor v1, made by the
holder of the release key. Without a receipt requirement, someone who can sign with the key can
produce an importable package that leaves no public trace. With it they must log the signature, and
the monitor reports any logged signature that none of our signing runs accounts for, within about
one scan interval (an hour at the hourly default). The log is also an independent record of everything the key signed, available to anyone,
which bounds the investigation after an incident.

**What it does not add.**

- *Prevention.* The verifier accepts a malicious artifact that carries a valid receipt. The monitor
  only shortens the time to detection. The response (revoking the key, pulling the release,
  telling installations) is outside this change.
- *A compromised run of our own signing workflow.* That run writes its own ledger, so its entries
  are explained. The monitor detects key use outside the signing workflows, not a poisoned build
  inside them.
- *Before enforcement.* While a missing receipt is accepted, an attacker omits it. Verifying a
  receipt only when one is present adds visibility, not security.
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
existing job watcher are added. Operationally, a release now cannot sign while public Rekor v1 is
down (already true in practice, since upload is on and failures are not swallowed), and the
monitor's alerts need an owner.

## Risks

- **Rekor v1 freeze.** Sigstore is moving public-good to Rekor v2. When v1 stops accepting
  entries, release signing fails closed by design. A Rekor v2 receipt cannot be carried in the
  legacy annotation, so continuing then needs a new decision: a self-hosted v1-compatible log,
  revisiting the bundle-format decision, or going back to key-only. Mitigation: the failure is
  loud, and the daily trusted-root check (Decision 5) warns when v1's `validFor.end` is set.
- **Deprecated flags.** `--tlog-upload` and `--offline` are deprecated in cosign v3. The cosign
  version is pinned, and contract tests fail if a pinned-version bump changes the behaviour.
- **Admission regression.** A malformed annotation denies an image at admission (Decision 3). The
  release verification gate runs the same check first.
- **Monitor noise.** Unexplained-entry alerts that turn out to be benign wear down attention. Keying
  the match on the payload hash and the acknowledgement file keep these rare.

## Migration plan

1. Upgrade cosign (signer and image), add `docs/sigstore/rekor-keys/` and `docs/sigstore/rekor.pub`,
   and add the consistency tests.
2. Ship the signer change (receipt annotation and ledger) and the receipt check in the release
   verification scripts. From then on every new signature carries a receipt.
3. Enable the monitor once the scan cost is measured. Release N+1's ledger is the first end-to-end
   canary.
4. Ship the verifier change with the frozen pre-cutover allowlist (Decision 9).
   Until it ships, #6778's key-only verification remains in force.

Rollback: the verifier change can be reverted to #6778's key-only mode on its own. A key-only
verifier (`--insecure-ignore-tlog=true`) never reads the annotation, so already-published
annotated `.sig` signatures stay valid for it. Kyverno with the current policy verifies the
annotation offline (Decision 3), and the release gate has already checked it.

## Open questions

### Open Question 1: Is an hourly full-log scan affordable on ARC?

Recommendation: measure first (task 5.1). Keep `rekor-monitor` log scanning even if the interval
has to grow. Do not fall back to the incomplete index search. A high scan cost never removes the
scheduled release-key monitor; only the scan interval may grow, with a correspondingly longer
window.

### Open Question 2: Where do signing-monitor alerts go?

Recommendation: a GitHub issue per unexplained entry, plus Discord. The existing
`CI_FAILURE_DISCORD_WEBHOOK_URL` is acceptable at the start. A dedicated security webhook secret
would keep key-misuse alerts out of CI-failure noise, and the owner should choose.

### Open Question 3: Which cosign version?

Recommendation: v3.1.4, the latest patch release at the time of writing, in the signer and the
image together. The floor is v3.1.3 (all four advisories in Decision 6).
