# Tasks: Integrate Ash Framework

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
- [ ] 1.4.6 Test mTLS cluster formation in staging environment
- [ ] 1.4.7 Add certificate rotation documentation
- [ ] 1.4.8 Implement certificate expiry monitoring

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
- [ ] 1.5.14 Test Horde registry synchronization across nodes

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
- [ ] 2.4.2 Replace UserLive.Login with AshAuthentication.Phoenix components
- [ ] 2.4.3 Replace UserLive.Registration with AshAuthentication.Phoenix components
- [ ] 2.4.4 Update UserSessionController to use AshAuthentication
- [ ] 2.4.5 Migrate user_auth.ex to AshAuthentication patterns
- [ ] 2.4.6 Update LiveView mount hooks for Ash actor
- [ ] 2.4.7 Test authentication flows end-to-end

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
- [ ] 3.2.8 Create policy test suite with multi-tenant scenarios

### 3.3 Authorization Configuration
- [x] 3.3.1 Set domain authorization to :by_default
- [x] 3.3.2 Configure require_actor? for all domains
- [x] 3.3.3 Add authorization error handling middleware
- [x] 3.3.4 Implement audit logging for authorization failures

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
- [ ] 9.1.6 Implement API error handling

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
- [ ] 9.3.2 Add AshPhoenix.Form to admin LiveViews (deferred - current Ecto forms work via context layer)
- [ ] 9.3.3 Implement form validation with Ash changesets (deferred - depends on 9.3.2)
- [ ] 9.3.4 Update dashboard plugins to use Ash queries where applicable (optional - SRQL handles routing)

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
- [ ] 11.1.4 Update existing tests to use Ash resources

### 11.2 Test Coverage
- [ ] 11.2.1 Write tests for all Identity domain resources
- [ ] 11.2.2 Write tests for all Inventory domain resources
- [ ] 11.2.3 Write tests for all Infrastructure domain resources
- [ ] 11.2.4 Write tests for all Monitoring domain resources
- [ ] 11.2.5 Write tests for AshOban jobs
- [ ] 11.2.6 Write tests for state machine transitions
- [ ] 11.2.7 Write API integration tests
- [ ] 11.2.8 Write SRQL adapter tests
- [x] 11.2.9 Write multi-tenant isolation tests
- [x] 11.2.10 Write policy enforcement tests

### 11.3 Documentation
- [ ] 11.3.1 Document domain architecture
- [ ] 11.3.2 Document authentication flows
- [ ] 11.3.3 Document authorization policies
- [ ] 11.3.4 Document API endpoints
- [ ] 11.3.5 Update AGENTS.md with Ash patterns
- [ ] 11.3.6 Create migration guide for existing deployments

## Phase 12: Migration & Cleanup

### 12.1 Data Migration
- [ ] 12.1.1 Create tenant seeding script for existing data
- [ ] 12.1.2 Create role assignment script for existing users
- [ ] 12.1.3 Verify data integrity after migrations
- [ ] 12.1.4 Create rollback scripts

### 12.2 Feature Flag Cleanup
- [x] 12.2.1 Remove Ecto-based Accounts context (replaced by Ash)
- [x] 12.2.2 Migrate Inventory context to use Ash resources (ServiceRadarWebNG.Inventory delegates to ServiceRadar.Inventory.Device)
- [x] 12.2.3 Migrate Infrastructure context to use Ash resources (ServiceRadarWebNG.Infrastructure delegates to ServiceRadar.Infrastructure.{Poller,Agent})
- [x] 12.2.4 Remove Ecto-based Edge context (replaced by Ash)
- [ ] 12.2.5 Remove custom Jobs.Scheduler (replaced by AshOban)
- [ ] 12.2.6 Remove feature flags once stable
- [ ] 12.2.7 Update all imports and aliases

### 12.3 API Deprecation
- [ ] 12.3.1 Add deprecation warnings to v1 API endpoints
- [ ] 12.3.2 Document migration path for API consumers
- [ ] 12.3.3 Set v1 API sunset date
- [ ] 12.3.4 Remove v1 API after sunset period

## Phase 13: Edge-to-Cloud Infrastructure

### 13.1 NATS JetStream Integration
- [ ] 13.1.1 Add gnat dependency to mix.exs (NATS client)
- [ ] 13.1.2 Create ServiceRadar.NATS.Connection module for connection management
- [ ] 13.1.3 Configure NATS connection in runtime.exs (NATS_URL, credentials)
- [ ] 13.1.4 Design subject hierarchy: `ocsf.<class>.<partition_id>.<tenant_id>`
- [ ] 13.1.5 Create ServiceRadar.NATS.Publisher module for OCSF event publishing
- [ ] 13.1.6 Create ServiceRadar.NATS.Consumer module for cloud-side consumption
- [ ] 13.1.7 Implement JetStream stream configuration for durability
- [ ] 13.1.8 Add acknowledgement handling for reliable delivery
- [ ] 13.1.9 Create NATS health check for cluster health monitoring
- [ ] 13.1.10 Add NATS metrics to telemetry (publish rate, lag, errors)
- [ ] 13.1.11 Document NATS deployment topology (edge vs cloud)

