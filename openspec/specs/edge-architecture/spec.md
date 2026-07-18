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

### Requirement: Default Helm Kubernetes install omits host SPIRE socket mounts
The default Helm Kubernetes installation path SHALL NOT mount host SPIRE Workload API sockets into workloads unless SPIRE is explicitly enabled through a dedicated opt-in path.

#### Scenario: Default Helm render
- **WHEN** the Helm chart is rendered without optional SPIRE resources
- **THEN** rendered workloads do not include `hostPath` mounts for `/run/spire/sockets`
- **AND** their runtime environment does not require a SPIRE workload socket to start

#### Scenario: SPIRE opt-in render
- **WHEN** an operator explicitly enables the SPIRE-specific Helm values
- **THEN** only the SPIRE-enabled workloads receive the required socket mounts and SPIRE-specific runtime wiring

### Requirement: Helm demo values keep datasvc internal by default
The shipped Helm demo values SHALL keep datasvc internal-only by default and SHALL NOT publish datasvc gRPC through an external service unless the operator explicitly opts in.

#### Scenario: Default demo values render
- **WHEN** the Helm chart is rendered with `helm/serviceradar/values-demo.yaml`
- **THEN** no external `LoadBalancer` or equivalent public-facing Service for datasvc is included by default

#### Scenario: Default demo staging values render
- **WHEN** the Helm chart is rendered with `helm/serviceradar/values-demo-staging.yaml`
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

### Requirement: Edge add-on metric feed
The agent SHALL be able to stream its locally collected metric samples to a
co-located native add-on through a dedicated `AddonService` RPC, before those
samples are published to the gateway. The feed SHALL apply flow control so a slow
add-on cannot block the agent's own collection or its gateway publishing path. An
add-on SHALL only receive the metric sources it explicitly declares.

#### Scenario: Add-on subscribes to local sysmon samples
- **WHEN** a native add-on declares a subscription to the local sysmon metric source
- **THEN** the agent SHALL stream locally collected sysmon `MetricBatch` samples to that add-on over the metric-feed RPC
- **AND** it SHALL NOT stream sources the add-on did not declare

#### Scenario: Slow add-on does not stall the agent
- **GIVEN** a co-located add-on is consuming the local metric feed slower than samples are produced
- **WHEN** the add-on falls behind
- **THEN** the agent SHALL apply bounded flow control to the feed
- **AND** the agent's own collection and gateway publishing SHALL continue unaffected

### Requirement: Native add-on resource governance
Native add-on manifests SHALL declare CPU and memory limits, and the add-on
supervisor and systemd unit generator SHALL enforce those limits. An add-on that
approaches its limit SHALL shed work and report the shed rather than impacting
the host or the agent.

#### Scenario: Add-on runs within a declared budget
- **WHEN** a native add-on is deployed with declared CPU and memory limits
- **THEN** the supervisor or systemd unit SHALL enforce those limits (for example `MemoryMax` and `CPUQuota`)
- **AND** the add-on SHALL NOT exceed its declared budget

#### Scenario: Add-on sheds under pressure
- **GIVEN** an anomaly add-on is approaching its memory or CPU limit
- **WHEN** the incoming series rate would exceed its bounded capacity
- **THEN** the add-on SHALL shed analysis for excess series
- **AND** it SHALL emit a telemetry counter recording the shed

### Requirement: Edge-resident per-series anomaly detection
A native anomaly add-on SHALL run the shared per-series detector extracted from
the former central raw-stream analyzer and SHALL own its per-series state
locally, without central ownership or a distributed lease. Detection verdicts
produced at the edge SHALL be equivalent to the verdicts the shared detector
produces for the same input.

#### Scenario: Edge verdict matches shared detector verdict
- **GIVEN** a captured set of metric samples for a series
- **WHEN** the edge anomaly add-on and the shared detector each process those samples
- **THEN** they SHALL produce the same anomaly verdicts

#### Scenario: Add-on restart re-warms without a verdict gap
- **GIVEN** an anomaly add-on with established per-series baselines
- **WHEN** the add-on restarts
- **THEN** it SHALL re-warm baselines from a local checkpoint or the live feed
- **AND** it SHALL suppress verdicts during a bounded warm-up window to avoid cold-start false positives

### Requirement: Edge Robust Dispersion Estimator

The edge anomaly detector SHALL stop self-masking, where a large spike inflates its own
mean/std baseline and hides a subsequent spike. Today the detector (`rust/anomaly-core`) computes
dispersion with Welford O(1) **mean/std** (non-robust). The detector SHALL EITHER (a) replace the
mean/std dispersion with a **robust median/MAD (Hampel) identifier**, OR (b) at minimum
**freeze (withhold) the baseline window updates during a confirmed breach** so the breaching
samples cannot enter the baseline. The detector SHALL **retain** the existing dispersion floors
(absolute + CV), the directional saturation gate for percent gauges (`min_value` 80/80/85 for
cpu/mem/disk), and the confirm-slot hysteresis defined in
`fix-anomaly-engine-semantics-and-delivery` (`Edge Detector Numeric Safety`,
`Anomaly Confirmation Slot Definition`); this change replaces only the dispersion estimator and
does not re-author those guards.

#### Scenario: A spike does not poison its own baseline

- **GIVEN** a series whose recent window contains one large sustained spike, followed by a second spike of similar magnitude
- **WHEN** the robust (median/MAD) detector — or the breach-freeze rule — scores the second spike
- **THEN** the second spike SHALL still breach (it SHALL NOT be masked by the first spike inflating the baseline)

#### Scenario: Existing guards are preserved

- **GIVEN** a cpu/mem/disk percent gauge below its saturation gate (`min_value` 80/80/85)
- **WHEN** the detector scores it under the robust dispersion estimator
- **THEN** the directional saturation gate, the dispersion floors, and the confirm-slot hysteresis SHALL still apply unchanged

### Requirement: Edge Drift Detection Via Two-Sided CUSUM

The edge detector SHALL add a **two-sided CUSUM** over the (deseasonalized, where available)
residual so slow drifts and leaks — which a point z-score cannot see — are detected. The CUSUM
SHALL accumulate signed residual deviations and SHALL signal when either the upward or downward
cumulative sum exceeds a configured decision threshold, complementing (not replacing) the spike
z-score.

#### Scenario: A slow leak is detected that a point z-score misses

- **GIVEN** a series that drifts slowly upward over a long window with no single sample exceeding the z-score threshold
- **WHEN** the two-sided CUSUM accumulates the signed residuals
- **THEN** the detector SHALL signal the drift once the cumulative sum crosses the decision threshold
- **AND** the point-z-score path SHALL remain unaffected for sudden spikes

### Requirement: Edge Deseasonalization From Coarse Hour-Of-Week Baseline

The edge detector SHALL support consuming a **coarse hour-of-week seasonal baseline** (sourced
from the core S-H-ESD seasonal profile). When a baseline is available for a series, the detector
SHALL score the **deseasonalized residual** (value minus the expected seasonal level) rather than
the raw value, so a normal recurring ramp (for example a morning business-hours ramp) does not
false-fire. When no baseline is available the detector SHALL fall back to scoring the raw value
as today.

#### Scenario: Morning ramp does not false-fire when a baseline is present

