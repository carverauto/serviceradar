## MODIFIED Requirements
### Requirement: Standardized Plugin Results
Plugins MUST report results using the `serviceradar.plugin_result.v1` schema, and the agent MUST map those results into `GatewayServiceStatus`.

Plugin results MAY include optional enrichment and event blocks. Camera-capable plugins MAY also publish camera source and stream descriptors for downstream inventory/relay use. Plugin results MUST NOT carry continuous live media payloads.

The ingestion pipeline MUST persist every accepted plugin result to historical `service_status` and MUST upsert the same latest result into the current service state read model using a stable service identity. Assignment placeholders MUST NOT overwrite a newer real plugin result.

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

#### Scenario: Plugin result updates current state
- **GIVEN** a scheduled plugin assignment has a pending placeholder state
- **WHEN** the plugin reports an OK, WARNING, CRITICAL, or UNKNOWN result
- **THEN** ingestion SHALL write the historical result to `service_status`
- **AND** upsert the latest result into the current service state read model for the same agent, gateway, partition, service type, and service name
- **AND** later assignment reconciliation SHALL NOT replace that result with `plugin assignment pending result`

#### Scenario: Current state can be rebuilt from history
- **GIVEN** historical plugin rows exist in `service_status` but the current service state row is missing
- **WHEN** the plugin service state repair path runs
- **THEN** it SHALL rebuild one active current-state row from the newest historical row for each plugin service identity

### Requirement: Plugin Assignment and Distribution
The control plane SHALL allow assigning plugin packages to agents and SHALL deliver assignments through the agent config response.

Assignments SHALL NOT embed reusable bearer download URLs for plugin blobs. Agents SHALL receive only the internal plugin reference material needed to perform an authenticated fetch without a tokenized URL appearing in config payloads. First-party assignments SHALL deliver the runtime configuration fields required by their plugin schemas before execution.

Only one package version for a given plugin ID SHALL be approved at a time. Approving a different version of the same plugin SHALL revoke the previously approved package and disable assignments that reference a superseded package.

An agent SHALL NOT receive more than one enabled assignment for the same plugin ID. Disabled historical assignments MAY remain for auditability but MUST NOT be included in generated agent config.

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

#### Scenario: First-party plugin receives required runtime config
- **GIVEN** an enabled first-party scheduled plugin assignment for AWX/AAP, Proxmox, AlienVault OTX, Dusk, UniFi Protect, or sample northbound NMS
- **WHEN** the control plane generates the agent plugin config
- **THEN** the assignment params SHALL include the required schema fields for that plugin or a typed configuration error before execution
- **AND** the generated permissions SHALL include only the approved capabilities and allowlists required by that plugin

#### Scenario: Approving a new package version supersedes the old version
- **GIVEN** plugin `proxmox-inventory` version `0.1.0` is approved
- **WHEN** an operator approves version `0.1.1` for the same plugin ID
- **THEN** version `0.1.0` SHALL be revoked
- **AND** assignments for version `0.1.0` SHALL be disabled
- **AND** the database SHALL reject a second simultaneously approved package for `proxmox-inventory`

#### Scenario: Duplicate enabled assignment rejected
- **GIVEN** an agent already has an enabled assignment for plugin `proxmox-inventory`
- **WHEN** another assignment for `proxmox-inventory` is created or enabled for the same agent
- **THEN** the database SHALL reject the duplicate enabled assignment
- **AND** generated agent config SHALL include only enabled assignments

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

#### Scenario: First-party plugin runtime smoke coverage
- **GIVEN** a first-party plugin is shipped with the repository
- **WHEN** the plugin is built for the agent Wasm runtime and executed with a valid fixture config and mocked host functions
- **THEN** it SHALL return a valid `serviceradar.plugin_result.v1` result without a Wasm trap
- **AND** any failure result SHALL contain a concise operator-actionable summary
