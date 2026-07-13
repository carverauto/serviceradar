## ADDED Requirements

### Requirement: Grant-scoped form credential injection
The Wasm HTTP host SHALL support a generic form-url-encoded credential injection mode for approved plugin requests that require username/password form fields. Injection SHALL be constrained by a short-lived broker grant to an exact agent, HTTPS host, port, method, path, and allowlisted field names. Secret material SHALL remain host-side.

#### Scenario: Approved token form receives credentials
- **GIVEN** an approved plugin request matches an active grant for an HTTPS token endpoint
- **WHEN** the request is sent through host HTTP
- **THEN** the host SHALL overwrite only the grant-declared secret form fields with resolved credential material
- **AND** the Wasm module SHALL not receive the long-lived secret values

#### Scenario: Plugin supplies a secret field
- **GIVEN** a plugin request body already contains a grant-declared username or password field
- **WHEN** host injection evaluates the request
- **THEN** the host SHALL overwrite or reject the caller value according to the approved injection contract
- **AND** the caller value SHALL not bypass grant resolution

#### Scenario: Unsafe form injection is denied
- **WHEN** the request uses insecure TLS, a mismatched endpoint, unsupported content type, unapproved field, expired grant, or redirect outside scope
- **THEN** credential injection SHALL be denied
- **AND** no resolved secret SHALL be sent

### Requirement: Approved action results may enter plugin-result ingestion
An approved plugin package producer schedule MAY declare that a captured `plugin.run_action` result is an inventory/telemetry result that must enter the normal plugin-result ingestion path. The agent SHALL validate and enqueue the full result while returning only bounded status metadata through the command bus.

#### Scenario: Inventory-producing action completes
- **GIVEN** an approved package declares plugin-result ingestion for its producer action
- **WHEN** the action submits a valid `serviceradar.plugin_result.v1` payload
- **THEN** the agent SHALL enqueue the payload through the normal plugin-result channel
- **AND** the command result SHALL contain only safe status, counts, identifiers, and hashes

#### Scenario: Ad hoc caller requests ingestion
- **GIVEN** a package was not approved for action-result ingestion
- **WHEN** a command payload attempts to enable it
- **THEN** the agent SHALL ignore or reject the request
- **AND** it SHALL not enqueue the captured payload as inventory

#### Scenario: Retried result is idempotent
- **GIVEN** command delivery retries an already completed producer action
- **WHEN** the same source instance, collection ID, and content hash are ingested again
- **THEN** inventory state SHALL remain idempotent
- **AND** duplicate canonical devices or source observations SHALL not be created

### Requirement: Producer-only assignments do not start local schedules
An approved Wasm package MAY declare `action-only:v1` when its assignment exists solely to support command-bus actions. The agent SHALL admit and cache that assignment without starting the normal interval runner, while retaining the same artifact, resource, and action admission controls.

#### Scenario: Action-only assignment is delivered
- **GIVEN** an enabled assignment for an approved package with `action-only:v1`
- **WHEN** the agent applies plugin configuration
- **THEN** it SHALL retain and prefetch the assignment for exact-ID action lookup
- **AND** it SHALL NOT invoke `run_check` on assignment receipt or an agent-local ticker

#### Scenario: Scheduled producer command arrives
- **GIVEN** an admitted action-only assignment
- **WHEN** the control plane dispatches its approved producer action
- **THEN** the agent SHALL execute the action through the normal bounded action path
- **AND** action-result ingestion and credential-grant enforcement SHALL remain unchanged