- **GIVEN** a series with a coarse hour-of-week baseline whose expected level rises during business hours
- **WHEN** the value rises along the expected seasonal level
- **THEN** the detector SHALL score the deseasonalized residual and SHALL NOT breach on the expected ramp

#### Scenario: Cold-start falls back to raw scoring

- **GIVEN** a series with no coarse hour-of-week baseline available
- **WHEN** the detector scores a sample
- **THEN** it SHALL score the raw value (current behavior) and SHALL NOT block on a missing baseline

### Requirement: Agent-routed remote access tunnel
The system SHALL provide a generic remote-access tunnel that routes operator sessions through web-ng, agent-gateway, and the selected edge agent before connecting to the target.

#### Scenario: Reach target only visible to an edge agent
- **GIVEN** a target device is reachable from agent `A` but not directly from the platform
- **AND** an operator is authorized for remote access to that target
- **WHEN** the operator starts a remote access session
- **THEN** web-ng SHALL create a session bound to agent `A`
- **AND** agent-gateway SHALL route frames over agent `A`'s authenticated control stream
- **AND** agent `A` SHALL open the protocol-specific connection to the target.

#### Scenario: Overlapping networks remain agent-scoped
- **GIVEN** two agents can each reach a target at `192.168.1.10` in different networks
- **WHEN** an operator opens a session for a specific inventory target
- **THEN** the session SHALL be bound to the agent selected by policy or inventory relationship
- **AND** browser create requests SHALL NOT select or override the agent or gateway route
- **AND** target host/port/protocol SHALL NOT be retargetable by browser-supplied frame data.

#### Scenario: Browser target override is disabled by default
- **GIVEN** an operator opens a session for a registered inventory target
- **WHEN** the browser create request supplies a different target host or target port
- **THEN** the public API SHALL reject the request unless the matching target override policy is explicitly enabled
- **AND** the target SHALL default to the inventory target selected by policy.

#### Scenario: Enabled target port override is range checked
- **GIVEN** target-port override policy is explicitly enabled
- **WHEN** the browser create request supplies a target port outside the valid TCP port range
- **THEN** the public API SHALL reject the request before a session ticket is issued.

#### Scenario: Public SSH endpoint cannot request other adapters
- **GIVEN** the public browser endpoint is authorized by the SSH remote-access permission
- **WHEN** the browser create request supplies a non-SSH protocol, non-SSH adapter, or non-inventory target kind
- **THEN** the public API SHALL reject the request before a session ticket is issued
- **AND** future protocol adapters SHALL use a dedicated endpoint or permission check before target access is opened.

#### Scenario: Terminal dimensions are bounded
- **WHEN** the browser create request, attach frame, or resize frame supplies terminal dimensions
- **THEN** the browser-facing boundary SHALL require integer columns and rows within deployment-safe bounds
- **AND** malformed terminal payloads SHALL be rejected before opening or resizing the agent-side adapter.

#### Scenario: Browser terminal data frames are bounded
- **WHEN** the browser sends terminal or protocol data frames
- **THEN** the browser-facing stream SHALL reject frames above the deployment-safe payload size before forwarding to the broker
- **AND** oversized data frames SHALL fail the session with a sanitized error.

#### Scenario: Agent control frames are independently bounded
- **WHEN** the selected agent receives remote-access open, data, or resize frames from the control stream
- **THEN** the agent-side session manager SHALL reject oversized open payloads, oversized terminal data, and invalid terminal dimensions before opening or writing to the target PTY
- **AND** invalid active-session frames SHALL close the session with a sanitized error frame.

#### Scenario: Agent output frames are bounded
- **WHEN** a target PTY adapter returns terminal output larger than the deployment-safe frame size
- **THEN** the agent-side session manager SHALL split the output into bounded data frames before forwarding it to the control stream
- **AND** the split output SHALL preserve byte order.

#### Scenario: SSH adapter inputs are bounded
- **WHEN** the SSH adapter decodes an open frame
- **THEN** it SHALL reject invalid target ports and oversized target, terminal, username, credential, certificate, password, or passphrase fields before dialing
- **AND** rejected SSH adapter input SHALL NOT invoke the dialer.

#### Scenario: Proxmox SSH compatibility inputs are bounded
- **WHEN** the legacy Proxmox SSH compatibility connector receives SSH target or credential config
- **THEN** it SHALL reject invalid target ports and oversized target, username, private key, password, or passphrase fields before dialing
- **AND** rejected compatibility input SHALL NOT invoke the dialer.

### Requirement: Remote access manages SSH host-key trust
The system SHALL maintain auditable SSH host-key trust state for agent-routed remote access without storing reusable login credentials.

#### Scenario: Trust-on-first-use host key is collected
- **GIVEN** the selected agent observes an unknown SSH host key for a remote-access target
- **WHEN** the session uses trust-on-first-use policy and no trusted key exists for the same agent-scoped target
- **THEN** the control plane SHALL record the key fingerprint, target, selected agent, lifecycle status, first seen time, and last seen time
- **AND** the record SHALL be trusted without storing user credentials or target login secrets.

#### Scenario: Host-key conflict is detected
- **GIVEN** a remote-access target already has a trusted SSH host key
- **WHEN** the selected agent observes a different key for the same agent-scoped target
- **THEN** the control plane SHALL record the new key as a conflict
- **AND** the conflict SHALL be auditable before an operator trusts, revokes, or rotates the key.

#### Scenario: Host-key rotation is audited
- **GIVEN** an operator approves a replacement key for the same agent-scoped target
- **WHEN** the host-key management API rotates the trusted key
- **THEN** the prior key SHALL be marked rotated with a replacement reference
- **AND** the replacement key SHALL be trusted
- **AND** trust and rotation audit events SHALL include actor, target, agent, key type, fingerprint, and lifecycle decision.

### Requirement: Teleport-like access capability coverage
The system SHALL evolve the remote-access tunnel into a ServiceRadar-native access plane with Teleport-like coverage while preserving ServiceRadar ownership of policy, inventory, agent routing, and audit data.

#### Scenario: Capability area is added incrementally
- **GIVEN** a capability such as SSH, session recording, application access, database access, Kubernetes access, desktop/RDP access, or enhanced host tracing is planned
- **WHEN** the capability is implemented
- **THEN** it SHALL reuse the generic session, authorization, audit, credential custody, and agent routing model
- **AND** protocol-specific behavior SHALL remain isolated to an adapter or collector boundary.

#### Scenario: Teleport implementation path is not license clean
- **GIVEN** a Teleport package or source path has AGPL headers or an AGPL transitive dependency path
- **WHEN** ServiceRadar implements equivalent functionality
- **THEN** the implementation SHALL be clean-room and ServiceRadar-authored
- **AND** it SHALL NOT copy, translate, or mechanically port that Teleport implementation source.

### Requirement: Remote access supports multiple protocols
The remote-access tunnel SHALL separate session lifecycle and routing from protocol-specific adapters and browser renderers.

#### Scenario: SSH and RDP use shared session lifecycle
- **GIVEN** SSH uses an xterm renderer and future RDP uses a graphical renderer
- **WHEN** either session is created
- **THEN** both SHALL use the same RBAC, audit, TTL, gateway routing, and agent ownership model
- **AND** only protocol adapter and browser renderer behavior SHALL differ.

