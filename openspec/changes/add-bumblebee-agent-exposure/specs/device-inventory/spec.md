## ADDED Requirements
### Requirement: Bumblebee Posture Associates With Canonical Devices
The system SHALL associate Bumblebee scan posture and findings with the canonical device record for the reporting agent. Current posture and active findings SHALL be keyed by canonical device UID and agent ID, while preserving scanner run, catalog snapshot, and coverage provenance.

#### Scenario: Agent finding links to device record
- **GIVEN** an agent is registered to a canonical device UID
- **WHEN** the agent reports Bumblebee findings from a completed scan
- **THEN** the system SHALL persist current Bumblebee posture linked to that device UID
- **AND** the posture SHALL also retain the reporting agent ID and scan run ID

#### Scenario: Agent report precedes device association
- **GIVEN** a Bumblebee scan report arrives for an agent without a resolved canonical device UID
- **WHEN** the report is ingested
- **THEN** the system SHALL store the posture as agent-scoped pending state
- **AND** backfill the device UID when the agent-to-device association becomes available

#### Scenario: Existing source risk remains explainable
- **GIVEN** a device has risk data from another source system
- **WHEN** Bumblebee posture is computed for the device
- **THEN** the Bumblebee risk score SHALL be stored as source-specific posture
- **AND** the system SHALL preserve unrelated source-specific risk fields for explainability

### Requirement: Bumblebee Contributes To Composite Device Risk
The system SHALL feed active Bumblebee posture into the device composite risk calculation as an explainable source-specific risk contribution. The composite risk result SHALL preserve contribution provenance so operators can see how Bumblebee findings affected the overall device risk.

#### Scenario: Active findings raise composite risk
- **GIVEN** a device has active Bumblebee findings with catalog severities
- **WHEN** composite device risk is calculated
- **THEN** the Bumblebee contribution SHALL be included in the composite risk inputs
- **AND** the final risk score SHALL expose Bumblebee as a contributing source with contribution score, highest severity, active finding count, catalog snapshot ID, and catalog content hash

#### Scenario: Resolved findings lower contribution
- **GIVEN** a device previously had active Bumblebee findings contributing to composite risk
- **WHEN** a completed scan resolves those findings
- **THEN** the Bumblebee contribution SHALL be reduced or removed according to the composite risk rules
- **AND** the composite risk result SHALL retain historical posture provenance for audit

#### Scenario: Partial coverage avoids false risk reduction
- **GIVEN** a device has active Bumblebee findings
- **WHEN** a later Bumblebee scan completes with partial coverage and does not see those findings
- **THEN** the system SHALL NOT lower the Bumblebee composite risk contribution solely because the partial scan omitted the findings
- **AND** the contribution SHALL remain explainable as stale or coverage-limited until a full or policy-sufficient scan resolves it

### Requirement: Composite Risk Prevents Source Clobbering
The device inventory risk score shown in `/devices` and device details SHALL be derived from active source-specific risk contributions rather than overwritten directly by any single ingestion source. Each source SHALL update only its own contribution, and the composite reducer SHALL publish the inventory-visible `risk_score` and `risk_level`.

#### Scenario: Bumblebee raises risk above Armis
- **GIVEN** Armis has contributed risk score 35 for a device
- **AND** Bumblebee contributes active risk score 85 for the same canonical device UID
- **WHEN** composite risk is recalculated
- **THEN** the inventory-visible device risk score SHALL reflect the higher active Bumblebee contribution according to the reducer policy
- **AND** the risk explanation SHALL show both Armis and Bumblebee contribution provenance

#### Scenario: Later Armis update cannot clobber higher Bumblebee risk
- **GIVEN** a device has an active Bumblebee contribution of 85
- **AND** the inventory-visible composite risk score is 85
- **WHEN** a later Armis ingestion updates the Armis contribution to 20
- **THEN** the inventory-visible composite risk score SHALL remain 85
- **AND** the Armis update SHALL NOT overwrite the Bumblebee contribution or final composite score

#### Scenario: Composite risk lowers only when highest active contribution resolves
- **GIVEN** Bumblebee is the highest active contribution for a device
- **WHEN** a full or policy-sufficient Bumblebee scan resolves the active findings
- **THEN** the Bumblebee contribution SHALL be reduced or removed
- **AND** the composite risk score MAY lower to the next highest active contribution
- **AND** the risk explanation SHALL retain historical Bumblebee provenance for audit

#### Scenario: Source-specific write preserves reducer boundary
- **GIVEN** an ingestion source receives new device risk data
- **WHEN** it writes risk state
- **THEN** it SHALL write to that source's risk contribution record
- **AND** it SHALL NOT directly replace the inventory-visible composite `risk_score` with a lower source value

### Requirement: Composite Risk Auditability
The system SHALL use AshPaperTrail for auditable composite risk configuration and source contribution lifecycle state where control-plane actions can change the inventory-visible risk score. The audit trail SHALL preserve actor or system-job provenance without versioning every high-volume finding ingest row.

#### Scenario: Risk policy change is versioned
- **GIVEN** an authorized operator changes the composite risk reducer policy
- **WHEN** the policy is saved
- **THEN** AshPaperTrail SHALL record the prior policy, new policy, actor, action name, and action inputs

#### Scenario: Bumblebee contribution lifecycle is explainable
- **GIVEN** Bumblebee findings create, update, or resolve a source risk contribution
- **WHEN** the contribution lifecycle state changes
- **THEN** the system SHALL retain contribution provenance including source, score, reason, catalog snapshot, and scan run
- **AND** AshPaperTrail SHALL be used for contribution resources when they are represented as Ash-managed lifecycle records

### Requirement: Bumblebee Coverage State
The system SHALL persist Bumblebee scan coverage state for each current posture so operators can distinguish clean scans from unscanned or partially scanned devices.

#### Scenario: Full coverage is recorded
- **GIVEN** the scanner service successfully scans every eligible configured root
- **WHEN** the scan summary is ingested
- **THEN** the device posture SHALL record coverage state as full
- **AND** include attempted root count, scanned root count, skipped root count, and `/root` coverage status

#### Scenario: Partial coverage is recorded
- **GIVEN** the scanner service skips one or more configured roots due to permissions, policy, timeout, or errors
- **WHEN** the scan summary is ingested
- **THEN** the device posture SHALL record coverage state as partial
- **AND** include bounded skipped-root reasons for operator review

#### Scenario: Never scanned is distinct from zero findings
- **GIVEN** a device has no completed Bumblebee scan
- **WHEN** device posture is requested
- **THEN** the system SHALL report Bumblebee state as not scanned
- **AND** SHALL NOT treat the device as having zero exposure risk
