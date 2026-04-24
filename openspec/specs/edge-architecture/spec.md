# edge-architecture Specification

## Purpose
TBD - created by archiving change remove-elixir-edge-agent. Update Purpose after archive.
## Requirements
### Requirement: Edge Network Isolation

Edge components (agents, checkers) deployed in customer networks SHALL NOT join the ERTS Erlang cluster. Communication between edge and platform SHALL use gRPC with mTLS only.

#### Scenario: Edge agent cannot execute RPC on core
- **WHEN** an agent is deployed in customer network
- **AND** attempts to call `:rpc.call(core_node, Module, :function, [args])`
- **THEN** the call fails because no ERTS connection exists
- **AND** the agent has no knowledge of core node names

#### Scenario: Edge agent cannot enumerate cluster processes
- **WHEN** an agent is deployed in customer network
- **AND** attempts to query Horde registries
- **THEN** the query fails because agent is not a cluster member
- **AND** the agent cannot discover other tenants' processes

#### Scenario: Edge communicates via gRPC only
- **WHEN** an agent needs to report data to the platform
- **THEN** it initiates a gRPC connection to the gateway
- **AND** pushes status updates via gRPC
- **AND** no Erlang distribution protocol is used

### Requirement: Internal ERTS Cluster

Platform services (core, gateway, web-ng) running in Kubernetes SHALL form an ERTS Erlang cluster for distributed coordination. This cluster SHALL NOT include edge components.

#### Scenario: Horde registry for gateways
- **WHEN** gateways need to coordinate work distribution
- **THEN** they use Horde distributed registry
- **AND** only platform nodes participate in Horde

#### Scenario: Oban job scheduling across nodes
- **WHEN** scheduled jobs need to run
- **THEN** Oban coordinates via ERTS cluster
- **AND** jobs run on available platform nodes

#### Scenario: Phoenix PubSub for real-time updates
- **WHEN** real-time updates need to broadcast
- **THEN** Phoenix PubSub uses ERTS cluster
- **AND** web-ng receives updates from core/gateway

### Requirement: mTLS Agent Authentication

Edge agents SHALL authenticate using mTLS client certificates. Certificates SHALL encode tenant identity for multi-tenant isolation.

#### Scenario: Agent presents tenant certificate
- **WHEN** a gateway connects to an agent
- **THEN** mTLS handshake requires client certificate from gateway
- **AND** agent verifies gateway certificate is from platform CA

#### Scenario: Gateway verifies agent tenant
- **WHEN** a gateway receives data from an agent
- **THEN** the gateway extracts tenant ID from agent certificate
- **AND** verifies agent belongs to expected tenant
- **AND** rejects cross-tenant data

#### Scenario: Certificate encodes tenant identity
- **WHEN** an agent certificate is issued during onboarding
- **THEN** the certificate CN contains tenant slug
- **AND** SPIFFE ID encodes tenant workload identity
- **AND** certificate is signed by tenant-specific intermediate CA

### Requirement: Agent-Initiated Communication

Edge agents SHALL initiate gRPC connections to gateway endpoints to push status updates and results. Gateways SHALL NOT initiate outbound connections to edge agents.

#### Scenario: Agent pushes status to gateway
- **WHEN** an edge agent collects monitoring data
- **THEN** it opens a gRPC connection to the gateway endpoint
- **AND** it calls `PushStatus` or `StreamStatus` with the payload

#### Scenario: Gateway does not poll agents
- **WHEN** a gateway needs agent data
- **THEN** it waits for the agent to push updates
- **AND** it does not dial the agent endpoint directly

#### Scenario: Onboarding provides gateway endpoint
- **WHEN** an edge agent starts after onboarding
- **THEN** it receives the gateway endpoint in its configuration
- **AND** uses that endpoint to establish the gRPC session

### Requirement: Sysmon Metrics Ingestion

Sysmon metrics pushed via gRPC SHALL be routed to core ingestion and stored in tenant-scoped hypertables.

#### Scenario: Sysmon metrics forwarded to core
- **WHEN** an edge agent emits sysmon metrics
- **AND** the payload is sent with `source=sysmon-metrics`
- **THEN** the gateway forwards the payload to core ingestion
- **AND** core writes CPU, CPU cluster, memory, disk, and process metrics into tenant schemas

#### Scenario: Sysmon payload size tolerance
- **WHEN** a sysmon metrics payload exceeds the standard status size limit
- **THEN** the gateway accepts the larger payload up to the configured sysmon limit
- **AND** oversized payloads are rejected explicitly

### Requirement: Per-tenant gateway pools
The platform SHALL run a dedicated gateway pool per tenant, and each gateway instance SHALL register and operate only within that tenant scope.

#### Scenario: Tenant-specific gateway pool
- **GIVEN** tenant "acme" is provisioned
- **WHEN** gateway pools are created
- **THEN** at least one gateway instance is assigned to tenant "acme"
- **AND** that gateway is not eligible to serve other tenants

#### Scenario: Multi-gateway HA per tenant
- **GIVEN** tenant "acme" has two gateway instances
- **WHEN** one instance becomes unavailable
- **THEN** agent connections for tenant "acme" continue via the remaining instance
- **AND** cross-tenant traffic is never routed to the pool

### Requirement: Tenant-scoped gateway registration
Gateway registry entries SHALL include tenant identifiers and SHALL be used for tenant-scoped routing and coordination.