#### Scenario: Generic SSH uses session-present credentials before certificate issuance is available
- **GIVEN** an operator opens an SSH terminal for a general inventory device
- **WHEN** short-lived certificate issuance is not yet available for that target
- **THEN** the browser SHALL collect the private key or password for that session only
- **AND** the platform SHALL forward it through the remote-access tunnel without persisting it in core, gateway, database, object storage, or plugin configuration
- **AND** the agent SHALL discard the credential when the session ends.

#### Scenario: Proxmox console does not require SSH keys
- **GIVEN** an operator opens a Proxmox node, LXC, or VM console
- **WHEN** the selected agent has an authorized Proxmox API credential grant
- **THEN** the Proxmox adapter SHALL request a temporary provider console ticket or proxy endpoint from the Proxmox API
- **AND** it SHALL route that console stream through the generic remote-access tunnel without requiring or storing SSH private keys.

#### Scenario: OT protocol adapter can be added later
- **GIVEN** a future OT integration needs CEA-852/CN-IP access to LonTalk networks through an edge agent
- **WHEN** representative test data or equipment is available
- **THEN** the adapter SHALL reuse the generic remote-access session, RBAC, audit, and agent routing model
- **AND** CEA-852-specific UDP/TCP framing and validation SHALL remain isolated to the protocol adapter.

#### Scenario: CEA-852 starts as read-only diagnostics
- **GIVEN** CEA-852/CN-IP can expose building-management systems to disruptive packet types and weak/default authentication conditions
- **WHEN** ServiceRadar first adds CEA-852 support
- **THEN** the adapter SHALL be limited to passive capture parsing or read-only diagnostics by default
- **AND** active packet crafting, reboot/configuration operations, or credential/key changes SHALL require a separate approved proposal, lab validation, explicit policy enablement, and audit coverage.

### Requirement: Future protocol adapters require approved proposals
Future app, database, Kubernetes, desktop/RDP, vSphere console, and OT adapters SHALL require per-protocol OpenSpec proposals and threat models before implementation.

#### Scenario: Adapter proposal defines the security contract
- **WHEN** ServiceRadar adds a new remote-access protocol adapter
- **THEN** the adapter proposal SHALL define protocol name, target resource type, agent capability flag, RBAC permissions, approval triggers, credential custody mode, recording policy, quota behavior, validation tests, demo proof path, and Teleport/source reuse license notes
- **AND** implementation SHALL NOT start until the proposal is approved.

#### Scenario: App access is not an open proxy
- **WHEN** ServiceRadar adds HTTP or HTTPS application access
- **THEN** the adapter SHALL route only to registered targets selected by trusted policy
- **AND** it SHALL reject arbitrary browser-supplied upstream hosts, routes, credentials, or CONNECT tunnel behavior unless a dedicated approved policy enables that behavior
- **AND** it SHALL define Host/SNI, header, origin-isolation, upstream TLS, request audit, and upload/download content boundaries.

#### Scenario: Database access protects query and result data
- **WHEN** ServiceRadar adds database access
- **THEN** the adapter SHALL avoid broad shared database credentials by preferring short-lived credentials, mTLS, or one-session broker grants
- **AND** it SHALL define read-only policy, query/result-size quotas, metadata recording, query redaction, and destructive-operation controls before target access opens.

#### Scenario: Kubernetes access preserves actor identity
- **WHEN** ServiceRadar adds Kubernetes API, exec, logs, or port-forward access
- **THEN** the adapter SHALL preserve the ServiceRadar actor through impersonation or short-lived client identity
- **AND** namespace, resource, verb, exec, and port-forward permissions SHALL be policy scoped
- **AND** bearer tokens, kubeconfigs, and client private keys SHALL NOT be persisted in recordings, audit events, or browser-visible metadata.

#### Scenario: Desktop and RDP access gates redirection features
- **WHEN** ServiceRadar adds graphical desktop or RDP access
- **THEN** clipboard, drive, printer, audio, smart-card, and file redirection SHALL be disabled by default
- **AND** each redirection feature SHALL require explicit RBAC and policy enablement
- **AND** screen recording, screenshot, frame-rate, bitrate, and credential-prompt handling SHALL be defined before production access.

#### Scenario: Provider console adapters use provider tickets
- **WHEN** ServiceRadar adds vSphere or similar provider-console access
- **THEN** the adapter SHALL use short-lived provider-issued console tickets or one-session provider grants
- **AND** provider API credentials and console tickets SHALL NOT be stored in browser request bodies, session metadata, recordings, or replay events
- **AND** power or configuration operations SHALL require a separate approved proposal.

### Requirement: Remote access auditability
The system SHALL record audit events for remote-access session lifecycle and policy decisions without storing plaintext credentials or terminal byte contents by default.

#### Scenario: Session is audited
- **WHEN** a remote-access session is created, attached, resized, closed, expires, or fails
- **THEN** the audit event SHALL include actor, target, selected agent, protocol, credential rule or custody mode, RBAC/approval result, timestamps, and terminal outcome
- **AND** the audit event SHALL NOT include plaintext credentials.

#### Scenario: Browser metadata cannot carry credentials
- **WHEN** a browser create request includes credential-shaped metadata such as private keys, passwords, passphrases, tickets, tokens, or secrets
- **THEN** the public API SHALL remove those fields before requesting a session
- **AND** only non-sensitive metadata SHALL be forwarded to the session lifecycle.

#### Scenario: Attach credential envelope is bounded
- **WHEN** the browser attach frame supplies SSH credential material
- **THEN** the browser-facing boundary SHALL reject oversized credential fields before starting the broker
- **AND** client-supplied identity claims, principal mappings, target routing fields, or credential-policy fields SHALL NOT be accepted from the credential envelope.

#### Scenario: Session recording is policy controlled
- **GIVEN** session recording is disabled by policy
- **WHEN** operators use a remote shell
- **THEN** terminal byte contents SHALL NOT be persisted
- **AND** lifecycle audit events SHALL still be recorded.

#### Scenario: Browser cannot choose recording policy
- **WHEN** the browser create request supplies recording or enhanced-recording policy fields
- **THEN** the public API SHALL reject the request before a session ticket is issued
- **AND** recording policy SHALL be selected only by trusted remote-access policy.

#### Scenario: Browser cannot choose credential rules
- **WHEN** the browser create request supplies a credential rule ID
- **THEN** the public API SHALL reject the request before a session ticket is issued
- **AND** credential rule selection SHALL be selected only by trusted remote-access policy.

#### Scenario: Recording manifest tracks retention without plaintext defaults
- **GIVEN** session recording is enabled by policy
- **WHEN** a remote-access session opens, exchanges terminal data, and closes
- **THEN** the system SHALL persist a recording manifest with storage pointer, retention expiry, lifecycle status, and aggregate input/output byte counters
- **AND** raw terminal byte contents SHALL NOT be persisted unless a separate explicit content-recording policy permits it.

### Requirement: Remote access file transfer is policy controlled
The system SHALL plan SFTP/SCP-style file transfer as a remote-access capability that inherits session identity, RBAC, approval, credential custody, recording, quota, and target routing gates.

#### Scenario: Browser cannot choose file-transfer policy
- **WHEN** the browser requests a file-transfer operation
- **THEN** the browser-facing API SHALL accept only bounded operation, direction, and path intent fields
- **AND** it SHALL reject client-supplied route, selected agent, target host, credential rule, custody, recording policy, content-audit policy, approval, or quota fields
- **AND** trusted remote-access policy SHALL select the final route, credential mode, recording behavior, and quota before target access starts.

