## ADDED Requirements

### Requirement: Armis northbound availability source selection
Armis northbound update configuration SHALL allow operators to choose which ServiceRadar availability source drives outbound Armis availability/custom-property updates.

#### Scenario: Armis northbound uses canonical availability
- **GIVEN** an Armis integration source has northbound updates enabled
- **AND** no availability agent is selected
- **WHEN** the northbound update job builds outbound payloads
- **THEN** the value pushed SHALL follow that source's northbound availability semantics
- **AND** that contract is owned by `add-merged-device-availability` (`openspec/changes/add-merged-device-availability/specs/sync-service-integrations/spec.md`)

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
