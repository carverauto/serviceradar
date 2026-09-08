# Change: Integrate Ash Framework for Multi-Tenant SaaS Platform

## Why

ServiceRadar is transitioning from a Go-based monolithic core (serviceradar-core) to an Elixir-based distributed architecture. The current Phoenix LiveView app (`web-ng`) uses standard Ecto patterns with manual context modules, basic Oban scheduling, and Phoenix.gen.auth for authentication. This approach requires significant boilerplate for:

- Multi-tenancy isolation across all queries
- RBAC and authorization enforcement
- API layer generation (REST/GraphQL)
- Job scheduling coordination
- Device/asset identity reconciliation
- Event-driven state machines for alerts/responses

The Ash Framework provides a declarative, resource-centric approach that enforces these concerns at the framework level, reducing the risk of security gaps and dramatically accelerating feature development.

**Key drivers:**
1. **Multi-tenant SaaS**: ServiceRadar needs to support customers running agents/pollers in their own networks while orchestrating from a central engine
2. **Security by default**: Authorization must be enforced at the resource level, not manually in each controller
3. **OCSF alignment**: Device inventory already follows OCSF schema; Ash resources can map directly to OCSF columns
4. **Distributed polling**: Replace Go poller with Elixir nodes coordinated via AshOban + Horde for "one big brain" architecture
5. **Replace serviceradar-core**: Port all API functionality from Go core to Ash-powered Elixir
6. **Primary workflow**: Sync from external systems (Armis/IPAM) to discover devices, then schedule ping/tcp checks via Oban and poller/agent execution

## What Changes

### Phase 0: Core Service (serviceradar-core-elx)
- **Standalone coordinator**: Add `core-elx` as a separate Elixir release that owns orchestration.
- **Headless runtime**: Core-elx is headless (no HTTP); it speaks ERTS and minimal gRPC.
- **AshOban scheduling**: Core runs polling, sweep, sync, and monitoring jobs on Oban schedules.
- **ERTS job dispatch**: Core communicates with pollers over BEAM distribution (PubSub/RPC/Horde).
- **Result processing**: Core ingests poller/agent results and runs the DIRE engine before persisting.
- **Large payload handling**: Preserve gRPC streaming + chunking for massive result sets (sync/sweep).
 - **DB access boundary**: Only core-elx and web-ng connect to CNPG; pollers/agents do not.

### Primary Use Case (Target Workflow)
1. **Sync ingest**: Sync service talks to Armis/IPAM and streams devices to core-elx (gRPC chunking).
2. **Inventory write**: Core-elx persists new devices into Ash resources (tenant/domain scoped).
3. **Schedule checks**: Core-elx enqueues ping/tcp checks via AshOban (user-configured schedules).
4. **Execute checks**: Poller selects agent; agent calls sweep/checker services over gRPC.
5. **Persist results**: Core-elx ingests check results and updates device/health resources.

### Phase 1: Foundation (Core Infrastructure)
- **AshPostgres migration**: Convert existing Ecto schemas to Ash resources with backward-compatible table mappings
- **AshAuthentication**: Replace Phoenix.gen.auth with AshAuthentication supporting:
  - Magic link email authentication
  - OAuth2 providers (Google, GitHub, etc.)
  - Password authentication (existing)
  - API tokens for CLI/external tools
- **Ash.Policy.Authorizer**: Implement RBAC with role-based policies for all resources
- **Multi-tenancy**: Add tenant context to all resources using Ash's attribute-based multi-tenancy

### Phase 2: Business Domains
Define Ash domains and resources for ServiceRadar's core entities:
- **Inventory domain**: Device, Interface, NetworkInterface, DeviceGroup
- **Infrastructure domain**: Poller, Agent, Checker, Partition
- **Monitoring domain**: ServiceCheck, HealthStatus, Metric, Alert
- **Collection domain**: Flow, SyslogEntry, SNMPTrap, OTELTrace, OTELMetric
- **Identity domain**: User, Tenant, ApiToken, Session
- **Events domain**: Event, Notification, AuditLog

### Phase 3: Job Orchestration
- **AshOban integration**: Replace custom Oban scheduler with declarative AshOban triggers
- **AshStateMachine**: Implement state machines for:
  - Alert lifecycle (pending -> acknowledged -> resolved)
  - Device onboarding (discovered -> identified -> managed)
  - Edge package delivery (created -> downloaded -> installed -> expired)
- **Polling coordination**: Define schedulable actions for service checks coordinated across distributed pollers
- **UI scheduling**: Expose schedule configuration in web-ng (sync cadence, ping/tcp check cadence)

### Phase 4: Data Ingestion Pipelines (Broadway + NATS JetStream)
- **Broadway integration**: Use Broadway for high-volume data ingestion with back-pressure and batching
- **NATS JetStream producer**: Implement `OffBroadway.Jetstream.Producer` for reliable message consumption from collectors
- **Pipeline topologies**:
  - **Metrics pipeline**: Collector telemetry → NATS JetStream → Broadway → TimescaleDB
  - **Events pipeline**: Collector events → NATS JetStream → Broadway → PostgreSQL (Ash resources)
  - **Logs pipeline**: Netflow/syslog/trapd → NATS JetStream → Broadway → TimescaleDB (with pg_bm25 for full-text search)
- **Batching strategies**: Configure batch sizes and timeouts per data type for optimal throughput
- **Acknowledgement**: Use JetStream's exactly-once delivery semantics with Broadway acknowledgements
- **Partition awareness**: Route messages to correct partition-scoped Broadway pipelines

### Phase 5: API Layer
- **AshJsonApi**: Auto-generate JSON:API endpoints from resources
- **AshPhoenix**: Integrate Ash forms with LiveView for real-time UI
- **gRPC bridge**: Maintain gRPC for agent/checker communication (existing Go agents stay)
- **ERTS clustering**: Implement distributed Elixir for core-to-poller coordination and job dispatch

