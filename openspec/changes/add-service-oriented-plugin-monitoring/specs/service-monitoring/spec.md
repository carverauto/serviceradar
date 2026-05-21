## ADDED Requirements

### Requirement: First-class monitored services
The system SHALL provide first-class monitored service targets that can represent device-associated services or standalone services such as URLs, APIs, database endpoints, TCP ports, and TLS endpoints.

#### Scenario: Create standalone URL service
- **GIVEN** an authorized operator creates a monitored service for `https://example.com/health`
- **WHEN** the service is saved
- **THEN** the system SHALL persist the service target with kind `http`, endpoint URL, tags, display name, and ownership metadata
- **AND** it SHALL NOT require a device association

#### Scenario: Create device-associated database service
- **GIVEN** canonical device `sr:db-1` exists
- **WHEN** an operator creates a PostgreSQL service on that device
- **THEN** the service SHALL persist the device UID, protocol, host, port, database metadata, tags, and service identity
- **AND** the device details UI SHALL be able to show the associated service

### Requirement: Bulk service import
The system SHALL support bulk creation and update of monitored services from pasted lists, CSV upload, or API import with validation before commit.

#### Scenario: Import two hundred URLs
- **GIVEN** an operator uploads a CSV containing 200 URL targets
- **WHEN** validation runs
- **THEN** the system SHALL show valid, duplicate, and invalid rows before saving
- **AND** saving SHALL create or update services without requiring 200 manual forms

#### Scenario: Import rejects invalid target
- **GIVEN** a bulk import row contains an unsupported URL scheme
- **WHEN** validation runs
- **THEN** the row SHALL be marked invalid with a field-level error
- **AND** no check assignment SHALL be generated for that row

### Requirement: Monitoring bindings connect capabilities to target sets
The system SHALL provide monitoring bindings that connect a built-in or plugin-declared check capability to service and/or device target sets, schedules, threshold profiles, credential policy, and event/alert policy.

#### Scenario: Bind HTTP check to service group
- **GIVEN** a service group contains 200 HTTP services
- **AND** an approved plugin exposes an `http.url.availability` check descriptor
- **WHEN** an operator creates a monitoring binding for that group and descriptor
- **THEN** the system SHALL materialize check instances for each service target
- **AND** the operator SHALL NOT have to edit plugin config with 200 URLs

#### Scenario: Bind database check to tagged devices
- **GIVEN** devices tagged `role=db` have associated PostgreSQL service templates
- **WHEN** an operator binds a PostgreSQL availability capability to `in:devices tags.role:db`
- **THEN** the system SHALL expand the binding into database service check instances for matching devices
- **AND** newly matching devices SHALL be picked up during binding reconciliation

### Requirement: Stable check instance identity
The system SHALL assign stable check instance identities for each binding, target, descriptor, and vantage point so result history and alerts survive assignment recompilation.

#### Scenario: Assignment recompiles without changing check identity
- **GIVEN** a monitoring binding is already materialized for a URL service
- **WHEN** the target batch is recompiled because another service was added to the group
- **THEN** the existing URL service check instance ID SHALL remain unchanged
- **AND** its latest state, history, and open alerts SHALL remain attached to that ID

### Requirement: Device and service credential precedence
The system SHALL resolve check credentials through unified credentials with deterministic precedence: per-service override, per-device override, matching network credential rule, then no credential when the descriptor allows anonymous checks.

#### Scenario: Service override wins
- **GIVEN** a database service has a service-specific credential override
- **AND** its associated device matches a network-wide database credential rule
- **WHEN** the database check assignment is compiled
- **THEN** the service-specific credential SHALL be selected
- **AND** the assignment SHALL include only a broker grant or secret reference, not plaintext credential material

#### Scenario: Anonymous HTTP check uses no credential
- **GIVEN** an HTTP service does not require authentication
- **AND** the selected descriptor allows anonymous checks
- **WHEN** the assignment is compiled
- **THEN** no credential grant SHALL be attached

#### Scenario: Ad-hoc service/device task uses same credential precedence
- **GIVEN** an operator runs an ad-hoc task against a device or service
- **AND** the task descriptor declares an API credential requirement
- **WHEN** ServiceRadar prepares the task execution
- **THEN** it SHALL select credentials using the same service/device/rule precedence model
- **AND** it SHALL attach only a scoped broker grant to the task execution
- **AND** it SHALL record redacted audit and OCSF events for launch, dispatch, credential resolution, completion, denial, or failure

### Requirement: Vantage-point aware execution
The system SHALL allow monitoring bindings to specify eligible agents, gateways, edge sites, or partitions as execution vantage points and SHALL preserve per-vantage latest state.

#### Scenario: Same service checked from two agents
- **GIVEN** one URL service is bound to agents `agent-a` and `agent-b`
- **WHEN** both agents report check results
- **THEN** latest state SHALL be stored separately for each agent vantage point
- **AND** service availability consumers SHALL be able to choose canonical or per-vantage state

### Requirement: Result policy controls event and alert promotion
The system SHALL let operators define how check status changes create events and when those events promote to alerts.

#### Scenario: Critical transition creates event
- **GIVEN** a monitoring binding is configured to emit events on `CRITICAL` transitions
- **WHEN** a check instance changes from `OK` to `CRITICAL`
- **THEN** the system SHALL create an OCSF event linked to the check instance, service, device when present, binding, and plugin descriptor

#### Scenario: Alert rule promotes repeated failures
- **GIVEN** a binding alert policy requires three critical results in five minutes
- **WHEN** a check instance meets that threshold
- **THEN** the system SHALL create or update one alert for the check instance
- **AND** cooldown and re-notify behavior SHALL prevent duplicate alert storms

### Requirement: Existing static plugin assignments remain compatible
The system SHALL preserve existing manually configured plugin assignments while making service-oriented monitoring bindings the default path for check-style plugins.

#### Scenario: Legacy plugin assignment still runs
- **GIVEN** an existing static plugin assignment has params JSON
- **WHEN** the service-oriented monitoring model is enabled
- **THEN** the assignment SHALL continue to run with its existing params
- **AND** it SHALL be labeled as an advanced/manual assignment in admin UI
