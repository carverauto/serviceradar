# wasm-plugin-system Specification

## Purpose
TBD - created by archiving change add-wasm-plugin-system. Update Purpose after archive.
## Requirements
### Requirement: Plugin Package Format
The system SHALL accept plugin packages that include a manifest YAML and a Wasm binary, and it SHALL validate required metadata (including resource requests) before storing or distributing the package.

#### Scenario: Valid package upload
- **GIVEN** a plugin package containing `plugin.yaml` and `plugin.wasm`
- **WHEN** the package is uploaded
- **THEN** the system validates required fields (`id`, `name`, `version`, `entrypoint`, `capabilities`, `outputs`, `resources`)
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

#### Scenario: GitHub repository source
- **GIVEN** a plugin package is configured to be sourced from a GitHub repository
- **WHEN** core fetches the package
- **THEN** core stores the package in the configured backend
- **AND** the web-ng API serves the package by reference ID

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
- **GIVEN** a plugin configured with `requested_memory_mb: 32` and `requested_cpu_ms: 5000`
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

### Requirement: Plugin Result Ingestion Compatibility
The gateway/core ingestion pipeline MUST accept `serviceradar.plugin_result.v1` payloads without breaking existing checker ingestion, and it MUST preserve perfdata and structured metrics.

#### Scenario: Dedicated result processor
- **GIVEN** a plugin result payload in `serviceradar.plugin_result.v1`
- **WHEN** the gateway forwards the payload to core
- **THEN** core routes it through a plugin result processor that preserves perfdata and metrics

#### Scenario: Legacy checker ingestion unaffected
- **GIVEN** legacy checker statuses arriving at the gateway
- **WHEN** plugin results are enabled
- **THEN** the legacy ingestion path continues unchanged

### Requirement: Package Integrity Verification
The agent MUST verify package integrity using a hash and signature before executing a plugin.

#### Scenario: Invalid signature
- **GIVEN** a plugin package with a signature that does not match its hash
- **WHEN** the agent attempts to execute the plugin
- **THEN** the agent rejects the package
- **AND** reports an `UNKNOWN` result with an integrity error

### Requirement: GitHub Source Verification Policy
The system MUST allow configuring a policy that requires verification for GitHub-sourced plugin packages and it MUST enforce the policy in core before distribution.

#### Scenario: Verified GitHub package accepted
- **GIVEN** a GitHub-sourced plugin package with a valid GPG signature
- **WHEN** core validates the package
- **THEN** the package is accepted and stored for distribution

#### Scenario: Unverified package rejected
- **GIVEN** a GitHub-sourced plugin package without a valid GPG signature
- **AND** the verification policy requires verification
- **WHEN** core validates the package
- **THEN** the package is rejected
- **AND** it is not distributed to agents

### Requirement: Staged Import Review and Capability Confirmation
The system MUST stage every plugin import and require an explicit approve/deny decision with a diff view of requested vs approved capabilities and allowlists before a plugin is distributable.

#### Scenario: Import is staged with approve/deny
- **GIVEN** a newly uploaded or GitHub-sourced plugin package
- **WHEN** the package is staged for import
- **THEN** the system presents an approve/deny decision
- **AND** shows a diff view of requested vs approved capabilities and allowlists
- **AND** the package remains inactive until approved

#### Scenario: Capability override on import
- **GIVEN** a plugin requesting `http_request` and an allowlist of `api.example.com`
- **WHEN** an admin removes `http_request` or narrows the allowlist during import
- **THEN** the approved policy is persisted
- **AND** the plugin executes with the approved (reduced) capabilities

#### Scenario: Unapproved plugin not distributable
- **GIVEN** a plugin package that has not been approved
- **WHEN** an agent config is generated
- **THEN** the plugin is excluded from assignments

#### Scenario: Denied import remains blocked
- **GIVEN** a plugin package that was denied during import review
- **WHEN** an admin attempts to assign the plugin to an agent
- **THEN** the assignment is blocked

### Requirement: Core-Only GitHub Fetching
The system MUST ensure that agents never download plugin packages directly from GitHub.

#### Scenario: Agent receives only internal package references
- **GIVEN** a GitHub-sourced plugin assignment
- **WHEN** the agent fetches configuration
- **THEN** the assignment includes an internal package reference and hash
- **AND** no GitHub URL is provided to the agent

### Requirement: Package Caching
The agent SHALL cache plugin packages by content hash and avoid re-downloading unchanged packages.

#### Scenario: Cached package reuse
- **GIVEN** an agent has already downloaded a plugin package with hash `abc123`
- **WHEN** the agent receives a config update referencing the same hash
- **THEN** it reuses the cached package
- **AND** does not re-download the binary

### Requirement: Resource Budgeting and Admission Control
The system MUST support per-agent engine limits and per-plugin resource requests, and it MUST enforce admission control when requested resources exceed available capacity.

#### Scenario: Per-agent limits configured
- **GIVEN** an admin configures plugin engine limits for a specific agent (memory, CPU window, max concurrent plugins)
- **WHEN** the agent fetches configuration
- **THEN** the limits are applied to the plugin runtime

#### Scenario: Admission control rejects over-commit
- **GIVEN** per-agent limits of 256MB memory and 4 concurrent plugins
- **AND** existing plugin assignments already request 240MB and 4 slots
- **WHEN** a new plugin assignment requests 64MB and 1 slot
- **THEN** the assignment is rejected or queued
- **AND** the agent reports an `UNKNOWN` result indicating capacity exhaustion

### Requirement: Capacity Planning Visibility
The system SHALL expose plugin resource usage and capacity metrics in the Settings UI for each agent.

#### Scenario: Capacity view shows usage
- **GIVEN** an agent running multiple plugins
- **WHEN** an admin opens the agent capacity view
- **THEN** the UI shows current usage, configured limits, and remaining headroom

### Requirement: Runtime Telemetry Reporting
The agent MUST periodically report Wasm runtime health and resource usage telemetry to the control plane.

#### Scenario: Telemetry heartbeat
- **GIVEN** the agent has the Wasm runtime enabled
- **WHEN** the telemetry interval elapses
- **THEN** the agent submits a runtime status payload including engine health, resource usage, and recent execution stats
- **AND** the status is delivered through the normal `GatewayServiceStatus` pipeline

#### Scenario: Runtime unhealthy
- **GIVEN** the Wasm runtime fails to initialize or repeatedly crashes
- **WHEN** the agent emits runtime telemetry
- **THEN** the status indicates a degraded or unhealthy runtime
- **AND** the payload includes the failure reason

