# Tasks: Integrate Ash Framework

## Phase 0: Core-ELX Service

### 0.1 Core-ELX Release and Packaging
- [x] 0.1.1 Define `core-elx` release entrypoint (separate from web-ng)
- [x] 0.1.2 Add core-elx Docker image + Bazel push target
- [x] 0.1.3 Add `core-elx` service to docker compose
- [x] 0.1.4 Remove legacy Go services from docker compose

### 0.2 Core Scheduling and Dispatch
- [ ] 0.2.1 Move AshOban scheduler ownership to core-elx
- [ ] 0.2.2 Define ERTS dispatch protocol (Horde Registry + RPC)
- [ ] 0.2.3 Implement poller selection by tenant/domain
- [ ] 0.2.4 Implement agent selection by tenant/domain in poller
- [ ] 0.2.5 Enforce DB access boundaries (core-elx/web-ng only)

### 0.3 Large Payload Handling
- [ ] 0.3.1 Define gRPC streaming contracts for sync/sweep results
- [ ] 0.3.2 Implement chunked ingest pipeline to core-elx
- [ ] 0.3.3 Add backpressure and retry semantics for stream ingestion

### 0.4 Sweep Renames - REMOVED
> **DROPPED**: The serviceradar-agent-elx has been dropped due to security concerns. Only the Go serviceradar-core will be deployed to edge networks - no ERTS-enabled software goes into customer networks to avoid security risks.

### 0.5 Scheduling UI
- [ ] 0.5.1 Add scheduling resources/actions (sync cadence, ping/tcp cadence)
- [ ] 0.5.2 Build LiveView forms for schedule configuration
- [ ] 0.5.3 Wire schedules to AshOban triggers

### 0.6 Sync Rewrite + JetStream - REMOVED
> **DROPPED**: The sync service will remain in Go/gRPC. The existing NATS architecture stays the same - collectors push data to NATS via datasvc, zen-engine does ETL, and db-event-writer writes to the database. Focus shifts to publishing events from Elixir and onboarding tenant edge leaf servers (see 13.1).

### 0.7 Integration Source Management (Sync Configuration UI)
- [x] 0.7.1 Create IntegrationSource Ash resource in Configuration domain
- [x] 0.7.2 Add database migration for integration_sources table
- [x] 0.7.3 Create DataService.Client GenServer for gRPC KV operations
- [x] 0.7.4 Add GRPC.Client.Supervisor to application supervision tree
- [x] 0.7.5 Implement mTLS support in DataService.Client (DATASVC_* env vars)
- [x] 0.7.6 Add handle_info handlers for gun connection events (gun_down, gun_up, gun_error)
- [x] 0.7.7 Create IntegrationLive.Index LiveView for managing integration sources
- [x] 0.7.8 Add routes for /admin/integrations
- [x] 0.7.9 Fix Phoenix.Ecto.CheckRepoStatus to use :serviceradar_core for Ash migrations
- [x] 0.7.10 Create IntegrationLive.Form modals for creating/editing sources (inline in Index)
- [x] 0.7.11 Implement IntegrationSource :sync action to push config to datasvc KV (after_action hooks)
- [x] 0.7.12 Add UI for sync source credentials (encrypted via AshCloak) - credentials_json textarea
- [x] 0.7.13 Add IntegrationSource policies (admin-only write, operator read)
- [x] 0.7.14 Create Oban SyncToDataSvcWorker for reliable datasvc sync with retries
- [x] 0.7.15 Add partition dropdown to IntegrationSource create/edit forms
- [x] 0.7.16 Add Poller.list_by_partition action for partition-aware poller lookup
- [x] 0.7.17 Update SyncToDataSvcWorker to include available_pollers in sync config

### 0.8 Horde Cluster Visibility UI (Settings Page)
- [x] 0.8.1 Create Settings.ClusterLive.Index LiveView under /settings/cluster
- [x] 0.8.2 Display cluster node list with status (connected, disconnected)
- [x] 0.8.3 Show Horde registry counts (pollers, agents per partition)
- [ ] 0.8.4 Display partition summary with poller/agent counts (grouped by partition)
- [x] 0.8.5 Add real-time updates via PubSub for node join/leave events
- [x] 0.8.6 Show poller health status (healthy, degraded, offline)
- [x] 0.8.7 Display agent registration status per poller
- [x] 0.8.8 Add cluster connectivity health indicator (5 health cards with metrics)
- [x] 0.8.9 Show Oban job queue status (query oban_jobs table for queue stats)
- [ ] 0.8.10 Add manual poller drain/resume controls
- [x] 0.8.11 Create cluster event timeline (recent join/leave/failover)
- [x] 0.8.12 Add routes for /settings/cluster

### 0.9 Agent Check Configuration UI
- [x] 0.9.1 Update AgentLive.Index to show live Horde-registered agents section
- [x] 0.9.2 Add ServiceCheck table to AgentLive.Show page
- [ ] 0.9.3 Create ServiceCheck create modal (check type, target, interval, port)
- [ ] 0.9.4 Implement ServiceCheck enable/disable toggles
- [ ] 0.9.5 Add ServiceCheck edit/delete actions
- [ ] 0.9.6 Display check results and status in agent details
- [ ] 0.9.7 Add check execution history timeline