#### Scenario: File transfer requires scoped RBAC and approval
- **GIVEN** an operator requests list, download, upload, or file-management access
- **WHEN** the operator lacks the required file-transfer permission or a required approval is missing, expired, or mismatched
- **THEN** the system SHALL deny the transfer before the selected agent opens a target file handle
- **AND** the denial SHALL be audited without exposing credentials or file contents.

#### Scenario: Path and quota policy are enforced before access
- **GIVEN** a file-transfer policy defines path rules, symlink behavior, byte limits, file-count limits, recursive-depth limits, or concurrent-transfer limits
- **WHEN** a transfer is requested
- **THEN** the selected agent SHALL enforce those policy gates before opening or mutating target files
- **AND** relative paths, symlinks, and realpaths SHALL be validated according to policy
- **AND** unclear or unverifiable paths SHALL fail closed.

#### Scenario: Content audit stores metadata by default
- **WHEN** a file transfer starts, progresses, completes, or fails
- **THEN** the system SHALL record transfer lifecycle metadata, byte counts, status, policy decision, and hashes when enabled
- **AND** file contents SHALL NOT be persisted in recordings, replay events, audit events, or exports unless an explicit content-audit policy enables a sensitive artifact retention path.

#### Scenario: SFTP is the first-class transfer model
- **WHEN** ServiceRadar adds file-transfer support
- **THEN** SFTP SHALL be the preferred first implementation because it exposes structured operations for policy, quota, and audit
- **AND** SCP compatibility SHALL NOT be added unless it maps to the same transfer manager, authorization checks, quota enforcement, recording events, and content-audit controls.

### Requirement: Generic SSH uses certificate-first enterprise identity
Generic SSH remote access SHALL support an enterprise certificate flow where ServiceRadar exchanges an authenticated SSO identity and ServiceRadar RBAC decision for a short-lived OpenSSH user certificate.

#### Scenario: Authentik-backed user opens SSH session
- **GIVEN** an operator authenticated through Authentik with OIDC or SAML claims
- **AND** ServiceRadar RBAC maps those claims to allowed SSH principals for a registered target
- **AND** the target trusts the ServiceRadar SSH user CA through OpenSSH `TrustedUserCAKeys`
- **WHEN** the operator opens an SSH remote-access session
- **THEN** ServiceRadar SHALL sign a per-session public key with a TTL bounded by session and role policy
- **AND** the certificate SHALL be scoped to the actor, principal set, target, selected agent, protocol, and session
- **AND** no shared bastion account, reusable target password, generic agent-local target private key, or LDAP password pass-through secret SHALL be required.

#### Scenario: Authentik smoke path proves enterprise certificate flow
- **GIVEN** the Kubernetes Authentik namespace is reachable
- **WHEN** the Authentik/OpenSSH smoke harness runs
- **THEN** it SHALL provision disposable Authentik OIDC fixtures, exchange an authorization code for a signed ID token, verify the token through ServiceRadar OIDC handling, map claims to an SSH principal, issue a short-lived ServiceRadar OpenSSH certificate, and authenticate to an OpenSSH target through `TrustedUserCAKeys`
- **AND** it SHALL clean up disposable fixtures by default
- **AND** it SHALL NOT persist target passwords, shared bastion credentials, reusable private keys, ID tokens, or certificate envelopes.

#### Scenario: Certificate issuance is denied before target dial
- **GIVEN** the requested principal, target, agent route, approval, MFA state, or TTL violates policy
- **WHEN** the operator attempts to open an SSH session
- **THEN** ServiceRadar SHALL deny certificate issuance before the selected agent dials the target
- **AND** the denial SHALL be audited without exposing credential material.

#### Scenario: SSH certificate request and signer response fields are bounded
- **WHEN** ServiceRadar authorizes or signs an SSH certificate request
- **THEN** session, agent, public-key, target, principal, and signer-response certificate fields SHALL be bounded before issuance succeeds
- **AND** oversized certificate request or signer response fields SHALL be rejected without invoking target access.

#### Scenario: Identity claim principal expansion is bounded
- **WHEN** ServiceRadar maps OIDC/SAML identity claims to SSH principals
- **THEN** mapping count, claim value count, individual claim value size, and selected principal count SHALL be bounded
- **AND** oversized claim values SHALL NOT produce SSH principals.

### Requirement: Enhanced host-event tracing
The system SHALL support policy-controlled enhanced tracing for remote-access sessions on capable Linux agents.

#### Scenario: BPF tracing is required by policy
- **GIVEN** a remote-access policy requires enhanced tracing
- **AND** the selected agent cannot start the required BPF collectors
- **WHEN** the operator starts the session
- **THEN** the session SHALL fail before target access is opened
- **AND** the failure SHALL be audited with a sanitized reason.

#### Scenario: BPF tracing records session-correlated events
- **GIVEN** enhanced tracing is enabled for an active session
- **WHEN** commands execute, files are opened, or network connections are attempted from the session context
- **THEN** the agent SHALL emit normalized events correlated to the remote-access session
- **AND** the events SHALL include dropped-event counters when kernel or user-space buffers lose data
- **AND** the events SHALL NOT include plaintext credentials, terminal input bytes, or file contents.

#### Scenario: Required BPF uses ServiceRadar-owned cilium runtime
- **GIVEN** a remote-access policy requires BPF enhanced recording
- **WHEN** the selected agent evaluates whether it can satisfy the policy
- **THEN** the agent SHALL use the shared ServiceRadar `go/pkg/agent/ebpf` runtime backed by `github.com/cilium/ebpf`
- **AND** it SHALL NOT use Teleport BPF implementation source unless the exact source path and transitive dependency path have been cleared for Apache-2.0 reuse.

#### Scenario: BPF loss counters are auditable
- **GIVEN** BPF enhanced recording is active
- **WHEN** kernel buffers, parser logic, or user-space backpressure drop events
- **THEN** the agent SHALL emit loss-counter events correlated to the remote-access session
- **AND** policy MAY later fail closed when loss exceeds a configured threshold.

### Requirement: Remote-Access Adapter Security Review Gate
Every remote-access protocol adapter (SSH, RDP/desktop, file-transfer, recording, application/TCP, database, Kubernetes, MCP, and future protocols) SHALL pass a documented security review covering authentication/authorization, credential custody (in-memory, at-rest, in-transit), input handling, transport/protocol hardening, data lifecycle, failure modes, dependency licensing, and browser-side surface before it is enabled by default in any environment.

#### Scenario: New adapter requires review record
- **WHEN** a new remote-access protocol adapter is proposed
- **THEN** the proposal MUST include a threat-model section and a dependency/license scan
- **AND** the adapter MUST be feature-flagged off until the review is signed off

#### Scenario: Existing adapter changes require delta review
- **WHEN** an adapter is materially extended (new redirection channel, new credential mode, new transport, new browser path)
- **THEN** the change MUST update the adapter's threat-model record and re-run the dependency/license scan

### Requirement: Credential Custody and Zeroisation
Remote-access components SHALL minimise credential residency in memory, at rest, and in audit trails. In-memory credentials MUST be zeroised on session end. Static long-lived credential references MUST NOT be used; credential references handed to agents or browsers MUST be HMAC-signed, time-bound (sub-minute TTL), and replay-rejecting. Audit trails MUST NOT capture credential-bearing inputs, secret refs, attach-ticket plaintexts, or grant metadata.

