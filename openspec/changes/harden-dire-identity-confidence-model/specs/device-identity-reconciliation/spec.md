## ADDED Requirements

### Requirement: Evidence-First Identity Resolution
The system SHALL treat discovery-time observations (for example interface MACs, neighbor hints, and single-sighting aliases) as identity evidence, not canonical identifiers, until promotion criteria are met.

#### Scenario: Interface MAC remains evidence until promoted
- **GIVEN** mapper discovers interface MAC `0CEA1432D277` for a device
- **WHEN** the evidence has not met promotion criteria
- **THEN** the MAC SHALL be stored as evidence only
- **AND** it SHALL NOT be used as a canonical identifier for automatic merge decisions

### Requirement: Promotion Requires Corroboration
The system SHALL promote weak or medium-confidence evidence into canonical identity only after corroboration and repeated sightings according to configured thresholds.

#### Scenario: Single weak sighting is not promoted
- **GIVEN** a device has one interface-derived MAC observation and no corroborating strong signal
- **WHEN** DIRE evaluates promotion eligibility
- **THEN** the observation SHALL remain unpromoted evidence
- **AND** canonical identity SHALL remain unchanged

#### Scenario: Corroborated evidence is promoted
- **GIVEN** evidence is observed repeatedly and corroborated by an independent stable signal
- **WHEN** DIRE evaluates promotion eligibility
- **THEN** DIRE SHALL promote that evidence to canonical identity according to policy

### Requirement: MAC-Only Conflict Merge Safety
The system SHALL NOT automatically merge devices when the shared conflict set contains only MAC evidence.

#### Scenario: Globally-administered MAC-only conflict is blocked
- **GIVEN** two devices share MAC `001122334455`
- **AND** no non-MAC strong identifier links them
- **WHEN** DIRE evaluates a merge
- **THEN** DIRE SHALL block automatic merge
- **AND** retain separate canonical devices

### Requirement: Deterministic Identity Under Ingestion Reordering
The system SHALL produce the same canonical identity outcome for equivalent evidence sets regardless of ingestion order.

#### Scenario: Reordered mapper payloads produce same canonical device
- **GIVEN** two mapper runs report the same interfaces in different orders
- **WHEN** DIRE processes both runs
- **THEN** canonical device IDs and merge outcomes SHALL be identical

### Requirement: Identity Regression Matrix Coverage
The system SHALL maintain an automated regression matrix that covers merge eligibility, evidence promotion, ingestion order invariance, and known historical regressions.

#### Scenario: Historical regression class remains protected
- **GIVEN** a test fixture representing the farm01/tonka01-style conflict pattern
- **WHEN** the full identity regression suite executes
- **THEN** no destructive merge or identity flip-flop SHALL occur

## MODIFIED Requirements

### Requirement: Interface MAC Registration
The system SHALL ingest interface MAC observations for a device within the device's partition as **evidence only** by default. The polling agent's identity MUST NOT be included in interface-derived identity processing. Interface-derived MAC evidence SHALL require promotion criteria before being treated as canonical identity.

#### Scenario: Interface MAC observation is ingested without canonical promotion
- **GIVEN** a mapper or sweep update includes interface MAC addresses for a device
- **WHEN** DIRE ingests the update
- **THEN** the interface MAC observations SHALL be recorded as evidence
- **AND** they SHALL NOT be immediately inserted as canonical device identifiers
- **AND** the polling agent's `agent_id` SHALL NOT be attached to the observed device identity

#### Scenario: Promoted interface MAC evidence can influence canonical resolution
- **GIVEN** interface MAC evidence has met promotion criteria
- **WHEN** DIRE re-evaluates canonical identity
- **THEN** the promoted evidence MAY participate in canonical resolution according to merge policy

### Requirement: Locally-Administered MAC Classification
The system SHALL classify MAC addresses using the IEEE local-administered bit and retain confidence labels, but SHALL NOT use MAC-only conflicts (local or global) as sufficient grounds for automatic merges.

#### Scenario: Locally-administered MAC conflict remains non-mergeable
- **GIVEN** two devices share locally-administered MAC `0EEA1432D278`
- **WHEN** DIRE evaluates merge eligibility
- **THEN** DIRE SHALL block auto-merge

#### Scenario: Globally-administered MAC conflict remains non-mergeable without corroboration
- **GIVEN** two devices share globally-administered MAC `001122334455`
- **AND** no non-MAC strong identifier corroborates identity
- **WHEN** DIRE evaluates merge eligibility
- **THEN** DIRE SHALL block auto-merge
