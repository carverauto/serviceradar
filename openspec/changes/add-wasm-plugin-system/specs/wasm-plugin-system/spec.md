## ADDED Requirements
### Requirement: Plugin Package Format
The system SHALL accept plugin packages that include a manifest YAML and a Wasm binary, and it SHALL validate required metadata before storing or distributing the package.

#### Scenario: Valid package upload
- **GIVEN** a plugin package containing `plugin.yaml` and `plugin.wasm`
- **WHEN** the package is uploaded
- **THEN** the system validates required fields (`id`, `name`, `version`, `entrypoint`, `capabilities`, `outputs`)
- **AND** stores the package only if validation succeeds

#### Scenario: Invalid package rejection
- **GIVEN** a plugin package missing `plugin.yaml`
- **WHEN** the package is uploaded
- **THEN** the system rejects the upload
- **AND** returns a validation error describing missing files

### Requirement: Plugin Package Storage Backends
The system SHALL store plugin packages using a configured backend and expose them through the web-ng API for agent download.

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

### Requirement: Plugin Assignment and Distribution
The control plane SHALL allow assigning plugin packages to agents and SHALL deliver assignments through the agent config response.

#### Scenario: Assign plugin to an agent
- **GIVEN** a plugin package exists
- **WHEN** an admin assigns the plugin to an agent
- **THEN** the next `AgentConfigResponse` includes a plugin assignment with package reference, schedule, and timeout
- **AND** the config version changes

#### Scenario: No assignment change
- **GIVEN** an agent with current plugin assignments
- **WHEN** the agent polls for config
- **THEN** the control plane returns `not_modified: true`
- **AND** the agent continues using cached plugin packages

### Requirement: Agent Wasm Runtime Sandbox
The agent MUST execute plugins in a sandboxed Wasm runtime with resource limits and must not expose raw filesystem or socket access.

#### Scenario: Resource limits enforced
- **GIVEN** a plugin configured with `max_memory_mb: 32` and `max_cpu_ms: 5000`
- **WHEN** the plugin executes
- **THEN** the agent enforces the memory limit
- **AND** terminates execution on timeout

#### Scenario: Plugin crash isolation
- **GIVEN** a plugin that traps or panics
- **WHEN** it executes
- **THEN** the agent reports an `UNKNOWN` result for that plugin
- **AND** the agent process continues running

### Requirement: Host Function Capabilities
Plugins SHALL access external resources only through declared host functions, and the agent SHALL enforce capability and permission checks on each call.

#### Scenario: HTTP proxy allowlist
- **GIVEN** a plugin with `allowed_domains: ["api.example.com"]`
- **WHEN** the plugin calls `http_request` for `https://api.example.com/health`
- **THEN** the agent performs the request and returns the response

#### Scenario: HTTP proxy denied
- **GIVEN** a plugin with `allowed_domains: ["api.example.com"]`
- **WHEN** the plugin calls `http_request` for `https://google.com/`
- **THEN** the agent denies the request
- **AND** returns a permission error to the plugin

### Requirement: Standardized Plugin Results
Plugins MUST report results using the `serviceradar.plugin_result.v1` schema, and the agent MUST map those results into `GatewayServiceStatus`.

#### Scenario: OK result mapping
- **GIVEN** a plugin result with `status: "OK"` and a summary string
- **WHEN** the agent submits the status to the gateway
- **THEN** `GatewayServiceStatus.available` is `true`
- **AND** `GatewayServiceStatus.message` contains the result JSON

#### Scenario: CRITICAL result mapping
- **GIVEN** a plugin result with `status: "CRITICAL"`
- **WHEN** the agent submits the status to the gateway
- **THEN** `GatewayServiceStatus.available` is `false`
- **AND** the summary is preserved in the result payload

### Requirement: Package Integrity Verification
The agent MUST verify package integrity using a hash and signature before executing a plugin.

#### Scenario: Invalid signature
- **GIVEN** a plugin package with a signature that does not match its hash
- **WHEN** the agent attempts to execute the plugin
- **THEN** the agent rejects the package
- **AND** reports an `UNKNOWN` result with an integrity error

### Requirement: Package Caching
The agent SHALL cache plugin packages by content hash and avoid re-downloading unchanged packages.

#### Scenario: Cached package reuse
- **GIVEN** an agent has already downloaded a plugin package with hash `abc123`
- **WHEN** the agent receives a config update referencing the same hash
- **THEN** it reuses the cached package
- **AND** does not re-download the binary
