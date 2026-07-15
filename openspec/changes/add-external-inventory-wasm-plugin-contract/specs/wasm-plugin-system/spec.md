## ADDED Requirements

### Requirement: Grant-scoped form credential injection
The Wasm HTTP host SHALL support a generic form-url-encoded credential injection mode for approved plugin requests that require username/password form fields. Injection SHALL be constrained by a short-lived broker grant to an exact agent, HTTPS host, port, method, path, and allowlisted field names. Secret material SHALL remain host-side.

#### Scenario: Approved token form receives credentials
- **GIVEN** an approved plugin request matches an active grant for an HTTPS token endpoint
- **WHEN** the request is sent through host HTTP
- **THEN** the host SHALL overwrite only grant-declared secret form fields with resolved credential material
- **AND** the Wasm module SHALL not receive the long-lived secret values

#### Scenario: Unsafe form injection is denied
- **WHEN** a request uses insecure TLS, a mismatched endpoint, unsupported content type, unapproved field, expired grant, or redirect outside scope
- **THEN** credential injection SHALL be denied
- **AND** no resolved secret SHALL be sent

### Requirement: Approved action results may enter plugin-result ingestion
An approved package producer schedule MAY declare that a captured `plugin.run_action` result enters normal plugin-result ingestion. The agent SHALL validate and enqueue the full result while returning only bounded status metadata through the command bus.

#### Scenario: Inventory-producing action completes
- **GIVEN** an approved package declares plugin-result ingestion for its producer action
- **WHEN** the action submits a valid `serviceradar.plugin_result.v1` payload
- **THEN** the agent SHALL enqueue the payload through the normal plugin-result channel
- **AND** the command result SHALL contain only safe status, counts, identifiers, and hashes

#### Scenario: Ad hoc caller requests ingestion
- **GIVEN** a package was not approved for action-result ingestion
- **WHEN** a command payload attempts to enable it
- **THEN** the agent SHALL reject or ignore the request
- **AND** it SHALL not enqueue the captured payload as inventory

### Requirement: Producer-only assignments do not start local schedules
An approved Wasm package MAY declare `action-only:v1` when its assignment exists solely for command-bus actions. The agent SHALL admit and cache that assignment without starting a normal interval runner while retaining artifact, resource, and action admission controls.

#### Scenario: Action-only assignment is delivered
- **GIVEN** an enabled assignment for a package with `action-only:v1`
- **WHEN** the agent applies plugin configuration
- **THEN** it SHALL retain and prefetch the assignment for exact-ID action lookup
- **AND** it SHALL NOT invoke `run_check` on assignment receipt or an agent-local ticker

### Requirement: Generic protected external plugin publication
The release system SHALL publish external Wasm plugins through one repository/tag-parameterized protected workflow. The trusted build and signing path SHALL validate repository namespace, tag ancestry, artifact bounds, package identity, reproducibility, signatures, and conventional package resources without executing external repository scripts in a privileged job.

#### Scenario: A new external plugin is released
- **GIVEN** an allowed external plugin repository has a release tag reachable from its main branch
- **WHEN** an authorized operator dispatches the generic release workflow
- **THEN** the workflow SHALL build and package the exact tag with pinned trusted tooling
- **AND** it SHALL publish signed artifacts and an import index without a provider-specific workflow file

#### Scenario: External repository attempts privileged execution
- **GIVEN** an external repository contains arbitrary build or release scripts
- **WHEN** the protected workflow processes its tag
- **THEN** the signing job SHALL NOT execute those scripts
- **AND** signing and publish credentials SHALL remain unavailable to the unprivileged build job