### Phase 6: Legacy Removal and Service Renames
- **Remove legacy stack**: Drop Go `core`, `poller`, `agent`, and `sync` from docker compose.
- **Rename Go agent**: Rename `serviceradar-agent` to `serviceradar-sweep` as the gRPC target.
- **Connectivity model**: Core and pollers talk over ERTS; pollers and sweep/checkers talk over gRPC.
 - **Sync rewrite**: Replace Go sync with an Elixir sync service scheduled by AshOban.

### Phase 7: Observability & Admin
- **AshAdmin**: Admin UI for resource management during development
- **Ash OpenTelemetry**: Distributed tracing integration
- **AshAppSignal** (optional): Production monitoring integration

## Impact

### Affected Specs
- `cnpg` - Database schema additions for Ash resources and multi-tenancy
- `kv-configuration` - Minimal impact; KV patterns remain for agent config

### Affected Code
- `elixir/serviceradar_core/` - Core-elx release packaging and orchestration logic
- `web-ng/lib/serviceradar_web_ng/accounts/` - Complete rewrite to AshAuthentication
- `web-ng/lib/serviceradar_web_ng/inventory/` - Convert to Ash domain
- `web-ng/lib/serviceradar_web_ng/infrastructure/` - Convert to Ash domain
- `web-ng/lib/serviceradar_web_ng/edge/` - Convert to Ash domain with state machines
- `web-ng/lib/serviceradar_web_ng/jobs/` - Replace with AshOban
- `web-ng/lib/serviceradar_web_ng_web/router.ex` - Add Ash routes, auth routes
- `web-ng/lib/serviceradar_web_ng_web/live/` - Integrate AshPhoenix.Form
- `web-ng/config/config.exs` - Ash configuration
- `docker-compose.yml` - Add core-elx, remove legacy Go services
- `docker/images/BUILD.bazel` - New core-elx image target
 - `web-ng/lib/serviceradar_web_ng_web/live/` - Scheduling UI for sync and check cadence

### Breaking Changes
- **BREAKING**: API authentication flow changes (magic link, OAuth additions)
- **BREAKING**: API response format changes (JSON:API compliance)
- **BREAKING**: Database migrations for tenant_id columns on all tenant-scoped tables
- **BREAKING**: Legacy Go services removed from docker compose; `core-elx` becomes mandatory
- **BREAKING**: Go `serviceradar-agent` renamed to `serviceradar-sweep`

### Migration Strategy
1. **Parallel resources**: Create Ash resources alongside existing Ecto schemas initially
2. **Feature flags**: Toggle between old/new implementations per-feature
3. **Data migration scripts**: Add tenant_id to existing records
4. **API versioning**: `/api/v2/` for Ash-powered endpoints while `/api/` continues working
5. **Gradual rollout**: Domain-by-domain migration with comprehensive test coverage
6. **Core cutover**: Replace Go `core` with `core-elx`, remove legacy services from docker compose
7. **Agent cutover**: Route sweep/check work through `serviceradar-sweep` via the new Elixir agent layer
8. **DB access boundaries**: Only core-elx and web-ng connect to CNPG; pollers/agents remain DB-free

## Progress Update (2025-12-29)

### web-ng Decoupling from core-elx

- **Created ClusterStatus Module** (`elixir/serviceradar_core/lib/serviceradar/cluster/cluster_status.ex`):
  - Unified API for cluster status queries from any node in the ERTS cluster
  - Works from web-ng (cluster_coordinator=false) without requiring ClusterSupervisor/ClusterHealth locally
  - Key functions: `get_status/0`, `node_info/0`, `registry_counts/0`, `coordinator_health/0`, `find_coordinator/0`
  - Uses RPC to query ClusterHealth on core-elx when needed from web-ng
  - Includes comprehensive architecture documentation with ASCII diagrams

- **Updated ClusterLive Views**:
  - `web-ng/lib/serviceradar_web_ng_web/live/settings/cluster_live/index.ex`: Uses ClusterStatus instead of ClusterSupervisor/ClusterHealth
  - `web-ng/lib/serviceradar_web_ng_web/live/admin/cluster_live/index.ex`: Same ClusterStatus integration

- **Updated Telemetry** (`web-ng/lib/serviceradar_web_ng_web/telemetry.ex`):
  - Periodic cluster health measurements now use ClusterStatus.get_status()
  - No longer references ClusterHealth directly (not available on web-ng nodes)

- **Added core-elx Health Check** (`web-ng/lib/serviceradar_web_ng/application.ex`):
  - Non-blocking health check on startup when CLUSTER_ENABLED=true
  - Uses Task.start to avoid blocking application startup
  - Logs warning if no coordinator found, but allows web-ng to continue

### Architecture: web-ng -> core-elx Communication

