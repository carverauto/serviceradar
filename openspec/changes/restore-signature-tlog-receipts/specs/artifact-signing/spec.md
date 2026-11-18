## ADDED Requirements

### Requirement: Classic signatures carry the transparency-log receipt
Each classic Cosign `.sig` signature created for a first-party container image, native add-on or Wasm plugin SHALL carry, on its signature layer, the Rekor receipt for that signature in the `dev.sigstore.cosign/bundle` annotation.
The annotation value is the legacy Cosign `RekorBundle`: the SignedEntryTimestamp, and a payload with `body`, `integratedTime`, `logIndex` and `logID`. The signature stays one classic `.sig` tag per digest with one `simplesigning` layer. No Sigstore bundle or OCI-referrer signature is produced.

#### Scenario: New signature carries its receipt
- **GIVEN** a first-party artifact digest that has no classic signature yet
- **WHEN** the release signer signs it
- **THEN** the `.sig` layer SHALL hold both `dev.cosignproject.cosign/signature` and `dev.sigstore.cosign/bundle`
- **AND** the logged body SHALL name the same signature, release public key and payload hash as the layer

#### Scenario: Rekor returns no signed entry timestamp
- **GIVEN** a transparency-log upload whose response has no SignedEntryTimestamp, or a log ID other than the pinned log
- **WHEN** the release signer processes the response
- **THEN** signing SHALL fail
- **AND** no `.sig` tag SHALL be written for that digest

#### Scenario: Existing signature is reused, not replaced
- **GIVEN** a digest that already has a classic `.sig` signature that verifies under the release key
- **WHEN** a release run signs that digest again
- **THEN** the signer SHALL reuse the existing signature
- **AND** SHALL NOT write or overwrite the `.sig` tag

### Requirement: Signing uses the pinned transparency log
The release signer SHALL upload signatures to ServiceRadar's self-hosted Rekor v1 log (`https://rekor.serviceradar.cloud`) through Cosign's legacy upload path, and SHALL NOT take the log location from a TUF-delivered signing configuration.
When that log cannot be reached, rejects the upload, or answers without a SignedEntryTimestamp from the pinned log, signing SHALL fail and the release SHALL stop; the signer SHALL NOT fall back to another log or to signing without a log entry.

#### Scenario: Signing configuration names a different log
- **GIVEN** the public Sigstore signing configuration lists a transparency log other than the pinned self-hosted Rekor v1 log
- **WHEN** the release signer signs an artifact
- **THEN** the entry SHALL be written to the pinned self-hosted Rekor v1 log

#### Scenario: Self-hosted log unreachable at signing time
- **GIVEN** the self-hosted Rekor log cannot be reached
- **WHEN** the release signer signs an artifact
- **THEN** signing SHALL fail
- **AND** no `.sig` tag SHALL be written for that digest

### Requirement: Release verification requires the receipt offline
The repository release verification for images, native add-ons and Wasm plugins SHALL verify the embedded receipt of every signature created in the run against the pinned Rekor public key without contacting any Sigstore service.
A missing or invalid receipt on a signature created in the run fails the release before promotion. The cutover release is v1.5.8 or later: the first release built from a commit containing the signer change. Release verification SHALL classify each digest from the signer's per-digest record in the signing ledger of whether it created a new signature or reused an existing one, and SHALL NOT classify it by whether a receipt is present. A digest in neither the created set nor the reused set SHALL fail verification. Every signature created in the run, and every reused signature that carries a receipt, SHALL be verified in receipt-required mode: the pinned Rekor key selected by the receipt's log ID from the retained key set, passed as `SIGSTORE_REKOR_PUBLIC_KEY`, with `--offline=true` and `--new-bundle-format=false`, and with no `--trusted-root` and no `--insecure-ignore-tlog`. A reused signature without a receipt can only predate the cutover release, for an image, a native add-on or a Wasm plugin; it SHALL be exempt from the receipt check and is verified in key-only mode, with the release key alone (`--insecure-ignore-tlog=true`, no Rekor key). Kyverno remains the admission gate for images, and release verification does not consult the import allowlist. A signature created in the run SHALL carry a receipt from a log in `docs/sigstore/rekor-keys/`. A reused signature whose receipt names the public-good Rekor log SHALL be verified in receipt-required mode against `docs/sigstore/pre-cutover-rekor-keys/`; a receipt naming a log in neither set SHALL fail. Release verification SHALL NOT contact any Rekor, the self-hosted one included.