#### Scenario: Registry is tenant-scoped
- **WHEN** a gateway registers itself in the cluster
- **THEN** the registry entry includes the tenant identifier
- **AND** scheduling/routing queries only consider gateways for the same tenant

### Requirement: Platform SPIFFE mTLS for internal gRPC
Platform services, bootstrap tooling, and shipped runtime daemons that communicate over internal gRPC SHALL use authenticated transport and SHALL NOT silently fall back to plaintext when security configuration is omitted or explicitly set to insecure modes. Datasvc SHALL validate SPIFFE identities for platform services. When SPIFFE Workload API mode is enabled, Elixir and Rust services SHALL fetch X.509 SVIDs via the SPIRE agent socket. When SPIFFE is disabled for platform services, those services SHALL use file-based mTLS configuration so Docker Compose and non-SPIFFE environments remain functional.

#### Scenario: SPIFFE-enabled web-ng connects to datasvc
- **GIVEN** SPIFFE is enabled for the cluster
- **AND** web-ng has access to the SPIRE agent socket
- **WHEN** web-ng establishes a gRPC channel to datasvc
- **THEN** the connection uses a SPIFFE SVID for client authentication
- **AND** datasvc validates the SPIFFE identity of web-ng

#### Scenario: SPIFFE Workload API supplies SVIDs for Elixir services
- **GIVEN** SPIFFE Workload API mode is enabled
- **AND** the SPIRE agent socket is available in the pod
- **WHEN** web-ng or core-elx needs a gRPC client certificate
- **THEN** the service fetches an X.509 SVID and bundle from the Workload API
- **AND** the resulting mTLS credentials are used for the gRPC connection

#### Scenario: SPIFFE disabled uses file-based mTLS
- **GIVEN** SPIFFE is disabled for the deployment
- **WHEN** web-ng connects to datasvc
- **THEN** web-ng uses file-based mTLS certificates configured via environment variables
- **AND** the connection succeeds without SPIFFE dependencies

#### Scenario: Bootstrap tooling rejects missing transport security
- **GIVEN** bootstrap tooling needs to register a configuration template with core over gRPC
- **WHEN** `CORE_SEC_MODE` is empty or `none`
- **THEN** the tooling SHALL reject the registration attempt before dialing core
- **AND** it SHALL NOT fall back to plaintext transport

#### Scenario: Flowgger rejects insecure gRPC sidecar transport
- **GIVEN** `rust/flowgger` is configured with `grpc.listen_addr`
- **WHEN** `grpc.mode` is `none` or `grpc.mode = "mtls"` is configured without the required certificate paths
- **THEN** the gRPC sidecar configuration SHALL be rejected
- **AND** flowgger SHALL NOT serve the health sidecar over plaintext

### Requirement: Helm deploys agent-gateway with edge mTLS
Helm installs SHALL deploy `serviceradar-agent-gateway` when enabled in values. The workload SHALL serve edge-facing gRPC and gateway-served edge artifact delivery over tenant-issued mTLS certificates only. The gateway SHALL NOT use SPIFFE identities. Deployments that disable the gateway SHALL not render gateway workloads. If the edge-facing certificate bundle is unavailable, the gateway SHALL fail startup rather than serving plaintext edge listeners.

#### Scenario: Agent-gateway is deployed by Helm
- **GIVEN** a Helm install with agent-gateway enabled
- **WHEN** the chart is rendered and applied
- **THEN** a `serviceradar-agent-gateway` Deployment and Service are created
- **AND** the gateway pod reaches Ready state

#### Scenario: Gateway workload omits SPIRE socket
- **GIVEN** the agent-gateway workload is deployed
- **WHEN** the pod specification is inspected
- **THEN** the SPIRE agent socket is not mounted
- **AND** the gateway serves edge gRPC using tenant-issued mTLS only

#### Scenario: Gateway startup fails without edge certificates
- **GIVEN** the agent-gateway workload starts without the required edge-facing certificate files
- **WHEN** the application initializes the edge gRPC and artifact listeners
- **THEN** startup fails closed
- **AND** the gateway does not serve plaintext listeners for edge traffic

#### Scenario: Gateway disabled removes workloads
- **GIVEN** a Helm install with agent-gateway disabled
- **WHEN** the chart is rendered
- **THEN** no `serviceradar-agent-gateway` Deployment or Service is created

### Requirement: Agent-gateway uses tenant CA for edge mTLS
The agent-gateway SHALL use tenant-issued mTLS certificates for edge agent connections and MUST reject edge connections that are not signed by the expected tenant CA. The gateway's internal control-plane communication SHALL use ERTS where applicable and does not require SPIFFE. Gateway-issued edge certificate bundles SHALL be staged using secure temporary paths so private-key material is not written to predictable shared temp locations during issuance.

#### Scenario: Gateway uses tenant CA for edge mTLS
- **GIVEN** an edge agent presents a certificate signed by the tenant CA
- **WHEN** the agent connects to the gateway
- **THEN** the mTLS handshake succeeds
- **AND** the gateway derives tenant identity from the certificate

#### Scenario: Gateway rejects unknown tenant CA
- **GIVEN** an edge agent presents a certificate signed by an unknown CA
- **WHEN** the agent connects to the gateway
- **THEN** the gateway rejects the connection

#### Scenario: Gateway-issued bundle staging uses secure temp paths
- **GIVEN** the gateway issues an edge mTLS bundle for onboarding
- **WHEN** it stages the private key, CSR, and certificate before assembling the bundle
- **THEN** the staging paths are created with secure exclusive temp handling
- **AND** private-key material is removed during cleanup