```
┌─────────────────────────────────────────────────────────────────────┐
│                         ERTS Cluster                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌───────────────┐      ┌───────────────┐      ┌───────────────┐   │
│  │   core-elx    │      │    web-ng     │      │  poller-elx   │   │
│  │               │      │               │      │               │   │
│  │ • ClusterSupv │      │ • LiveViews   │      │ • PollerProc  │   │
│  │ • ClusterHlth │◄────►│ • ClusterStat │◄────►│ • Horde reg   │   │
│  │ • AshOban     │      │ • Telemetry   │      │ • No DB       │   │
│  │ • PollOrch    │      │ • DB access   │      │               │   │
│  │ • DB access   │      │               │      │               │   │
│  │               │      │               │      │               │   │
│  │ cluster_coord │      │ cluster_coord │      │ cluster_coord │   │
│  │    = true     │      │    = false    │      │    = false    │   │
│  └───────────────┘      └───────────────┘      └───────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

- **Horde Registries**: Process registration synced across all nodes via CRDT
- **Phoenix.PubSub**: Events broadcast to all nodes automatically
- **RPC**: ClusterStatus uses `:rpc.call/4` to query ClusterHealth on core-elx

### Deployment

- Rebuilt and deployed `core-elx`, `web-ng`, `poller-elx` with SHA `sha-108a12656c28fca596aebba236951ab7cb005a30`
- All services healthy in docker compose cluster

## Progress Update (2025-12-28, Late)

### Infrastructure State Machine & Health Events

- **Fixed Duplicate Health Events** (`elixir/serviceradar_core/lib/serviceradar/infrastructure/state_monitor.ex`):
  - Removed manual `publish_poller_event`, `publish_agent_event`, `publish_checker_event` calls
  - These were duplicating events already published by `PublishStateChange` Ash change attached to state transition actions
  - StateMonitor now relies solely on Ash actions (`:degrade`, `:go_offline`, `:lose_connection`, `:mark_failing`) which have `PublishStateChange` attached

- **Fixed Entity Metadata in PublishStateChange** (`elixir/serviceradar_core/lib/serviceradar/infrastructure/changes/publish_state_change.ex`):
  - Corrected metadata fields per entity type:
    - Pollers: `partition_id`
    - Agents: `poller_id` (was incorrectly using `partition_id`)
    - Checkers: `agent_uid`
  - Ensures health events have proper context for each entity type

- **Removed Unused Functions from StateMonitor**:
  - Cleaned up `publish_poller_event/3`, `publish_agent_event/3`, `publish_checker_event/3`
  - Removed unused `entity_type_to_string/1` helper
  - Eliminated compiler warnings about unused functions

### Config Bootstrap Hot-Reload Fix

- **Fixed config-bootstrap Restart Loop** (`rust/config-bootstrap/src/watch.rs`):
  - Added `is_initial` flag to skip the first KV watch event (initial snapshot)
  - Initial config is already loaded during `bootstrap.load()` - the watch was triggering unnecessary restarts
  - Services now only reload on actual KV changes, not on initial subscription

### Docker Compose Health Check Fixes

- **Increased Health Check Timeouts** (`docker-compose.yml`):
  - Extended health check parameters for services that need longer startup time
  - Prevents premature service restarts during initial startup
  - All services (core-elx, poller-elx, web-ng, zen, db-event-writer) running healthy

### Deployment

- Rebuilt and deployed `core-elx` with SHA `sha-1ee6a5fad039cb9712d17fd7bbbb8f102edfcf3c`
- Removed deprecated `agent-elx` containers (were test attempts for multi-tenant services)
- Verified all services healthy in docker compose

## Progress Update (2025-12-27, Late)

### Infrastructure Pages and Horde Integration
- **Enhanced Poller Details Page** (`web-ng/lib/serviceradar_web_ng_web/live/poller_live/show.ex`):
  - Live status banner (Horde vs database source)
  - Node system info via RPC: uptime, processes, schedulers, OTP release, memory breakdown
  - Registration timeline with time ago display
  - **Note**: Removed misleading "capabilities" display - pollers don't have capabilities (see Architecture Clarification below)

- **Enhanced Agent Details Page** (`web-ng/lib/serviceradar_web_ng_web/live/agent_live/show.ex`):
  - Live status banner (Horde vs database source)
  - Poller node system info via RPC (uptime, processes, memory)
  - Capabilities card with descriptions (ICMP, TCP, HTTP, gRPC, DNS, etc.)
  - Registration timeline (registered_at, connected_at, last_heartbeat)
  - Service checks card showing configured checks

- **Infrastructure Page Navigation** (`web-ng/lib/serviceradar_web_ng_web/live/infrastructure_live/index.ex`):
  - Made poller rows clickable → navigate to poller details
  - Made node names clickable (poller nodes link to poller details)
  - Added `extract_poller_id/1` helper for Horde key extraction

- **Cluster Health Sync Fix** (`elixir/serviceradar_core/lib/serviceradar/cluster/cluster_health.ex`):
  - Fixed Horde `members: :auto` not syncing across nodes
  - Added explicit `Horde.Cluster.set_members` calls on init and nodeup
  - Added RPC-based member sync to remote nodes (for containers running old code)
  - Verified 4-node cluster working: web-ng, core-elx, poller-elx, agent-elx

### Architecture Clarification: Poller vs Agent Roles

**IMPORTANT**: Pollers do NOT have capabilities. The previous UI was misleading.

#### Correct Data Flow (Service Checks)
```
Scheduler (AshOban in core-elx)
    ↓
Oban Job Triggered
    ↓
Poller (receives job via ERTS RPC/PubSub)
    ↓
Poller finds available Agent (Horde AgentRegistry lookup by partition/tenant)
    ↓
RPC to Agent
    ↓
Agent performs check:
  - ICMP ping (native capability)
  - TCP port check (native capability)
  - Process check (native capability)
  - OR: gRPC to external checker (SNMP, Dusk, etc.)
    ↓
Results to ERTS PubSub/ETS (or gRPC stream for large payloads)
    ↓
core-elx processes results (DIRE, identity reconciliation, alerts)
    ↓
Database write (only core-elx/web-ng access DB)
```

#### Collector Data Flow (Netflow, Syslog, SNMP Traps)
```
Collector (serviceradar-netflow, serviceradar-syslog, serviceradar-trapd)
    ↓
Publish to NATS JetStream
    ↓
serviceradar-zen (Rust ETL service)
  - Watches JetStream queues
  - Transforms to OCSF format
    ↓
db-event-writer (Rust)
  - Writes OCSF events to database