#### Scenario: Reused signature with a pre-cutover public-good receipt
- **GIVEN** a digest the signing ledger records as reused, whose signature carries a receipt from the public-good Rekor log made before the cutover
- **WHEN** release verification runs
- **THEN** the receipt SHALL be verified offline against the key in `docs/sigstore/pre-cutover-rekor-keys/`

#### Scenario: Created signature with a public-good receipt
- **GIVEN** a digest the signing ledger records as created in the current run, whose receipt names the public-good Rekor log
- **WHEN** release verification runs
- **THEN** verification SHALL fail

#### Scenario: Signature created without a receipt
- **GIVEN** a signature created in the current release run whose `.sig` layer has no receipt
- **WHEN** release verification runs
- **THEN** verification SHALL fail
- **AND** the artifact SHALL NOT be promoted

#### Scenario: Created signature whose receipt was dropped
- **GIVEN** a digest the signing ledger records as created in the current run
- **AND** its `.sig` layer has no receipt
- **WHEN** release verification runs
- **THEN** verification SHALL fail in receipt-required mode
- **AND** SHALL NOT fall back to key-only mode

#### Scenario: Digest with no signing record
- **GIVEN** a digest that the signing ledger records neither as created nor as reused in the current run
- **WHEN** release verification runs
- **THEN** verification SHALL fail

#### Scenario: Reused post-cutover signature after a Rekor rotation
- **GIVEN** a digest the signing ledger records as reused, whose receipt names an older log ID that is still in the retained key set
- **WHEN** release verification runs
- **THEN** it SHALL select the key for that log ID
- **AND** the receipt SHALL verify

#### Scenario: Reused pre-cutover signature
- **GIVEN** an image, native add-on or Wasm plugin digest whose classic `.sig` signature was created before the cutover release and is reused by the current run
- **WHEN** release verification runs
- **THEN** the signature SHALL be verified with the release key
- **AND** the absence of a receipt SHALL NOT fail the release

#### Scenario: Receipt for a different entry
- **GIVEN** a `.sig` layer whose receipt carries a valid SignedEntryTimestamp for a log entry that names a different signature, key or payload hash
- **WHEN** release verification runs
- **THEN** verification SHALL fail

### Requirement: Pinned Rekor public key
The repository SHALL hold the full set of accepted Rekor v1 public keys in `docs/sigstore/rekor-keys/`, one file per accepted log ID, and the key of the log the signer currently writes to in `docs/sigstore/rekor.pub`; the accepted keys are those of ServiceRadar's self-hosted log.
A key is read from the self-hosted log's `GET /api/v1/log/publicKey` endpoint and accepted only when the log's current signed tree head verifies under it; the commit records how and when it was fetched. The public-good Rekor key is not accepted: it is kept in `docs/sigstore/pre-cutover-rekor-keys/` for release verification of reused pre-cutover receipts only and is not shipped in the web-ng image. The web-ng image ships the whole accepted set, byte-identical to the committed files, and a contract test enforces that. A key update adds the new key and keeps every key whose log ID is still accepted; a rotation SHALL NOT drop a key that an accepted receipt names.

#### Scenario: Image copy drifts from the committed key
- **GIVEN** a Rekor key shipped in the web-ng image differs from its file in `docs/sigstore/rekor-keys/`, or a committed key is missing from the image
- **WHEN** the contract tests run
- **THEN** the test SHALL fail

#### Scenario: Receipt under a rotated-out signing log
- **GIVEN** a receipt whose log ID names a Rekor key that the signer no longer writes to but that is still accepted
- **WHEN** a web-ng release that follows the rotation verifies it
- **THEN** the key for that log ID SHALL still be in the shipped key set
- **AND** the receipt SHALL verify

#### Scenario: The self-hosted log serves a different key
- **GIVEN** the self-hosted log's `GET /api/v1/log/publicKey` returns a key other than `docs/sigstore/rekor.pub`
- **WHEN** the monitor runs
- **THEN** it SHALL raise a signing-monitor alert naming the change

### Requirement: Signing ledger
Every run of a release-key signing workflow SHALL record each signature in a signing ledger before it uploads the signature to the transparency log.
A ledger line holds the payload SHA-256, the subject, the workflow, the run ID and attempt, and the time. A second line adds the log index and entry UUID once the upload returns. For a digest whose existing signature is reused, the ledger SHALL record that the signature was reused, so the ledger states for every digest in the run whether its signature was created or reused. The ledger is kept as a workflow artifact for at least 90 days whether or not the run succeeds, and for tag runs it is also attached to the GitHub release. The release-key signing workflows are every workflow that signs with the release key, including `release.yml`, `publish-oci.yml`, `wasm-plugins.yml`, `native-addons.yml` and `external-wasm-plugin.yml`.