### Requirement: Results ingestion uses gRPC/ERTS routing
The system SHALL ingest sync and sweep results through the standard gRPC results pipeline. The agent-gateway SHALL accept results via the existing `PushStatus` and `StreamStatus` methods and SHALL forward results to core without introducing sync-specific routing, handlers, or gateway-only behaviors.

#### Scenario: Sync results ingestion via gRPC stream
- **GIVEN** an agent emits sync results that exceed single-message limits
- **WHEN** the agent streams the results via `StreamStatus`
- **THEN** the agent-gateway forwards the chunked payload to core through the standard results pipeline
- **AND** no sync-specific handler or routing branch is applied in the gateway

#### Scenario: Status and results use standard methods
- **GIVEN** an agent emits regular status updates and smaller results payloads
- **WHEN** the agent calls `PushStatus`
- **THEN** the agent-gateway forwards the payload to core using the normal status/results routing
- **AND** the same routing logic applies regardless of whether the result is `sync` or `sweep`

### Requirement: Results routing is explicit by result type
The core results pipeline SHALL route sync and sweep results by type using dedicated handlers instead of relying on generic status handling.

#### Scenario: Results routing selects the correct handler
- **GIVEN** core receives a gRPC results payload tagged as `sync`
- **WHEN** the results pipeline processes the payload
- **THEN** it SHALL dispatch to the sync ingestor
- **AND** sweep payloads SHALL dispatch to the sweep ingestor

### Requirement: Sysmon metrics ingestion via gRPC
The system SHALL ingest sysmon metrics delivered over gRPC status updates into the tenant-scoped CNPG hypertables (`cpu_metrics`, `cpu_cluster_metrics`, `memory_metrics`, `disk_metrics`, and `process_metrics`).

#### Scenario: Sysmon metrics persisted for the agent device
- **GIVEN** an agent streams a `sysmon-metrics` status payload for tenant `platform`
- **WHEN** the gateway forwards the status update to core
- **THEN** core SHALL resolve the agent's device identifier
- **AND** core SHALL insert the parsed metrics into the `tenant_platform` hypertables

#### Scenario: Device mapping unavailable
- **GIVEN** an agent streams a `sysmon-metrics` status payload but has no linked device record
- **WHEN** the gateway forwards the status update to core
- **THEN** core SHALL ingest the metrics with a safe fallback device identifier or leave it null
- **AND** the ingest SHALL NOT fail due to missing device linkage

### Requirement: Sysmon payload size handling
The gateway SHALL accept `sysmon-metrics` payloads larger than the default status message limit and forward them without truncation.

#### Scenario: Large sysmon payload
- **GIVEN** a `sysmon-metrics` status payload larger than 4KB
- **WHEN** the gateway processes the message
- **THEN** the payload SHALL be accepted up to the configured sysmon limit
- **AND** the payload SHALL be forwarded to core intact

### Requirement: Mapper discovery runs inside the agent
The system SHALL run mapper discovery jobs inside `serviceradar-agent` and SHALL NOT deploy a standalone mapper service in default deployments.

#### Scenario: Deployment excludes mapper workload
- **GIVEN** a standard deployment (Helm or Compose)
- **WHEN** workloads are rendered or started
- **THEN** no `serviceradar-mapper` deployment or container is created
- **AND** mapper discovery is executed by the agent runtime

#### Scenario: Agent executes mapper discovery job
- **GIVEN** an agent with mapper config assigned
- **WHEN** the scheduled mapper job interval elapses
- **THEN** the agent executes mapper discovery locally
- **AND** records job status for reporting

### Requirement: Mapper discovery results ingestion via gRPC
Mapper discovery results SHALL be submitted by agents to the gateway via gRPC and forwarded to core ingestion without requiring a standalone mapper service.

#### Scenario: Agent pushes mapper discovery results
- **GIVEN** an agent completes a mapper discovery job
- **WHEN** it calls `PushResults` (or equivalent) with `result_type = mapper_discovery`
- **THEN** the gateway SHALL forward the results to core
- **AND** core SHALL ingest the discovery results into device inventory streams

#### Scenario: Mapper results routing is explicit
- **GIVEN** core receives a mapper discovery results payload
- **WHEN** the results pipeline processes the payload
- **THEN** it SHALL dispatch to the mapper discovery handler
- **AND** results SHALL not be treated as generic status updates

### Requirement: SPIFFE identity errors are actionable for Zen
When the zen consumer runs with SPIFFE-enabled gRPC, it SHALL treat SPIFFE Workload API "no identity issued" responses as configuration errors, log actionable guidance, retry for a bounded interval, and then exit with a clear error.

#### Scenario: Missing SPIFFE registration for zen
- **GIVEN** zen is configured to use SPIFFE for gRPC
- **AND** the SPIFFE Workload API returns PermissionDenied with "no identity issued"
- **WHEN** zen attempts to load its X.509 SVID
- **THEN** zen logs that SPIFFE registration is missing or mismatched and includes the trust domain
- **AND** zen retries for a bounded interval before exiting with an error

### Requirement: Analysis branches stay platform-local
The system SHALL run camera stream analysis from platform-local relay branches and SHALL NOT require browsers or external workers to connect directly to edge agents or customer cameras.