```

#### Component Responsibilities

| Component | Has Capabilities? | Role |
|-----------|------------------|------|
| **Poller-elx** | NO | Job orchestration, agent selection, work dispatch |
| **Agent-elx** | YES | ICMP, TCP, process checks; gRPC to external checkers |
| **Core-elx** | NO | Scheduling, identity reconciliation, result processing |
| **Web-ng** | NO | UI, API, database queries (no Horde supervisor) |
| **Sweep (Go)** | YES | Large-scale ICMP/TCP sweeps via gRPC |
| **Checkers** | YES | SNMP, Dusk, custom protocols via gRPC |

#### Agent Capabilities (defined in agent-elx)
- `icmp` - ICMP ping checks
- `tcp` - TCP port checks
- `http` - HTTP/HTTPS endpoint checks
- `dns` - DNS resolution checks
- `grpc` - gRPC health checks (to external checkers)
- `process` - Local process monitoring
- `agent` - Agent management (self-reporting)

## Progress Update (2025-12-27)
- **Integration Source Management**: Added IntegrationSource Ash resource for managing sync integrations (Armis, NetBox, etc.) via web UI.
- **DataService.Client**: Created gRPC client GenServer for pushing configuration to datasvc KV store with full mTLS support.
- **GRPC supervision**: Added GRPC.Client.Supervisor to application tree; implemented gun connection event handlers for reconnection.
- **Migration check fix**: Updated endpoint.ex CheckRepoStatus to use `:serviceradar_core` for Ash migrations (was incorrectly using `:serviceradar_web_ng`).
- **Next steps**: Create IntegrationLive.Form for CRUD, implement sync action to push config to datasvc, add credential encryption.

## Progress Update (2025-12-26)
- Docker compose stack runs elixir `web-ng`, `poller-elx`, and `agent-elx` services with mTLS; legacy Go services are slated for removal.
- Bazel remote builds for Elixir releases are working with an offline Hex registry cache (`build/hex_cache.tar.gz`) and updated mix_release handling.
- AshAuthentication routes are active in `web-ng` and the magic link request flow now delivers to `/dev/mailbox`.
- Mailer fixes: convert `Ash.CiString` emails to strings in magic link and password reset senders; ensure `:swoosh` and `:telemetry` are started as extra applications.
- Compose runtime includes `ELIXIR_ERL_OPTIONS=+fnu` for elixir services to avoid latin1 locale warnings.
- Task 1.4 (mTLS for ERTS Distribution) verified complete: ssl_dist.*.conf files configured for web, poller, and agent with proper TLS settings.
- Magic link sign-in still returned 403; AshAuthentication magic link LiveComponent does not include a CSRF token and crashes when `remember_me_field` resolves for a create action.
- Added a custom `AuthLive.MagicLinkSignIn` LiveView with explicit CSRF token handling and no remember-me field; router overrides wire this LiveView into `magic_sign_in_route`.
- TLS distribution certs now require `core-elx` in the core cert SAN list to prevent `hostname_check_failed`; regenerate certs after updates to `docker/compose/generate-certs.sh`.

## Resolved: Standalone core-elx Service

**Decision**: Yes, we need a standalone `core-elx` service to replace the Go `serviceradar-core`.
**Decision**: Remove legacy Go services from docker compose and rename `serviceradar-agent` to `serviceradar-sweep`.
**Decision**: Only core-elx and web-ng access the database; pollers/agents do not.
**Decision**: Collectors (netflow/syslog/trapd) publish to NATS JetStream for Broadway processing.
**Decision**: Use Horde Registry + RPC for ERTS job dispatch (initial implementation).

### Why a Separate Core Service?

The current architecture has `web-ng` running the full `serviceradar_core` library including Horde supervisors, cluster infrastructure, and coordination logic. This conflates the web frontend with the coordination layer:

1. **Separation of concerns**: The web frontend should serve HTTP/WebSocket traffic and render UI, not coordinate distributed polling
2. **Scalability**: Multiple web-ng instances for horizontal scaling shouldn't each try to run Horde supervisors
3. **Failure isolation**: Core coordination should survive web-ng restarts and vice versa
4. **Resource allocation**: Core coordination needs different resources (CPU for ERTS messaging) than web (memory for LiveView)

### Core-elx Responsibilities

The `core-elx` service acts as the central "brain" of the distributed cluster:

| Go Core Component | Elixir Replacement |
|-------------------|-------------------|
| `identity_lookup.go` | `ServiceRadar.Identity.DeviceLookup` |
| `result_processor.go` | `ServiceRadar.Core.ResultProcessor` |
| `stats_aggregator.go` | `ServiceRadar.Core.StatsAggregator` |
| `stats_alerts.go` | `ServiceRadar.Core.AlertGenerator` |
| `poller_recovery.go` | `ServiceRadar.Core.PollerRecovery` |
| `canonical_cache.go` | ETS-backed identity cache |
| `alias_events.go` | Ash change tracking |
| `pollers.go` | Horde PollerRegistry + PollerSupervisor |
| gRPC PollerService | ERTS messaging (preferred) + gRPC fallback |
| `scheduler.go` | AshOban jobs + AshStateMachine triggers |
| `sync_streams.go` | gRPC streaming ingestion + chunking |
| `dire_engine.go` | `ServiceRadar.Core.DIRE` (identity reconciliation) |

### Core Job Flow (Target)
1. **Schedule**: AshOban enqueues polling/sweep/sync jobs at configured intervals.
2. **Dispatch**: Core sends work over ERTS to the correct poller (tenant/domain aware).
3. **Select agent**: Poller chooses an available agent registered in the same tenant/domain.
4. **Execute**: Agent invokes `serviceradar-sweep` (gRPC) or checker services as needed.
5. **Stream results**: Large payloads stream back (chunked) to core via gRPC or ERTS.
6. **Reconcile**: Core runs DIRE to normalize identities and stores results via Ash resources.

### Feature Map: Go Core -> Core-ELX (Functional)
- **Scheduling**: Go cron/queue logic -> AshOban jobs and triggers.
- **Polling orchestration**: gRPC PollerService -> ERTS dispatch + Horde registries.
- **Agent selection**: Go core selection -> poller selects agent by tenant/domain.
- **Sweep/scan**: Go agent -> `serviceradar-sweep` via new Agent-ELX gRPC bridge.
- **Sync ingestion**: gRPC streaming GetResults -> core streaming pipeline with chunking.
- **DIRE engine**: Go DIRE processing -> Core-ELX reconciliation before persistence.
- **Auth/tenancy**: Hand-rolled RBAC -> AshAuthentication + Ash policies.
- **API layer**: Legacy REST -> AshJsonApi endpoints.
- **Alerts/metrics**: Custom workers -> AshOban + AshStateMachine.

### Cluster Topology with core-elx

```
┌──────────────────────────────────────────────────────────────────┐
│                         Cloud / Data Center                       │
│  ┌─────────────────┐  ┌──────────────────┐  ┌─────────────────┐  │
│  │    core-elx     │  │     web-ng       │  │     cnpg        │  │
│  │  (coordinator)  │◄─│  (web frontend)  │  │   (postgres)    │  │
│  │                 │  │                  │  │                 │  │
│  │ • Horde primary │  │ • LiveView UI    │  │ • TimescaleDB   │  │
│  │ • Identity rec. │  │ • JSON:API       │  │ • Ash data      │  │
│  │ • Result proc.  │  │ • Queries data   │  │                 │  │
│  │ • Alert gen.    │  │ • No Horde super.│  │                 │  │
│  └────────┬────────┘  └──────────────────┘  └─────────────────┘  │
│           │ mTLS ERTS                                             │
└───────────┼──────────────────────────────────────────────────────┘
            │
   ─────────┼───────────────────────────────────────────────────────
            │ mTLS ERTS (Tailscale/Mesh VPN)
            │
