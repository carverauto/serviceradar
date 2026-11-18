## 0. Decisions before implementation

- [ ] 0.1 Product owner answers design.md, Open Question 2 (alert channel) and Open Question 3
  (cosign version).

## 1. Cosign upgrade and pinned trust material

- [ ] 1.1 Move `scripts/install-cosign.sh` and the `cosign_linux_amd64`/`cosign_linux_arm64`
  archives in `MODULE.bazel` to the chosen release (at least v3.1.3), with pinned checksums.
- [ ] 1.2 Re-read the chosen version's `sign_blob.go`, `verify.go` (`VerifyBundle`,
  `verifySignature`) and `cmd/cosign/cli/verify/common.go`, and confirm design.md, Decisions 1
  and 4 still hold. Record the result in the PR.
- [ ] 1.3 Add `docs/sigstore/rekor.pub` from Sigstore's TUF `trusted_root.json`, recording the
  root version in the commit message. Ship the same bytes in the web-ng image.
- [ ] 1.4 Add `build/contracts` tests: image Rekor key byte-identical to `docs/sigstore/rekor.pub`;
  signer and image cosign versions equal.

## 2. Signer

- [ ] 2.1 Move `attach_legacy_signature` into `scripts/cosign_common.sh` and use it from
  `sign-oci-publish.sh`, `sign-native-addon-publish.sh` and `sign-wasm-plugin-publish.sh`.
- [ ] 2.2 Sign with `--use-signing-config=false --new-bundle-format=false --rekor-url <pinned v1>`.
  Fail when `rekorBundle.SignedEntryTimestamp` is empty or `logID` is not the pinned log.
- [ ] 2.3 Write `.rekorBundle` as the `dev.sigstore.cosign/bundle` annotation on the
  `simplesigning` layer.
- [ ] 2.4 Write the signing ledger line before each `sign-blob` call and the log index/UUID line
  after it. Upload the ledger with `if: always()` in every release-key signing workflow
  (`release.yml`, `publish-oci.yml`, `wasm-plugins.yml`, `native-addons.yml` and
  `external-wasm-plugin.yml`), and attach it to the release on tag runs. Cover
  `sign-release-checksums.sh` too.
- [ ] 2.5 Extend `scripts/test-release-publish-contracts.sh`: an upload without a SET fails; the
  annotation equals the legacy bundle's `rekorBundle`; a reused signature is not re-signed; the
  ledger line exists before the upload.

## 3. Release verification

- [ ] 3.1 Switch `cosign_verify_legacy_signature` to the offline receipt form (design.md,
  Decision 4) for signatures created in the current run only. Reused pre-cutover signatures,
  including container images, stay key-only and are exempt from the receipt check; the import
  allowlist is not consulted here.
- [ ] 3.2 Add negative contract tests built from synthetic material: a stand-in "log" ECDSA key
  that signs a SET over a synthetic entry, plus a synthetic release key. A missing receipt fails, a
  valid SET for a different entry fails, and an unknown log ID fails.
- [ ] 3.3 Re-run one image digest's `.sig` through the release gate and through Kyverno-equivalent
  verification (`cosign verify --new-bundle-format=false --key`, `IgnoreTlog=false`, TUF Rekor keys)
  before the first release with annotations. Record the output in the PR.

## 4. Import verifier (web-ng)

- [ ] 4.1 `CosignVerifier`: receipt-required mode for non-allowlisted digests, key-only mode for
  allowlisted digests, and selection of the pinned key by `logID`. No `--trusted-root`, no TUF,
  isolated home and cache directories, bounded timeout.
- [ ] 4.2 Generate and commit the frozen pre-cutover digest allowlist from every published
  `serviceradar-wasm-plugin-index.json` and `serviceradar-native-addon-index.json`. Ship it in
  the image and add the freeze contract test.
- [ ] 4.3 Store `transparency_receipt` (`verified` with log index and integrated time, or
  `absent_allowlisted`) in the import verification metadata.
- [ ] 4.4 Load the `test-audit` skill, then extend `cosign_verifier_test.exs`: receipt-required
  rejects a missing receipt without a network call, allowlisted digests pass key-only, and an
  unknown log ID is rejected. Include one test that runs the real pinned cosign binary against
  synthetic fixtures with networking blocked.

## 5. Monitor

- [ ] 5.1 Measure the run time and download volume of an hourly `rekor_monitor` fingerprint scan of
  public Rekor v1 on an `arc-runner-set` runner before enabling the schedule (design.md, Open
  Question 1).
- [ ] 5.2 Add `.github/workflows/rekor-signing-monitor.yml`: `rekor_monitor` built from a pinned
  commit with a verified checksum; checkpoint kept as an artifact; fingerprint of `docs/cosign.pub`;
  ledger matching against every release-key signing workflow, with entries left pending (no alert)
  while a run active at their integrated time is still in progress;
  `docs/sigstore/rekor-acknowledged-entries.json`; a GitHub issue per unexplained entry UUID,
  closed when a later scan finds the entry explained; Discord post; failure on inconsistency or
  missing state.
- [ ] 5.3 Add the blindness canary (ledger entries older than two hours, integrated after the
  monitor's first retained checkpoint, that were never observed) and the daily TUF trusted-root comparison for the pinned Rekor key.
- [ ] 5.4 Extend `build/ci/scheduled_job_watch.py` to report the monitor when its last successful
  run is more than three hours old.
- [ ] 5.5 Prove the alert path once with a self-test dispatch that posts a test alert, and record
  the result in the PR.

## 6. Docs

- [ ] 6.1 Update `docs/sigstore/README.md` and `docs/RELEASE_PUBLISHING.md` (receipt in `.sig`,
  pinned log, ledger, monitor, key update process, history gap before the first monitor run).
- [ ] 6.2 Update `docs/docs/wasm-plugins.md` and `docs/docs/native-addons.md` for offline receipt
  verification and the `absent_allowlisted` status.
- [ ] 6.3 Replace the manual demo signing path in `docs/agent-runbooks.md` with the
  `publish-oci.yml` dispatch, or document that each manual signature must be acknowledged.
