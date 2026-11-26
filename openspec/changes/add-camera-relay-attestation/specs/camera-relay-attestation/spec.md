## ADDED Requirements

### Requirement: Opt-in relay attestation in the shared uploader
When `camera_relay_attestation.enabled` is set in its configuration, the agent SHALL hash every access unit that passes through the shared camera relay uploader. This applies to sources from both native readers and Wasm streaming plugins. Attestation MUST be off by default.

#### Scenario: Wasm-sourced stream
- **WHEN** attestation is enabled, and a Wasm streaming plugin writes media through `camera_media_write`
- **THEN** that stream's access units are hashed and included in attestations, with no change to the plugin

### Requirement: Normalized access-unit hashing
The agent SHALL compute each access unit's hash over its video-coding-layer NAL units only: H.264 types 1-5 and H.265 types 0-31. Each NAL unit is hashed as received, without start codes or length prefixes, under the `sr-au-v1` construction. The agent SHALL chain the hashes per stream. The repository MUST publish golden test vectors for H.264 and H.265, Annex B and AVCC input, and B-frame ordering.

#### Scenario: Parameter sets changed downstream
- **WHEN** a recorder rewrites SPS, PPS or SEI units but leaves the VCL NAL units unchanged
- **THEN** the access-unit hashes computed from the recorded media equal those in the attestation

### Requirement: Interval attestations signed by a hardware key
Every interval (10 seconds by default, configurable from 5 to 60) the agent SHALL produce one `serviceradar.relay_attestation.v1` record, signed as a DSSE envelope by its hardware signer. The record MUST contain:
- the signer key ID and agent ID;
- a monotonic `seq` and the previous attestation digest;
- the interval's wall-clock bounds;
- each stream's identifiers, first and last PTS, access-unit count and chain head;
- an RFC 6962 Merkle root over the interval's access-unit hashes.

#### Scenario: Many cameras
- **WHEN** one agent relays 250 streams
- **THEN** it makes exactly one hardware signature per interval, covering all 250 streams

### Requirement: Hardware-only signer
The signing key SHALL be a non-exportable ECDSA P-256 key. It MUST be created in a TPM 2.0 (physical, firmware or virtual) by default, or on a YubiKey (PIV) or YubiHSM 2. The agent MUST NOT use a software key. It MUST NOT expose any host function that lets plugins request signatures. It MUST sign only attestation records it builds itself.

#### Scenario: No hardware available
- **WHEN** attestation is enabled on a host with no TPM and no supported security key
- **THEN** the status is `unavailable`, no attestations are produced, and relaying continues unchanged

### Requirement: Signer announcement with hardware evidence
The agent SHALL publish a `serviceradar.relay_signer.v1` announcement when a signer key is created or rotated. The announcement MUST contain the public key, key ID and device type. For a TPM it MUST also include the endorsement-key certificate chain, the attestation key public part, and `TPM2_Certify` evidence for the signing key. For a YubiKey or YubiHSM it MUST include the device attestation certificate chain.

#### Scenario: TPM signer created
- **WHEN** the agent creates its TPM signing key
- **THEN** an announcement with the EK certificate chain and certify evidence is published before the first attestation that uses the key

### Requirement: Publication without modification
Attestations and announcements SHALL travel over the existing agent uplink. Core MUST publish them unmodified on `camera.recording.relay_attestations.v1` and `camera.recording.relay_signers.v1` in `CAMERA_RECORDING_EVENTS`, with `Nats-Msg-Id` `<signer_key_id>:<seq>`. The agent MUST buffer unsent records on disk, for 24 hours by default, while the uplink is down.

#### Scenario: Uplink outage
- **WHEN** the agent's uplink is down for 2 hours
- **THEN** the buffered attestations are published in `seq` order once it returns, and none are duplicated

### Requirement: Attestation never blocks relaying
Attestation failures SHALL NOT drop, delay or alter relayed media, and SHALL NOT cause relay errors. Signing MUST run asynchronously. When the bounded signing queue overflows, the oldest intervals MUST be published marked `unsigned`.

#### Scenario: Signer stalls
- **WHEN** the TPM stops responding for 5 minutes
- **THEN** relaying continues, the status becomes `degraded`, and the affected intervals are published as `unsigned` once the queue overflows

### Requirement: Attestation status reporting
The agent SHALL report a relay attestation status of `disabled`, `active`, `degraded` or `unavailable`, with a reason and its last signed `seq`, in agent health. Each status transition MUST also be emitted as a `health.state_change` event.

#### Scenario: Signer lost
- **WHEN** the YubiKey used as the signer is removed
- **THEN** the status changes to `unavailable` with reason `signer_missing`, and a `health.state_change` event is emitted