#### Scenario: In-memory secret zeroisation
- **WHEN** a session terminates or a credential grant is dropped
- **THEN** the structures holding password, secret-ref, CA bundle, and Kerberos ticket material MUST be wiped (Rust `Zeroize` / `Drop`; Elixir process-state purge)
- **AND** subsequent allocations MUST NOT be able to read residual bytes

#### Scenario: Credential reference replay rejected
- **WHEN** a credential reference handed to an agent has expired or been used once already (per protocol)
- **THEN** the reference dereferencing endpoint MUST refuse the lookup and emit an audit event

#### Scenario: Audit row free of sensitive inputs
- **WHEN** an audit / PaperTrail row is written for a remote-access action
- **THEN** the row MUST NOT include `credential_rule_id`, `approval_id`, `metadata` carrying secrets, `attach_ticket_hash` plaintext, or any `*_credential` / `*_secret` field
- **AND** field-level exclusion MUST be configured at the resource (not relied on at the call site)

### Requirement: Bastion Logging Confidentiality
The remote-access bastion's logging, tracing, and telemetry pipelines SHALL NOT emit RPC payload bodies, frame contents, credential references, or session secrets at any default log level. Per-method metadata (method name, duration, status, actor identifier) is permitted; payload bodies are not.

#### Scenario: gRPC interceptor body redaction
- **WHEN** a gRPC method is invoked on the agent-gateway or bastion
- **THEN** any interceptor emitting log entries MUST emit only `{method, duration, status, actor}` and MUST NOT serialise the request or response body

#### Scenario: Error path redaction
- **WHEN** an internal error occurs while handling agent or operator traffic
- **THEN** the error returned to the operator (terminal, browser, structured response) MUST be a generic message; full error detail MUST be logged server-side with audit context only

### Requirement: Authenticated Frame Routing
Inter-component frames carrying control or media for a remote-access session (broker frames, desktop-media frames, control-stream messages) SHALL be cryptographically bound to the originating component identity and the session they belong to. String-equality comparison of identifiers MUST NOT be the sole authorisation check.

#### Scenario: Forged session/agent id rejected at broker
- **WHEN** a broker receives a frame whose `(session_id, agent_id)` pair is correct but whose per-frame HMAC (over `session_id, agent_id, seq, payload_hash`) is invalid
- **THEN** the broker MUST reject the frame, emit an audit event, and continue routing other traffic

#### Scenario: Cross-agent media injection refused
- **WHEN** a desktop-media frame's declared `agent_id` or `partition_id` does not match the session's bound agent/partition
- **THEN** the media server MUST refuse the frame and emit an audit event

#### Scenario: Control stream re-validates per message
- **WHEN** a control-stream session receives a message after `register/1`
- **THEN** the handler MUST verify the inbound message's caller certificate matches the registered cert/agent_id before acting

### Requirement: Single-Use Session Attach Tickets
Session attach tickets SHALL be single-use within their TTL. The first successful consume MUST be atomic with the session's state transition; any subsequent consume of the same ticket MUST be refused with an audit event.

#### Scenario: Replay within TTL rejected
- **WHEN** a stolen but unexpired attach ticket is presented a second time
- **THEN** the consume action MUST return `invalid_or_expired` and emit an audit event identifying the replay attempt

### Requirement: Per-Action Authorization and Post-Authentication Re-Check
Authorisation for remote-access actions SHALL be enforced per-action — not only at mount or attach. Long-lived UI surfaces (LiveView event handlers, WebSocket message handlers, streaming HTTP responses) MUST re-check the actor's permission against the action before each effectful operation, OR subscribe to a permission-revocation channel that immediately terminates affected sessions.

#### Scenario: LiveView event without permission denied
- **WHEN** an authenticated operator triggers a mutating handle_event on a remote-access settings LiveView without holding the action's permission
- **THEN** the event MUST be refused and the audit event recorded

#### Scenario: Revocation mid-stream closes WebSocket
- **WHEN** an operator's permission to use a target is revoked while a remote-access WebSocket is open
- **THEN** the bastion MUST close the affected socket within seconds and notify the operator

### Requirement: Recording Integrity and Lifecycle Custody
Session recordings SHALL be append-only, hash-chained, and tamper-evident. Manifest finalisation MUST be idempotent and bind cryptographically to the event list. Recording deletion MUST be RBAC-gated, audited, and use a soft-delete + grace-period pattern. Storage-tier infrastructure identifiers (bucket names, object keys, backend type) MUST NOT be returned to clients.

#### Scenario: Manifest hash binds events
- **WHEN** a recording is finalised
- **THEN** the manifest's signature MUST cover the manifest contents AND a canonical digest of the event list
- **AND** any post-seal event with a sequence greater than the sealed `event_count` MUST be refused

#### Scenario: Double finalize prevented
- **WHEN** the broker's terminate path is reached after `handle_cast(:close)` already finalised
- **THEN** the second finalisation attempt MUST be a no-op and MUST NOT rewrite the sealed manifest

#### Scenario: Recording delete is RBAC-gated and audited
- **WHEN** a recording deletion is requested
- **THEN** the action MUST require an explicit `recording.delete` permission, set a tombstone with `{deleted_at, actor, reason}`, emit an audit event, and defer hard-delete until the retention grace period elapses

#### Scenario: Infrastructure paths not leaked
- **WHEN** the recording controller or LiveView serialises a recording for the client
- **THEN** `storage_backend`, `storage_bucket`, and `object_key` MUST NOT appear in the response

### Requirement: Recording Access Scoping
Read access to a recording or its events SHALL be scoped to the actor's permission for *that specific recording's* session and target. Holding a protocol-wide permission (e.g. `remote-access.ssh.open`) MUST NOT grant read access to recordings the actor was not a party to, unless an explicit broad-view permission is held.

#### Scenario: Cross-session recording read denied
- **WHEN** an operator who was not the session actor (and lacks `recordings.view_all`) attempts to read or export a recording
- **THEN** the request MUST be refused with a 403-equivalent and audited

#### Scenario: Export requires view permission
- **WHEN** a recording export is requested
- **THEN** the actor MUST hold both `recordings.export` AND the recording's read permission; export of recordings in `:active` / `:pending` status MUST be refused

### Requirement: Approval Workflow Integrity
Access-request approvals SHALL prohibit self-approval and use atomic state transitions. The approver's identity MUST differ from the requester's identity unless the request explicitly enables self-approval and that exception is itself audited.

#### Scenario: Self-approval forbidden by default
- **WHEN** the requester of an access request attempts to approve their own request without the `allow_self_approval` exception
- **THEN** the approve action MUST be forbidden by the resource policy

#### Scenario: Approval bind is atomic
- **WHEN** two concurrent attach attempts reference the same approval
- **THEN** only one bind MUST succeed; the loser MUST receive a deterministic failure and MUST NOT produce side effects (session creation, audit row) past the failed point

### Requirement: Desktop Adapter Redirection Default-Off
Desktop / RDP adapters SHALL ship with all device-redirection channels disabled by default. Enabling any redirection (clipboard, drives, printers, audio, smart-card, USB, file-copy) MUST require both an RBAC permission for the actor and a per-target policy opt-in. Browser-side equivalents (clipboard API, display-capture, screen-share) MUST also be denied unless the same gates are satisfied.

