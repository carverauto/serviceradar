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
A missing or invalid receipt on a signature created in the run fails the release before promotion.

#### Scenario: Signature created without a receipt
- **GIVEN** a signature created in the current release run whose `.sig` layer has no receipt
- **WHEN** release verification runs
- **THEN** verification SHALL fail
- **AND** the artifact SHALL NOT be promoted

#### Scenario: Receipt for a different entry
- **GIVEN** a `.sig` layer whose receipt carries a valid SignedEntryTimestamp for a log entry that names a different signature, key or payload hash
- **WHEN** release verification runs
- **THEN** verification SHALL fail

### Requirement: Pinned Rekor public key
The repository SHALL hold the accepted Rekor v1 public key or keys in `docs/sigstore/rekor.pub`, taken from Sigstore's TUF-signed trusted root.
The copy shipped in the web-ng image is byte-identical to it, and a contract test enforces that.

#### Scenario: Image copy drifts from the committed key
- **GIVEN** the Rekor key shipped in the web-ng image differs from `docs/sigstore/rekor.pub`
- **WHEN** the contract tests run
- **THEN** the test SHALL fail

#### Scenario: Sigstore changes the Rekor v1 key set
- **GIVEN** the published public-good trusted root adds a Rekor v1 key, removes the pinned key, or sets an end date on the pinned key
- **WHEN** the daily trusted-root check runs
- **THEN** it SHALL raise a signing-monitor alert naming the change

### Requirement: Signing ledger
Every workflow run that signs with the release key SHALL record each signature in a signing ledger before it uploads the signature to the transparency log.
A ledger line holds the payload SHA-256, the subject, the workflow, the run ID and attempt, and the time. A second line adds the log index and entry UUID once the upload returns. The ledger is kept as a workflow artifact for at least 90 days whether or not the run succeeds, and for tag runs it is also attached to the GitHub release.

#### Scenario: Run fails after the upload
- **GIVEN** a signing run whose transparency-log upload succeeded and which then failed
- **WHEN** the run ends
- **THEN** the ledger artifact SHALL still be uploaded
- **AND** it SHALL contain the payload SHA-256 of the logged signature

### Requirement: Transparency-log monitoring for the release key
A scheduled GitHub Actions workflow on `arc-runner-set` SHALL scan every new public-good Rekor v1 entry for the release public key's fingerprint at least every hour, verifying log consistency between checkpoints.
It SHALL alert on every matching entry that is not explained. An entry is explained when it is a `hashedrekord` whose payload hash appears in the signing ledger of a run of a repository signing workflow active at the entry's integrated time, or when it is listed in the committed acknowledged-entries file. An alert opens one GitHub issue labelled `security` and `signing-monitor` per entry UUID and posts to the configured Discord webhook.

#### Scenario: Signature made outside the signing workflows
- **GIVEN** a Rekor v1 entry signed by the release key whose payload hash is in no signing ledger and not acknowledged
- **WHEN** the monitor scans the log past that entry
- **THEN** the monitor SHALL open a GitHub issue for the entry UUID
- **AND** SHALL post an alert to Discord

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
- **GIVEN** the monitor's last successful run is more than three hours old
- **WHEN** the scheduled job watch runs
- **THEN** it SHALL report the monitor as stale to Discord

#### Scenario: Monitor is blind to its own signatures
- **GIVEN** a ledger line with a log index from a signing run that ended more than two hours ago
- **AND** the monitor has not observed that entry as a match
- **WHEN** the monitor runs
- **THEN** it SHALL raise an alert that the monitor or the receipt is broken

### Requirement: Signer and verifier Cosign versions move together
The Cosign version installed by the release signer and the Cosign version shipped in the web-ng image SHALL be the same release, and that release SHALL include the fixes for GHSA-whqx-f9j3-ch6m and GHSA-fx35-mq7g-6g98.

#### Scenario: Versions diverge
- **GIVEN** `scripts/install-cosign.sh` and the web-ng image Cosign archive name different versions
- **WHEN** the contract tests run
- **THEN** the test SHALL fail