#### Scenario: External worker receives analysis input
- **GIVEN** an active camera relay session
- **WHEN** the platform forwards bounded analysis input to an external worker
- **THEN** the worker input SHALL originate from the platform relay branch
- **AND** the worker SHALL NOT open a direct session to the edge agent or customer camera

### Requirement: External analysis workers remain downstream of the platform
The system SHALL keep HTTP analysis workers downstream of the platform-local relay branch and SHALL NOT require them to connect directly to edge agents or customer cameras.

#### Scenario: Worker processes relay-derived media input
- **GIVEN** an active relay session with an attached analysis branch
- **WHEN** the platform dispatches bounded analysis input to an external HTTP worker
- **THEN** the worker input SHALL originate from the platform-local relay branch
- **AND** the worker SHALL NOT open a direct session to the edge agent or customer camera

### Requirement: The platform must provide an executable reference worker for analysis contracts
The system SHALL provide an executable reference analysis worker that validates the platform-owned analysis worker contract without requiring direct access to edge agents or customer cameras.

#### Scenario: Reference worker validates the contract
- **GIVEN** an active relay session with an attached analysis branch
- **WHEN** the platform dispatches a bounded analysis input to the reference worker
- **THEN** the worker SHALL process only the normalized platform input payload
- **AND** SHALL NOT open a direct session to the edge agent or customer camera

### Requirement: Boombox-backed analysis remains relay-attached
The system SHALL allow a Boombox-backed analysis adapter to consume relay-derived analysis media without requiring another upstream camera pull or direct worker access to edge cameras.

#### Scenario: Relay-derived media is bridged through Boombox
- **GIVEN** an active relay session with an attached analysis branch
- **WHEN** the platform enables a Boombox-backed analysis adapter for that branch
- **THEN** the adapter SHALL consume media from the platform relay branch
- **AND** SHALL NOT require a direct session to the edge agent or customer camera

### Requirement: Boombox analysis remains optional
The system SHALL treat Boombox as an optional analysis adapter and SHALL NOT require it for all analysis paths.

#### Scenario: Deployment uses another analysis adapter
- **GIVEN** a deployment that uses the existing HTTP analysis adapter
- **WHEN** Boombox is not enabled
- **THEN** the platform SHALL continue to support bounded analysis dispatch without Boombox

### Requirement: Boombox-backed sidecar workers remain relay-attached
The system SHALL allow a relay-scoped Boombox-backed sidecar worker path to consume bounded relay-derived media without requiring another upstream camera pull or direct camera session from the worker.

#### Scenario: Relay-derived media is consumed by a sidecar
- **GIVEN** an active relay session with an attached sidecar worker path
- **WHEN** the platform enables a sidecar worker for that branch
- **THEN** the worker SHALL consume media derived from the platform relay path
- **AND** SHALL NOT open a separate session to the edge agent or camera

### Requirement: Boombox sidecar workers remain optional
The system SHALL treat the Boombox-backed sidecar worker as an optional analysis path alongside the existing HTTP worker adapter.

#### Scenario: Deployment uses another analysis adapter
- **GIVEN** a deployment that uses the existing HTTP analysis adapter
- **WHEN** the Boombox-backed sidecar worker is not enabled
- **THEN** the platform SHALL continue to support analysis without the Boombox sidecar path

### Requirement: External Boombox workers remain relay-attached
The system SHALL allow a relay-scoped analysis branch to feed an external Boombox-backed worker without requiring another upstream camera pull or direct camera session from that worker.

#### Scenario: Relay-derived media is handed to an external worker
- **GIVEN** an active relay session with an attached analysis branch
- **WHEN** the platform enables an external Boombox-backed worker for that branch
- **THEN** the worker SHALL consume media derived from the platform relay path
- **AND** SHALL NOT open a separate session to the edge agent or camera

### Requirement: External workers remain optional
The system SHALL treat the external Boombox-backed worker as an optional analysis path alongside existing in-process and HTTP-based adapters.

#### Scenario: Deployment uses another analysis adapter
- **GIVEN** a deployment that uses another supported analysis adapter
- **WHEN** the external Boombox-backed worker is not enabled
- **THEN** the platform SHALL continue to support analysis without the external worker path

### Requirement: Camera analysis workers are platform-registered
The system SHALL maintain a platform-owned registry of camera analysis workers that can be targeted by relay-scoped analysis branches.

#### Scenario: A branch targets a registered worker
- **GIVEN** a camera analysis worker registered with the platform
- **WHEN** a relay-scoped analysis branch requests that worker by id
- **THEN** the platform SHALL resolve dispatch against the registered worker
- **AND** SHALL NOT require the branch to carry a raw endpoint as its only target model

### Requirement: Camera analysis workers can be selected by capability
The system SHALL support simple capability-based selection of camera analysis workers for relay-scoped branches.

#### Scenario: A branch requests a capability
- **GIVEN** multiple registered camera analysis workers
- **AND** at least one worker advertises the requested capability
- **WHEN** a relay-scoped analysis branch requests that capability
- **THEN** the platform SHALL resolve one matching worker
- **AND** SHALL surface an explicit bounded failure when no worker matches

### Requirement: Camera analysis worker selection is health-aware
The system SHALL maintain platform-owned health state for registered camera analysis workers and SHALL use that state during relay-scoped analysis worker selection.

#### Scenario: Capability selection skips unhealthy workers
- **GIVEN** multiple registered camera analysis workers with the requested capability
- **AND** one or more matching workers are marked unhealthy
- **WHEN** a relay-scoped analysis branch requests that capability
- **THEN** the platform SHALL select a healthy matching worker
- **AND** SHALL NOT select a worker marked unhealthy when a healthy match exists