### 13.2 Device Actor System
- [ ] 13.2.1 Create ServiceRadar.Actors.Device GenServer module
- [ ] 13.2.2 Implement device actor registration with `{partition_id, device_id}` key
- [ ] 13.2.3 Create ServiceRadar.Actors.DeviceSupervisor (Horde.DynamicSupervisor)
- [ ] 13.2.4 Implement device actor state: identity, last_seen, health, config
- [ ] 13.2.5 Create get_or_start_device/2 function for lazy actor initialization
- [ ] 13.2.6 Implement device actor commands (update_identity, record_event, refresh_config)
- [ ] 13.2.7 Add device actor timeout/hibernation for inactive devices
- [ ] 13.2.8 Implement device actor handoff on node failure (Horde automatic)
- [ ] 13.2.9 Create device actor LiveView debugging panel
- [ ] 13.2.10 Add device actor metrics (count, message rate, memory)

### 13.3 Oban Queue Partitioning
- [ ] 13.3.1 Design queue naming convention: `{job_type}_{partition_id}`
- [ ] 13.3.2 Create queue configuration generator for dynamic partitions
- [ ] 13.3.3 Implement partition-aware job insertion (insert_job_for_partition/3)
- [ ] 13.3.4 Configure Oban peer coordination per edge site
- [ ] 13.3.5 Update AshOban triggers to use partition-aware queues
- [ ] 13.3.6 Create queue monitoring dashboard component
- [ ] 13.3.7 Implement queue rebalancing on partition changes
- [ ] 13.3.8 Add queue depth alerts per partition
- [ ] 13.3.9 Document Oban partitioning strategy

### 13.4 Mesh VPN Configuration
- [ ] 13.4.1 Document Tailscale deployment for edge nodes
- [ ] 13.4.2 Document Nebula deployment alternative
- [ ] 13.4.3 Create ERTS cookie management guide for mesh VPN
- [ ] 13.4.4 Configure libcluster for Tailscale DNS discovery
- [ ] 13.4.5 Create Tailscale ACL recommendations for ERTS traffic
- [ ] 13.4.6 Document port requirements (EPMD 4369, ERTS dynamic range)
- [ ] 13.4.7 Create network troubleshooting guide
- [ ] 13.4.8 Add mesh VPN connectivity health check

### 13.5 Partition Namespacing
- [ ] 13.5.1 Update all Horde registrations to use `{partition_id, resource_id}` keys
- [ ] 13.5.2 Update AgentRegistry to support partition-scoped lookups
- [ ] 13.5.3 Update PollerRegistry to support partition-scoped lookups
- [ ] 13.5.4 Create partition context plug for web requests
- [ ] 13.5.5 Implement partition validation in Ash policies
- [ ] 13.5.6 Update SRQL adapter for partition-aware queries
- [ ] 13.5.7 Create partition hierarchy validation (tenant owns partition)
- [ ] 13.5.8 Add partition-scoped PubSub topics
- [ ] 13.5.9 Document overlapping IP space handling strategy

### 13.6 Datasvc Transition (Rust -> Elixir)
- [ ] 13.6.1 Audit datasvc functions for migration priority
- [ ] 13.6.2 Identify performance-critical paths requiring Rustler NIFs
- [ ] 13.6.3 Create migration plan for datasvc to Ash resources
- [ ] 13.6.4 Implement first batch of datasvc functions in Ash
- [ ] 13.6.5 Add feature flags for datasvc function routing
- [ ] 13.6.6 Benchmark Ash vs Rustler for hot paths
- [ ] 13.6.7 Document datasvc deprecation timeline

### 13.7 SPIRE/SPIFFE Integration
- [ ] 13.7.1 Create ServiceRadar.SPIFFE module in shared library
- [ ] 13.7.2 Implement certificate file loading from SPIRE agent
- [ ] 13.7.3 Create SPIFFE ID extraction from X.509 certificates
- [ ] 13.7.4 Add SPIFFE ID to Ash actor context
- [ ] 13.7.5 Create Ash policy helper macros for SPIFFE authorization
- [ ] 13.7.6 Implement certificate expiry monitoring
- [ ] 13.7.7 Document SPIRE workload registration for BEAM nodes
- [ ] 13.7.8 Create SPIFFE trust bundle refresh mechanism
- [ ] 13.7.9 Add SPIFFE identity verification to gRPC connections

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
