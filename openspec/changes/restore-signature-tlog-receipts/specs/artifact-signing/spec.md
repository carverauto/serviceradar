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
The release signer SHALL upload signatures to the pinned public-good Rekor v1 log through Cosign's legacy upload path, and SHALL NOT take the log location from a TUF-delivered signing configuration.

#### Scenario: Signing configuration names a different log
- **GIVEN** the public Sigstore signing configuration lists a transparency log other than the pinned Rekor v1 log
- **WHEN** the release signer signs an artifact
- **THEN** the entry SHALL be written to the pinned Rekor v1 log

### Requirement: Release verification requires the receipt offline
The repository release verification for images, native add-ons and Wasm plugins SHALL verify the embedded receipt of every signature created in the run against the pinned Rekor public key without contacting any Sigstore service.
A missing or invalid receipt on a signature created in the run fails the release before promotion. A signature reused from before the cutover release, for an image, a native add-on or a Wasm plugin, carries no receipt and SHALL be exempt from the receipt check; it is verified with the release key alone. Kyverno remains the admission gate for images, and release verification does not consult the import allowlist.

#### Scenario: Signature created without a receipt
- **GIVEN** a signature created in the current release run whose `.sig` layer has no receipt
- **WHEN** release verification runs
- **THEN** verification SHALL fail
- **AND** the artifact SHALL NOT be promoted

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
The repository SHALL hold the full set of accepted Rekor v1 public keys in `docs/sigstore/rekor-keys/`, one file per accepted log ID, taken from Sigstore's TUF-signed trusted root, and the key of the log the signer currently writes to in `docs/sigstore/rekor.pub`.
The web-ng image ships the whole set, byte-identical to the committed files, and a contract test enforces that. A key update adds the new key and keeps every key whose log ID is still accepted; a rotation SHALL NOT drop a key that an accepted receipt names.

#### Scenario: Image copy drifts from the committed key
- **GIVEN** a Rekor key shipped in the web-ng image differs from its file in `docs/sigstore/rekor-keys/`, or a committed key is missing from the image
- **WHEN** the contract tests run
- **THEN** the test SHALL fail

#### Scenario: Receipt under a rotated-out signing log
- **GIVEN** a receipt whose log ID names a Rekor key that the signer no longer writes to but that is still accepted
- **WHEN** a web-ng release that follows the rotation verifies it
- **THEN** the key for that log ID SHALL still be in the shipped key set
- **AND** the receipt SHALL verify

#### Scenario: Sigstore changes the Rekor v1 key set
- **GIVEN** the published public-good trusted root adds a Rekor v1 key, removes the pinned key, or sets an end date on the pinned key
- **WHEN** the daily trusted-root check runs
- **THEN** it SHALL raise a signing-monitor alert naming the change

### Requirement: Signing ledger
Every run of a release-key signing workflow SHALL record each signature in a signing ledger before it uploads the signature to the transparency log.
A ledger line holds the payload SHA-256, the subject, the workflow, the run ID and attempt, and the time. A second line adds the log index and entry UUID once the upload returns. The ledger is kept as a workflow artifact for at least 90 days whether or not the run succeeds, and for tag runs it is also attached to the GitHub release. The release-key signing workflows are every workflow that signs with the release key, including `release.yml`, `publish-oci.yml`, `wasm-plugins.yml`, `native-addons.yml` and `external-wasm-plugin.yml`.

#### Scenario: Run fails after the upload
- **GIVEN** a signing run whose transparency-log upload succeeded and which then failed
- **WHEN** the run ends
- **THEN** the ledger artifact SHALL still be uploaded
- **AND** it SHALL contain the payload SHA-256 of the logged signature

### Requirement: Transparency-log monitoring for the release key
A scheduled GitHub Actions workflow on `arc-runner-set` SHALL scan every new public-good Rekor v1 entry for the release public key's fingerprint at a configured scan interval, verifying log consistency between checkpoints. The scan interval is one hour unless a measured scan cost forces a longer one.
It SHALL alert on every matching entry that is not explained. An entry is explained when it is a `hashedrekord` whose payload hash appears in a signing ledger that a run of any release-key signing workflow active at the entry's integrated time has published or will publish, or when it is listed in the committed acknowledged-entries file. While such a run is still in progress, the monitor SHALL NOT alert on the entry and SHALL evaluate it after the run ends. An alert opens one GitHub issue labelled `security` and `signing-monitor` per entry UUID and posts to the configured Discord webhook. When a later scan finds the entry explained, the monitor SHALL close that issue. An unexplained entry is reported within about one scan interval. The blindness canary alerts on a ledgered entry still unseen two scan intervals after its signing run ended, and the monitor is reported stale when its last successful run is older than three scan intervals.

#### Scenario: Signature made outside the signing workflows
- **GIVEN** a Rekor v1 entry signed by the release key whose payload hash is in no signing ledger and not acknowledged
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
- **GIVEN** a monitor run that cannot reach the log, finds the log inconsistent with its stored checkpoint, or has lost its checkpoint
- **WHEN** the run ends
- **THEN** the workflow SHALL fail
- **AND** an alert SHALL be raised

#### Scenario: Monitor stops running
- **GIVEN** the monitor's last successful GitHub Actions run is older than three scan intervals (three hours at the hourly default)
- **WHEN** the scheduled job watch runs
- **THEN** it SHALL find that run through a GitHub Actions workflow-run lookup, not a BuildBuddy commit status
- **AND** it SHALL report the monitor as stale to Discord

#### Scenario: Monitor is blind to its own signatures
- **GIVEN** a ledger line with a log index from a signing run that ended more than two scan intervals ago (two hours at the hourly default)
- **AND** the entry was integrated after the monitor's first retained checkpoint
- **AND** the monitor has not observed that entry as a match
- **WHEN** the monitor runs
- **THEN** it SHALL raise an alert that the monitor or the receipt is broken

#### Scenario: Ledgered entry from before the monitor's first checkpoint
- **GIVEN** a ledger line whose entry was integrated before the monitor's first retained checkpoint
- **WHEN** the monitor runs
- **THEN** the blindness canary SHALL NOT raise an alert for that line

### Requirement: Signer and verifier Cosign versions move together
The Cosign version installed by the release signer and the Cosign version shipped in the web-ng image SHALL be the same release, and that release SHALL include the fixes for GHSA-whqx-f9j3-ch6m and GHSA-fx35-mq7g-6g98.

#### Scenario: Versions diverge
- **GIVEN** `scripts/install-cosign.sh` and the web-ng image Cosign archive name different versions
- **WHEN** the contract tests run
- **THEN** the test SHALL fail
