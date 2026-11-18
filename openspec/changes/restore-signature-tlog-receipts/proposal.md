# Change: Carry the transparency-log receipt in classic signatures and verify it offline

## Why

Up to v1.5.3, first-party Wasm plugins and native add-ons were signed with `cosign sign`, which
also wrote a Sigstore bundle referrer holding the Rekor inclusion proof. The importer read that
bundle and checked the log entry offline. Commit cc4e0917d5 (issue #6619) moved images, add-ons and
Wasm plugins to one classic `.sig` signature per digest, because demo Kyverno key-based
`verifyImages` reads only `.sig`. The signers still run `cosign sign-blob` with transparency-log
upload on, so every signature is logged in public Rekor. The hand-built `.sig` manifest, however,
carries only the `dev.cosignproject.cosign/signature` annotation, and the Rekor receipt is
discarded. From v1.5.4 the importer could confirm the log entry only by an online lookup. An
air-gapped install waited about three minutes per package and then rejected the import.

`verify-first-party-imports-without-sigstore` (#6778, merged) made import verification key-only
(`--insecure-ignore-tlog=true`). Imports work again, but the log check is gone. With key-only
verification, anyone who can produce a signature with the release key can produce an importable
package without a public trace.

This change restores the receipt to the classic signature, verifies it offline at import, and adds
a monitor that watches the log for the release key. Without the monitor, the receipt has no
detection value.

**Amendment (2026-11-18): the log is ServiceRadar's own Rekor, not public-good Rekor.** Measured
while implementing: public-good Rekor v1 grows by about 300 entries a second (about 1.1 million an
hour), and `rekor_monitor` fetches entries ten at a time, sequentially. A 10-entry retrieve took
10 to 27 seconds and about 55 KB, a single-entry read 3 to 8 seconds. Scanning one hour of the
public log would take about 110,000 requests and 6 GB, many hours of work per hour of log, so a
full-log monitor of the public log can never keep up at any interval. The product owner chose to
log release signatures to the self-hosted Rekor v1 at `https://rekor.serviceradar.cloud`
(`carverauto/gitops` `k8s/sigstore`), which holds only ServiceRadar's entries and can be scanned
in full. Verification stays fully offline: no verifier, installer or admission check calls any
Rekor, so no installation depends on that log being up.

## What Changes

- **Signing (images, native add-ons, Wasm plugins).** Each new classic `.sig` layer carries the
  legacy Rekor bundle in the `dev.sigstore.cosign/bundle` annotation: the SignedEntryTimestamp
  (SET) plus the payload with `body`, `integratedTime`, `logIndex` and `logID`. The three
  duplicated `attach_legacy_signature` implementations become one shared helper. Signing fails if
  Rekor returns no SET, so a signature can never be published without its receipt. The signature
  format stays the same. Kyverno and Harbor promotion read the same `.sig` tag as before.
- **Pinned log.** The signer uploads to ServiceRadar's self-hosted Rekor v1 log
  (`https://rekor.serviceradar.cloud`, tree `7401445772329872027`) through cosign's legacy upload
  path (`--use-signing-config=false --rekor-url <that URL>`), never to a log a TUF-delivered
  signing config names. A Rekor v2 entry has no SET and cannot be expressed in the legacy
  annotation. When that log is unreachable or returns no SET from the pinned log, signing fails
  and the release stops.
- **Release verification.** The signer records in its ledger whether each digest's signature was
  created or reused in the run, and the repository verification scripts classify digests from that
  record, never from whether a receipt is present; a digest in neither set fails. They check offline
  the receipt of every created signature and every reused signature that carries one, selecting
  the pinned Rekor key by the receipt's log ID, and fail the release when it is missing or does not
  verify. A signature created in the run must carry a receipt from the self-hosted log. A reused
  pre-cutover signature (including a container image's) carries no receipt, or a receipt from
  public-good Rekor written by an earlier manual signing; it is exempt from the receipt
  requirement, and a public-good receipt on it is still checked offline against a separately kept
  pre-cutover key. Kyverno remains the admission gate for images.
- **Offline verification at import.** The web-ng image ships the self-hosted log's public key,
  pinned byte-for-byte to a committed copy. `CosignVerifier` verifies the receipt with that key:
  the SET must verify, and the logged body must name the same signature, release public key and
  payload hash. Import never makes a network call to a Sigstore service or to any Rekor, the
  self-hosted one included; a test proves it.
- **Artifacts without a receipt.** The cutover release is v1.5.8 or later: the first release built
  from a commit containing the signer change (v1.5.7 was cut without it). All first-party `.sig`
  signatures published before it lack the annotation, and Harbor tag immutability prevents adding it. The product owner
  decided on a frozen allowlist of every first-party Wasm plugin and native add-on digest
  published up to and including v1.5.7, shipped in the web-ng image; those import key-only. Once
  the allowlist is frozen, no release is cut from a commit without the signer. From the cutover release on, every
  other first-party Wasm plugin or native add-on digest requires a receipt (design.md,
  Decision 9).
- **Cosign upgrade.** The signer (`scripts/install-cosign.sh`) and the web-ng image
  (`MODULE.bazel`) move together from v3.0.3 to a release with the fixes for
  GHSA-whqx-f9j3-ch6m and GHSA-fx35-mq7g-6g98. GHSA-whqx-f9j3-ch6m (fixed in 3.0.4) lets a
  receipt for an unrelated Rekor entry pass verification on the trusted-root path. The check this
  change relies on is the pinned-key path (`SIGSTORE_REKOR_PUBLIC_KEY`, no trusted root), which
  binds the receipt to the artifact and is the advisory's own workaround; the upgrade also closes
  the gap in the trusted-root branch.
- **Monitoring.** A scheduled GitHub Actions workflow on `arc-runner-set` runs a project-owned
  scanner (`build/ci/rekor_signing_monitor.py`) hourly. It reads every entry of the self-hosted log
  (small and fully enumerable), recomputes the RFC 6962 root against the log's signed tree head
  under the pinned key, requires the previous checkpoint to be a prefix of the log (except on the manual bootstrap
  dispatch that seeds the first checkpoint while none exists; any other run that finds a non-prefix
  checkpoint fails, alerts and keeps the stored one), and selects the entries signed by the
  release key. It alerts on any entry that does not match a payload
  recorded by one of the repository's release-key signing runs, is not currently acknowledged, and was not
  already recorded as explained by a ledger match in the monitor's checkpoint state, within about one scan interval
  after the entry becomes decidable (every release-key signing run active at its integrated time
  has ended; a few hours at worst for an entry overlapping a long `release.yml` run), and
  on its own failure or blindness. The blindness canary alerts on a ledgered entry still unseen two
  scan intervals after its signing run ended, and the scheduled job watch reports the monitor stale
  when its last successful run is older than three scan intervals.
- **Pinned-key update process.** The pinned key is the self-hosted log's public key, read from
  its `GET /api/v1/log/publicKey` endpoint and checked against the log's signed tree head. The same
  workflow compares the served key with the pinned one on every run and alerts on a change. A
  reviewed update adds the new key and keeps every key an accepted receipt names.
- **Kyverno trust configuration.** The demo `verify-serviceradar-images` policy today names no
  Rekor, so Kyverno defaults to public-good Rekor and its TUF keys and would deny an image whose
  receipt comes from the self-hosted log. The policy gains a receipt entry with the pinned
  self-hosted key and no Rekor URL, so that it verifies the receipt offline, and keeps a
  transition entry for pre-cutover images until every admitted demo image carries a self-hosted
  receipt (design.md, Decision 3). This is a `carverauto/gitops` change, drafted with this work
  and merged and applied by a person; it must be live on demo before the cutover release is cut.
- **Second line: the OpenBao audit log.** The self-hosted Rekor signs with an OpenBao Transit key
  in the same OpenBao as `cosign-release`, so someone who can use both keys could forge a receipt
  without logging anything. An OpenBao audit device and a watch that reports every
  `transit/sign/cosign-release` call no signing ledger accounts for close that gap (design.md,
  Decision 10). This change specifies them; the operator enables the audit device.
- **Operator precondition.** `bao read transit/keys/cosign-release` must show `exportable=false`
  and `allow_plaintext_backup=false` (design.md, Decision 11). Recorded as an operator check.

## Non-goals

- No change to the key-only import behaviour from #6778 until this change is implemented and
  released. Until then, #6778 is the contract.
- No Sigstore bundle or OCI-referrer signature format. The 2026-11-15 single-classic-signature
  decision stands.
- No Kyverno change beyond its Rekor trust configuration (design.md, Decision 3). The original
  non-goal ("no Kyverno policy change") assumed receipts from public-good Rekor, whose key
  Kyverno already trusts through TUF; a receipt from the self-hosted log needs the pinned key.
- No public, third-party-auditable record. The self-hosted log is append-only and monitored, but
  only ServiceRadar runs it.
- No prevention. A receipt and a monitor detect misuse of the key. They do not stop a validly
  logged malicious signature from being imported.
- Third-party plugin repositories are out of scope. They are verified with per-repository
  ed25519 upload signatures, not Cosign (`add-third-party-plugin-repositories`), so there is no
  receipt to require.
- Rekor v2 receipts are out of scope; see Risks in design.md.

## Threat model (summary; full version in design.md)

- **Adds:** from the cutover release on, a first-party Wasm plugin or native add-on accepted at
  import must have a record of its signature in the self-hosted Rekor log, unless its digest is on
  the frozen pre-cutover allowlist. A signature made with the release key outside the repository's
  signing workflows, for example by a stolen OpenBao token or an abused Transit role, is detectable
  in that log. The monitor
  reports it within about one scan interval (an hour at the hourly default) after it becomes
  decidable, that is, after every release-key signing run active at its integrated time has ended.
  For an entry overlapping a long release run the worst case is the remaining run time plus one
  scan interval, a few hours for `release.yml`. The log is also a history of everything the key
  signed, which helps the forensics after an incident. A receipt forged without logging, which
  needs the self-hosted log's Transit key as well, is caught by the second line: the OpenBao audit
  log shows every `cosign-release` signing call.
- **Does not add:** prevention, protection against a compromised run of the signing workflow
  itself (its ledger explains its own entries), or protection before the cutover release. Until
  then receipts are optional, and an attacker simply omits one.
- **Likelihood:** low. The key is non-exportable in OpenBao Transit behind a sign-only policy and a
  dedicated signing runner and `release` environment. The practical exposure is abuse of the
  signing oracle, not theft of the key bytes.
- **Complexity cost:** moderate. It touches one shared signer helper, one verifier, a cosign bump,
  a pinned key file with a consistency test, a digest allowlist, a signing ledger, one new
  scheduled workflow, a Kyverno trust change and an OpenBao audit watch. Release signing then
  depends on the self-hosted Rekor and its OpenBao Transit token being up; when either is not,
  releases fail closed. Verification of already-issued receipts never depends on them.

## Impact

- Affected specs: `artifact-signing` (new), `wasm-plugin-system`, `wasm-plugin-builds`
- Affected infrastructure (`carverauto/gitops`): `k8s/kyverno/base/verify-serviceradar-images.yaml`
  (Rekor trust), the OpenBao audit device (operator), `k8s/sigstore` (Rekor's OpenBao token and
  Trillian database backups)
- Affected code: `scripts/cosign_common.sh`, `scripts/sign-oci-publish.sh`,
  `scripts/sign-native-addon-publish.sh`, `scripts/sign-wasm-plugin-publish.sh`,
  `scripts/verify-*-publish.sh`, `scripts/install-cosign.sh`, `MODULE.bazel` (cosign archives),
  `docker/images/BUILD.bazel` (web-ng image layer for the pinned key),
  `elixir/web-ng/lib/serviceradar_web_ng/plugins/cosign_verifier.ex`,
  `elixir/web-ng/lib/serviceradar_web_ng/plugins/first_party_importer.ex` (plugin verification
  metadata), `elixir/web-ng/lib/serviceradar_web_ng/plugins/native_addon_importer.ex` and
  `elixir/serviceradar_core/lib/serviceradar/plugins/native_addon_importer.ex` (add-on verification
  metadata in `source_metadata/2`),
  `.github/workflows/` (new monitor workflow; ledger upload in every release-key signing workflow:
  `release.yml`, `publish-oci.yml`, `wasm-plugins.yml`, `native-addons.yml`,
  `external-wasm-plugin.yml`; `actions: read` in `scheduled-job-watch.yml`),
  `build/ci/scheduled_job_watch.py` (separate Actions run lookup for the monitor),
  `build/contracts/` (new consistency tests)
- Affected docs: `docs/sigstore/README.md`, `docs/RELEASE_PUBLISHING.md`, `docs/agent-runbooks.md`
  (manual demo signing), `docs/docs/wasm-plugins.md`, `docs/docs/native-addons.md`
- Interaction with pending changes: builds on `verify-first-party-imports-without-sigstore` and
  keeps its "no public Sigstore service" requirement. The pending `add-signed-wasm-plugin-import`
  delta still says "Rekor entry" for import. This change makes that wording accurate again, as an
  offline receipt check.