### 0.10 Infrastructure Detail Pages
- [x] 0.10.1 Create PollerLive.Show page with Horde registry integration
- [x] 0.10.2 Add node system info via RPC (uptime, processes, schedulers, memory)
- [x] 0.10.3 Add registration timeline with time ago display
- [x] 0.10.4 Enhance AgentLive.Show with Horde data and node info
- [x] 0.10.5 Add capabilities card with descriptions to agent details
- [x] 0.10.6 Make infrastructure page rows clickable to detail pages
- [x] 0.10.7 Add breadcrumb navigation from detail pages back to infrastructure
- [x] 0.10.8 Fix ClusterHealth Horde member sync (set_members on init/nodeup)
- [ ] 0.10.9 Remove capabilities display from poller details (pollers don't have capabilities)

## Phase 1: Foundation Setup

### 1.1 Dependencies and Configuration
- [x] 1.1.1 Add Ash core dependencies to mix.exs (ash, ash_postgres)
- [x] 1.1.2 Add AshAuthentication dependencies (ash_authentication, ash_authentication_phoenix)
- [x] 1.1.3 Add AshOban dependencies (ash_oban)
- [x] 1.1.4 Add AshStateMachine dependencies (ash_state_machine)
- [x] 1.1.5 Add AshJsonApi dependencies (ash_json_api)
- [x] 1.1.6 Add AshPhoenix dependencies (ash_phoenix)
- [x] 1.1.7 Add AshAdmin dependencies (ash_admin, dev only)
- [ ] 1.1.8 Add optional observability deps (open_telemetry_ash, ash_appsignal) - deferred, package not yet available
- [x] 1.1.9 Configure Ash in config.exs with domains
- [x] 1.1.10 Set up AshPostgres repo configuration
- [x] 1.1.11 Create feature flag system for gradual rollout

### 1.2 Multi-Tenancy Foundation
- [x] 1.2.1 Create database migration for tenants table
- [x] 1.2.2 Create ServiceRadar.Identity.Tenant Ash resource
- [x] 1.2.3 Add tenant_id column migration for ng_users table
- [x] 1.2.4 Create data migration script for existing users (assign default tenant)
- [x] 1.2.5 Implement tenant context plug for web requests
- [x] 1.2.6 Configure Ash multitenancy strategy (attribute-based)
- [x] 1.2.7 Test tenant isolation with multi-tenant test fixtures

### 1.3 Cluster Infrastructure (libcluster + Horde)
- [x] 1.3.1 Add libcluster dependency to mix.exs
- [x] 1.3.2 Add horde dependency to mix.exs
- [x] 1.3.3 Create ServiceRadar.ClusterSupervisor module
- [x] 1.3.4 Configure libcluster topologies in config/runtime.exs
- [x] 1.3.5 Implement cluster strategy selection (kubernetes/epmd/dns)
- [x] 1.3.6 Configure EPMD strategy for development environment
- [x] 1.3.7 Configure DNSPoll strategy for bare metal deployments
- [x] 1.3.8 Configure Kubernetes strategy for production (DNS mode)
- [x] 1.3.9 Create Kubernetes headless service manifest
- [x] 1.3.10 Implement dynamic cluster membership (update_topology/2)
- [x] 1.3.11 Add cluster strategy environment variable (CLUSTER_STRATEGY)
- [x] 1.3.12 Create cluster health monitoring GenServer
- [x] 1.3.13 Add cluster connectivity metrics to telemetry

### 1.4 mTLS for ERTS Distribution
- [x] 1.4.1 Create ssl_dist.conf template for TLS distribution
- [x] 1.4.2 Update rel/env.sh.eex with TLS distribution flags
- [x] 1.4.3 Document certificate generation process (CA + node certs)
- [x] 1.4.4 Create Kubernetes Secret manifest for node certificates
- [x] 1.4.5 Configure inet_tls proto_dist in vm.args
- [x] 1.4.6 Test mTLS cluster formation in staging environment
- [x] 1.4.7 Add certificate rotation documentation
- [x] 1.4.8 Implement certificate expiry monitoring

### 1.5 Horde Registry and Supervisor Setup
- [x] 1.5.1 Create ServiceRadar.PollerRegistry (Horde.Registry)
- [x] 1.5.2 Create ServiceRadar.AgentRegistry (Horde.Registry)
- [x] 1.5.3 Create ServiceRadar.PollerSupervisor (Horde.DynamicSupervisor)
- [x] 1.5.4 Configure Horde members: :auto for cluster auto-join
- [x] 1.5.5 Create ServiceRadar.Poller.RegistrationWorker GenServer
- [x] 1.5.6 Implement poller auto-registration on startup
- [x] 1.5.7 Implement heartbeat mechanism for poller health
- [x] 1.5.8 Create ServiceRadar.Poller.AgentRegistry module (integrated in AgentRegistry)
- [x] 1.5.9 Implement agent registration when connecting via gRPC
- [x] 1.5.10 Implement agent unregistration on disconnect
- [x] 1.5.11 Add PubSub broadcasting for registration events
- [x] 1.5.12 Create find_poller_for_partition/1 lookup function
- [x] 1.5.13 Create find_available_pollers/0 for load balancing
- [x] 1.5.14 Test Horde registry synchronization across nodes

## Phase 2: Authentication Migration

### 2.1 AshAuthentication Setup
- [x] 2.1.1 Create ServiceRadar.Identity domain module
- [x] 2.1.2 Create ServiceRadar.Identity.User Ash resource (parallel to existing)
- [x] 2.1.3 Map User attributes to ng_users table with source: option
- [x] 2.1.4 Implement password authentication strategy
- [x] 2.1.5 Implement magic link authentication strategy
- [x] 2.1.6 Add email confirmation workflow
- [x] 2.1.7 Create database migration for tokens table (if different from existing)
- [x] 2.1.8 Implement session management with AshAuthentication

### 2.2 OAuth2 Integration
- [ ] 2.2.1 Configure OAuth2 strategy for Google
- [ ] 2.2.2 Configure OAuth2 strategy for GitHub
- [ ] 2.2.3 Create OAuth callback handlers
- [ ] 2.2.4 Implement user creation/linking from OAuth
- [ ] 2.2.5 Add OAuth provider configuration per-tenant (future)
- [ ] 2.2.6 Test OAuth flows in development environment

### 2.3 API Token Authentication
- [x] 2.3.1 Create ServiceRadar.Identity.ApiToken Ash resource
- [x] 2.3.2 Create database migration for api_tokens table
- [x] 2.3.3 Implement API token generation action
- [x] 2.3.4 Implement API token validation action
- [x] 2.3.5 Add API token scopes (read-only, full-access, admin)
- [x] 2.3.6 Integrate API token auth with existing api_key_auth pipeline

### 2.4 Phoenix Integration
- [x] 2.4.1 Update router.ex with AshAuthentication.Phoenix routes
- [x] 2.4.2 Replace UserLive.Login with AshAuthentication.Phoenix components
- [x] 2.4.3 Replace UserLive.Registration with AshAuthentication.Phoenix components
- [x] 2.4.4 Update UserSessionController to use AshAuthentication
- [x] 2.4.5 Migrate user_auth.ex to AshAuthentication patterns
- [x] 2.4.6 Update LiveView mount hooks for Ash actor (actor/tenant in socket assigns)
- [x] 2.4.7 Add Ash actor/tenant to browser pipeline (set_ash_actor plug)
- [x] 2.4.8 Test authentication flows end-to-end
- [x] 2.4.9 Migrate Ecto UserToken to Ash Token (JWT-based)

## Phase 3: Authorization (RBAC)

### 3.1 Role System
- [x] 3.1.1 Create database migration for roles (admin, operator, viewer)
- [x] 3.1.2 Add role field to User resource
- [x] 3.1.3 Create data migration for existing users (assign default role)
- [x] 3.1.4 Create role assignment actions
- [ ] 3.1.5 Document role permissions matrix

### 3.2 Policy Implementation
- [x] 3.2.1 Create base policy macros for common patterns
- [x] 3.2.2 Implement tenant isolation policy (applies to all tenant-scoped resources)
- [x] 3.2.3 Implement admin bypass policy
- [x] 3.2.4 Implement operator policies (create, update, no destroy)
- [x] 3.2.5 Implement viewer policies (read-only)
- [x] 3.2.6 Add partition-aware policies for overlapping IP spaces
- [x] 3.2.7 Implement field-level policies for sensitive data (N/A - sensitive fields use public? false)
- [x] 3.2.8 Create policy test suite with multi-tenant scenarios

### 3.3 Authorization Configuration
- [x] 3.3.1 Set domain authorization to :by_default
- [x] 3.3.2 Configure require_actor? for all domains
- [x] 3.3.3 Add authorization error handling middleware
- [x] 3.3.4 Implement audit logging for authorization failures

### 3.4 PII Encryption (AshCloak)
- [x] 3.4.1 Add ash_cloak and cloak dependencies to mix.exs
- [x] 3.4.2 Configure encryption keys in runtime.exs (CLOAK_KEY env var)
- [x] 3.4.3 Create ServiceRadar.Vault module with AES-256-GCM encryption
- [x] 3.4.4 Add AshCloak extension to Tenant resource (contact_email, contact_name encryption)
- [x] 3.4.5 Create database migration for encrypted_contact_email/name columns
- [ ] 3.4.6 Implement key rotation strategy - DEFERRED (documented in Vault module)
- [ ] 3.4.7 Add AshCloak to User resource (email) - DEFERRED (requires blind indexing for auth lookups)
- [ ] 3.4.8 Implement data migration script to encrypt existing tenant contacts

## Phase 4: Inventory Domain

### 4.1 Device Resource
- [x] 4.1.1 Create ServiceRadar.Inventory domain module
- [x] 4.1.2 Create ServiceRadar.Inventory.Device Ash resource
- [x] 4.1.3 Map all OCSF attributes with source: option to ocsf_devices table
- [x] 4.1.4 Add tenant_id to Device with multitenancy config
- [x] 4.1.5 Implement Device read action with pagination
- [x] 4.1.6 Implement Device show action
- [x] 4.1.7 Implement Device update action (admin/operator only)
- [x] 4.1.8 Add Device calculations (type_name, status_color, display_name)
- [x] 4.1.9 Implement Device policies
- [x] 4.1.10 Add database migration for tenant_id on ocsf_devices

### 4.2 Device Relationships
- [x] 4.2.1 Create ServiceRadar.Inventory.Interface resource
- [x] 4.2.2 Define Device has_many :interfaces relationship
- [x] 4.2.3 Create ServiceRadar.Inventory.DeviceGroup resource
- [x] 4.2.4 Define Device belongs_to :group relationship
- [x] 4.2.5 Implement relationship loading with policies

### 4.3 Device Identity Reconciliation
- [x] 4.3.1 Create device identity custom action
- [x] 4.3.2 Implement MAC-based identity resolution
- [x] 4.3.3 Implement IP-based identity resolution
- [x] 4.3.4 Implement external ID resolution (Armis, NetBox)
- [x] 4.3.5 Create identity merge audit resource
- [x] 4.3.6 Port Go identity reconciliation logic

## Phase 5: Infrastructure Domain

### 5.1 Poller Resource
- [x] 5.1.1 Create ServiceRadar.Infrastructure domain module
- [x] 5.1.2 Create ServiceRadar.Infrastructure.Poller Ash resource
- [x] 5.1.3 Map attributes to pollers table
- [x] 5.1.4 Add tenant_id and partition_id to Poller
- [x] 5.1.5 Implement Poller CRUD actions
- [x] 5.1.6 Add Poller health calculation
- [x] 5.1.7 Implement Poller policies (partition-aware)
- [x] 5.1.8 Add database migration for tenant_id on pollers

### 5.2 Agent Resource
- [x] 5.2.1 Create ServiceRadar.Infrastructure.Agent Ash resource
- [x] 5.2.2 Map attributes to agents table (OCSF-aligned)
- [x] 5.2.3 Define Agent belongs_to :poller relationship
- [x] 5.2.4 Implement Agent lifecycle state machine
- [x] 5.2.5 Add Agent health status calculation
- [x] 5.2.6 Implement Agent policies
- [x] 5.2.7 Add tenant_id to Agent with multitenancy config
- [x] 5.2.8 Add database migration for ocsf_agents table
- [x] 5.2.9 Define Agent belongs_to :device relationship
- [x] 5.2.10 Define Agent has_many :checkers relationship

### 5.3 Checker Resource
- [x] 5.3.1 Create ServiceRadar.Infrastructure.Checker Ash resource
- [x] 5.3.2 Define Checker belongs_to :agent relationship
- [x] 5.3.3 Implement checker type enum (snmp, grpc, sweep, etc.)
- [x] 5.3.4 Implement Checker policies
- [x] 5.3.5 Add tenant_id to Checker with multitenancy config
- [x] 5.3.6 Add database migration for checkers table

### 5.4 Partition Resource
- [x] 5.4.1 Create ServiceRadar.Infrastructure.Partition Ash resource
- [x] 5.4.2 Define Partition has_many :pollers relationship
- [x] 5.4.3 Implement partition validation (CIDR ranges)
- [x] 5.4.4 Add partition context to actor for policy evaluation
- [x] 5.4.5 Add Poller belongs_to :partition relationship
- [x] 5.4.6 Add database migration for partitions table

## Phase 6: Monitoring Domain

### 6.1 Service Check Resource
- [x] 6.1.1 Create ServiceRadar.Monitoring domain module
- [x] 6.1.2 Create ServiceRadar.Monitoring.ServiceCheck Ash resource
- [x] 6.1.3 Implement service check scheduling action
- [x] 6.1.4 Integrate with AshOban for check execution
- [x] 6.1.5 Implement check result recording

### 6.2 Alert Resource with State Machine
- [x] 6.2.1 Create ServiceRadar.Monitoring.Alert Ash resource
- [x] 6.2.2 Add AshStateMachine extension to Alert
- [x] 6.2.3 Define alert states (pending, acknowledged, resolved, escalated)
- [x] 6.2.4 Define alert transitions (acknowledge, resolve, escalate)
- [x] 6.2.5 Implement alert acknowledgement action
- [x] 6.2.6 Implement alert resolution action
- [x] 6.2.7 Implement alert escalation action with AshOban
- [x] 6.2.8 Add alert notification trigger
- [x] 6.2.9 Implement alert policies

### 6.3 Event Resource
- [x] 6.3.1 Create ServiceRadar.Monitoring.Event Ash resource
- [x] 6.3.2 Implement event recording action
- [x] 6.3.3 Add event severity enum
- [x] 6.3.4 Add event source tracking (device, poller, system)
- [x] 6.3.5 Implement event read action with time filtering

## Phase 7: Edge Onboarding Domain

### 7.1 Edge Package State Machine
- [x] 7.1.1 Create ServiceRadar.Edge domain module
- [x] 7.1.2 Create ServiceRadar.Edge.OnboardingPackage Ash resource
- [x] 7.1.3 Add AshStateMachine extension to OnboardingPackage
- [x] 7.1.4 Define package states (issued, delivered, activated, expired, revoked, deleted)
- [x] 7.1.5 Define package transitions
- [x] 7.1.6 Implement package creation action
- [x] 7.1.7 Implement package deliver action with state transition
- [x] 7.1.8 Implement package revocation action
- [x] 7.1.9 Port existing Edge context functions (integrate with OnboardingPackages module)

### 7.2 Edge Events
- [x] 7.2.1 Create ServiceRadar.Edge.OnboardingEvent Ash resource
- [x] 7.2.2 Implement event recording with AshOban worker
- [x] 7.2.3 Link events to packages (relationship defined)
- [x] 7.2.4 Port existing OnboardingEvents functions

## Phase 8: Job Scheduling (AshOban)

### 8.1 AshOban Configuration
- [x] 8.1.1 Configure AshOban in Oban config
- [x] 8.1.2 Define queues for different job types
- [x] 8.1.3 Set up Oban.Peer for distributed coordination

### 8.2 Migrate Existing Jobs
- [x] 8.2.1 Move refresh_trace_summaries to Oban.Plugins.Cron (not AshOban - no Ash resource)
- [x] 8.2.2 Convert expire_packages to AshOban trigger on OnboardingPackage
- [x] 8.2.3 Comment out custom Jobs.Scheduler (legacy, pending removal)
- [ ] 8.2.4 Update ng_job_schedules table or migrate to Ash

### 8.3 Polling Job System
- [x] 8.3.1 Create ServiceCheck :execute action with AshOban
- [x] 8.3.2 Implement polling schedule resource (PollingSchedule with AshOban)
- [x] 8.3.3 Create poll orchestration action (:execute action on PollingSchedule)
- [x] 8.3.4 Implement result processing action (:record_result action on PollingSchedule)
- [x] 8.3.5 Add distributed locking for poll coordination (:acquire_lock/:release_lock actions)

## Phase 9: API Layer

### 9.1 AshJsonApi Setup
- [x] 9.1.1 Add AshJsonApi extension to resources (Device, Poller, Agent, ServiceCheck, Alert)
- [x] 9.1.2 Configure JSON:API routes for Inventory domain (/api/v2/devices)
- [x] 9.1.3 Configure JSON:API routes for Infrastructure domain (/api/v2/pollers, /api/v2/agents)
- [x] 9.1.4 Configure JSON:API routes for Monitoring domain (/api/v2/service-checks, /api/v2/alerts)
- [x] 9.1.5 Add API versioning (mount at /api/v2 with AshJsonApiRouter)
- [x] 9.1.6 Implement API error handling (ApiErrorHandler plug with telemetry, JSON:API error formatting)

### 9.2 SRQL Integration
- [x] 9.2.1 Create ServiceRadarWebNG.SRQL.AshAdapter module
- [x] 9.2.2 Implement SRQL entity to Ash resource routing
- [x] 9.2.3 Implement SRQL filter to Ash filter translation
- [x] 9.2.4 Implement SRQL sort to Ash sort translation
- [x] 9.2.5 Implement pagination format conversion
- [x] 9.2.6 Add actor context to SRQL queries for policy enforcement
- [x] 9.2.7 Route devices, pollers, agents through Ash path
- [x] 9.2.8 Keep metrics, flows, traces on SQL path
- [x] 9.2.9 Add performance monitoring for Ash vs SQL paths
- [x] 9.2.10 Update QueryController to use AshAdapter

### 9.3 Phoenix LiveView Integration
- [x] 9.3.1 Add AshPhoenix.Form to device LiveViews (N/A - device LiveViews are read-only)
- [x] 9.3.2 Add AshPhoenix.Form to admin LiveViews (EdgePackageLive uses Ash via context, JobLive uses Ecto for schedules - task 8.2.4)
- [x] 9.3.3 Implement form validation with Ash changesets (EdgePackageLive validates via Ash create action, errors handled properly)
- [x] 9.3.4 Update dashboard plugins to use Ash queries where applicable (SRQL handles routing to Ash for devices/pollers/agents)

## Phase 10: Admin & Observability

### 10.1 AshAdmin Setup
- [x] 10.1.1 Configure AshAdmin for development environment
- [x] 10.1.2 Add admin routes to router (dev/staging only)
- [ ] 10.1.3 Customize AshAdmin appearance (optional)
- [ ] 10.1.4 Add tenant switcher to admin interface (optional)

### 10.2 Horde Cluster Admin Dashboard
- [x] 10.2.1 Create ClusterLive.Index LiveView for cluster/infrastructure overview
- [x] 10.2.2 Implement real-time node status via PubSub
- [x] 10.2.3 Create poller registry table component (both Horde and Ash resources)
- [x] 10.2.4 Create agent registry table component (both Horde and Ash resources)
- [ ] 10.2.5 Implement cluster topology visualization (D3.js or similar) - DEFERRED
- [ ] 10.2.6 Add process supervisor view with memory stats - DEFERRED
- [ ] 10.2.7 Implement node disconnect alerts - DEFERRED
- [ ] 10.2.8 Add manual poller status control (mark unavailable) - DEFERRED
- [x] 10.2.9 Create cluster health metrics cards
- [ ] 10.2.10 Add job distribution visualization per node - DEFERRED
- [x] 10.2.11 Implement cluster event log viewer
- [x] 10.2.12 Add admin routes for cluster dashboard (/admin/cluster)

### 10.3 Observability Integration
- [x] 10.3.1 Configure Ash telemetry metrics (action duration/count, query duration/count)
- [x] 10.3.2 Add Ash action tracing via telemetry events
- [ ] 10.3.3 Add policy evaluation metrics - DEFERRED (requires Ash policy tracer)
- [x] 10.3.4 Integrate with existing telemetry module
- [x] 10.3.5 Add Horde registry metrics export (poller/agent count)
- [x] 10.3.6 Add cluster connectivity metrics (node count)

## Phase 11: Testing & Documentation

### 11.1 Test Infrastructure
- [x] 11.1.1 Create Ash test helpers and fixtures
- [x] 11.1.2 Create multi-tenant test factory
- [x] 11.1.3 Create policy test macros
- [x] 11.1.4 Update existing tests to use Ash resources (all 436 tests use Ash fixtures/contexts with multitenancy)

### 11.2 Test Coverage
- [x] 11.2.1 Write tests for all Identity domain resources (identity_policies_test.exs, identity/policy_test.exs)
- [x] 11.2.2 Write tests for all Inventory domain resources (inventory/device_test.exs)
- [x] 11.2.3 Write tests for all Infrastructure domain resources (infrastructure/poller_test.exs, agent_test.exs, partition_test.exs)
- [x] 11.2.4 Write tests for all Monitoring domain resources (monitoring/alert_test.exs, service_check_test.exs, event_test.exs)
- [x] 11.2.5 Write tests for AshOban jobs (OnboardingPackage expire trigger, PollingSchedule execute, ServiceCheck execute, Alert auto_escalate/send_notifications)
- [x] 11.2.6 Write tests for state machine transitions (covered in alert_test.exs, agent_test.exs, onboarding_package_test.exs)
- [x] 11.2.7 Write API integration tests (29 tests: JSON:API format, tenant isolation, CRUD operations, OpenAPI spec)
- [x] 11.2.8 Write SRQL adapter tests (47 tests for entity routing, filter ops, sort, tenant isolation)
- [x] 11.2.9 Write multi-tenant isolation tests
- [x] 11.2.10 Write policy enforcement tests

### 11.3 Documentation
- [x] 11.3.1 Document domain architecture (docs/docs/ash-domains.md)
- [x] 11.3.2 Document authentication flows (docs/docs/ash-authentication.md)
- [x] 11.3.3 Document authorization policies (docs/docs/ash-authorization.md)
- [x] 11.3.4 Document API endpoints (docs/docs/ash-api.md)
- [x] 11.3.5 Update AGENTS.md with Ash patterns (web-ng/AGENTS.md)
- [x] 11.3.6 Create migration guide for existing deployments (docs/docs/ash-migration-guide.md)

## Phase 12: Migration & Cleanup

### 12.1 Data Migration - REMOVED
> **DROPPED**: No existing production data to migrate - no users are currently on the system. Fresh deployments will use the new Ash-based schema directly.

### 12.2 Feature Flag Cleanup
- [x] 12.2.1 Remove Ecto-based Accounts context (replaced by Ash)
- [x] 12.2.2 Migrate Inventory context to use Ash resources (ServiceRadarWebNG.Inventory delegates to ServiceRadar.Inventory.Device)
- [x] 12.2.3 Migrate Infrastructure context to use Ash resources (ServiceRadarWebNG.Infrastructure delegates to ServiceRadar.Infrastructure.{Poller,Agent})
- [x] 12.2.4 Remove Ecto-based Edge context (replaced by Ash)
- [x] 12.2.5 Remove custom Jobs.Scheduler (replaced by AshOban + Oban.Plugins.Cron)
- [x] 12.2.6 Remove feature flags once stable (enabled ash_srql_adapter by default, removed unused flags and FeatureFlags module)
- [x] 12.2.7 Update all imports and aliases (verified clean - no stale imports after FeatureFlags removal)

### 12.3 API Deprecation - REMOVED
> **DROPPED**: No API consumers to migrate - no existing users. The v2 Ash-based API becomes the primary API without deprecation cycle.

## Phase 13: Edge-to-Cloud Infrastructure

### 13.1 NATS JetStream Integration (Revised Scope)
> **SCOPE**: The NATS architecture stays the same - collectors push to NATS, zen-engine does ETL, db-event-writer writes to DB. Focus is on: (1) publishing events TO NATS from Elixir using [Jetstream](https://hexdocs.pm/jetstream/Jetstream.html), (2) onboarding tenant-specific NATS JetStream edge leaf servers.

- [x] 13.1.1 Add jetstream dependency to mix.exs
- [x] 13.1.2 Create ServiceRadar.NATS.Connection module for connection management
- [ ] 13.1.3 Configure NATS connection in runtime.exs (NATS_URL, credentials)
- [x] 13.1.4 Create ServiceRadar.Infrastructure.EventPublisher module for publishing events from Elixir
- [ ] 13.1.5 Design tenant-scoped subject hierarchy for edge leaf servers
- [ ] 13.1.6 Create tenant edge leaf server onboarding workflow
- [ ] 13.1.7 Add NATS credentials generation per tenant
- [ ] 13.1.8 Create NATS health check for cluster health monitoring
- [ ] 13.1.9 Add NATS metrics to telemetry (publish rate, errors)
- [ ] 13.1.10 Document edge leaf server topology and tenant isolation

### 13.2 Device Actor System
- [x] 13.2.1 Create ServiceRadar.Actors.Device GenServer module
- [x] 13.2.2 Implement device actor registration with `{tenant_id, partition_id, device_id}` key
- [x] 13.2.3 Create ServiceRadar.Actors.DeviceRegistry for discovery and lazy initialization (uses TenantRegistry's DynamicSupervisor)
- [x] 13.2.4 Implement device actor state: identity, last_seen, health, config, events, metrics
- [x] 13.2.5 Create get_or_start/3 function for lazy actor initialization
- [x] 13.2.6 Implement device actor commands (update_identity, record_event, record_health_check, refresh_config, flush_events, touch)
- [x] 13.2.7 Add device actor timeout/hibernation for inactive devices (@hibernate_after, @idle_timeout)
- [x] 13.2.8 Implement device actor handoff on node failure (Horde automatic via TenantRegistry)
- [ ] 13.2.9 Create device actor LiveView debugging panel
- [x] 13.2.10 Add device actor telemetry metrics (ServiceRadar.Actors.Telemetry module)

### 13.3 Per-Tenant Oban Queue Isolation (HIGH PRIORITY)
> **GOAL**: Each tenant should have their own AshOban registry/queues for complete compartmentalization. This ensures tenant workloads don't interfere with each other and enables per-tenant job prioritization.

- [x] 13.3.1 Design per-tenant queue naming: `t_{tenant_hash}_{job_type}` (e.g., `t_a1b2c3d4_polling`)
- [x] 13.3.2 Create ServiceRadar.Oban.TenantQueues module (GenServer for queue management)
- [x] 13.3.3 Implement tenant-aware job insertion via TenantQueues.insert_job/4
- [x] 13.3.4 Create ServiceRadar.Oban.AshObanQueueResolver for AshOban trigger integration
- [x] 13.3.5 Implement tenant queue isolation (separate queues per tenant)
- [x] 13.3.6 Create TenantQueues.get_tenant_stats/1 for queue monitoring
- [x] 13.3.7 Add pause_tenant/resume_tenant/scale_tenant_queue for queue control
- [x] 13.3.8 Integrate queue provisioning into InitializeTenantInfrastructure change
- [x] 13.3.9 Create ServiceRadar.Oban.TenantWorker behaviour for tenant-aware workers
- [ ] 13.3.10 Create LiveView dashboard for per-tenant queue monitoring

### 13.4 Mesh VPN Configuration - DEFERRED
> **DEFERRED**: Mesh VPN configuration deferred until core platform is stable. Will revisit when edge deployment requirements are clearer.

### 13.5 Partition Namespacing
- [x] 13.5.1 Update all Horde registrations to use `{tenant_id, partition_id, resource_id}` keys (tenant-scoped)
- [x] 13.5.2 Update AgentRegistry to support tenant-scoped lookups (find_agents_for_tenant, find_agents_for_partition)
- [x] 13.5.3 Update PollerRegistry to support tenant-scoped lookups (find_pollers_for_tenant, find_available_pollers)
- [ ] 13.5.4 Create partition context plug for web requests
- [ ] 13.5.5 Implement partition validation in Ash policies
- [ ] 13.5.6 Update SRQL adapter for partition-aware queries
- [ ] 13.5.7 Create partition hierarchy validation (tenant owns partition)
- [ ] 13.5.8 Add partition-scoped PubSub topics
- [ ] 13.5.9 Document overlapping IP space handling strategy

### 13.6 Datasvc Transition (Rust -> Elixir) - REMOVED
> **DROPPED**: Not transitioning datasvc. It will remain as a Rust service. The existing architecture works well for KV operations and edge configuration.

### 13.7 SPIRE/SPIFFE Integration - DEFERRED
> **DEFERRED**: SPIRE/SPIFFE integration deferred for later. Current mTLS setup with generated certificates is sufficient for initial deployments.

### 13.8 Remote Shell Testing & Debugging
- [ ] 13.8.1 Create test script for mTLS remote shell connection
- [ ] 13.8.2 Document IEx remote shell usage with ssl_dist.conf
- [ ] 13.8.3 Create debug helper module with observer shortcuts
- [ ] 13.8.4 Test remote shell from cloud to edge node
- [ ] 13.8.5 Document process inspection across distributed cluster
- [ ] 13.8.6 Create troubleshooting guide for connection failures
- [ ] 13.8.7 Add firewall rule documentation for mTLS ERTS traffic

## Phase 14: Shared Library Architecture

### 14.1 Create serviceradar_core Library
- [x] 14.1.1 Create elixir/serviceradar_core directory structure
- [x] 14.1.2 Initialize mix.exs with library configuration
- [x] 14.1.3 Add hex package metadata (optional, for internal publishing)
- [x] 14.1.4 Create ServiceRadar.Cluster module (ssl_dist helpers)
- [x] 14.1.5 Create ServiceRadar.Registry module (partition-namespaced registration)
- [x] 14.1.6 Create ServiceRadar.SPIFFE module (certificate helpers)
- [x] 14.1.7 Create ServiceRadar.Telemetry module (shared metrics)
- [x] 14.1.8 Add comprehensive tests for shared modules
- [x] 14.1.9 Document library usage for standalone releases

### 14.2 Create serviceradar_poller Release
- [x] 14.2.1 Create elixir/serviceradar_poller directory structure
- [x] 14.2.2 Initialize mix.exs with dependency on :serviceradar_core
- [x] 14.2.3 Move PollerRegistry and related code from web-ng
- [x] 14.2.4 Create Poller.Application supervision tree
- [x] 14.2.5 Configure libcluster for cluster joining
- [x] 14.2.6 Configure ssl_dist for mTLS distribution
- [x] 14.2.7 Create release configuration (rel/env.sh.eex)
- [x] 14.2.8 Create Dockerfile for poller release
- [x] 14.2.9 Create Helm chart for K8s deployment
- [x] 14.2.10 Test standalone poller joining cloud cluster

### 14.3 Create serviceradar_agent Release
- [x] 14.3.1 Create elixir/serviceradar_agent directory structure
- [x] 14.3.2 Initialize mix.exs with dependency on :serviceradar_core
- [x] 14.3.3 Move AgentRegistry and related code from web-ng
- [x] 14.3.4 Create Agent.Application supervision tree
- [x] 14.3.5 Configure libcluster for cluster joining
- [x] 14.3.6 Configure ssl_dist for mTLS distribution
- [x] 14.3.7 Create release configuration (rel/env.sh.eex)
- [x] 14.3.8 Create Dockerfile for agent release
- [x] 14.3.9 Create systemd service file for bare metal deployment
- [x] 14.3.10 Test standalone agent joining cloud cluster

### 14.4 Update web-ng as serviceradar_web
- [x] 14.4.1 Add dependency on :serviceradar_core to mix.exs
- [x] 14.4.2 Remove duplicated code now in shared library
- [x] 14.4.3 Update imports/aliases for shared modules
- [x] 14.4.4 Verify all tests pass with shared library (209 tests pass with Ash Identity integration)
- [x] 14.4.5 Update Docker build to include shared library
- [x] 14.4.6 Document web-ng to serviceradar_web transition

## Phase 15: Standalone Core-Elx Service (Go Core Replacement)

The Go `serviceradar-core` service handles coordination, identity reconciliation, poller management, and gRPC endpoints. This phase creates the Elixir replacement (`core-elx`) that acts as the central "brain" of the distributed cluster.

### 15.1 Core-Elx Service Foundation
- [ ] 15.1.1 Create elixir/serviceradar_core_service directory structure
- [ ] 15.1.2 Initialize mix.exs with dependency on :serviceradar_core library
- [ ] 15.1.3 Create ServiceRadarCoreService.Application supervision tree
- [ ] 15.1.4 Configure as the primary Horde supervisor node
- [ ] 15.1.5 Configure libcluster for cluster coordination
- [ ] 15.1.6 Configure ssl_dist for mTLS distribution
- [ ] 15.1.7 Create release configuration (rel/env.sh.eex)
- [ ] 15.1.8 Create Dockerfile for core-elx release
- [ ] 15.1.9 Add core-elx service to docker-compose.yml
- [ ] 15.1.10 Generate ssl_dist.core.conf for mTLS distribution

### 15.2 Horde Coordination (Moved from web-ng)
- [ ] 15.2.1 Move PollerSupervisor to core-elx (primary coordinator)
- [ ] 15.2.2 Move ClusterSupervisor to core-elx (cluster leader)
- [ ] 15.2.3 Move ClusterHealth to core-elx
- [ ] 15.2.4 Configure Horde registries with core-elx as primary member
- [ ] 15.2.5 Update web-ng to query Horde from core-elx (not run Horde itself)
- [ ] 15.2.6 Add coordination handoff on core-elx restart
- [ ] 15.2.7 Implement leader election for multi-core deployments

### 15.3 Device Identity Reconciliation (Port from Go)
- [x] 15.3.1 Create ServiceRadar.Identity.DeviceLookup module
- [x] 15.3.2 Implement GetCanonicalDevice equivalent (identity_lookup.go)
- [x] 15.3.3 Port MAC-based identity resolution
- [x] 15.3.4 Port IP-based identity resolution with partition awareness
- [x] 15.3.5 Port external ID resolution (Armis, NetBox, etc.)
- [x] 15.3.6 Implement identity merge with audit logging
- [x] 15.3.7 Create identity cache with TTL (replaces canonical_cache.go)
- [x] 15.3.8 Port alias event tracking (alias_events.go) + DeviceAliasState with AshStateMachine
- [x] 15.3.9 Add identity metrics (lookup latency, hit rate, merge count)
- [x] 15.3.10 Generate database migration for device_alias_states table

### 15.4 Result Processing (Port from Go)
- [x] 15.4.1 Create ServiceRadar.Core.ResultProcessor module
- [x] 15.4.2 Implement host metadata building (response_time, ICMP, ports)
- [x] 15.4.3 Implement canonical identity resolution for sweeps
- [x] 15.4.4 Port sweep result processing (result_processor.go)
- [ ] 15.4.5 Implement result batching for database writes
- [ ] 15.4.6 Add result processing metrics (throughput, latency)
- [ ] 15.4.7 Connect to Broadway pipelines for high-volume data

### 15.5 Alert Generation (Port from Go)
- [x] 15.5.1 Create ServiceRadar.Core.AlertGenerator module
- [x] 15.5.2 Port alert threshold evaluation (stats_alerts.go)
- [x] 15.5.3 Implement alert deduplication logic (cooldown mechanism)
- [x] 15.5.4 Connect to AshStateMachine Alert resource
- [x] 15.5.5 Port webhook notification (alerts/webhook.go) - WebhookNotifier module
- [ ] 15.5.6 Port Discord notification (alerts/discord.go) - via webhook
- [x] 15.5.7 Add startup/shutdown notifications (stats_anomaly alert)

### 15.6 Stats Aggregation (Port from Go)
- [x] 15.6.1 Create ServiceRadar.Core.StatsAggregator module
- [x] 15.6.2 Port stats aggregation logic (stats_aggregator.go)
- [x] 15.6.3 Implement canonical record filtering and deduplication
- [x] 15.6.4 Implement per-partition stats tracking
- [x] 15.6.5 Add telemetry metrics for stats snapshots
- [ ] 15.6.6 Create stats dashboard endpoint

### 15.7 Infrastructure State Machine & Events (Expanded Scope)
> **SCOPE**: Track state of ALL infrastructure components (pollers, agents, checkers, collectors) using AshStateMachine. Publish online/offline and state transition events to NATS JetStream using [Jetstream](https://hexdocs.pm/jetstream/Jetstream.html). This replaces the narrow "poller recovery" scope.

#### 15.7.A State Machine for Pollers
- [x] 15.7.1 Add AshStateMachine to Infrastructure.Poller resource
- [x] 15.7.2 Define poller states: healthy, degraded, offline, recovering, maintenance, draining, inactive
- [x] 15.7.3 Define state transitions with guards and conditions
- [x] 15.7.4 Implement automatic state transitions based on heartbeat timeout (via StateMonitor)
- [x] 15.7.5 Add after_transition hooks to publish events to NATS JetStream (via PublishStateChange Ash change)

#### 15.7.B State Machine for Agents
- [x] 15.7.6 AshStateMachine already exists for Infrastructure.Agent (connecting, connected, degraded, disconnected, unavailable)
- [x] 15.7.7 Agent state transitions already defined (establish_connection, degrade, lose_connection, etc.)
- [x] 15.7.8 Reachability tracking exists (last_seen_time) - StateMonitor handles timeout detection
- [x] 15.7.9 Add after_transition hooks for agent events to NATS (via PublishStateChange Ash change)

#### 15.7.C State Machine for Checkers/Collectors
- [x] 15.7.10 Add AshStateMachine to Infrastructure.Checker resource
- [x] 15.7.11 Define checker states: active, paused, failing, disabled
- [x] 15.7.12 Track checker health (consecutive_failures, last_success, last_failure, failure_reason)
- [x] 15.7.13 Add after_transition hooks for checker events to NATS (via PublishStateChange Ash change)

#### 15.7.D Infrastructure State Monitor
- [x] 15.7.14 Create ServiceRadar.Infrastructure.StateMonitor GenServer
- [x] 15.7.15 Implement heartbeat timeout detection for pollers
- [x] 15.7.16 Implement reachability checks for agents
- [x] 15.7.17 Implement health checks for checkers (consecutive_failures threshold)
- [ ] 15.7.18 Integrate with Horde for distributed tracking
- [x] 15.7.19 Add telemetry metrics (state_monitor.check_completed)

#### 15.7.E NATS JetStream Event Publishing
- [x] 15.7.20 Create ServiceRadar.Infrastructure.EventPublisher module
- [x] 15.7.21 Define event schema: type, entity_type, entity_id, tenant_id, old_state, new_state, timestamp
- [x] 15.7.22 Publish to subjects: `sr.infra.{tenant}.{entity_type}.{event_type}` (e.g., `sr.infra.acme.poller.offline`)
- [ ] 15.7.23 Add event batching for high-frequency updates
- [x] 15.7.24 Integrate with 13.1 NATS connection module (ServiceRadar.NATS.Connection)

#### 15.7.F Recovery & Reassignment
- [ ] 15.7.25 Create ServiceRadar.Core.PollerRecovery module
- [ ] 15.7.26 Port poller health monitoring (poller_recovery.go)
- [ ] 15.7.27 Implement automatic poller reassignment on failure (via state machine hooks)
- [ ] 15.7.28 Add AshOban trigger for recovery attempts
- [ ] 15.7.29 Add recovery metrics (recovery time, success rate)

### 15.8 Template Registry (Port from Go)
- [ ] 15.8.1 Create ServiceRadar.Core.TemplateRegistry module
- [ ] 15.8.2 Port checker template management (templateregistry/registry.go)
- [ ] 15.8.3 Implement template CRUD operations
- [ ] 15.8.4 Add template validation
- [ ] 15.8.5 Expose templates via JSON:API

### 15.9 gRPC Server for Edge Connectivity (Go serviceradar-core)
> **NOTE**: Since no ERTS-enabled software goes to customer networks (security), edge sites run the Go serviceradar-core which communicates via gRPC to the cloud. The Elixir poller-elx speaks gRPC *as a client* to Go agents (serviceradar-sweep).

- [ ] 15.9.1 Add grpc server dependency to core-elx mix.exs
- [ ] 15.9.2 Implement CoreService gRPC server (for Go serviceradar-core at edge)
- [ ] 15.9.3 Implement RegisterPoller RPC (edge Go core registers pollers)
- [ ] 15.9.4 Implement ReportHealth RPC (health heartbeats from edge)
- [ ] 15.9.5 Implement ReportResults RPC (poll results from edge)
- [ ] 15.9.6 Implement SyncConfig RPC (push config to edge)
- [ ] 15.9.7 Configure mTLS for gRPC server
- [ ] 15.9.8 Add gRPC metrics (request count, latency)
- [ ] 15.9.9 Integrate with Horde for edge node tracking (virtual presence)

### 15.10 Docker Compose Integration
- [x] 15.10.1 Add core-elx service to docker-compose.yml
- [x] 15.10.2 Configure core-elx as CLUSTER_HOSTS entry for other services
- [x] 15.10.3 Update web-ng to depend on core-elx
- [x] 15.10.4 Update poller-elx to list core-elx in CLUSTER_HOSTS
- [x] 15.10.5 Update agent-elx to list core-elx in CLUSTER_HOSTS
- [x] 15.10.6 Generate core.pem certificate in generate-certs.sh (already exists)
- [x] 15.10.7 Create ssl_dist.core.conf for TLS distribution
- [x] 15.10.8 Move Go core to legacy profile (already done)
- [x] 15.10.9 Add sync service to docker-compose.yml
- [x] 15.10.10 Configure agent-elx to connect to sync via gRPC
- [ ] 15.10.11 Test full stack with core-elx replacing Go core

### 15.11 web-ng Decoupling
- [ ] 15.11.1 Remove ClusterSupervisor start from web-ng Application
- [ ] 15.11.2 Remove ClusterHealth start from web-ng Application
- [ ] 15.11.3 Keep PollerRegistry/AgentRegistry for local queries (read from Horde)
- [ ] 15.11.4 Update ClusterLive to query core-elx for cluster status
- [ ] 15.11.5 Update admin LiveViews to work without local Horde supervisor
- [ ] 15.11.6 Add core-elx health check to web-ng startup
- [ ] 15.11.7 Document web-ng -> core-elx architecture
