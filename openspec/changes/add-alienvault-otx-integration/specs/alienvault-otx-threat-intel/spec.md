## ADDED Requirements

### Requirement: TAXII/STIX-Shaped Provider Boundary
The system SHALL model threat-intel ingestion around TAXII 2.1 collection/object semantics and STIX 2.1 indicator normalization so AlienVault OTX is not hard-coded as the only provider shape.

#### Scenario: Provider returns paged collection objects
- **GIVEN** a threat-intel provider supports incremental collection retrieval
- **WHEN** the sync worker requests a page with a cursor, limit, or high-water mark
- **THEN** the provider SHALL return objects with collection identity, object identity, object type, version or modified metadata when available, raw payload reference, and next-page state
- **AND** the sync worker SHALL persist the next-page or high-water state without depending on provider-specific field names

#### Scenario: STIX indicator normalizes to NetFlow CIDR indicator
- **GIVEN** a provider object is a STIX 2.1 Indicator with an IPv4, IPv6, or CIDR observable pattern
- **WHEN** the normalizer processes the object
- **THEN** it SHALL create or update a `platform.threat_intel_indicators` row compatible with existing NetFlow CIDR matching
- **AND** it SHALL preserve source object metadata needed to explain the match where configured

#### Scenario: Non-STIX provider adapts to the same boundary
- **GIVEN** AlienVault OTX returns DirectConnect pulse JSON rather than a TAXII envelope
- **WHEN** the OTX adapter processes the response
- **THEN** it SHALL map OTX pulses and indicators into the same internal collection/object/indicator model used by TAXII providers

#### Scenario: SIEM provider adapts to the same boundary
- **GIVEN** a customer-local SIEM API exposes indicators or sightings in a vendor-specific schema
- **WHEN** a provider adapter processes the SIEM response
- **THEN** it SHALL map supported indicators into the same internal collection/object/indicator model used by TAXII providers
- **AND** it SHALL preserve source system and query context needed to explain the imported intelligence

### Requirement: Edge Wasm Threat-Intel Collectors
The system SHALL support threat-intel collectors running as signed Wasm plugins on assigned agents so ServiceRadar can ingest feeds and SIEM intelligence from networks that are only reachable at the edge.

#### Scenario: Collector uses supported ServiceRadar SDK
- **GIVEN** a first-party threat-intel collector is implemented with `serviceradar-sdk-go` or `serviceradar-sdk-rust`
- **WHEN** the collector is built as a Wasm plugin
- **THEN** it SHALL use the ServiceRadar host ABI for config loading, logging, network calls, and result submission
- **AND** it SHALL emit the same CTI page contract regardless of SDK language
- **AND** core ingestion SHALL NOT depend on whether the plugin was authored in Go or Rust

#### Scenario: Edge collector fetches provider page
- **GIVEN** a threat-intel collector plugin is assigned to an agent
- **AND** the plugin package is approved with HTTP/TCP/UDP capabilities and allowlists for the target provider
- **WHEN** the plugin runs on schedule
- **THEN** the agent SHALL enforce the approved resource limits and network allowlists
- **AND** the plugin SHALL emit a bounded CTI page containing provider identity, collection identity, object metadata, normalized indicators, skipped counts, and cursor or high-water hints

#### Scenario: Core ingests edge collector page
- **GIVEN** an agent submits a CTI page from a threat-intel collector plugin
- **WHEN** core receives the plugin result
- **THEN** core SHALL validate the CTI payload schema
- **AND** core SHALL upsert supported IP/CIDR indicators into `platform.threat_intel_indicators`
- **AND** core SHALL record source metadata and provider sync status without requiring the core service to contact the external provider directly

#### Scenario: Edge collector egress is denied
- **GIVEN** a collector plugin attempts to call a provider endpoint outside its approved allowlist
- **WHEN** the plugin requests the network call through the host
- **THEN** the agent SHALL deny the call
- **AND** the plugin run SHALL report a redacted failure status
- **AND** no provider secret SHALL be logged or returned in UI payloads

### Requirement: AlienVault OTX Settings
The system SHALL provide deployment-scoped AlienVault OTX settings that allow an authorized operator to enable OTX ingestion, configure execution mode, configure the OTX base URL, configure edge plugin assignment or core worker execution, configure sync cadence, configure current NetFlow match lookback, configure retrohunt window length, configure raw payload archival, and store an OTX API key or secret reference encrypted at rest.

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
The system SHALL synchronize subscribed AlienVault OTX pulses and indicators using the configured API key and SHALL persist supported NetFlow-matchable indicators in the existing CNPG threat-intel indicator table.

#### Scenario: Initial sync imports subscribed pulses
- **GIVEN** OTX ingestion is enabled
- **AND** a valid OTX API key is configured
- **WHEN** the OTX sync job runs for the first time
- **THEN** the system SHALL fetch subscribed OTX pulses
- **AND** the system SHALL store IPv4, IPv6, and CIDR indicators in `platform.threat_intel_indicators` with source `alienvault_otx`
- **AND** the system SHALL record sync counts and completion status