#### Scenario: Explicit worker id targeting fails on an unhealthy worker
- **GIVEN** a registered camera analysis worker targeted by explicit id
- **AND** that worker is marked unhealthy
- **WHEN** a relay-scoped analysis branch requests that worker
- **THEN** the platform SHALL fail selection explicitly
- **AND** SHALL NOT silently reroute the branch to a different worker

### Requirement: Capability-targeted branches can fail over in a bounded way
The system SHALL support bounded worker failover for relay-scoped analysis branches that were targeted by capability rather than explicit worker id.

#### Scenario: Capability-targeted branch fails over after worker unavailability
- **GIVEN** a relay-scoped analysis branch selected by capability
- **AND** the selected worker becomes unavailable during dispatch
- **WHEN** the platform detects that unavailability
- **THEN** the platform SHALL attempt bounded reselection to another healthy matching worker
- **AND** SHALL stop after the configured bounded failover limit

### Requirement: Camera analysis workers have a supported management API
The system SHALL provide an authenticated management surface for platform-registered camera analysis workers.

#### Scenario: Operator lists registered workers
- **GIVEN** one or more registered camera analysis workers
- **WHEN** an authorized operator requests the worker list
- **THEN** the platform SHALL return the registered workers with identity, adapter, endpoint, capability, enabled, and health state

#### Scenario: Operator disables a worker
- **GIVEN** a registered camera analysis worker
- **WHEN** an authorized operator disables that worker through the management surface
- **THEN** the platform SHALL persist that state on the worker registry model
- **AND** subsequent dispatch selection SHALL treat that worker as unavailable

### Requirement: Active Camera Analysis Worker Probing
The platform SHALL actively probe registered camera analysis workers so worker health state is refreshed even when no relay-scoped analysis dispatch is in flight.

#### Scenario: Enabled worker passes active probe
- **WHEN** a registered enabled analysis worker responds successfully to the platform probe
- **THEN** the platform marks the worker healthy
- **AND** updates the worker health timestamps and clears stale failure reason state

#### Scenario: Enabled worker fails active probe
- **WHEN** a registered enabled analysis worker times out, returns a transport failure, or returns a non-success probe response
- **THEN** the platform marks the worker unhealthy
- **AND** records a normalized health reason and failure timestamp

### Requirement: Health-Aware Selection Uses Active Probe State
Capability-based worker selection SHALL honor the latest active probe health state stored in the worker registry.

#### Scenario: Capability selection skips actively unhealthy workers
- **WHEN** a capability-targeted analysis branch is opened
- **AND** one matching worker is unhealthy from active probing
- **THEN** the platform does not select that worker while a healthy compatible worker exists

#### Scenario: Explicit worker targeting remains fail-fast
- **WHEN** a branch explicitly targets a registered worker id
- **AND** that worker is unhealthy from active probing
- **THEN** the platform fails branch creation instead of silently rerouting to another worker

### Requirement: Camera Analysis Worker Probe Configuration
The platform SHALL support operator-managed probe configuration for registered camera analysis workers.

#### Scenario: Worker has explicit probe endpoint override
- **WHEN** an operator configures a worker with an explicit probe endpoint URL
- **THEN** the platform uses that endpoint for active health probing

#### Scenario: Worker uses bounded probe defaults
- **WHEN** an operator does not configure explicit probe overrides for a worker
- **THEN** the platform applies bounded default probe behavior

### Requirement: Active Probing Uses Registry-Managed Probe Settings
The active probe runtime SHALL use the current probe configuration stored on the worker registry record.

#### Scenario: Probe timeout override is configured
- **WHEN** a worker has an explicit probe timeout configured
- **THEN** the platform uses that timeout for active probing of that worker

### Requirement: Camera Analysis Worker Recent Probe History
The platform SHALL keep a bounded recent history of active probe outcomes for registered camera analysis workers.

#### Scenario: Successful probe is recorded
- **WHEN** the platform successfully probes a registered worker
- **THEN** it records a recent probe history item with success status and timestamp

#### Scenario: Failed probe is recorded
- **WHEN** the platform fails to probe a registered worker
- **THEN** it records a recent probe history item with failure status, timestamp, and normalized reason

#### Scenario: Probe history stays bounded
- **WHEN** probe outcomes exceed the configured recent-history capacity
- **THEN** the platform drops the oldest items and keeps the newest items only

### Requirement: Camera Analysis Workers SHALL Derive Flapping State
The platform SHALL derive a bounded flapping state for each registered camera analysis worker from recent probe history.

#### Scenario: Worker meets flapping threshold
- **WHEN** a worker's recent probe history contains enough healthy/unhealthy transitions to meet the configured threshold
- **THEN** the worker SHALL be marked as flapping
- **AND** the derived flapping metadata SHALL include the transition count and bounded history window size

#### Scenario: Worker falls below flapping threshold
- **WHEN** newer probe results reduce the transition count below the configured threshold
- **THEN** the worker SHALL no longer be marked as flapping

### Requirement: Camera Analysis Worker Flapping SHALL Be Recomputed On Probe Updates
The platform SHALL recompute worker flapping state whenever recent probe history changes through active probing or dispatch-driven health updates.

#### Scenario: Probe update changes flapping state
- **WHEN** a probe result is recorded on a worker
- **THEN** the platform SHALL recompute flapping state from the bounded recent probe history
- **AND** the stored worker record SHALL reflect the updated flapping state