#### Scenario: Default-off enforced at adapter and policy layers
- **WHEN** a new desktop target is created with no explicit redirection policy
- **THEN** clipboard, drives, printers, audio, smart-card, USB, and file-copy redirection MUST all be off
- **AND** the connector MUST refuse to negotiate any redirection channel the target policy doesn't explicitly enable

#### Scenario: Browser surface mirrors backend policy
- **WHEN** an operator opens a desktop session in the browser
- **THEN** the served response MUST set Content-Security-Policy + Permissions-Policy denying clipboard-read, clipboard-write, display-capture, camera, microphone unless the target policy explicitly enables that surface

### Requirement: Agent Identity Lifecycle
Agent mTLS certificates SHALL be short-lived, revocable, and partition-bound at issuance. Default certificate TTL MUST be measured in days, not months. A revocation mechanism (in-memory denylist at minimum) MUST exist so a compromised agent can be excluded before TTL expiry. The certificate's partition / tenant binding MUST be derived from the authenticated provisioning context, not from caller-supplied request fields.

#### Scenario: Issuance requires partition authorisation
- **WHEN** a provisioning action requests issuance of an agent certificate for a partition
- **THEN** the issuer MUST verify the requesting actor is authorised for that specific partition before signing
- **AND** the resulting certificate's partition extension MUST be set from the authoritative actor context, not echoed from the request body

#### Scenario: Revocation excludes a stolen cert before expiry
- **WHEN** an operator marks an agent certificate as compromised via the admin endpoint
- **THEN** subsequent connections presenting that certificate MUST be refused by the gateway, even while the cert is still within its TTL

#### Scenario: Short TTL by default
- **WHEN** an agent certificate is issued without an explicit `validity_days` override
- **THEN** the default TTL MUST be at most a few days; any longer TTL MUST require an explicit override flag and an audit event recording the override

### Requirement: Bootstrap Token Lifecycle
Bootstrap / onboarding tokens SHALL be single-use, partition-bound in the signed payload, and time-limited. Server-side enforcement MUST refuse a second consume of the same token regardless of TTL.

#### Scenario: Token consumed once
- **WHEN** a download / onboarding token is consumed successfully
- **THEN** subsequent presentations of the same token MUST be refused
- **AND** the package's partition_id MUST match the partition_id embedded in the signed token payload

### Requirement: Outbound Network Policy for User-Driven Egress
Any user-driven outbound network access from the bastion (URL fetches, integrations, webhooks, OIDC discovery follow-ups) SHALL be gated by an outbound network policy. The policy MUST block RFC1918, loopback, link-local, CGNAT, multicast, reserved, IPv6 link-local / ULA / multicast, and IPv4-mapped-IPv6 addresses. URL parsing MUST allowlist schemes and ports. Requests MUST be bound to the resolved IP at the time of policy evaluation to defeat DNS rebinding.

#### Scenario: SSRF to cloud metadata refused
- **WHEN** a user-driven fetch is attempted against `http://169.254.169.254/...` or `https://[::ffff:169.254.169.254]/...`
- **THEN** the outbound policy MUST refuse the request before any TCP connect

#### Scenario: DNS rebinding defeated
- **WHEN** a hostname resolves to a public address at policy-evaluation time but a private address at connect time
- **THEN** the actual HTTP connect MUST be to the resolved (policy-evaluated) address, not a re-resolution

#### Scenario: Scheme and port allowlisted
- **WHEN** an outbound URL specifies a non-http/https scheme or a non-allowlisted port
- **THEN** the policy MUST refuse before resolution

### Requirement: Server-Side WebRTC Signalling Filtering
The bastion's WebRTC signalling server SHALL apply codec, fingerprint-algorithm, and ICE-candidate allowlists on every SDP offer/answer and every ICE candidate. TURN credentials handed to the browser MUST be per-session ephemeral with sub-hour TTL. SDP renegotiation that introduces new media sections MUST be refused.

#### Scenario: Codec outside allowlist refused
- **WHEN** an SDP offer or answer contains a codec outside the documented allowlist (`avc1`, `vp8`, `vp09`, `av01`)
- **THEN** the signalling layer MUST reject the SDP before propagating it

#### Scenario: Private-network ICE candidate stripped
- **WHEN** an ICE candidate's address is in RFC1918 / loopback / link-local / CGNAT / multicast / IPv6 ULA
- **THEN** the candidate MUST be dropped before being forwarded

#### Scenario: TURN credentials are per-session
- **WHEN** the bastion delivers `iceServers` to a browser
- **THEN** the TURN username MUST encode a session-bound HMAC over an expiry timestamp; credentials MUST expire within one hour

### Requirement: eBPF Probe Safety
Agent-side eBPF probes feeding enhanced-recording telemetry SHALL use stable kernel ABIs (tracepoints, not kprobes/uprobes where avoidable), a documented minimum kernel version, an explicit capability precheck, and a safe-helper allowlist. Ring-buffer events ingested into the recording schema MUST be bounds-validated before storage. Enhanced recording MUST be off by default.

#### Scenario: Minimum kernel version enforced
- **WHEN** the agent starts on a kernel below the documented minimum
- **THEN** enhanced recording MUST refuse to load and surface a structured "kernel too old" reason

#### Scenario: Capability precheck
- **WHEN** the agent lacks the capabilities required to load probes
- **THEN** the agent MUST surface a structured "capability missing" reason before any load attempt

#### Scenario: Ring buffer events sanitised
- **WHEN** a probe writes an event into the ring buffer
- **THEN** the user-space consumer MUST validate `argc`, strip control bytes, and reject non-UTF-8 fields before persisting to the recording schema

### Requirement: Kubernetes Deploy Posture for the Bastion
The bastion's Kubernetes deployment SHALL run with: explicit NetworkPolicy default-deny for both ingress and egress with named allow edges; non-`privileged` containers (capability allowlist only); encrypted-at-rest persistent volumes; pod-level `runAsUser`, `fsGroup`, and `readOnlyRootFilesystem`; minimal bootstrap Job RBAC scoped by `resourceNames`. The agent DaemonSet MUST NOT use `privileged: true` when its required capabilities (`CAP_BPF`, `CAP_PERFMON`, `CAP_NET_RAW`) suffice.

#### Scenario: Cross-pod traffic restricted
- **WHEN** any namespace pod outside the named allow edges attempts to connect to a bastion control-plane pod
- **THEN** the connection MUST be refused by NetworkPolicy

#### Scenario: Agent DaemonSet not privileged
- **WHEN** the agent DaemonSet renders on a supported kernel
- **THEN** its pod spec MUST NOT set `privileged: true`; it MUST rely on its declared capability allowlist

#### Scenario: Recording PVC encrypted
- **WHEN** the recording storage PVC is provisioned
- **THEN** the storage class MUST enforce encryption at rest; installs without an encrypted storage class MUST require an explicit `--values insecure-storage.yaml` opt-in

### Requirement: Supply-Chain License and Vulnerability Gate
The bastion's CI SHALL enforce, on every PR: an AGPL transitive-import scan against documented Teleport package paths; a Rust advisory scan against any workspace member that pulls in the RDP connector tree; a Go advisory scan; pinned-by-SHA references for third-party CI actions used in release / publish workflows. Failures MUST block merge.