#### Scenario: Edge OTX sync imports subscribed pulses
- **GIVEN** OTX ingestion is enabled in edge plugin mode
- **AND** a valid OTX API key or secret reference is available to the assigned collector
- **WHEN** the assigned agent runs the OTX collector plugin
- **THEN** the plugin SHALL fetch paginated OTX export results through the agent host network bridge
- **AND** core SHALL persist supported IPv4, IPv6, and CIDR indicators in `platform.threat_intel_indicators` with source `alienvault_otx`
- **AND** core SHALL record sync counts and completion status for the provider and agent assignment
- **AND** the plugin SHALL stop at configured page, timeout, and indicator budgets while returning a cursor for the next continuation point

#### Scenario: Incremental sync uses high-water mark
- **GIVEN** a previous OTX sync completed successfully
- **WHEN** the next scheduled sync runs
- **THEN** the system SHALL request only pulses modified since the previous high-water mark when supported by the API
- **AND** unchanged normalized indicators SHALL NOT create duplicate records

#### Scenario: Unsupported OTX indicator types are counted
- **GIVEN** an OTX pulse contains URL, domain, hostname, or file hash indicators
- **WHEN** the OTX sync job imports the pulse
- **THEN** the system SHALL record skipped or deferred counts for those indicator types
- **AND** the unsupported indicators SHALL NOT break IP/CIDR import

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

### Requirement: Current NetFlow Threat Matching
The system SHALL match active OTX IP/CIDR indicators against current or recent NetFlow data through the existing NetFlow security refresh and IP threat-intel cache path.

#### Scenario: IP indicator matches recent NetFlow
- **GIVEN** an imported active OTX IPv4 or IPv6 indicator
- **AND** recent NetFlow data contains traffic involving that IP during the configured current match lookback
- **WHEN** the NetFlow matching worker runs
- **THEN** the system SHALL update the per-IP threat-intel cache for the observed IP
- **AND** the cache entry SHALL include match count, max severity, source `alienvault_otx`, lookup time, and expiration

#### Scenario: NetFlow view shows OTX context
- **GIVEN** OTX NetFlow findings exist for traffic visible in a NetFlow analysis view
- **WHEN** an authorized operator opens that NetFlow view
- **THEN** the UI SHALL surface OTX hit counts or markers
- **AND** the operator SHALL be able to inspect source `alienvault_otx`, match count, max severity, and pulse context when available

#### Scenario: Current matching is disabled
- **GIVEN** OTX ingestion is enabled
- **AND** current NetFlow matching is disabled
- **WHEN** the OTX sync job imports indicators
- **THEN** the system SHALL store the indicators
- **AND** the system SHALL NOT enqueue current NetFlow match work

### Requirement: Optional Retroactive Threat Hunting
The system SHALL support optional retroactive hunts for imported or reactivated OTX indicators against retained NetFlow and DNS history over a configurable window that defaults to 90 days.

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
The system SHALL schedule OTX sync, edge collector runs, current NetFlow matching, and optional retrohunt work with uniqueness/bounds appropriate to the execution mode and SHALL provide authorized manual run controls.

#### Scenario: Scheduled sync enqueues once
- **GIVEN** OTX ingestion is enabled
- **WHEN** the scheduled sync interval elapses on a multi-node deployment
- **THEN** exactly one OTX sync job SHALL be enqueued for the interval

#### Scenario: Scheduled edge collector assignment runs once per interval
- **GIVEN** OTX ingestion is enabled in edge plugin mode
- **AND** an OTX collector plugin assignment exists for a reachable agent
- **WHEN** the scheduled sync interval elapses
- **THEN** the system SHALL schedule bounded plugin execution for that assignment
- **AND** duplicate concurrent runs for the same provider/assignment interval SHALL be prevented

#### Scenario: Operator triggers manual sync
- **GIVEN** an operator has permission to manage threat intelligence settings
- **WHEN** the operator selects "Sync now"
- **THEN** the system SHALL enqueue an OTX sync job
- **AND** the UI SHALL show whether the job was enqueued or the scheduler is unavailable

#### Scenario: Operator triggers current NetFlow matching
- **GIVEN** active OTX indicators are available
- **AND** an operator has permission to manage threat intelligence settings
- **WHEN** the operator selects "Match recent NetFlow now"
- **THEN** the system SHALL enqueue current NetFlow match work
- **AND** the UI SHALL show whether the job was enqueued or the scheduler is unavailable

### Requirement: OTX Findings Visibility
The system SHALL provide operator visibility into OTX sync health, imported indicator inventory, current NetFlow findings, and retroactive findings.

#### Scenario: Operator views OTX status
- **GIVEN** OTX ingestion has run at least once
- **WHEN** an authorized operator opens the OTX settings or threat intelligence page
- **THEN** the UI SHALL show execution mode, assigned agent/plugin health where applicable, last attempt time, last success time, imported pulse count, imported indicator count, current NetFlow finding count, latest error summary, and active job status where available

#### Scenario: Operator reviews NetFlow finding
- **GIVEN** an OTX NetFlow finding exists
- **WHEN** an authorized operator opens the findings view
- **THEN** the UI SHALL show the indicator value, indicator type, pulse context, observed host or entity, first observed time, last observed time, source telemetry kind, and evidence count
