## ADDED Requirements

### Requirement: Sandboxed HPNA inventory plugin
The system SHALL provide an importable signed Go/TinyGo Wasm plugin that acquires HPNA inventory through host-mediated HTTP and emits `serviceradar.plugin_result.v1` with `serviceradar.device_discovery.v1`. The plugin MUST NOT access CNPG, NATS, the host filesystem, raw sockets, or arbitrary ServiceRadar APIs.

#### Scenario: HPNA collection runs at the assigned edge
- **GIVEN** the approved HPNA package is assigned to an agent that can reach HPNA
- **WHEN** the agent executes the inventory action
- **THEN** the plugin SHALL use only its approved config and host HTTP capability
- **AND** its inventory SHALL enter ServiceRadar through normal plugin-result ingestion

#### Scenario: Unapproved capability is unavailable
- **GIVEN** the HPNA package was not approved for a requested host capability or endpoint
- **WHEN** the plugin attempts to use it
- **THEN** the agent SHALL deny the operation
- **AND** no inventory snapshot SHALL be activated

### Requirement: Configurable bounded list-device queries
The HPNA plugin SHALL execute only the fixed HPNA `list device` command. Its JSON configuration SHALL support one or more named query parameter sets using a strict allowlist, with a default query parameter `type=Switch`. The plugin SHALL own pagination parameters and reject arbitrary commands, URLs, credentials, unknown flags, or unbounded values.

#### Scenario: Default switch query
- **GIVEN** an HPNA assignment omits `queries`
- **WHEN** the plugin builds its first wrapper request
- **THEN** it SHALL execute `list device` with `type=Switch`
- **AND** it SHALL add bounded plugin-owned `startid` and `limitcount`

#### Scenario: Operator configures multiple device classes
- **GIVEN** an operator configures named query sets for `type=Switch` and `type=L3Switch`
- **WHEN** collection runs
- **THEN** the plugin SHALL page both approved queries
- **AND** it SHALL deduplicate overlapping rows by HPNA `deviceID`

#### Scenario: Supported list-device flags
- **WHEN** an operator configures valid values for approved `software`, `vendor`, `type`, `model`, `family`, `group`, `disabled`, `pollexcluded`, `ids`, `hierarchy`, `host`, `ip`, `realm`, `vtpdomain`, or valid IP-scoped `context` filters
- **THEN** schema and runtime validation SHALL accept the bounded values
- **AND** the plugin SHALL serialize them only as `list device` parameters

#### Scenario: Unsafe parameter is rejected
- **WHEN** configuration contains `command`, `startid`, `limitcount`, an unknown parameter, an endpoint/credential override, an invalid `context`, or an excessive query/value/row bound
- **THEN** validation SHALL reject the assignment or run before an HPNA request
- **AND** the rejected value SHALL not be reflected into logs or errors

### Requirement: Brokered HPNA authentication
HPNA long-lived username/password credentials SHALL be selected by a scoped ServiceRadar credential rule and injected by the agent host only into the approved HTTPS token request. The Wasm module, assignment config, command payload, plugin result, device metadata, logs, and audit records SHALL NOT contain the long-lived credential.

#### Scenario: Token exchange succeeds
- **GIVEN** an enabled HPNA username/password credential rule matches the selected agent and endpoint
- **WHEN** the plugin issues the approved form-encoded token request
- **THEN** the host SHALL inject the declared username/password fields
- **AND** the plugin MAY use the returned short-lived bearer token only for the bounded execution

#### Scenario: Grant scope mismatch
- **GIVEN** a credential grant is expired or targets a different agent, host, port, method, or path
- **WHEN** HPNA collection attempts to use it
- **THEN** the host SHALL deny credential injection
- **AND** the run SHALL fail with a stable redacted authentication or scope error

#### Scenario: Credential is not exposed to Wasm
- **WHEN** the plugin loads config, handles HTTP responses, submits results, or logs diagnostics
- **THEN** no long-lived username or password SHALL be observable in plugin memory or output
- **AND** the short-lived token SHALL not be logged or persisted

### Requirement: Platform-owned daily and on-demand execution
The HPNA package SHALL declare an assignment-scoped `hpna.inventory.refresh` producer schedule using `plugin.run_action`, with a default cadence of once per 86,400 seconds. AshOban and the agent command bus SHALL own recurring and Run Now dispatch; the plugin SHALL NOT implement an internal scheduler.

