## MODIFIED Requirements

### Requirement: OTX Subscribed Pulse Synchronization

The system SHALL synchronize subscribed AlienVault OTX pulses and indicators
using the configured API key, SHALL persist supported NetFlow-matchable indicators
in the existing CNPG threat-intel indicator table, and SHALL progress to provider
completion through bounded pages and resumable cursors without an independent
per-invocation indicator-count cap.

#### Scenario: Initial sync imports subscribed pulses

- **GIVEN** OTX ingestion is enabled
- **AND** a valid OTX API key is configured
- **WHEN** the OTX sync job runs for the first time
- **THEN** the system SHALL fetch subscribed OTX pulses
- **AND** the system SHALL store IPv4, IPv6, and CIDR indicators in
  `platform.threat_intel_indicators` with source `alienvault_otx`
- **AND** the system SHALL record sync counts and completion status

#### Scenario: Edge OTX sync imports subscribed pulses

- **GIVEN** OTX ingestion is enabled in edge plugin mode
- **AND** a valid OTX API key or secret reference is available to the assigned
  collector
- **WHEN** the assigned agent runs the OTX collector plugin
- **THEN** the plugin SHALL fetch paginated OTX export results through the agent
  host network bridge
- **AND** core SHALL persist supported IPv4, IPv6, and CIDR indicators in
  `platform.threat_intel_indicators` with source `alienvault_otx`
- **AND** core SHALL record sync counts and completion status for the provider and
  agent assignment
- **AND** the plugin SHALL stop at configured page-count, request-attempt, and
  wall-time budgets while returning a cursor for the next continuation point
- **AND** it SHALL NOT silently skip a valid normalized indicator because an old
  `max_iocs` or `max_indicators` count was reached

#### Scenario: Incremental sync uses high-water mark

- **GIVEN** a previous OTX sync completed successfully
- **WHEN** the next scheduled sync runs
- **THEN** the system SHALL request only pulses modified since the previous
  high-water mark when supported by the API
- **AND** unchanged normalized indicators SHALL NOT create duplicate records

#### Scenario: Partial walk resumes

- **GIVEN** an OTX invocation reaches its page-count, request-attempt, or wall-time
  budget before the provider walk completes
- **WHEN** the next scheduled invocation runs
- **THEN** it SHALL resume from the persisted continuation cursor
- **AND** repeated bounded invocations SHALL progress toward provider completion
  without restarting at page one

#### Scenario: Unsupported OTX indicator types are counted

- **GIVEN** an OTX pulse contains URL, domain, hostname, or file hash indicators
- **WHEN** the OTX sync job imports the pulse
- **THEN** the system SHALL record skipped or deferred counts for those indicator
  types
- **AND** unsupported types SHALL NOT break IP/CIDR import
- **AND** valid IP/CIDR rows SHALL NOT be reported under a `max_indicators` skipped
  reason

#### Scenario: OTX API failure is recorded

- **GIVEN** OTX ingestion is enabled
- **WHEN** the OTX API returns a retryable or terminal error
- **THEN** the sync job SHALL record a redacted failure status
- **AND** the system SHALL NOT log the API key
- **AND** existing imported indicators and the last durable continuation cursor
  SHALL remain available

## ADDED Requirements

### Requirement: OTX Collection Bounds Are Page-Based And Backward Compatible

OTX collection SHALL bound resource use with page size, pages per invocation,
request timeout, retry-attempt budget, wall-time budget, payload admission, and a
durable continuation cursor. The system SHALL NOT expose or enforce an independent
operator-configured `Max IOCs` limit for collection completeness.

#### Scenario: Large OTX corpus exceeds one invocation

- **GIVEN** the subscribed OTX corpus contains more indicators than one bounded
  invocation can process
- **WHEN** collection runs repeatedly
- **THEN** each invocation SHALL remain within its page, request, wall-time, and
  payload budgets
- **AND** the durable cursor SHALL advance until the complete supported corpus has
  been considered
- **AND** retained inventory MAY exceed the number processed in any one invocation

#### Scenario: Legacy assignment contains max_indicators

- **GIVEN** an existing assignment contains `max_indicators` or `max_iocs`
- **WHEN** the control plane validates, delivers, or executes that assignment
- **THEN** it SHALL accept and ignore the obsolete value
- **AND** it SHALL preserve all unrelated assignment configuration
- **AND** the next successful edit SHALL omit the obsolete key

#### Scenario: Legacy core settings or job args contain an indicator cap

- **GIVEN** existing settings or queued jobs contain `otx_max_indicators` or
  `max_indicators`
- **WHEN** a supported release reads or performs that work
- **THEN** it SHALL ignore the obsolete collection cap without failing
- **AND** retrohunt SHALL use its internal resumable keyset batch rather than the
  obsolete value

#### Scenario: Emitted payload exceeds protocol admission

- **GIVEN** a producer emits a result larger than the documented hard payload
  admission bound despite page limits
- **WHEN** core validates the result
- **THEN** core SHALL reject the oversized result with an observable explicit
  error
- **AND** it SHALL NOT silently truncate or mark the omitted valid indicators as
  successfully imported
- **AND** the last durable cursor SHALL remain safe to retry