┌───────────┼──────────────────────────────────────────────────────┐
│           │                    Edge Site                          │
│  ┌────────▼────────┐           ┌─────────────────┐               │
│  │   poller-elx    │◄─────────►│   agent-elx     │               │
│  │                 │  ERTS     │                 │               │
│  │ • Joins cluster │           │ • Joins cluster │               │
│  │ • Executes polls│           │ • Disk/process  │               │
│  │ • Reports to    │           │ • ICMP checks   │               │
│  │   core-elx      │           │                 │               │
│  └─────────────────┘           └─────────┬───────┘               │
│                                          │ gRPC                  │
│                                ┌─────────▼─────────┐             │
│                                │ serviceradar-     │             │
│                                │ sweep (Go)        │             │
│                                └───────────────────┘             │
└──────────────────────────────────────────────────────────────────┘
```

### web-ng Changes

After core-elx is implemented, web-ng will be simplified:

**Remove from web-ng:**
- `ClusterSupervisor` startup (core-elx runs it)
- `ClusterHealth` startup (core-elx runs it)
- Horde supervisor responsibility

**Keep in web-ng:**
- `PollerRegistry` / `AgentRegistry` (read-only queries to Horde)
- Database queries via Ash resources
- LiveView UI and JSON:API endpoints
- Authentication and authorization

## Security Decision: No ERTS in Customer Networks

**IMPORTANT**: For security reasons, no ERTS-enabled software will be deployed to customer edge networks.

### Rationale
- ERTS distribution, even with mTLS, increases the attack surface
- A compromised edge node could potentially affect the entire cluster
- Reduces the blast radius of any security breach to the edge site only

### Edge Deployment Model
- **Edge sites run Go serviceradar-core only** (no Elixir pollers/agents in customer networks)
- Edge Go core communicates to cloud via gRPC over mTLS
- Cloud runs core-elx (coordinator), web-ng (UI), poller-elx, agent-elx
- ERTS clustering happens only within the secure cloud environment

### Communication Flow
```
┌─────────────────────────────────────────────────────────┐
│                     Cloud (ERTS Cluster)                 │
│   core-elx ←→ web-ng ←→ poller-elx ←→ agent-elx        │
│       ↑                                                  │
│       │ gRPC/mTLS                                        │
└───────┼─────────────────────────────────────────────────┘
        │
┌───────┼─────────────────────────────────────────────────┐
│       ↓               Edge Site                          │
│   Go serviceradar-core ←→ Go serviceradar-sweep         │
│   (gRPC to cloud)         (ICMP/TCP checks)             │
└─────────────────────────────────────────────────────────┘
```

## Resolved: ERTS Transport for Job Dispatch

**Decision**: Hybrid approach using AshOban + Horde Registry + GenServer.call + Phoenix.PubSub

### Job Dispatch Flow (Cloud ERTS Cluster)
```
AshOban Job Triggers (scheduled or resource-triggered)
        ↓
   Oban Worker executes on core-elx
        ↓
   Horde Registry lookup: find_poller_for_partition(tenant_id, partition_id)
        ↓
   GenServer.call(poller_pid, {:execute_poll, check_config})  ← targeted RPC
        ↓
   Poller executes check (or delegates to agent)
        ↓
   Returns result to core-elx
        ↓
   Core-elx persists via Ash resources
```

### Transport Usage Guidelines

| Use Case | Transport | Example |
|----------|-----------|---------|
| Schedule jobs | AshOban | Poll every 5 minutes, sync daily |
| Dispatch to specific poller | Horde + GenServer.call | Execute poll on tenant's poller |
| Broadcast config changes | Phoenix.PubSub | "Tenant config updated, refresh" |
| Cluster events | Phoenix.PubSub | Node join/leave, agent registration |
| UI real-time updates | Phoenix.PubSub | LiveView dashboard updates |

### Why This Approach
- **AshOban**: Idiomatic with Ash, persistent job storage, distributed locking
- **Horde Registry**: Already in place for poller/agent discovery, location-transparent
- **GenServer.call**: Confirmation that work was dispatched, back-pressure via blocking
- **Phoenix.PubSub**: Efficient broadcast, already used for LiveView updates

## Open Questions / Next Steps
- Define the gRPC contract between cloud core-elx and edge Go serviceradar-core
- Define the large-payload streaming contract for sync/sweep results (chunk size, backpressure, retry)
- Decide where DIRE runs for each ingestion path (core only vs edge pre-processing)

## Dependencies

### New Dependencies
```elixir
# Ash Framework
{:ash, "~> 3.0"}
{:ash_postgres, "~> 2.0"}
{:ash_authentication, "~> 4.0"}
{:ash_authentication_phoenix, "~> 2.0"}
{:ash_oban, "~> 0.4"}
{:ash_state_machine, "~> 0.2"}
{:ash_json_api, "~> 1.0"}
{:ash_phoenix, "~> 2.0"}
{:ash_admin, "~> 0.11"}  # dev/admin only

# Data Ingestion Pipelines
{:broadway, "~> 1.1"}
{:jetstream, "~> 0.1"}  # NATS JetStream client + OffBroadway.Jetstream.Producer
```

### Optional Dependencies
```elixir
{:ash_appsignal, "~> 0.1"}  # production monitoring
{:open_telemetry_ash, "~> 0.1"}  # distributed tracing
```

## Security Model

### Actor-Based Authorization
Every request carries an actor (user, API token, or system) that policies evaluate against:

```elixir
# Example: Only allow users to see devices in their tenant
policy action_type(:read) do
  authorize_if expr(tenant_id == ^actor(:tenant_id))
