## ADDED Requirements

### Requirement: Armis northbound availability source selection
Armis northbound update configuration SHALL allow operators to choose which ServiceRadar availability source drives outbound Armis availability/custom-property updates.

#### Scenario: Armis northbound uses canonical availability
- **GIVEN** an Armis integration source has northbound updates enabled
- **AND** its availability source is set to canonical device availability
- **WHEN** the northbound update job builds outbound payloads
- **THEN** the outbound value SHALL use `ocsf_devices.is_available`
- **AND** SHALL preserve existing default behavior for sources without an explicit source selection

#### Scenario: Armis northbound uses selected agent availability
- **GIVEN** an Armis integration source has northbound updates enabled
- **AND** its availability source is set to `agent-ot`
- **WHEN** the northbound update job builds outbound payloads
- **THEN** the outbound value for each Armis device SHALL use that device's latest `agent-ot` availability state
- **AND** missing `agent-ot` observations SHALL be counted as skipped or stale according to the configured policy

#### Scenario: Source selection is visible in run status
- **GIVEN** an Armis northbound run executes with availability source `agent-ot`
- **WHEN** the run status is persisted
- **THEN** the status SHALL include the selected availability source
- **AND** summary counts SHALL distinguish updated, skipped, and stale-source records when available