#### Scenario: Daily collection becomes due
- **GIVEN** an enabled HPNA producer schedule is due
- **WHEN** the AshOban schedule worker runs
- **THEN** it SHALL dispatch the package-declared action to the selected agent through the command bus
- **AND** it SHALL record command ID, run status, last error, and next due time

#### Scenario: Operator runs collection now
- **GIVEN** an authorized operator opens the HPNA schedule
- **WHEN** the operator selects Run Now
- **THEN** ServiceRadar SHALL dispatch the same action through the same command path
- **AND** RBAC, audit, uniqueness, timeout, credential, and result policies SHALL remain identical

#### Scenario: Concurrent refresh is requested
- **GIVEN** an HPNA refresh for an instance is active
- **WHEN** another scheduled or manual refresh is requested
- **THEN** ServiceRadar SHALL deduplicate, defer, or reject the overlapping run
- **AND** it SHALL NOT run two concurrent full polls for that instance

### Requirement: Complete bounded HPNA snapshots
The HPNA plugin SHALL paginate deterministically, validate every page, and emit a snapshot only after all configured queries complete within row and byte limits. A partial, non-advancing, malformed, or oversized result MUST NOT become current inventory.

#### Scenario: Complete multi-page collection
- **GIVEN** HPNA returns full pages with advancing device IDs followed by a final short or empty page
- **WHEN** all configured queries finish
- **THEN** the result SHALL identify the snapshot as complete
- **AND** it SHALL include collection ID, observed time, source instance, query/content hashes, and safe counts

#### Scenario: Pagination does not advance
- **GIVEN** HPNA returns a full page without a valid device ID greater than the previous `startid`
- **WHEN** the plugin evaluates the page
- **THEN** the run SHALL fail as incomplete
- **AND** no partial device discovery payload SHALL be ingested

#### Scenario: Snapshot exceeds bounds
- **GIVEN** configured queries exceed the approved row or serialized-byte budget
- **WHEN** the plugin reaches the bound
- **THEN** the run SHALL fail with a stable bounded error
- **AND** the previous current HPNA snapshot SHALL remain current

### Requirement: HPNA device normalization
The plugin SHALL map approved HPNA response fields into bounded device discovery records without forwarding raw source rows. Each valid row SHALL carry stable HPNA object identity and available hostname, IP, serial, vendor, model, type, site/partition, and management state.

#### Scenario: Valid switch row is normalized
- **GIVEN** a `list device` row with `deviceID`, `hostName`, `primaryIPAddress`, `serialNumber`, `vendor`, `model`, `deviceType`, `siteName`, and `managementStatus`
- **WHEN** the plugin normalizes it
- **THEN** the discovery record SHALL contain the corresponding canonical and HPNA-namespaced fields
- **AND** its stable source identifier SHALL be `hpna:v1:<instance>:device:<deviceID>`

#### Scenario: Raw HPNA fields are not copied
- **GIVEN** an HPNA row contains fields outside the approved mapping
- **WHEN** the plugin emits device discovery
- **THEN** unapproved fields and the raw row SHALL be omitted
- **AND** credentials, access method details, contacts, and API internals SHALL not enter inventory metadata

#### Scenario: Malformed identity value
- **GIVEN** an HPNA row has no valid device ID or contains malformed serial/IP data
- **WHEN** normalization runs
- **THEN** the row SHALL be rejected or the malformed optional field omitted according to the schema
- **AND** safe invalid-row counters SHALL be recorded

### Requirement: HPNA run observability
ServiceRadar SHALL expose redacted run history and freshness for HPNA collection, including page/row counts, reconciliation outcomes, duration, collection ID, and content hash.

#### Scenario: Successful run is inspectable
- **WHEN** a complete HPNA collection is ingested
- **THEN** authorized operators SHALL see retrieved, deduplicated, new, reconciled, conflicted, and absent counts
- **AND** they SHALL see the selected source instance and collection freshness

#### Scenario: Upstream error is redacted
- **WHEN** HPNA returns an authentication, authorization, malformed-response, rate, timeout, or server error
- **THEN** user-facing state SHALL use a stable safe code
- **AND** raw response bodies, credentials, bearer tokens, and request payloads SHALL not be exposed
