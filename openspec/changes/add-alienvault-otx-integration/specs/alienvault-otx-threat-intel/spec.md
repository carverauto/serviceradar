## ADDED Requirements

### Requirement: AlienVault OTX Settings
The system SHALL provide deployment-scoped AlienVault OTX settings that allow an authorized operator to enable OTX ingestion, configure the OTX base URL, configure sync cadence, configure retrohunt window length, configure raw payload archival, and store an OTX API key encrypted at rest.

#### Scenario: Operator saves OTX API key
- **GIVEN** an operator has permission to manage threat intelligence settings
- **WHEN** the operator saves an OTX API key
- **THEN** the API key SHALL be encrypted at rest
- **AND** subsequent UI/API reads SHALL show only whether a key is set
- **AND** the raw key SHALL NOT be returned in UI payloads, logs, or job arguments

#### Scenario: Unauthorized user opens OTX settings
- **GIVEN** a logged-in user lacks permission to manage threat intelligence settings
- **WHEN** the user navigates to the OTX settings page
- **THEN** the system SHALL deny access
- **AND** no settings data SHALL be returned to the user

### Requirement: OTX Subscribed Pulse Synchronization
The system SHALL synchronize subscribed AlienVault OTX pulses and indicators using the configured API key and SHALL persist normalized pulse and indicator records in CNPG.

#### Scenario: Initial sync imports subscribed pulses
- **GIVEN** OTX ingestion is enabled
- **AND** a valid OTX API key is configured
- **WHEN** the OTX sync job runs for the first time
- **THEN** the system SHALL fetch subscribed OTX pulses
- **AND** the system SHALL store pulse metadata and indicators in normalized platform tables
- **AND** the system SHALL record sync counts and completion status

#### Scenario: Incremental sync uses high-water mark
- **GIVEN** a previous OTX sync completed successfully
- **WHEN** the next scheduled sync runs
- **THEN** the system SHALL request only pulses modified since the previous high-water mark when supported by the API
- **AND** unchanged normalized indicators SHALL NOT create duplicate records

#### Scenario: OTX API failure is recorded
- **GIVEN** OTX ingestion is enabled
- **WHEN** the OTX API returns a retryable or terminal error
- **THEN** the sync job SHALL record a redacted failure status
- **AND** the system SHALL NOT log the API key
- **AND** existing imported indicators SHALL remain available

### Requirement: Raw OTX Payload Archival
The system SHALL optionally archive raw OTX API payloads for audit and replay without making raw object storage the primary query path.

#### Scenario: Raw archival succeeds
- **GIVEN** raw payload archival is enabled
- **AND** NATS Object Store is available
- **WHEN** an OTX sync imports a pulse page or pulse payload
- **THEN** the system SHALL store the raw JSON payload in object storage
- **AND** normalized pulse records SHALL reference the stored object key

#### Scenario: Raw archival unavailable
- **GIVEN** raw payload archival is enabled
- **AND** NATS Object Store is unavailable
- **WHEN** an OTX sync imports indicators
- **THEN** the system SHALL continue storing normalized CNPG records
- **AND** the sync run SHALL record that raw archival was skipped or failed

### Requirement: Retroactive Threat Hunting
The system SHALL run retroactive hunts for newly imported or reactivated OTX indicators against retained NetFlow and DNS history over a configurable window that defaults to 90 days.

#### Scenario: IP indicator matches historical NetFlow
- **GIVEN** an imported OTX IPv4 or IPv6 indicator
- **AND** retained NetFlow history contains traffic involving that IP during the configured retrohunt window
- **WHEN** the retrohunt worker runs
- **THEN** the system SHALL create a finding linked to the indicator
- **AND** the finding SHALL identify the observed host or entity, time window, direction where available, and evidence count

#### Scenario: Domain indicator matches historical DNS
- **GIVEN** an imported OTX domain or hostname indicator
- **AND** retained DNS history contains a matching query or answer during the configured retrohunt window
- **WHEN** the retrohunt worker runs
- **THEN** the system SHALL create a finding linked to the indicator
- **AND** the finding SHALL identify the observed host or entity, time window, and evidence count

#### Scenario: Unsupported indicator type is imported
- **GIVEN** an imported OTX indicator type without a current ServiceRadar telemetry source for retrohunt matching
- **WHEN** the retrohunt worker evaluates the indicator
- **THEN** the indicator SHALL remain visible in the imported indicator inventory
- **AND** the system SHALL mark it as not retrohunt-supported rather than failing the run

### Requirement: OTX Job Scheduling And Manual Runs
The system SHALL schedule OTX sync and retrohunt work through Oban with uniqueness constraints and SHALL provide authorized manual run controls.

#### Scenario: Scheduled sync enqueues once
- **GIVEN** OTX ingestion is enabled
- **WHEN** the scheduled sync interval elapses on a multi-node deployment
- **THEN** exactly one OTX sync job SHALL be enqueued for the interval

#### Scenario: Operator triggers manual sync
- **GIVEN** an operator has permission to manage threat intelligence settings
- **WHEN** the operator selects "Sync now"
- **THEN** the system SHALL enqueue an OTX sync job
- **AND** the UI SHALL show whether the job was enqueued or the scheduler is unavailable

### Requirement: OTX Findings Visibility
The system SHALL provide operator visibility into OTX sync health, imported indicator inventory, and retroactive findings.

#### Scenario: Operator views OTX status
- **GIVEN** OTX ingestion has run at least once
- **WHEN** an authorized operator opens the OTX settings or threat intelligence page
- **THEN** the UI SHALL show last attempt time, last success time, imported pulse count, imported indicator count, latest error summary, and active job status where available

#### Scenario: Operator reviews historical finding
- **GIVEN** a retrohunt finding exists
- **WHEN** an authorized operator opens the findings view
- **THEN** the UI SHALL show the indicator value, indicator type, pulse context, observed host or entity, observed time window, source telemetry kind, and evidence count
