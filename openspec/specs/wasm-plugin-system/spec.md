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

The runtime SHALL support authenticated HTTP requests through headers for VAPIX API access and SHALL continue enforcing allowlists for domains, networks, and ports.

#### Scenario: Authenticated VAPIX request succeeds with allowlist
- **GIVEN** a plugin configured with `http_request` capability and allowlisted AXIS domain/IP
- **AND** an HTTP request that includes authorization headers
- **WHEN** the plugin issues the request
- **THEN** the agent SHALL forward the request and return response payload to the plugin

#### Scenario: Authenticated request denied by allowlist
- **GIVEN** a plugin configured with `http_request` capability
- **AND** an HTTP request to a non-allowlisted AXIS endpoint
- **WHEN** the plugin issues the request
- **THEN** the agent SHALL deny the request regardless of headers

### Requirement: Standardized Plugin Results
Plugins MUST report results using the `serviceradar.plugin_result.v1` schema, and the agent MUST map those results into `GatewayServiceStatus`.

Plugin results MAY include optional enrichment and event blocks. Camera-capable plugins MAY also publish camera source and stream descriptors for downstream inventory/relay use. Plugin results MUST NOT carry continuous live media payloads.

#### Scenario: Camera discovery plugin publishes descriptors
- **GIVEN** a camera discovery plugin result containing source identifiers, stream descriptors, and status
- **WHEN** the payload is ingested
- **THEN** service status ingestion SHALL still preserve the plugin status
- **AND** the camera descriptors SHALL be routed into camera inventory processing
- **AND** no live media bytes SHALL be expected in the plugin result payload

#### Scenario: Plugin result without camera descriptors
- **GIVEN** a standard plugin result payload containing only status and summary
- **WHEN** the payload is ingested
- **THEN** ingestion SHALL behave exactly as before

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

### Requirement: First-Party Wasm OCI Artifacts Publish Upload-Signature Metadata
First-party Wasm plugin OCI artifacts published by the repository SHALL include upload-signature metadata that is compatible with the control-plane uploaded-package verification policy.

#### Scenario: Published Wasm OCI artifact includes upload-signature sidecar
- **GIVEN** a first-party Wasm plugin bundle published to Harbor
- **WHEN** an operator or CI workflow inspects the OCI artifact
- **THEN** the artifact SHALL include the canonical bundle payload
- **AND** it SHALL include an additional upload-signature metadata sidecar
- **AND** the sidecar SHALL identify the signing key and plugin content hash

#### Scenario: Upload-signature payload matches control-plane verification semantics
- **GIVEN** a first-party Wasm plugin manifest and Wasm content hash
- **WHEN** the repository generates the upload-signature sidecar
- **THEN** the Ed25519 signature SHALL cover the same canonical payload used by `web-ng` upload verification
- **AND** the sidecar SHALL be sufficient for a later import workflow to verify package trust without inventing a first-party-only signature format

### Requirement: Release Verification Enforces Wasm Upload Signatures
The repository release and verification workflows SHALL fail first-party Wasm plugin publication when the upload-signature sidecar is missing or invalid.

#### Scenario: Valid upload-signature sidecar passes verification
- **GIVEN** a published first-party Wasm plugin OCI artifact with a valid upload-signature sidecar
- **WHEN** the repository verification workflow runs
- **THEN** the workflow SHALL verify the upload-signature metadata against the trusted public key
- **AND** the artifact SHALL be considered publishable

#### Scenario: Missing or invalid upload-signature sidecar fails verification
- **GIVEN** a published first-party Wasm plugin OCI artifact missing the upload-signature sidecar or containing an invalid Ed25519 signature
- **WHEN** the repository verification workflow runs
- **THEN** verification SHALL fail
- **AND** the release workflow SHALL NOT treat the plugin artifact as successfully published

### Requirement: First-party plugin publication artifacts match the bundle contract
First-party Wasm plugins published by the repository SHALL use the same bundle contract accepted by the plugin import system rather than publishing a naked Wasm binary alone.

#### Scenario: Published artifact contains importable bundle contents
- **GIVEN** a first-party Wasm plugin published to Harbor
- **WHEN** the artifact payload is fetched
- **THEN** it SHALL contain the plugin manifest and Wasm binary
- **AND** it MAY contain optional sidecar files such as config schema or display contract

#### Scenario: Published artifact remains compatible with import validation
- **GIVEN** a first-party Wasm plugin bundle published from the repository
- **WHEN** the bundle is later submitted to the control-plane import flow
- **THEN** the same manifest and sidecar validation rules SHALL apply
- **AND** no alternate first-party-only package format SHALL be required

### Requirement: Streaming plugins use a distinct long-lived runtime mode
The agent SHALL support a distinct streaming plugin mode for Wasm plugins that need to maintain a live media session. This mode SHALL be separate from the bounded execution path used for scheduled plugins that emit `serviceradar.plugin_result.v1`.

#### Scenario: Streaming plugin runs without using the one-shot result runtime
- **GIVEN** a Wasm plugin assignment with streaming media capability
- **WHEN** the agent starts the plugin for a camera relay session
- **THEN** the plugin SHALL run in the streaming plugin mode
- **AND** the agent SHALL NOT require the plugin to terminate immediately after emitting a `plugin_result`

### Requirement: Streaming plugins use a host media bridge
Streaming plugins SHALL access live camera media transport through dedicated host functions for media session open, chunk write, heartbeat, and close. The agent SHALL enforce capability and permission checks on those calls.

#### Scenario: Streaming plugin writes media through host functions
- **GIVEN** a streaming plugin has been granted camera media capability
- **WHEN** the plugin opens a relay session and writes encoded media chunks
- **THEN** it SHALL do so through the host media bridge
- **AND** the agent SHALL reject media bridge calls from plugins without the required capability