### Requirement: Worker Alert Thresholds SHALL Derive From Authoritative Worker State
The platform SHALL derive camera analysis worker alert thresholds from the authoritative worker registry and runtime health updates.

#### Scenario: Threshold evaluation uses worker registry state
- **WHEN** worker health, flapping state, or failover outcomes change
- **THEN** the platform SHALL evaluate alert thresholds from the updated worker state
- **AND** it SHALL avoid maintaining a separate independent worker health model

### Requirement: Failover Exhaustion SHALL Produce A Worker Alert State
The platform SHALL derive a bounded worker alert state when capability-targeted analysis dispatch cannot find a healthy replacement worker.

#### Scenario: Capability failover cannot find a replacement
- **WHEN** a capability-targeted analysis worker fails and failover cannot resolve a healthy replacement
- **THEN** the platform SHALL derive an exhausted or unavailable alert state for the affected worker context
- **AND** it SHALL emit the corresponding alert transition signal

### Requirement: Worker alert routing uses authoritative registry state
The platform SHALL derive camera analysis worker alert routing inputs from the authoritative worker registry and runtime alert-transition path rather than from a parallel health model.

#### Scenario: Runtime transition produces routed alert input
- **WHEN** authoritative worker alert state changes in response to probe or dispatch-driven runtime updates
- **THEN** the platform SHALL build routed alert input from that same updated worker state
- **AND** the routed alert input SHALL include normalized worker identity and alert metadata

### Requirement: Worker alert routing preserves analysis-worker context
The platform SHALL preserve enough worker context in routed signals for operators to identify the affected worker and reason about the degradation cause.

#### Scenario: Routed worker alert includes context
- **WHEN** a worker alert transition is routed into the observability pipeline
- **THEN** the routed signal SHALL include the worker id
- **AND** it SHALL include normalized context such as adapter, capability, or failover reason when available

### Requirement: Camera analysis workers expose current assignment visibility
The platform SHALL derive current relay-scoped assignment visibility for registered camera analysis workers from the active analysis dispatch runtime.

#### Scenario: Worker has active assignments
- **GIVEN** one or more relay-scoped analysis branches are currently assigned to a registered worker
- **WHEN** the platform reads current worker assignment state
- **THEN** it SHALL report that worker's active assignment count
- **AND** it SHALL include bounded current assignment details for that worker

#### Scenario: Worker has no active assignments
- **GIVEN** no relay-scoped analysis branches are currently assigned to a registered worker
- **WHEN** the platform reads current worker assignment state
- **THEN** it SHALL report zero active assignments for that worker

### Requirement: Worker assignment visibility follows dispatch lifecycle
The platform SHALL update worker assignment visibility when analysis dispatch branches open, fail over, or close.

#### Scenario: Branch failover changes worker assignment
- **WHEN** an active analysis branch fails over from one registered worker to another
- **THEN** the previous worker's active assignment count SHALL decrease
- **AND** the replacement worker's active assignment count SHALL increase

### Requirement: Worker notification policy integration reuses routed alerts
The platform SHALL integrate camera analysis worker notifications from the existing routed alert lifecycle rather than from direct worker health transitions.

#### Scenario: Notification input comes from routed alert lifecycle
- **WHEN** a camera analysis worker alert becomes active
- **THEN** the platform SHALL derive notification-policy input from the routed observability alert
- **AND** it SHALL NOT create a parallel worker-only notification record

#### Scenario: Unchanged worker state remains duplicate-suppressed
- **GIVEN** repeated probe or dispatch failures occur while a worker remains in the same derived alert state
- **WHEN** notification-policy input is evaluated
- **THEN** the platform SHALL keep routed worker alert transitions duplicate-suppressed
- **AND** any repeated notifications SHALL come from the standard re-notify path instead

### Requirement: Worker notification audit state reuses routed alerts
The platform SHALL derive camera analysis worker notification audit state from the existing routed worker alert and standard alert lifecycle rather than a parallel worker notification model.

#### Scenario: Audit state comes from standard alert lifecycle
- **WHEN** the platform needs notification audit state for a worker alert
- **THEN** it SHALL resolve that state from the routed worker alert's corresponding standard alert record
- **AND** it SHALL NOT persist a separate worker notification record

### Requirement: Camera media uploads complete with explicit terminal acknowledgment
Camera media uploads over the dedicated relay gRPC service SHALL explicitly terminate the request stream before the sender treats the upload as successful. A sender SHALL wait for the terminal acknowledgment from the next hop before considering the upload accepted.

#### Scenario: Gateway forwards a media upload batch to core-elx
- **GIVEN** the gateway is streaming one or more camera media chunks to the upstream relay ingress
- **WHEN** the current upload batch is complete
- **THEN** the gateway SHALL half-close the request stream
- **AND** SHALL wait for the upstream upload acknowledgment
- **AND** SHALL NOT report upload success to the sender until that acknowledgment is received

### Requirement: Gateway relay lease state mirrors upstream relay decisions
The gateway camera relay session state SHALL preserve the upstream relay lease expiry and drain status returned by core-elx rather than synthesizing incompatible local lease state.

#### Scenario: Upstream heartbeat extends the relay lease
- **GIVEN** core-elx accepts a relay heartbeat and returns an updated lease expiry
- **WHEN** the gateway updates its local relay session
- **THEN** the gateway SHALL persist the upstream lease expiry on the session
- **AND** downstream viewers and agents SHALL observe the upstream relay lease state rather than a gateway-local replacement