end

# Example: Admin bypass
bypass actor_attribute_equals(:role, :admin) do
  authorize_if always()
end
```

### Multi-Tenancy Enforcement
All tenant-scoped resources use attribute-based multi-tenancy:

```elixir
multitenancy do
  strategy :attribute
  attribute :tenant_id
end
```

### Partition Isolation
For overlapping IP spaces, partition-aware queries prevent cross-boundary data leakage:

```elixir
policy action_type(:read) do
  authorize_if expr(partition_id == ^actor(:partition_id) or partition_id == nil)
end
```

## Distributed Cluster Security (mTLS via SPIRE)

ServiceRadar's "one big brain" architecture requires secure communication between all BEAM nodes (web-ng Core, standalone Pollers, standalone Agents) across untrusted networks. This uses **Distributed Erlang over TLS (`ssl_dist`)** with SPIRE-issued certificates.

### Transport Protocol: `inet_tls`

Configure BEAM to use TLS-wrapped distribution by passing flags at startup:

```bash
-proto_dist inet_tls \
-ssl_dist_optfile "/etc/serviceradar/ssl_dist.conf"
```

### mTLS Configuration (`ssl_dist.conf`)

The configuration file specifies certificates (issued by SPIRE or other PKI):

```erlang
[{server, [
    {certfile, "/etc/serviceradar/certs/node.pem"},
    {keyfile, "/etc/serviceradar/certs/node-key.pem"},
    {cacertfile, "/etc/serviceradar/certs/root.pem"},
    {verify, verify_peer},
    {fail_if_no_peer_cert, true}
  ]},
  {client, [
    {certfile, "/etc/serviceradar/certs/node.pem"},
    {keyfile, "/etc/serviceradar/certs/node-key.pem"},
    {cacertfile, "/etc/serviceradar/certs/root.pem"},
    {verify, verify_peer}
  ]}].
```

- **`verify_peer`**: Enforces mTLS; nodes cannot join without valid certificates
- **SPIFFE Integration**: SPIRE agent writes certs to shared volume; use long TTL or rolling restarts for renewal

### EPMDless Distribution (Fixed Ports)

Use fixed ports instead of EPMD for easier firewall rules:

```bash
export ERL_DIST_PORT=40001
```

Only port 40001 needs to be allowed between Cloud and Edge instances.

### Node Discovery via libcluster

Strategies based on deployment:
- **Tailscale/Mesh VPN**: `Cluster.Strategy.DNSPoll` with mesh DNS names
- **Kubernetes**: K8s API-based discovery for cloud nodes
- **Edge LAN**: Gossip strategy within same network segment

### Secure Remote Debugging

Debug edge pollers from anywhere with mTLS credentials:

```bash
iex --name debug@client.host \
    --cookie $ERLANG_COOKIE \
    --erl "-proto_dist inet_tls -ssl_dist_optfile /path/to/ssl_dist.conf" \
    --remsh poller_1@100.64.0.5
```

Run `:observer.start()` to visualize processes across the entire distributed cluster.

### Connection Hierarchy

1. **Core-ELX <-> Poller-ELX (Distributed Erlang/mTLS)**: Horde state + Ash commands + job orchestration
2. **Poller-ELX <-> Agent-ELX (Distributed Erlang/mTLS)**: agent selection and task assignment by tenant/domain
3. **Agent-ELX <-> serviceradar-sweep (gRPC/mTLS)**: ICMP sweeps, TCP scans, large payload streaming
4. **Agent-ELX <-> Checkers (gRPC/mTLS)**: checker calls (SNMP, Dusk, etc.)
5. **Sync service <-> Core-ELX (gRPC streaming)**: large device lists (Armis/IPAM) with chunking
6. **Collectors -> NATS JetStream**: netflow/syslog/trapd publish to JetStream for Broadway pipelines

### Overlapping IP Space Resolution

Horde uses **node names**, not IP addresses:
- `poller_a@100.64.0.5` handles Partition 1 for Tenant A
- `poller_b@100.64.0.6` handles Partition 2 for Tenant B
- Both can have devices at `10.0.0.1`; Horde routes via `{tenant_id, partition_id, device_id}` tuple
- All registry lookups are tenant-scoped to ensure multi-tenant isolation

### SPIFFE-Aware Ash Policies

Ash policies can authorize based on SPIFFE identity:

```elixir
policy action(:run_sweep) do
  authorize_if expr(context.spiffe_id == "spiffe://carverauto.dev/ns/demo/sa/serviceradar-core")
end
```

This ensures nodes can only execute actions their SPIFFE identity permits.

## Broadway Data Ingestion Architecture

### Overview

Broadway provides a multi-stage data processing pipeline with built-in back-pressure, batching, and fault tolerance. Combined with NATS JetStream, this enables reliable data ingestion from distributed agents/pollers to the central core.

### Pipeline Topology

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           NATS JetStream Cluster                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │
│  │metrics.>    │  │events.>     │  │logs.>       │  │discovery.>  │        │
│  │stream       │  │stream       │  │stream       │  │stream       │        │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘        │
└─────────┼────────────────┼────────────────┼────────────────┼───────────────┘
          │                │                │                │
          ▼                ▼                ▼                ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         ServiceRadar Core (Elixir)                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │
│  │Metrics      │  │Events       │  │Logs         │  │Discovery    │        │
│  │Broadway     │  │Broadway     │  │Broadway     │  │Broadway     │        │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘        │
│         │                │                │                │                │
│         ▼                ▼                ▼                ▼                │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │
│  │TimescaleDB  │  │Ash Resources│  │TimescaleDB  │  │Device       │        │
│  │Metrics      │  │PostgreSQL   │  │Logs+pg_bm25 │  │Inventory    │        │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘        │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Producer Configuration

```elixir
defmodule ServiceRadar.Pipeline.EventsBroadway do
  use Broadway

  alias Broadway.Message
  alias OffBroadway.Jetstream.Producer

  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {
          Producer,
          connection_name: :nats,
          stream_name: "EVENTS",
          consumer_name: "core_events_consumer"
        },
        concurrency: 2
      ],
      processors: [
        default: [concurrency: 10]
      ],
      batchers: [
        default: [concurrency: 5, batch_size: 100, batch_timeout: 1_000]
      ]
    )
  end

  @impl true
  def handle_message(_, %Message{data: data} = message, _) do
    case Jason.decode(data) do
      {:ok, event} ->
        message
        |> Message.update_data(fn _ -> event end)
        |> Message.put_batcher(:default)

      {:error, _} ->
        Message.failed(message, "invalid JSON")
    end
  end

  @impl true
  def handle_batch(:default, messages, _batch_info, _context) do
    # Batch insert into Ash resources
    events = Enum.map(messages, & &1.data)
    ServiceRadar.Events.bulk_create(events)
    messages
  end
