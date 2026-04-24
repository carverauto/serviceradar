## ADDED Requirements
### Requirement: Sweep Results Promote Eligible Discovery Candidates
The system SHALL evaluate live sweep-discovered hosts for mapper promotion after ingesting sweep results.

#### Scenario: Live unknown host becomes a mapper promotion candidate
- **GIVEN** a sweep group ingests a host result with `available = true`
- **AND** the host is newly created or matched in inventory
- **WHEN** sweep result ingestion completes for that host
- **THEN** the system SHALL evaluate whether the host is eligible for mapper promotion
- **AND** the decision SHALL be based on the host, sweep group scope, and available mapper job assignments

#### Scenario: Unavailable host is not promoted
- **GIVEN** a sweep group ingests a host result with `available = false`
- **WHEN** sweep result ingestion completes
- **THEN** the system SHALL NOT promote that host into mapper discovery

### Requirement: Sweep Promotion Decision Visibility
The system SHALL record why a sweep-discovered host was promoted, skipped, or suppressed for mapper discovery.

#### Scenario: Promotion skipped because no mapper job is eligible
- **GIVEN** a live sweep-discovered host
- **AND** no mapper job in the applicable partition or agent scope can accept promotion
- **WHEN** sweep result ingestion evaluates promotion
- **THEN** the system SHALL record a reason indicating no eligible mapper job was available

#### Scenario: Promotion suppressed by cooldown
- **GIVEN** a live sweep-discovered host that was recently promoted
- **WHEN** a later sweep sees the same host again inside the suppression window
- **THEN** the system SHALL suppress the duplicate promotion
- **AND** record that the host was skipped due to cooldown or recent successful promotion