### Requirement: Camera media uses gRPC at the edge and ERTS inside the platform
Live camera media transport SHALL use the dedicated camera media gRPC service only on the edge-facing `agent -> serviceradar-agent-gateway` hop. After `serviceradar-agent-gateway` terminates edge gRPC and authenticates the session, platform-internal camera media forwarding to `serviceradar_core_elx` SHALL use ERTS-native messaging.

#### Scenario: Gateway forwards media to core without an internal gRPC hop
- **GIVEN** an authenticated agent uploads camera media to `serviceradar-agent-gateway`
- **WHEN** the gateway forwards that session into the platform
- **THEN** the gateway SHALL use an ERTS-native ingress boundary in `serviceradar_core_elx`
- **AND** the gateway SHALL NOT open a second gRPC media channel to `serviceradar_core_elx`

### Requirement: Camera relay ingress is session-scoped inside the platform
The platform SHALL allocate a session-scoped ingress target for each live camera relay so high-rate media chunks can be forwarded without per-chunk distributed RPC negotiation.

#### Scenario: Gateway reuses an ingress target for a relay session
- **GIVEN** `serviceradar-agent-gateway` has opened a camera relay session with `serviceradar_core_elx`
- **WHEN** subsequent media chunks or heartbeats arrive for that relay session
- **THEN** the gateway SHALL reuse the previously allocated ingress target for the session
- **AND** per-chunk routing SHALL NOT require fresh service discovery or a new gRPC connection

### Requirement: External DNS authority is explicitly scoped
The shipped `k8s/external-dns` deployment SHALL limit DNS publication authority to the ServiceRadar namespaces and resources that are explicitly intended for external record management.

#### Scenario: Default external-dns render
- **WHEN** the external-dns base manifests are rendered as shipped
- **THEN** the controller only watches the explicit ServiceRadar namespaces configured by the repository
- **AND** it does not publish records for unannotated Services or Ingresses

#### Scenario: Explicit DNS publication
- **WHEN** a Service or Ingress in an allowed namespace carries the external-dns hostname annotation
- **THEN** the controller remains eligible to publish records for that resource within the configured managed zones

### Requirement: Release artifact mirroring validates every fetch hop
The platform SHALL mirror release artifacts only from outbound destinations that satisfy the release fetch policy on every HTTP hop, including redirects. Mirroring SHALL reject redirects that resolve to disallowed, private, loopback, link-local, or non-HTTPS destinations.

#### Scenario: Redirect target is revalidated before mirroring continues
- **GIVEN** a signed release manifest references an HTTPS artifact URL on an allowed public host
- **AND** that host responds with a redirect
- **WHEN** core mirrors the artifact
- **THEN** the redirect target is normalized and revalidated through the release fetch policy before any follow-up request
- **AND** mirroring fails closed if the redirect target is disallowed

#### Scenario: URL without a path still mirrors safely
- **GIVEN** a valid artifact URL whose parsed path is empty
- **WHEN** core derives the mirrored object name
- **THEN** it uses a safe fallback basename
- **AND** mirroring does not crash on path extraction

### Requirement: Release artifact mirroring enforces bounded downloads
The platform SHALL enforce the mirrored artifact byte limit while streaming the download, and SHALL abort the fetch as soon as the artifact exceeds the configured limit instead of buffering the full response in memory.

#### Scenario: Oversize artifact is rejected during streaming
- **GIVEN** a mirrored artifact response exceeds the configured maximum mirror size
- **WHEN** core streams the artifact download
- **THEN** the transfer is aborted once the limit is exceeded
- **AND** the artifact is not uploaded into internal storage

### Requirement: Edge-site setup bundles treat site metadata as data
Generated edge-site NATS leaf setup artifacts SHALL shell-escape edge-site names and other interpolated site metadata before embedding them into operator-run shell content.

#### Scenario: Edge-site name containing shell metacharacters does not execute
- **GIVEN** an edge site name contains shell metacharacters such as `$()`, backticks, or quotes
- **WHEN** the platform generates the NATS leaf setup script or related shell-facing bundle content
- **THEN** the resulting script treats the site name as literal text
- **AND** no command substitution or injected shell syntax is introduced

### Requirement: Default demo Kubernetes base omits host SPIRE socket mounts
The default `k8s/demo/base` deployment path SHALL NOT mount host SPIRE Workload API sockets into workloads unless SPIRE is explicitly enabled through a dedicated opt-in path.

#### Scenario: Default demo base render
- **WHEN** the default demo base is rendered without the optional SPIRE resources
- **THEN** workloads in the base do not include `hostPath` mounts for `/run/spire/sockets`
- **AND** their runtime environment does not require a SPIRE workload socket to start

#### Scenario: SPIRE opt-in render
- **WHEN** an operator explicitly enables the SPIRE-specific demo path
- **THEN** only the SPIRE-enabled workloads receive the required socket mounts and SPIRE-specific runtime wiring

### Requirement: Demo overlays keep datasvc internal by default
The shipped `k8s/demo/prod` and `k8s/demo/staging` overlays SHALL keep datasvc internal-only by default and SHALL NOT publish datasvc gRPC through an external service unless the operator explicitly opts in.

#### Scenario: Default prod overlay render
- **WHEN** the prod demo overlay is rendered as shipped
- **THEN** no external `LoadBalancer` or equivalent public-facing Service for datasvc is included by default