end
```

### Partition-Aware Routing

For multi-partition deployments, messages include partition context:

```elixir
def handle_message(_, %Message{data: data} = message, _) do
  event = Jason.decode!(data)
  partition_id = event["partition_id"]

  message
  |> Message.update_data(fn _ -> event end)
  |> Message.put_batch_key(partition_id)  # Route to partition-specific batch
end
```

### Agent/Poller Publishing

Agents and pollers publish to JetStream streams:

```elixir
# In poller
defmodule ServiceRadar.Poller.Publisher do
  def publish_event(event, partition_id) do
    subject = "events.#{partition_id}.#{event.type}"
    payload = Jason.encode!(event)

    Jetstream.publish(:nats, subject, payload,
      headers: %{"partition-id" => partition_id}
    )
  end
end
```

### Benefits

1. **Back-pressure**: Broadway automatically throttles producers when consumers can't keep up
2. **Batching**: Efficient bulk inserts reduce database round-trips
3. **Fault tolerance**: Failed messages are automatically retried or dead-lettered
4. **Exactly-once**: JetStream's acknowledgement semantics prevent duplicate processing
5. **Observability**: Broadway exports Telemetry events for monitoring pipeline health

## Shared Library Architecture

A shared Elixir library in `elixir/serviceradar_core/` provides common code:

```
elixir/
├── serviceradar_core/           # Shared library (hex package)
│   ├── lib/
│   │   ├── serviceradar/
│   │   │   ├── cluster/         # Horde, libcluster, ssl_dist helpers
│   │   │   ├── spiffe/          # SPIFFE/SPIRE integration
│   │   │   ├── registry/        # Partition-namespaced registry helpers
│   │   │   └── telemetry/       # Shared telemetry definitions
│   │   └── serviceradar.ex
│   └── mix.exs
├── serviceradar_poller/         # Standalone Poller release
│   └── mix.exs                  # depends on :serviceradar_core
├── serviceradar_agent/          # Standalone Agent release
│   └── mix.exs                  # depends on :serviceradar_core
└── serviceradar_web/            # Renamed from web-ng
    └── mix.exs                  # depends on :serviceradar_core
```

The shared library includes:
- **Cluster helpers**: ssl_dist configuration, libcluster strategies
- **SPIFFE helpers**: Certificate loading, identity verification
- **Registry helpers**: `{tenant_id, partition_id, resource_id}` tuple registration for tenant isolation
- **Telemetry**: Common metric definitions

## References

### Ash Framework
- [Ash Framework Documentation](https://ash-hq.org/)
- [Ash Actors & Authorization](https://hexdocs.pm/ash/actors-and-authorization.html)
- [Ash Policies](https://hexdocs.pm/ash/policies.html)
- [AshAuthentication Phoenix](https://hexdocs.pm/ash_authentication_phoenix/get-started.html)
- [AshOban](https://hexdocs.pm/ash_oban/AshOban.html)
- [AshStateMachine](https://hexdocs.pm/ash_state_machine/getting-started-with-ash-state-machine.html)
- [ElixirConf Lisbon 2024: AshOban & AshStateMachine](https://elixirconf.com/archives/lisbon_2024/talks/bring-your-app-to-life-with-ashoban-and-ashatatemachine/)

### Broadway & Data Pipelines
- [Broadway Overview](https://hexdocs.pm/broadway/Broadway.html)
- [Broadway Custom Producers](https://hexdocs.pm/broadway/custom-producers.html)
- [JetStream Elixir Client](https://hexdocs.pm/jetstream/overview.html)
- [OffBroadway.Jetstream.Producer](https://hexdocs.pm/jetstream/OffBroadway.Jetstream.Producer.html)
- [NATS JetStream Documentation](https://docs.nats.io/nats-concepts/jetstream)

### Project
- GitHub Issue #2205

## Multi-Tenant Security: Per-Tenant Certificate Binding (HIGH PRIORITY)

### Problem: Tenant ID Spoofing

Without cryptographic binding, a malicious actor could:
1. Deploy an agent with someone else's `tenant_id` env var
2. Join the cluster and receive monitoring traffic for another customer
3. Exfiltrate sensitive infrastructure data

**This is a critical security gap that must be addressed before production SaaS deployment.**

### Solution: Per-Tenant Certificate Binding

#### Certificate Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         ServiceRadar Root CA                                 │
│  (Managed by ServiceRadar Cloud / SPIRE Trust Domain)                       │
└───────────────────────────────┬─────────────────────────────────────────────┘
                                │
            ┌───────────────────┼───────────────────┐
            ▼                   ▼                   ▼
  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
  │ Tenant A        │  │ Tenant B        │  │ Tenant C        │
  │ Intermediate CA │  │ Intermediate CA │  │ Intermediate CA │
  │                 │  │                 │  │                 │
  │ tenant_id: AAA  │  │ tenant_id: BBB  │  │ tenant_id: CCC  │
  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘
           │                    │                    │
     ┌─────┴─────┐        ┌─────┴─────┐        ┌─────┴─────┐
     ▼           ▼        ▼           ▼        ▼           ▼
  poller-A   agent-A   poller-B   agent-B   poller-C   agent-C
```