#### Scenario: Run fails after the upload
- **GIVEN** a signing run whose transparency-log upload succeeded and which then failed
- **WHEN** the run ends
- **THEN** the ledger artifact SHALL still be uploaded
- **AND** it SHALL contain the payload SHA-256 of the logged signature

### Requirement: Transparency-log monitoring for the release key
A scheduled GitHub Actions workflow on `arc-runner-set` SHALL run the project-owned scanner `build/ci/rekor_signing_monitor.py` every hour; each run SHALL read every entry of the self-hosted Rekor v1 log, recompute the RFC 6962 root and check it against the log's signed tree head verified under `docs/sigstore/rekor.pub`, require the previous checkpoint (kept as a workflow artifact) to be a prefix of the log (only a manual `bootstrap=true` dispatch while no checkpoint exists is exempt from this prefix check; a bootstrap dispatch while a checkpoint exists still applies it), check the served key, and select and judge every entry in the whole log signed by the release public key, including entries integrated before the first checkpoint. The first checkpoint SHALL be seeded only by an explicit manual `workflow_dispatch` with input `bootstrap=true`, reviewed by a person; the bootstrap run verifies the signed tree head under the pinned key, checks the served key, judges every release-key entry in the whole log and writes the first checkpoint only when the run succeeds (log reachable, tree head verifies, root matches, configuration valid). Every run other than a `bootstrap=true` dispatch, scheduled or manual, SHALL fail, alert and not replace the checkpoint when it finds no checkpoint artifact, a stored checkpoint that is not a prefix of the log, a signed tree head that does not verify under `docs/sigstore/rekor.pub`, or a recomputed root that does not match it. A bootstrap run SHALL likewise fail, alert and not write a checkpoint when the log is unreachable, the tree head does not verify, the root does not match, the configuration is invalid, or an existing checkpoint is not a prefix; every failed run, bootstrap included, writes no checkpoint. The monitor SHALL keep each entry's decision (explained with its reason, or reported) and the first checkpoint's integrated time in its checkpoint state. The checkpoint artifact SHALL be retained 90 days, as long as the signing ledgers, and every successful run SHALL replace it, carrying that state forward, so it expires only if the monitor stops for 90 days. An entry explained by a ledger SHALL stay explained after that run and its ledger artifact age out.
It SHALL alert on every matching entry that is not explained. An entry is pending while a run of any release-key signing workflow that was active at the entry's integrated time is in progress; the monitor SHALL NOT alert on a pending entry and SHALL evaluate it after those runs end. An entry is explained when it is a `hashedrekord` whose payload hash appears in a published signing ledger of one of those runs, when it is listed in the committed acknowledged-entries file, or when the monitor's checkpoint state already records it as explained by a ledger match found by an earlier run. An acknowledgement explains an entry only while the acknowledged-entries file lists it; the monitor SHALL re-evaluate acknowledged entries on every run, so a retracted acknowledgement restores detection. Once those runs have ended, an entry that is explained by none of these is unexplained. An alert opens one GitHub issue labelled `security` and `signing-monitor` per entry UUID and posts to the configured Discord webhook. When a later scan finds the entry explained, the monitor SHALL close that issue. An unexplained entry is reported within about one scan interval after it becomes decidable, that is, after every release-key signing run active at its integrated time has ended; for an entry that overlaps a long release run the worst case is the remaining run time plus one scan interval. The blindness canary alerts on a ledgered entry still unseen two scan intervals after its signing run ended, and the monitor is reported stale when its last successful run is older than three scan intervals.

#### Scenario: Signature made outside the signing workflows
- **GIVEN** a Rekor v1 entry signed by the release key whose payload hash is in no signing ledger and not acknowledged
- **AND** the entry is not recorded as explained by a ledger match in the monitor's checkpoint state
- **AND** no release-key signing run that was active at the entry's integrated time is still in progress
- **WHEN** the monitor scans the log past that entry
- **THEN** the monitor SHALL open a GitHub issue for the entry UUID
- **AND** SHALL post an alert to Discord

#### Scenario: Entry from a signing run still in progress
- **GIVEN** a Rekor v1 entry signed by the release key during a release-key signing run that has not yet ended and has not yet published its ledger
- **WHEN** the monitor scans the log past that entry
- **THEN** the monitor SHALL NOT raise an alert for the entry
- **AND** SHALL evaluate the entry against that run's ledger after the run ends