#### Scenario: Default staging overlay render
- **WHEN** the staging demo overlay is rendered as shipped
- **THEN** no external `LoadBalancer` or equivalent public-facing Service for datasvc is included by default

### Requirement: Agent release downloads preserve the initial trusted origin
The agent SHALL download release artifacts only from the initial trusted HTTPS origin selected for that release fetch. The agent MAY follow redirects only when the redirect target preserves the original scheme, host, and effective port. The agent SHALL reject redirects that change origin.

#### Scenario: Same-origin HTTPS redirect is allowed
- **GIVEN** the agent begins a release download from `https://releases.example.com/downloads/v1.2.3/agent`
- **AND** that endpoint redirects to `https://releases.example.com/artifacts/v1.2.3/agent`
- **WHEN** the agent follows the redirect
- **THEN** the redirect is accepted
- **AND** the agent continues verification of the signed manifest and artifact digest before staging the release

#### Scenario: Cross-origin redirect from a signed artifact URL is rejected
- **GIVEN** the agent begins a release download from a signed artifact URL on `https://releases.example.com`
- **AND** that endpoint redirects to `https://objects.example-cdn.com/agent`
- **WHEN** the agent evaluates the redirect
- **THEN** the redirect is rejected
- **AND** the release download fails closed

#### Scenario: Gateway-served artifact delivery cannot leave the gateway origin
- **GIVEN** the agent begins a managed release download through the gateway artifact transport on `https://gateway.example.internal`
- **AND** the gateway response attempts to redirect the download to `https://downloads.example.net/agent`
- **WHEN** the agent evaluates the redirect
- **THEN** the redirect is rejected
- **AND** the agent does not continue the release download outside the gateway origin

### Requirement: Browser camera egress stays platform-local
The system SHALL deliver WebRTC camera playback from platform-local services, and browsers SHALL NOT negotiate media sessions directly with edge agents or customer cameras.

#### Scenario: Browser opens a live camera view
- **GIVEN** an operator opens a live camera view in the browser
- **WHEN** the viewer requests WebRTC playback
- **THEN** the browser SHALL negotiate the session against platform-local signaling/media endpoints
- **AND** SHALL NOT contact the agent or camera directly

### Requirement: WebRTC viewer egress does not change edge uplink transport
The system SHALL keep the existing agent-originated media uplink architecture when adding WebRTC browser egress.

#### Scenario: WebRTC viewer attaches to an existing relay
- **GIVEN** an agent-originated camera uplink is already active for a relay session
- **WHEN** a browser viewer attaches using WebRTC
- **THEN** the agent-to-gateway and gateway-to-core ingest path SHALL remain unchanged
- **AND** only the browser-facing egress path SHALL differ

### Requirement: Gateways serve mirrored agent release artifacts
The edge architecture SHALL allow `agent-gateway` to serve mirrored agent release artifacts from internal object storage to authorized edge agents over HTTPS.

#### Scenario: Gateway serves a mirrored artifact
- **GIVEN** the control plane has mirrored a rollout artifact into internal object storage
- **AND** an authorized agent has an active rollout target for that artifact
- **WHEN** the agent requests the artifact from `agent-gateway`
- **THEN** the gateway retrieves the object from internal storage and serves it over HTTPS
- **AND** the gateway does not need direct artifact bytes embedded in the control command stream

#### Scenario: Internal artifact storage supports repo-hosted source of truth
- **GIVEN** the operator uses GitHub, Forgejo, or Harbor as the source of truth for published releases
- **WHEN** a release is imported into ServiceRadar
- **THEN** the control plane mirrors the release artifacts into internal storage
- **AND** gateways serve the mirrored copy to agents even if the agents cannot reach the original repository host

### Requirement: Edge camera media flows are agent-initiated
Live camera media flows SHALL be initiated from the edge agent toward `serviceradar-agent-gateway` and the platform. The platform SHALL NOT depend on inbound connectivity from the customer network or direct camera reachability for live viewing.

#### Scenario: Platform cannot route directly to the camera
- **GIVEN** a customer camera is behind private addressing or NAT
- **WHEN** an operator starts a live view session
- **THEN** the platform SHALL request the assigned agent to start the camera source session
- **AND** the agent SHALL initiate the media uplink toward the platform
- **AND** live viewing SHALL NOT require opening a platform-to-camera connection

### Requirement: Agent-gateway forwards camera media under edge identity
`serviceradar-agent-gateway` SHALL authenticate the edge agent for camera media sessions and forward those sessions only within the authenticated deployment scope.

#### Scenario: Authenticated camera media uplink
- **GIVEN** an enrolled agent starts a camera media session
- **WHEN** the uplink reaches `serviceradar-agent-gateway`
- **THEN** the gateway SHALL bind the session to the authenticated agent identity
- **AND** SHALL forward the session to the platform relay
- **AND** SHALL reject media uplinks from unauthenticated edge identities

### Requirement: Camera media transport is separate from monitoring status services
The system SHALL use a dedicated camera media service for live-view control and media uplink rather than carrying live camera transport over the generic monitoring status/results service.

#### Scenario: Live camera session starts
- **GIVEN** an operator requests a live camera session
- **WHEN** the platform coordinates the edge uplink
- **THEN** the agent, gateway, and platform SHALL use the camera media service for relay control and media transport
- **AND** the generic monitoring status/results service SHALL remain unchanged for health and plugin payload ingestion

