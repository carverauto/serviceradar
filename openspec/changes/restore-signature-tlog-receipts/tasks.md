## 0. Decisions before implementation

- [x] 0.1 Product owner answers design.md, Open Question 2 (alert channel) and Open Question 3
  (cosign version).

## 1. Cosign upgrade and pinned trust material

- [x] 1.1 Move `scripts/install-cosign.sh` and the `cosign_linux_amd64`/`cosign_linux_arm64`
  archives in `MODULE.bazel` to the chosen release (at least v3.1.3), with pinned checksums.
- [x] 1.2 Re-read the chosen version's `sign_blob.go`, `verify.go` (`VerifyBundle`,
  `verifySignature`) and `cmd/cosign/cli/verify/common.go`, and confirm design.md, Decisions 1
  and 4 still hold. Record the result in the PR.
- [ ] 1.3 Add the accepted key set `docs/sigstore/rekor-keys/<logID>.pub` and the signing-log key
  `docs/sigstore/rekor.pub` from the self-hosted log's `GET /api/v1/log/publicKey`, accepted only
  after the log's signed tree head verifies under it; record the URL, time, tree ID and size.
  Keep the public-good key only in `docs/sigstore/pre-cutover-rekor-keys/`. Ship the accepted set
  (not the pre-cutover one) in the web-ng image.
- [ ] 1.4 Add `build/contracts` tests: every image Rekor key byte-identical to the committed key
  set; `docs/sigstore/rekor.pub` byte-identical to one member of the set; signer and image cosign
  versions equal.

## 2. Signer

- [x] 2.1 Move `attach_legacy_signature` into `scripts/cosign_common.sh` and use it from
  `sign-oci-publish.sh`, `sign-native-addon-publish.sh` and `sign-wasm-plugin-publish.sh`.
- [ ] 2.2 Sign with `--use-signing-config=false --new-bundle-format=false --rekor-url
  https://rekor.serviceradar.cloud`. Fail when the log is unreachable, when
  `rekorBundle.SignedEntryTimestamp` is empty, or when `logID` is not the pinned log.
- [ ] 2.3 Write `.rekorBundle` as the `dev.sigstore.cosign/bundle` annotation on the
  `simplesigning` layer.
- [x] 2.4 Write the signing ledger line before each `sign-blob` call and the log index/UUID line
  after it. Upload the ledger with `if: always()` in every release-key signing workflow
  (`release.yml`, `publish-oci.yml`, `wasm-plugins.yml`, `native-addons.yml` and
  `external-wasm-plugin.yml`), and attach it to the release on tag runs. Cover
  `sign-release-checksums.sh` too. Record in the ledger, per digest, whether the signature was
  created or reused in the run.
- [x] 2.5 Extend `scripts/test-release-publish-contracts.sh`: an upload without a SET fails; the
  annotation equals the legacy bundle's `rekorBundle`; a reused signature is not re-signed; the
  ledger line exists before the upload.

## 3. Release verification

- [x] 3.1 Classify each digest in `cosign_verify_legacy_signature` from the signer's ledger record
  (created or reused), never from whether a receipt is present, and fail a digest in neither set.
  Verify created signatures and reused signatures that carry a receipt in the receipt-required form
  (design.md, Decision 4), selecting the pinned key from `docs/sigstore/rekor-keys/` by the
  receipt's `logID`. Reused signatures without a receipt, which can only be pre-cutover (including
  container images), stay key-only and are exempt from the receipt check; the import allowlist is
  not consulted here.
- [x] 3.2 Add negative contract tests built from synthetic material: a stand-in "log" ECDSA key
  that signs a SET over a synthetic entry, plus a synthetic release key. A missing receipt fails, a
  valid SET for a different entry fails, an unknown log ID fails, a created digest without a
  receipt fails, and a digest with no ledger record fails.