#### Scenario: Entry explained after its issue was opened
- **GIVEN** an open signing-monitor issue for an entry UUID
- **WHEN** a later scan finds the entry explained by a published ledger or the acknowledged-entries file
- **THEN** the monitor SHALL close that issue

#### Scenario: Retried upload of the same payload
- **GIVEN** two Rekor entries for the same payload hash, created by retries within one ledgered signing run
- **WHEN** the monitor scans them
- **THEN** both entries SHALL be treated as explained
- **AND** no alert SHALL be raised

#### Scenario: Monitor run fails
- **GIVEN** a monitor run, `bootstrap=true` dispatch included, that cannot reach the log, has an invalid configuration, gets a signed tree head that does not verify under `docs/sigstore/rekor.pub`, or recomputes a root that does not match it
- **OR** a monitor run, scheduled or manually dispatched and including a `bootstrap=true` dispatch, that finds a stored checkpoint that is not a prefix of the log
- **OR** a monitor run other than a `bootstrap=true` dispatch that finds no checkpoint artifact
- **WHEN** the run ends
- **THEN** the workflow SHALL fail
- **AND** an alert SHALL be raised
- **AND** the run SHALL NOT write any checkpoint, so a stored checkpoint is kept

#### Scenario: Bootstrap seeds the first checkpoint
- **GIVEN** no checkpoint artifact exists yet
- **AND** the log is reachable, its signed tree head verifies under the pinned key, the recomputed root matches it, and the configuration is valid
- **WHEN** a person dispatches the monitor workflow with `bootstrap=true`
- **THEN** the run SHALL verify the signed tree head under the pinned key and judge every release-key entry in the whole log
- **AND** SHALL write the first checkpoint

#### Scenario: Unexplained entry from before the first checkpoint
- **GIVEN** a release-key entry integrated before the monitor's first checkpoint whose payload hash is in no signing ledger and that is not acknowledged
- **AND** the entry is not recorded as explained by a ledger match in the monitor's checkpoint state
- **AND** no release-key signing run that was active at the entry's integrated time is still in progress
- **WHEN** the monitor runs
- **THEN** the monitor SHALL raise an alert for that entry

#### Scenario: Explaining ledger ages out
- **GIVEN** an entry the monitor recorded as explained by a signing ledger
- **WHEN** that run and its ledger artifact age out of the lookback
- **THEN** the entry SHALL stay explained
- **AND** no alert SHALL be raised for it

#### Scenario: Monitor stops running
- **GIVEN** the monitor's last successful GitHub Actions run is older than three scan intervals (three hours at the hourly default)
- **WHEN** the scheduled job watch runs
- **THEN** it SHALL find that run through a GitHub Actions workflow-run lookup, not a BuildBuddy commit status
- **AND** it SHALL report the monitor as stale to Discord

#### Scenario: Monitor is blind to its own signatures
- **GIVEN** a ledger line with a log index from a signing run that ended more than two scan intervals ago (two hours at the hourly default)
- **AND** the entry was integrated after the first checkpoint's integrated time recorded in monitor state
- **AND** the monitor has not observed that entry as a match
- **WHEN** the monitor runs
- **THEN** it SHALL raise an alert that the monitor or the receipt is broken

#### Scenario: Ledgered entry from before the monitor's first checkpoint
- **GIVEN** a ledger line whose entry was integrated before the first checkpoint's integrated time recorded in monitor state
- **WHEN** the monitor runs
- **THEN** the blindness canary SHALL NOT raise an alert for that line

### Requirement: Signer and verifier Cosign versions move together
The Cosign version installed by the release signer and the Cosign version shipped in the web-ng image SHALL be the same release, and that release SHALL include the fixes for GHSA-whqx-f9j3-ch6m and GHSA-fx35-mq7g-6g98.

#### Scenario: Versions diverge
- **GIVEN** `scripts/install-cosign.sh` and the web-ng image Cosign archive name different versions
- **WHEN** the contract tests run
- **THEN** the test SHALL fail