Each tenant gets:
- An intermediate CA (or certificate set) issued by ServiceRadar
- Certificates encode `tenant_id` in the SPIFFE ID or SAN
- Agents/pollers CANNOT claim a tenant_id that doesn't match their certificate

#### SPIFFE ID Format

```
spiffe://serviceradar.io/tenant/<tenant_id>/poller/<poller_id>
spiffe://serviceradar.io/tenant/<tenant_id>/agent/<agent_id>
spiffe://serviceradar.io/tenant/<tenant_id>/collector/<collector_type>
```

The core validates that the SPIFFE ID tenant matches the claimed tenant_id on every connection.

#### Edge Onboarding Flow

##### Docker Compose (Development/Self-Hosted)
For development and single-tenant self-hosted deployments:
1. `generate-certs.sh` creates a single CA with all service certs
2. All services share the same tenant_id (default: `00000000-0000-0000-0000-000000000000`)
3. Zero-touch: certs are pre-provisioned via Docker volumes
4. No cloud connectivity required

##### SaaS Customer Onboarding
For multi-tenant SaaS deployments:

```
┌──────────────────────────────────────────────────────────────────────────┐
│                       User: Settings → Edge Onboarding                    │
└─────────────────────────────────────┬────────────────────────────────────┘
                                      │
                    ┌─────────────────▼─────────────────┐
                    │        Edge Onboarding Portal     │
                    │  (web-ng/lib/.../edge_live/*.ex)  │
                    │                                   │
                    │  1. Select component type:        │
                    │     • Poller                      │
                    │     • Agent                       │
                    │     • Collector (netflow/syslog)  │
                    │                                   │
                    │  2. Generate onboarding token     │
                    │     (JWT w/ tenant_id, exp, scope)│
                    │                                   │
                    │  3. Download installer bundle:    │
                    │     • Bootstrap script            │
                    │     • Onboarding token            │
                    │     • Cloud CA cert               │
                    └─────────────────┬─────────────────┘
                                      │
                    ┌─────────────────▼─────────────────┐
                    │       Edge Component Startup      │
                    │                                   │
                    │  1. Run bootstrap script          │
                    │  2. Present onboarding token      │
                    │  3. Request tenant-scoped cert    │
                    │     from SPIRE/onboarding-api     │
                    │  4. Receive:                      │
                    │     • Tenant intermediate CA      │
                    │     • Component certificate       │
                    │     • SPIFFE ID with tenant_id    │
                    │  5. Store certs, start service    │
                    └─────────────────┬─────────────────┘
                                      │
                    ┌─────────────────▼─────────────────┐
                    │         Component Joins Cluster   │
                    │                                   │
                    │  • mTLS handshake validates cert  │
                    │  • Core extracts SPIFFE tenant_id │
                    │  • Core verifies tenant_id match  │
                    │  • Component registered to Horde  │
                    │    with verified tenant context   │
                    └───────────────────────────────────┘
```

#### Validation at Connection Time

```elixir
defmodule ServiceRadar.Cluster.TenantValidator do
  @moduledoc """
  Validates that connecting nodes have valid tenant-scoped certificates.
  """

  @doc """
  Called on ERTS connection to validate peer certificate.
  Extracts tenant_id from SPIFFE ID and verifies against claimed tenant.
  """
  def validate_peer(peer_cert, claimed_tenant_id) do
    case extract_spiffe_id(peer_cert) do
      {:ok, spiffe_id} ->
        case parse_tenant_from_spiffe(spiffe_id) do
          {:ok, cert_tenant_id} when cert_tenant_id == claimed_tenant_id ->
            :ok

          {:ok, cert_tenant_id} ->
            {:error, {:tenant_mismatch, expected: cert_tenant_id, got: claimed_tenant_id}}

          :error ->
            {:error, :invalid_spiffe_format}
        end

      :error ->
        {:error, :no_spiffe_id}
    end
  end

  defp extract_spiffe_id(cert) do
    # Extract from SAN URI extension
    case :public_key.pkix_subject_id(cert) do
      {:ok, san} -> {:ok, find_spiffe_uri(san)}
      _ -> :error
    end
  end

  defp parse_tenant_from_spiffe("spiffe://serviceradar.io/tenant/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [tenant_id, _] -> {:ok, tenant_id}
      _ -> :error
    end
  end

  defp parse_tenant_from_spiffe(_), do: :error
end
```

#### NATS Multi-Tenant Users (for Edge Collectors)

Collectors that publish to NATS JetStream need tenant-scoped credentials:

```yaml
# NATS server config (per-tenant users)
authorization:
  users:
    - user: "tenant-AAA-collector"
      password: "$2a$11$..."
      permissions:
        publish:
          allow:
            - "metrics.AAA.>"
            - "events.AAA.>"
            - "logs.AAA.>"
        subscribe:
          deny: [">"]

    - user: "tenant-BBB-collector"
      password: "$2a$11$..."
      permissions:
        publish:
          allow:
            - "metrics.BBB.>"
            - "events.BBB.>"
            - "logs.BBB.>"
```

Edge onboarding generates NATS credentials alongside mTLS certificates.

#### Services Requiring Multi-Tenant Updates

| Service | Current State | Required Changes |
|---------|--------------|------------------|
| **datasvc** | No tenant awareness | Add tenant context to KV operations; validate tenant from mTLS cert |
| **serviceradar-zen** | No tenant awareness | Extract tenant from NATS subject; transform with tenant context |
| **db-event-writer** | No tenant awareness | Include tenant_id in all database writes |
| **onboarding-api** | Exists (Rust) | Add per-tenant cert issuance; NATS user provisioning |
| **core-elx** | Partial | Validate tenant on Horde registration; reject mismatched certs |
| **web-ng** | Partial | Edge Onboarding Portal UI for cert/token generation |

#### Implementation Priority

1. **Phase 1**: Certificate validation in Horde registration (block mismatched tenant_id)
2. **Phase 2**: Edge Onboarding Portal UI for token generation
3. **Phase 3**: Per-tenant cert issuance in onboarding-api
4. **Phase 4**: NATS user provisioning for collectors
5. **Phase 5**: datasvc/zen/db-event-writer multi-tenant updates