- [ ] 3.3 Re-run one image digest's `.sig` through the release gate and through Kyverno-equivalent
  verification (`cosign verify --new-bundle-format=false --key`, `IgnoreTlog=false`, with the
  amended policy's Rekor key) before the first release with annotations. Record the output in the PR.
- [ ] 3.4 Release verification accepts a created signature's receipt only from
  `docs/sigstore/rekor-keys/`, and checks a reused signature's public-good receipt against
  `docs/sigstore/pre-cutover-rekor-keys/`. Negative tests: a created signature with a public-good
  receipt fails; a reused one with a public-good receipt verifies offline.

## 4. Import verifier (web-ng)

- [ ] 4.1 `CosignVerifier` with exactly two command shapes (design.md, Decision 4): (a)
  receipt-required mode for every non-allowlisted digest, with the pinned key selected from the
  shipped key set by the receipt's `logID` and passed as `SIGSTORE_REKOR_PUBLIC_KEY`,
  `--offline=true`, `--new-bundle-format=false`, no `--trusted-root`, no `--insecure-ignore-tlog`,
  failing closed on a missing receipt; a digest whose signature carries a receipt always uses (a)
  and records `verified`; (b) key-only mode only for allowlisted digests without a receipt, with #6778's
  flags (`--insecure-ignore-tlog=true`, no Rekor key). No TUF, isolated home and cache directories,
  bounded timeout.
- [ ] 4.2 With the cutover release (the first release whose signer attaches receipts), generate
  and commit the frozen allowlist from every `serviceradar-wasm-plugin-index.json` and
  `serviceradar-native-addon-index.json` published before it. Ship that list unchanged with the
  verifier release, never regenerate it once receipt-bearing releases exist, and add the freeze
  contract test.
- [ ] 4.3 Store `transparency_receipt` (`verified` with log index and integrated time, or
  `absent_allowlisted`) in the import verification metadata on both write paths: web-ng
  `first_party_importer.ex` for Wasm plugins, and for native add-ons web-ng
  `native_addon_importer.ex` (the cosign call) passing the receipt fields into core
  `native_addon_importer.ex` `source_metadata/2`.
- [ ] 4.4 Load the `test-audit` skill, then extend `cosign_verifier_test.exs`: receipt-required
  rejects a missing receipt without a network call, allowlisted digests pass key-only, and an
  unknown log ID is rejected. Include one test that runs the real pinned cosign binary against
  synthetic fixtures with networking blocked.
- [ ] 4.5 Add a test that proves no request reaches a Rekor URL during import verification: a
  stand-in Rekor that records every request stays untouched while a receipt verifies.

## 5. Monitor

- [x] 5.1 Measure the scan cost (design.md, Context and Open Question 1). Public-good Rekor v1
  cannot be scanned in full; the log moved to the self-hosted Rekor, which can.
- [ ] 5.2 Add `.github/workflows/rekor-signing-monitor.yml`: `rekor_monitor` built from a pinned
  commit with a verified checksum; checkpoint kept as an artifact; fingerprint of `docs/cosign.pub`;
  ledger matching against every release-key signing workflow, with entries left pending (no alert)
  while a run active at their integrated time is still in progress;
  `docs/sigstore/rekor-acknowledged-entries.json`; a GitHub issue per unexplained entry UUID,
  closed when a later scan finds the entry explained; Discord post; failure on inconsistency or
  missing state.
- [ ] 5.3 Add the blindness canary (ledger entries from a signing run that ended more than two scan
  intervals ago, two hours at the hourly default, integrated after the monitor's first retained
  checkpoint, that were never observed) and the check that the self-hosted log still serves the
  pinned key.
- [ ] 5.4 Add a separate GitHub Actions workflow-run lookup for `rekor-signing-monitor.yml` to the
  scheduled job watch, give `.github/workflows/scheduled-job-watch.yml` `actions: read`, and report
  the monitor when its last successful run is older than three scan intervals (three hours at the
  hourly default). Do not add the monitor to `WATCHED_JOBS`.
- [ ] 5.5 Prove the alert path once with a self-test dispatch that posts a test alert, and record
  the result in the PR.

## 5b. Admission, second line and operations

- [ ] 5b.1 Change `carverauto/gitops` `k8s/kyverno/base/verify-serviceradar-images.yaml` as in
  design.md, Decision 3: a receipt entry with the pinned self-hosted `rekor.pubkey` and a
  pre-cutover entry, `count: 1`, no `ignoreTlog: true`. Live before demo runs a cutover-release
  image. Remove the pre-cutover entry once no admitted demo image carries a pre-cutover signature.
- [ ] 5b.2 Specify and, once the operator has enabled the OpenBao audit device, implement the watch
  that reports `transit/sign/cosign-release` requests no signing ledger accounts for (design.md,
  Decision 10). Agents do not enable the audit device.
- [ ] 5b.3 Operator check, recorded in `docs/sigstore/README.md`: `bao read
  transit/keys/cosign-release` shows `exportable=false` and `allow_plaintext_backup=false`
  (design.md, Decision 11). Agents do not run it.
- [ ] 5b.4 Back up the self-hosted log's Trillian MySQL database and test a restore, and remint the
  Rekor OpenBao token (or move Rekor to Kubernetes auth) before it expires (design.md, Risks).

## 6. Docs

- [ ] 6.1 Update `docs/sigstore/README.md` and `docs/RELEASE_PUBLISHING.md` (receipt in `.sig`,
  pinned log, ledger, monitor, key update process, history gap before the first monitor run).
- [ ] 6.2 Update `docs/docs/wasm-plugins.md` and `docs/docs/native-addons.md` for offline receipt
  verification and the `absent_allowlisted` status.
- [x] 6.3 Replace the manual demo signing path in `docs/agent-runbooks.md` with the
  `publish-oci.yml` dispatch, or document that each manual signature must be acknowledged.
- [ ] 6.4 Once `verify-first-party-imports-without-sigstore` is archived into
  `openspec/specs/wasm-plugin-system`, convert the precedence sentence in this change's
  wasm-plugin-system delta into a MODIFIED delta of "First-party artifact import needs no public
  Sigstore service" before archiving this change.