### Requirement: Admission trusts the pinned self-hosted log offline
The demo Kyverno image-verification policy SHALL verify a receipt from the self-hosted log offline against the pinned self-hosted Rekor key (`rekor.pubkey`), and SHALL NOT trust that log through TUF or an online lookup.
The receipt entry is a `keys` attestor with the release key, `rekor.pubkey` set to `docs/sigstore/rekor.pub`, `ignoreTlog: false`, and no `rekor.url`. In Kyverno v1.17.1 an unset `url` defaults to `https://rekor.sigstore.dev` (CRD default) and there is no offline switch, so an image without a receipt makes the receipt entry do an online public-good lookup; that lookup cannot pass the receipt entry, which verifies only against the pinned self-hosted key, so no admission call reaches the self-hosted Rekor. Until every image admitted in demo carries a self-hosted receipt, the policy keeps a transition entry with today's public-good configuration and its online lookups, and an image passes when either entry verifies (`count: 1`). The transition entry SHALL then be removed, after a check of the running images rather than an assumption (an unchanged digest such as `serviceradar-cnpg` keeps its pre-cutover signature until rebuilt); after that no admitted image causes any Rekor lookup. The policy SHALL NOT use `ignoreTlog: true`. The policy change SHALL be live on demo before the cutover release, the first release built from a commit containing the signer change, is cut; a `carverauto/gitops` PR implementing it is drafted with this change, and a person merges and applies it.

#### Scenario: Cutover-release image at admission
- **GIVEN** an image whose classic signature carries a receipt from the self-hosted log
- **WHEN** a demo pod using it is admitted
- **THEN** Kyverno SHALL verify the receipt offline with the pinned key
- **AND** SHALL NOT make a Rekor lookup for it

#### Scenario: Cutover release cut before the policy change
- **GIVEN** the amended Kyverno policy is not yet live on demo
- **WHEN** the cutover release is about to be cut
- **THEN** the cutover release SHALL NOT be cut until the policy change is live on demo

#### Scenario: Release-key signature in the self-hosted log without a bundled receipt
- **GIVEN** an image whose release-key signature was uploaded to the self-hosted log but whose `.sig` layer has no receipt annotation and which has no public-good log entry
- **WHEN** a demo pod using it is admitted
- **THEN** admission SHALL be denied
- **AND** no request SHALL reach the self-hosted Rekor

#### Scenario: Image logged nowhere
- **GIVEN** an image signed with the release key whose signature has no receipt and no public-good log entry
- **WHEN** a demo pod using it is admitted
- **THEN** admission SHALL be denied

### Requirement: OpenBao audit log as the second line
ServiceRadar's OpenBao SHALL have an audit device, enabled by the operator, and a scheduled watch SHALL report every `transit/sign/cosign-release` request that is not explained. A request is explained only by a `sign` line holding its input hash in a ledger of a release-key signing run that was active at the request's time; a ledger of any other run does not explain it. A request is pending while a release-key signing run that was active at its time is still in progress; the watch SHALL NOT alert on a pending request. Once those runs have ended the request is decided: explained if a ledger of one of them holds its input hash, otherwise alerted. The watch SHALL keep a position in its own state that advances only past decided records, and SHALL never re-examine a decided record, so a sign call decided while its ledger was retained is not re-examined after the ledger ages out.
The self-hosted Rekor signs with a Transit key in the same OpenBao as `cosign-release`, so a receipt can be forged without a log entry; the audit log records the signing call regardless. OpenBao refuses requests when no enabled audit device can write, so the device's sink is monitored for capacity. Agents do not enable the audit device.

#### Scenario: Release-key signing outside the signing runs
- **GIVEN** an audit record of a `transit/sign/cosign-release` request whose input hash matches no `sign` line in a ledger of a release-key signing run active at the request's time
- **AND** no release-key signing run that was active at the request's time is still in progress
- **WHEN** the audit watch runs
- **THEN** it SHALL raise a signing-monitor alert for that request

#### Scenario: Re-signing a previously ledgered payload outside a run
- **GIVEN** a release-key signing run that published a `sign` line for payload hash H and has ended
- **AND** a later `transit/sign/cosign-release` request for H made while no release-key signing run is active
- **WHEN** the audit watch runs
- **THEN** the earlier run's ledger SHALL NOT explain the request
- **AND** the watch SHALL raise a signing-monitor alert for it

### Requirement: Release key cannot leave OpenBao
The OpenBao Transit key `cosign-release` SHALL have `exportable=false` and `allow_plaintext_backup=false`, verified by an operator with `bao read transit/keys/cosign-release` and recorded in `docs/sigstore/README.md`.

#### Scenario: Key export enabled
- **GIVEN** `bao read transit/keys/cosign-release` shows `exportable=true` or `allow_plaintext_backup=true`
- **WHEN** the operator check runs
- **THEN** the release signing setup SHALL be treated as compromised-capable and signing SHALL stop until the key is replaced
