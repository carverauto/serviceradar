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

### Requirement: Host-owned derived token exchange
The Wasm HTTP host SHALL support a bounded broker-grant mode that exchanges a source credential for a short-lived token inside the trusted agent and injects that token into one exact approved upstream request. The token endpoint response, source credential, and derived token SHALL NOT be returned to or represented in Wasm guest memory.

#### Scenario: Approved request uses a derived bearer token
- **GIVEN** a broker grant binds an HTTPS token endpoint and one HTTPS upstream endpoint to the same execution, agent, and credential
- **WHEN** the guest requests the approved upstream operation
- **THEN** the host SHALL resolve the credential, perform the declared token exchange, and attach the derived bearer token
- **AND** the guest SHALL receive only the upstream operation response

#### Scenario: Token exchange response is unsafe
- **WHEN** the token endpoint redirects, exceeds response bounds, returns malformed JSON, omits the declared token field, or returns an error
- **THEN** the host SHALL fail the upstream request closed
- **AND** neither response bytes nor credential material SHALL be exposed to the guest or logs

#### Scenario: Derived token scope does not match the request
- **WHEN** the guest request differs from the grant-bound scheme, host, port, method, or path
- **THEN** the host SHALL deny the request before credential resolution or token exchange
- **AND** no network request containing credential material SHALL occur

### Requirement: Approved action results use the durable producer sink
An approved package producer schedule MAY declare assignment-approved durable output contracts for a captured `plugin.run_action`. The guest SHALL publish persistent inventory, telemetry, observations, events, findings, or traces through the versioned binary durable-output host ABI. The agent SHALL validate and crash-safely enqueue those bounded records through its common producer sink while returning only bounded status metadata through the command bus. `serviceradar.plugin_result.v1` SHALL remain limited to bounded action/check status.

#### Scenario: Inventory-producing action completes
- **GIVEN** an approved package has a durable inventory output contract for its
  producer action
- **WHEN** the action submits a valid assignment-approved inventory page through the binary host ABI
- **THEN** the agent SHALL transfer ownership only after the exact bytes and idempotency receipt are durable in the common spool
- **AND** the command result SHALL contain only safe status, counts, identifiers, and hashes

#### Scenario: Ad hoc caller requests ingestion
- **GIVEN** a package was not granted the requested output contract
- **WHEN** a command payload or guest call attempts to enable it
- **THEN** the agent SHALL reject or ignore the request
- **AND** it SHALL not enqueue the captured payload through the durable sink or
  disguise it as a bounded status result

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

### Requirement: Source-native local plugin host
The supported Go and Rust SDKs SHALL provide equivalent non-Wasm local-host contracts that let plugin authors run source code with production-shaped configuration and action invocation payloads, host-mediated HTTP, and captured results without building, signing, publishing, or deploying a Wasm artifact. Local credentials SHALL be loaded from an optional `.env` file and process environment, SHALL remain separate from plugin configuration and action input, and SHALL be available only to the trusted local host adapter.

#### Scenario: Developer runs a plugin from source
- **GIVEN** a developer supplies a public configuration JSON document and an optional action invocation JSON document
- **WHEN** the plugin runs through the SDK local host
- **THEN** the plugin SHALL receive the same merged host configuration shape used by the agent
- **AND** submitted results, telemetry, and logs SHALL be captured for inspection

#### Scenario: Local credentials authorize host HTTP
- **GIVEN** credential fields are present in an optional `.env` file or process environment
- **WHEN** a local host HTTP adapter performs a provider request
- **THEN** process environment values SHALL override file values
- **AND** credential fields SHALL NOT be merged into plugin configuration, action invocation, captured results, or logs

#### Scenario: Local execution does not bypass production admission
- **WHEN** a source-native local run succeeds
- **THEN** it SHALL provide no package approval, signature, assignment, or production authorization state
- **AND** production execution SHALL continue to require the normal signed-package and agent admission controls
