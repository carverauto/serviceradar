## MODIFIED Requirements
### Requirement: Plugin Package Storage Backends
The system SHALL store plugin packages using a configured backend and expose them through the web-ng API for agent download.

Blob upload and download authorization SHALL NOT embed bearer tokens in request URLs. Token-gated blob access SHALL use request headers or request bodies so signed tokens do not appear in generated URLs, copied links, logs, browser history, or agent configuration payloads.

#### Scenario: Filesystem-backed storage
- **GIVEN** the storage backend is configured as filesystem
- **WHEN** a package is uploaded
- **THEN** the package is stored under the configured path
- **AND** the web-ng API serves the package by reference ID

#### Scenario: JetStream object storage
- **GIVEN** the storage backend is configured as NATS JetStream object storage
- **WHEN** a package is uploaded
- **THEN** the package is written to the JetStream object store
- **AND** the web-ng API serves the package by object key

#### Scenario: GitHub repository source
- **GIVEN** a plugin package is configured to be sourced from a GitHub repository
- **WHEN** core fetches the package
- **THEN** core stores the package in the configured backend
- **AND** the web-ng API serves the package by reference ID

#### Scenario: Plugin blob download avoids URL-borne bearer tokens
- **GIVEN** an operator or agent requests a plugin blob
- **WHEN** the web-ng API authorizes the blob download
- **THEN** the bearer token is supplied via request header or body
- **AND** the request URL does not contain the signed token

### Requirement: Plugin Assignment and Distribution
The control plane SHALL allow assigning plugin packages to agents and SHALL deliver assignments through the agent config response.

Assignments SHALL NOT embed reusable bearer download URLs for plugin blobs. Agents SHALL receive only the internal plugin reference material needed to perform an authenticated fetch without a tokenized URL appearing in config payloads.

#### Scenario: Assign plugin to an agent
- **GIVEN** a plugin package exists
- **WHEN** an admin assigns the plugin to an agent
- **THEN** the next `AgentConfigResponse` includes a plugin assignment with package reference, schedule, and timeout
- **AND** the config version changes
- **AND** the assignment does not include a bearer token in the URL

#### Scenario: No assignment change
- **GIVEN** an agent with current plugin assignments
- **WHEN** the agent polls for config
- **THEN** the control plane returns `not_modified: true`
- **AND** the agent continues using cached plugin packages