#### Scenario: AGPL guardrail fails build on offending import
- **WHEN** a PR introduces a dependency path that re-includes an AGPL-licensed Teleport module
- **THEN** `scripts/check-teleport-license-paths.sh` (or equivalent) MUST run in CI and fail the build with the offending path

#### Scenario: Floating action tags rejected in release workflow
- **WHEN** a release / publish workflow references `uses: <action>@<floating-tag>`
- **THEN** CI MUST refuse the change; only full commit SHAs are accepted

### Requirement: Recording Sensitive-Field Redaction Allowlist Discipline
Resources that store user-provided policy maps containing potentially sensitive fields (desktop target policies, file-transfer policies, recording policies) SHALL redact via a *denylist + structural rule* approach rather than a field allowlist. Adding a new field MUST default to redacted until explicitly proven non-sensitive.

#### Scenario: New policy field defaults to redacted
- **WHEN** a new attribute is added to a desktop / recording / file-transfer policy map
- **THEN** read actions MUST redact it by default; exempting the field MUST require an explicit non-sensitive declaration with a property-based regression test

### Requirement: Registered application access targets
ServiceRadar SHALL provide remote application access only to registered HTTP/HTTPS application targets selected by trusted inventory or policy, not by browser-supplied upstream addresses.

#### Scenario: Browser opens a registered internal app
- **GIVEN** an authenticated user is authorized to open a registered application target
- **AND** the target has a selected agent route and trusted upstream policy
- **WHEN** the user starts an application access session
- **THEN** ServiceRadar SHALL derive the upstream scheme, host, port, Host header, SNI, TLS policy, allowed paths, allowed methods, quotas, approval requirement, and recording policy from trusted target state
- **AND** SHALL route the session through the selected agent.

#### Scenario: Browser cannot select an arbitrary upstream
- **GIVEN** a browser or API client requests application access
- **WHEN** the request includes an upstream host, port, route, gateway, agent, Host header, SNI, TLS verification override, credential rule, quota, approval override, or recording override
- **THEN** ServiceRadar SHALL reject the request before dispatching any agent frame.

### Requirement: Application access prevents SSRF and open-proxy behavior
ServiceRadar SHALL enforce SSRF and open-proxy protections for application access before any selected agent opens an upstream connection.

#### Scenario: Unsupported scheme or redirect is denied
- **GIVEN** a registered application target allows HTTP or HTTPS access only to a configured upstream
- **WHEN** a request or upstream redirect attempts to use an unsupported scheme, policy-external host, policy-external port, or unapproved Host/SNI value
- **THEN** ServiceRadar SHALL deny or stop the request
- **AND** SHALL emit an audit/recording event without exposing sensitive header or body values.

#### Scenario: CONNECT tunneling is not available through application access
- **GIVEN** a browser session is opened for a registered HTTP application
- **WHEN** the browser attempts arbitrary CONNECT tunneling or raw TCP forwarding through that session
- **THEN** ServiceRadar SHALL reject the behavior unless a separately registered TCP target and permissioned TCP adapter are used.

### Requirement: Application access isolates browser origin and headers
ServiceRadar SHALL isolate browser application sessions and enforce header/cookie policy so private upstream applications do not receive ServiceRadar credentials or unrelated app state.

#### Scenario: Sensitive headers are stripped
- **GIVEN** a browser sends a request through an application access session
- **WHEN** web-ng and the selected agent forward the request upstream
- **THEN** ServiceRadar SHALL strip ServiceRadar authentication headers, hop-by-hop proxy headers, and other policy-denied headers
- **AND** SHALL inject only policy-approved upstream headers.

#### Scenario: Application session origin is isolated
- **GIVEN** two registered application targets are opened by the same browser
- **WHEN** each target sets cookies or uses browser storage through the ServiceRadar access surface
- **THEN** the sessions SHALL use isolated origin or path namespaces so app state cannot collide across targets.

### Requirement: Registered TCP access targets
ServiceRadar SHALL provide raw TCP access only for explicitly registered TCP targets with route, protocol, quota, timeout, recording, and approval policy selected by trusted state.

#### Scenario: TCP target opens through selected route
- **GIVEN** an authenticated user is authorized to open a registered TCP target
- **WHEN** the user starts the TCP session
- **THEN** ServiceRadar SHALL route bounded data frames through the selected agent to the registered host and port
- **AND** SHALL enforce idle timeout, byte quotas, lifecycle audit, and recording policy.

#### Scenario: TCP target cannot become arbitrary forwarding
- **GIVEN** a TCP access session is active
- **WHEN** the client attempts to change the upstream host, port, protocol, route, credential, or policy after session creation
- **THEN** ServiceRadar SHALL reject the request or close the session.

### Requirement: Application and TCP recording stores metadata by default
ServiceRadar SHALL record application/TCP lifecycle, policy, request/response metadata, byte counts, and failures without storing request or response bodies by default.

#### Scenario: HTTP request is recorded without body content
- **GIVEN** a user sends an HTTP request through application access
- **WHEN** ServiceRadar writes replay or audit events
- **THEN** the event SHALL include actor, target, session, route, method, redacted path, status code, byte counts, policy decision, and timing metadata
- **AND** SHALL NOT include cookies, authorization headers, request bodies, or response bodies unless a future explicit content-retention policy enables it.

### Requirement: Remote access file transfer is route-bound and policy-controlled
ServiceRadar SHALL provide SFTP-style file transfer through the existing remote-access selected-agent route without allowing clients to choose arbitrary routes, target hosts, credential rules, custody modes, recording policies, quotas, or approval overrides.

#### Scenario: Browser submits only transfer intent
- **GIVEN** an authenticated user requests a remote-access file operation
- **WHEN** the request reaches the browser/API boundary
- **THEN** the accepted fields SHALL be limited to target or session reference, operation, direction, path intent, optional destination path, and display metadata
- **AND** ServiceRadar SHALL derive route, selected agent, gateway, target host, credential mode, credential rule, recording policy, quota, content-audit policy, and approval requirements from trusted inventory, policy, and session state.

#### Scenario: Client attempts to override trusted policy
- **GIVEN** a file-transfer request includes client-supplied route, agent, gateway, target host, credential rule, custody, recording, content-audit, approval, or quota fields
- **WHEN** ServiceRadar validates the request
- **THEN** the request SHALL be rejected before any gateway or agent frame is emitted
- **AND** the denial SHALL be audited without exposing credentials or file contents.

### Requirement: File transfer enforces per-operation RBAC and approval
ServiceRadar SHALL authorize file transfer by operation and SHALL support approval gates for sensitive transfers before the selected agent opens or mutates a target file.

#### Scenario: User lacks operation permission
- **GIVEN** a user has remote SSH access to a target but lacks `devices.remote_access.files.download`
- **WHEN** the user requests a download
- **THEN** ServiceRadar SHALL deny the transfer before dispatch to the selected agent
- **AND** the denial SHALL identify the operation and target in audit metadata without recording file contents.

#### Scenario: Sensitive path requires approval
- **GIVEN** policy marks a path or operation as approval-required
- **WHEN** a user requests that transfer without a matching unexpired approval
- **THEN** ServiceRadar SHALL create or require an approval workflow according to policy
- **AND** SHALL NOT issue a transfer grant until approval matches actor, target, route, operation, path policy, and expiry.

### Requirement: File transfer path and quota policy fail closed
The selected agent SHALL enforce path and quota policy locally before and during target file operations.

#### Scenario: Path cannot be validated
- **GIVEN** a transfer policy defines path allow/deny rules, root containment, or symlink behavior
- **WHEN** the agent cannot normalize the requested path or verify the symlink/realpath behavior required by policy
- **THEN** the agent SHALL fail the transfer before opening or mutating the file
- **AND** SHALL return a sanitized policy failure.

#### Scenario: Quota is exhausted during transfer
- **GIVEN** a transfer has byte, file-count, recursive-depth, rate, or concurrent-transfer limits
- **WHEN** the operation would exceed a configured limit
- **THEN** the selected agent SHALL stop the transfer
- **AND** ServiceRadar SHALL record a quota-exhausted outcome with byte/file counters and without persisted file contents.

### Requirement: File transfer recording stores metadata by default
ServiceRadar SHALL record file-transfer lifecycle metadata for audit and replay while avoiding file-content persistence unless an explicit content-audit artifact policy enables it.

#### Scenario: Download completes
- **WHEN** a download completes successfully
- **THEN** ServiceRadar SHALL record transfer ID, actor, target, selected route, operation, direction, redacted path or path hash according to policy, byte count, file count, status, timestamps, and retention expiry
- **AND** SHALL NOT store downloaded file bytes in audit, replay, recording events, or exports by default.

#### Scenario: Content artifact retention is enabled
- **GIVEN** an explicit content-audit policy enables artifact retention for a transfer class
- **WHEN** a matching transfer runs
- **THEN** ServiceRadar MAY retain a sensitive artifact reference with retention and export controls
- **AND** export SHALL require a dedicated file-transfer export permission.

### Requirement: SFTP is the first-class implementation model
ServiceRadar SHALL implement structured SFTP operations first and SHALL defer SCP compatibility until SCP maps into the same policy, quota, recording, and audit manager.

#### Scenario: SFTP adapter is available
- **WHEN** an agent advertises `remote_access.sftp`
- **THEN** it SHALL be able to enforce operation, path, symlink, quota, cancellation, audit, and recording policy locally
- **AND** it SHALL reuse the existing SSH credential custody and host-key trust paths.

#### Scenario: SCP support is requested before policy parity exists
- **WHEN** SCP compatibility would bypass structured operation authorization, quota enforcement, or recording events
- **THEN** ServiceRadar SHALL keep `remote_access.scp` unavailable
- **AND** SHALL direct callers to the SFTP transfer path.

### Requirement: Remote access supports ServiceRadar-owned eBPF enhanced recording
The system SHALL support Linux eBPF enhanced recording for remote-access sessions through ServiceRadar-owned collector code or explicitly approved Apache-2.0 source provenance.

#### Scenario: Required eBPF tracing starts before target dial
- **GIVEN** a remote-access policy requires eBPF enhanced recording
- **AND** the selected Linux agent advertises `remote_access.bpf`
- **WHEN** the operator starts a remote-access session
- **THEN** the agent SHALL start the eBPF collector and bind it to the session boundary before dialing the target
- **AND** the target SHALL NOT be dialed if the eBPF collector fails to load, attach, or register the session.

#### Scenario: eBPF tracing is session-scoped
- **GIVEN** an active remote-access session with eBPF enhanced recording enabled
- **WHEN** unrelated processes execute commands, open files, or create network connections on the same host
- **THEN** those unrelated host events SHALL NOT be emitted as remote-access session events
- **AND** emitted events SHALL be correlated to the session, actor, target, selected agent, and policy snapshot.

#### Scenario: Agentless SSH cannot satisfy target-side command tracing
- **GIVEN** a generic SSH session is opened by an intermediate ServiceRadar agent to a separate target host
- **AND** the target host is not running a ServiceRadar-managed execution component for that session
- **WHEN** policy requires target-side command or file eBPF tracing
- **THEN** the system SHALL NOT treat the intermediate agent's eBPF support as satisfying that policy
- **AND** the session SHALL fail before target access unless policy explicitly allows a non-target-side fallback.

#### Scenario: Managed target satisfies target-side tracing
- **GIVEN** a target host runs a ServiceRadar-managed execution component that can place the remote-access shell process tree in a session boundary
- **WHEN** policy requires target-side command, file, or network eBPF tracing
- **THEN** the managed target component SHALL register the session boundary before the shell starts
- **AND** emitted eBPF events SHALL describe the target-side process tree rather than only the intermediate SSH client.

#### Scenario: Sensitive contents are not captured
- **GIVEN** eBPF enhanced recording observes commands, file activity, and network connections
- **WHEN** the agent emits enhanced events
- **THEN** events SHALL NOT contain private key bytes, passwords, terminal input bytes, or file contents
- **AND** argv, paths, and metadata SHALL be redacted according to policy before being forwarded.

#### Scenario: Dropped events are visible
- **GIVEN** kernel buffers, maps, or user-space queues drop enhanced-recording observations
- **WHEN** the agent reports enhanced recording telemetry
- **THEN** it SHALL emit loss events that identify the event family, source, and dropped-event count
- **AND** final session audit SHALL include whether enhanced recording was complete or degraded.

### Requirement: Teleport-derived BPF code follows license boundaries
The system SHALL NOT copy, translate, or mechanically port current Teleport AGPL BPF implementation code into ServiceRadar.

#### Scenario: Apache-era Teleport source is considered for reuse
- **GIVEN** an engineer proposes copying or adapting a Teleport v14 BPF source file
- **WHEN** the code is introduced
- **THEN** the change SHALL record the Teleport tag, commit, file path, license header, and dependency scan
- **AND** the copied code SHALL NOT include modifications derived from Teleport v15 or later AGPL source.

#### Scenario: Current Teleport BPF source is consulted
- **GIVEN** current Teleport BPF source has AGPL headers
- **WHEN** ServiceRadar implements equivalent BPF functionality
- **THEN** the implementation SHALL be clean-room and ServiceRadar-authored from public Linux interfaces, behavior requirements, and ServiceRadar tests.

### Requirement: Agent-routed remote console tunnel
The system SHALL provide a generic remote-console tunnel that routes operator sessions from the browser through web-ng, agent-gateway, and the selected edge agent before connecting to a target in that agent's reachable network.

#### Scenario: Reach device in segmented edge network
- **GIVEN** an operator is authorized to open a remote console for a device reachable only from a specific agent
- **WHEN** the operator starts the session from web-ng
- **THEN** web-ng SHALL create a session and route console frames through agent-gateway to that selected agent
- **AND** the agent SHALL connect to the target using the requested protocol adapter
- **AND** target credentials SHALL remain brokered to the agent-side adapter and SHALL NOT be sent to the browser.

#### Scenario: Reuse tunnel across protocols
- **GIVEN** ServiceRadar supports SSH console targets and later adds RDP or provider-native console targets
- **WHEN** a target declares protocol, renderer, agent, credential purpose, and capability metadata
- **THEN** the session lifecycle, authorization, audit, and gateway-to-agent routing SHALL be shared
- **AND** only the browser renderer and agent-side protocol adapter SHALL vary by protocol.
