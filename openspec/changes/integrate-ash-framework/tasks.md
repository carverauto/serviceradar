# Tasks: Integrate Ash Framework

## Phase 1: Foundation Setup

### 1.1 Dependencies and Configuration
- [ ] 1.1.1 Add Ash core dependencies to mix.exs (ash, ash_postgres)
- [ ] 1.1.2 Add AshAuthentication dependencies (ash_authentication, ash_authentication_phoenix)
- [ ] 1.1.3 Add AshOban dependencies (ash_oban)
- [ ] 1.1.4 Add AshStateMachine dependencies (ash_state_machine)
- [ ] 1.1.5 Add AshJsonApi dependencies (ash_json_api)
- [ ] 1.1.6 Add AshPhoenix dependencies (ash_phoenix)
- [ ] 1.1.7 Add AshAdmin dependencies (ash_admin, dev only)
- [ ] 1.1.8 Add optional observability deps (open_telemetry_ash, ash_appsignal)
- [ ] 1.1.9 Configure Ash in config.exs with domains
- [ ] 1.1.10 Set up AshPostgres repo configuration
- [ ] 1.1.11 Create feature flag system for gradual rollout

### 1.2 Multi-Tenancy Foundation
- [ ] 1.2.1 Create database migration for tenants table
- [ ] 1.2.2 Create ServiceRadar.Identity.Tenant Ash resource
- [ ] 1.2.3 Add tenant_id column migration for ng_users table
- [ ] 1.2.4 Create data migration script for existing users (assign default tenant)
- [ ] 1.2.5 Implement tenant context plug for web requests
- [ ] 1.2.6 Configure Ash multitenancy strategy (attribute-based)
- [ ] 1.2.7 Test tenant isolation with multi-tenant test fixtures

### 1.3 Cluster Infrastructure (libcluster + Horde)
- [ ] 1.3.1 Add libcluster dependency to mix.exs
- [ ] 1.3.2 Add horde dependency to mix.exs
- [ ] 1.3.3 Create ServiceRadar.ClusterSupervisor module
- [ ] 1.3.4 Configure libcluster topologies in config/runtime.exs
- [ ] 1.3.5 Implement cluster strategy selection (kubernetes/epmd/dns)
- [ ] 1.3.6 Configure EPMD strategy for development environment
- [ ] 1.3.7 Configure DNSPoll strategy for bare metal deployments
- [ ] 1.3.8 Configure Kubernetes strategy for production (DNS mode)
- [ ] 1.3.9 Create Kubernetes headless service manifest
- [ ] 1.3.10 Implement dynamic cluster membership (update_topology/2)
- [ ] 1.3.11 Add cluster strategy environment variable (CLUSTER_STRATEGY)
- [ ] 1.3.12 Create cluster health monitoring GenServer
- [ ] 1.3.13 Add cluster connectivity metrics to telemetry

### 1.4 mTLS for ERTS Distribution
- [ ] 1.4.1 Create ssl_dist.conf template for TLS distribution
- [ ] 1.4.2 Update rel/env.sh.eex with TLS distribution flags
- [ ] 1.4.3 Document certificate generation process (CA + node certs)
- [ ] 1.4.4 Create Kubernetes Secret manifest for node certificates
- [ ] 1.4.5 Configure inet_tls proto_dist in vm.args
- [ ] 1.4.6 Test mTLS cluster formation in staging environment
- [ ] 1.4.7 Add certificate rotation documentation
- [ ] 1.4.8 Implement certificate expiry monitoring

### 1.5 Horde Registry and Supervisor Setup
- [ ] 1.5.1 Create ServiceRadar.PollerRegistry (Horde.Registry)
- [ ] 1.5.2 Create ServiceRadar.AgentRegistry (Horde.Registry)
- [ ] 1.5.3 Create ServiceRadar.PollerSupervisor (Horde.DynamicSupervisor)
- [ ] 1.5.4 Configure Horde members: :auto for cluster auto-join
- [ ] 1.5.5 Create ServiceRadar.Poller.RegistrationWorker GenServer
- [ ] 1.5.6 Implement poller auto-registration on startup
- [ ] 1.5.7 Implement heartbeat mechanism for poller health
- [ ] 1.5.8 Create ServiceRadar.Poller.AgentRegistry module
- [ ] 1.5.9 Implement agent registration when connecting via gRPC
- [ ] 1.5.10 Implement agent unregistration on disconnect
- [ ] 1.5.11 Add PubSub broadcasting for registration events
- [ ] 1.5.12 Create find_poller_for_partition/1 lookup function
- [ ] 1.5.13 Create find_available_pollers/0 for load balancing
- [ ] 1.5.14 Test Horde registry synchronization across nodes

## Phase 2: Authentication Migration

### 2.1 AshAuthentication Setup
- [ ] 2.1.1 Create ServiceRadar.Identity domain module
- [ ] 2.1.2 Create ServiceRadar.Identity.User Ash resource (parallel to existing)
- [ ] 2.1.3 Map User attributes to ng_users table with source: option
- [ ] 2.1.4 Implement password authentication strategy
- [ ] 2.1.5 Implement magic link authentication strategy
- [ ] 2.1.6 Add email confirmation workflow
- [ ] 2.1.7 Create database migration for tokens table (if different from existing)
- [ ] 2.1.8 Implement session management with AshAuthentication

### 2.2 OAuth2 Integration
- [ ] 2.2.1 Configure OAuth2 strategy for Google
- [ ] 2.2.2 Configure OAuth2 strategy for GitHub
- [ ] 2.2.3 Create OAuth callback handlers
- [ ] 2.2.4 Implement user creation/linking from OAuth
- [ ] 2.2.5 Add OAuth provider configuration per-tenant (future)
- [ ] 2.2.6 Test OAuth flows in development environment

### 2.3 API Token Authentication
- [ ] 2.3.1 Create ServiceRadar.Identity.ApiToken Ash resource
- [ ] 2.3.2 Create database migration for api_tokens table
- [ ] 2.3.3 Implement API token generation action
- [ ] 2.3.4 Implement API token validation action
- [ ] 2.3.5 Add API token scopes (read-only, full-access)
- [ ] 2.3.6 Integrate API token auth with existing api_key_auth pipeline

### 2.4 Phoenix Integration
- [ ] 2.4.1 Update router.ex with AshAuthentication.Phoenix routes
- [ ] 2.4.2 Replace UserLive.Login with AshAuthentication.Phoenix components
- [ ] 2.4.3 Replace UserLive.Registration with AshAuthentication.Phoenix components
- [ ] 2.4.4 Update UserSessionController to use AshAuthentication
- [ ] 2.4.5 Migrate user_auth.ex to AshAuthentication patterns
- [ ] 2.4.6 Update LiveView mount hooks for Ash actor
- [ ] 2.4.7 Test authentication flows end-to-end

## Phase 3: Authorization (RBAC)

### 3.1 Role System
- [ ] 3.1.1 Create database migration for roles (admin, operator, viewer)
- [ ] 3.1.2 Add role field to User resource
- [ ] 3.1.3 Create data migration for existing users (assign default role)
- [ ] 3.1.4 Create role assignment actions
- [ ] 3.1.5 Document role permissions matrix

### 3.2 Policy Implementation
- [ ] 3.2.1 Create base policy macros for common patterns
- [ ] 3.2.2 Implement tenant isolation policy (applies to all tenant-scoped resources)
- [ ] 3.2.3 Implement admin bypass policy
- [ ] 3.2.4 Implement operator policies (create, update, no destroy)
- [ ] 3.2.5 Implement viewer policies (read-only)
- [ ] 3.2.6 Add partition-aware policies for overlapping IP spaces
- [ ] 3.2.7 Implement field-level policies for sensitive data
- [ ] 3.2.8 Create policy test suite with multi-tenant scenarios

### 3.3 Authorization Configuration
- [ ] 3.3.1 Set domain authorization to :by_default
- [ ] 3.3.2 Configure require_actor? for all domains
- [ ] 3.3.3 Add authorization error handling middleware
- [ ] 3.3.4 Implement audit logging for authorization failures

## Phase 4: Inventory Domain

### 4.1 Device Resource
- [ ] 4.1.1 Create ServiceRadar.Inventory domain module
- [ ] 4.1.2 Create ServiceRadar.Inventory.Device Ash resource
- [ ] 4.1.3 Map all OCSF attributes with source: option to ocsf_devices table
- [ ] 4.1.4 Add tenant_id to Device with multitenancy config
- [ ] 4.1.5 Implement Device read action with pagination
- [ ] 4.1.6 Implement Device show action
- [ ] 4.1.7 Implement Device update action (admin/operator only)
- [ ] 4.1.8 Add Device calculations (type_name, status_color, display_name)
- [ ] 4.1.9 Implement Device policies
- [ ] 4.1.10 Add database migration for tenant_id on ocsf_devices

### 4.2 Device Relationships
- [ ] 4.2.1 Create ServiceRadar.Inventory.Interface resource
- [ ] 4.2.2 Define Device has_many :interfaces relationship
- [ ] 4.2.3 Create ServiceRadar.Inventory.DeviceGroup resource
- [ ] 4.2.4 Define Device belongs_to :group relationship
- [ ] 4.2.5 Implement relationship loading with policies

### 4.3 Device Identity Reconciliation
- [ ] 4.3.1 Create device identity custom action
- [ ] 4.3.2 Implement MAC-based identity resolution
- [ ] 4.3.3 Implement IP-based identity resolution
- [ ] 4.3.4 Implement external ID resolution (Armis, NetBox)
- [ ] 4.3.5 Create identity merge audit resource
- [ ] 4.3.6 Port Go identity reconciliation logic

## Phase 5: Infrastructure Domain

### 5.1 Poller Resource
- [ ] 5.1.1 Create ServiceRadar.Infrastructure domain module
- [ ] 5.1.2 Create ServiceRadar.Infrastructure.Poller Ash resource
- [ ] 5.1.3 Map attributes to pollers table
- [ ] 5.1.4 Add tenant_id and partition_id to Poller
- [ ] 5.1.5 Implement Poller CRUD actions
- [ ] 5.1.6 Add Poller health calculation
- [ ] 5.1.7 Implement Poller policies (partition-aware)
- [ ] 5.1.8 Add database migration for tenant_id on pollers

### 5.2 Agent Resource
- [ ] 5.2.1 Create ServiceRadar.Infrastructure.Agent Ash resource
- [ ] 5.2.2 Map attributes to agents table (OCSF-aligned)
- [ ] 5.2.3 Define Agent belongs_to :poller relationship
- [ ] 5.2.4 Implement Agent lifecycle state machine
- [ ] 5.2.5 Add Agent health status calculation
- [ ] 5.2.6 Implement Agent policies

### 5.3 Checker Resource
- [ ] 5.3.1 Create ServiceRadar.Infrastructure.Checker Ash resource
- [ ] 5.3.2 Define Checker belongs_to :agent relationship
- [ ] 5.3.3 Implement checker type enum (snmp, grpc, sweep, etc.)
- [ ] 5.3.4 Implement Checker policies

### 5.4 Partition Resource
- [ ] 5.4.1 Create ServiceRadar.Infrastructure.Partition Ash resource
- [ ] 5.4.2 Define Partition has_many :pollers relationship
- [ ] 5.4.3 Implement partition validation (CIDR ranges)
- [ ] 5.4.4 Add partition context to actor for policy evaluation

## Phase 6: Monitoring Domain

### 6.1 Service Check Resource
- [ ] 6.1.1 Create ServiceRadar.Monitoring domain module
- [ ] 6.1.2 Create ServiceRadar.Monitoring.ServiceCheck Ash resource
- [ ] 6.1.3 Implement service check scheduling action
- [ ] 6.1.4 Integrate with AshOban for check execution
- [ ] 6.1.5 Implement check result recording

### 6.2 Alert Resource with State Machine
- [ ] 6.2.1 Create ServiceRadar.Monitoring.Alert Ash resource
- [ ] 6.2.2 Add AshStateMachine extension to Alert
- [ ] 6.2.3 Define alert states (pending, acknowledged, resolved, escalated)
- [ ] 6.2.4 Define alert transitions (acknowledge, resolve, escalate)
- [ ] 6.2.5 Implement alert acknowledgement action
- [ ] 6.2.6 Implement alert resolution action
- [ ] 6.2.7 Implement alert escalation action with AshOban
- [ ] 6.2.8 Add alert notification trigger
- [ ] 6.2.9 Implement alert policies

### 6.3 Event Resource
- [ ] 6.3.1 Create ServiceRadar.Monitoring.Event Ash resource
- [ ] 6.3.2 Implement event recording action
- [ ] 6.3.3 Add event severity enum
- [ ] 6.3.4 Add event source tracking (device, poller, system)
- [ ] 6.3.5 Implement event read action with time filtering

## Phase 7: Edge Onboarding Domain

### 7.1 Edge Package State Machine
- [ ] 7.1.1 Create ServiceRadar.Edge domain module
- [ ] 7.1.2 Create ServiceRadar.Edge.OnboardingPackage Ash resource
- [ ] 7.1.3 Add AshStateMachine extension to OnboardingPackage
- [ ] 7.1.4 Define package states (created, downloaded, installed, expired, revoked)
- [ ] 7.1.5 Define package transitions
- [ ] 7.1.6 Implement package creation action
- [ ] 7.1.7 Implement package download action with state transition
- [ ] 7.1.8 Implement package revocation action
- [ ] 7.1.9 Port existing Edge context functions

### 7.2 Edge Events
- [ ] 7.2.1 Create ServiceRadar.Edge.OnboardingEvent Ash resource
- [ ] 7.2.2 Implement event recording with AshOban worker
- [ ] 7.2.3 Link events to packages
- [ ] 7.2.4 Port existing OnboardingEvents functions

## Phase 8: Job Scheduling (AshOban)

### 8.1 AshOban Configuration
- [ ] 8.1.1 Configure AshOban in Oban config
- [ ] 8.1.2 Define queues for different job types
- [ ] 8.1.3 Set up Oban.Peer for distributed coordination

### 8.2 Migrate Existing Jobs
- [ ] 8.2.1 Convert refresh_trace_summaries to AshOban trigger
- [ ] 8.2.2 Convert expire_packages to AshOban trigger
- [ ] 8.2.3 Remove custom Jobs.Scheduler after migration
- [ ] 8.2.4 Update ng_job_schedules table or migrate to Ash

### 8.3 Polling Job System
- [ ] 8.3.1 Create ServiceCheck :execute action with AshOban
- [ ] 8.3.2 Implement polling schedule resource
- [ ] 8.3.3 Create poll orchestration action
- [ ] 8.3.4 Implement result processing action
- [ ] 8.3.5 Add distributed locking for poll coordination

## Phase 9: API Layer

### 9.1 AshJsonApi Setup
- [ ] 9.1.1 Add AshJsonApi extension to resources
- [ ] 9.1.2 Configure JSON:API routes for Inventory domain
- [ ] 9.1.3 Configure JSON:API routes for Infrastructure domain
- [ ] 9.1.4 Configure JSON:API routes for Monitoring domain
- [ ] 9.1.5 Add API versioning (mount at /api/v2)
- [ ] 9.1.6 Implement API error handling

### 9.2 SRQL Integration
- [ ] 9.2.1 Create ServiceRadarWebNG.SRQL.AshAdapter module
- [ ] 9.2.2 Implement SRQL entity to Ash resource routing
- [ ] 9.2.3 Implement SRQL filter to Ash filter translation
- [ ] 9.2.4 Implement SRQL sort to Ash sort translation
- [ ] 9.2.5 Implement pagination format conversion
- [ ] 9.2.6 Add actor context to SRQL queries for policy enforcement
- [ ] 9.2.7 Route devices, pollers, agents through Ash path
- [ ] 9.2.8 Keep metrics, flows, traces on SQL path
- [ ] 9.2.9 Add performance monitoring for Ash vs SQL paths
- [ ] 9.2.10 Update QueryController to use AshAdapter

### 9.3 Phoenix LiveView Integration
- [ ] 9.3.1 Add AshPhoenix.Form to device LiveViews
- [ ] 9.3.2 Add AshPhoenix.Form to admin LiveViews
- [ ] 9.3.3 Implement form validation with Ash changesets
- [ ] 9.3.4 Update dashboard plugins to use Ash queries where applicable

## Phase 10: Admin & Observability

### 10.1 AshAdmin Setup
- [ ] 10.1.1 Configure AshAdmin for development environment
- [ ] 10.1.2 Add admin routes to router (dev/staging only)
- [ ] 10.1.3 Customize AshAdmin appearance
- [ ] 10.1.4 Add tenant switcher to admin interface

### 10.2 Horde Cluster Admin Dashboard
- [ ] 10.2.1 Create ClusterLive.Index LiveView for cluster overview
- [ ] 10.2.2 Implement real-time node status via PubSub
- [ ] 10.2.3 Create poller registry table component
- [ ] 10.2.4 Create agent registry table component
- [ ] 10.2.5 Implement cluster topology visualization (D3.js or similar)
- [ ] 10.2.6 Add process supervisor view with memory stats
- [ ] 10.2.7 Implement node disconnect alerts
- [ ] 10.2.8 Add manual poller status control (mark unavailable)
- [ ] 10.2.9 Create cluster health metrics cards
- [ ] 10.2.10 Add job distribution visualization per node
- [ ] 10.2.11 Implement cluster event log viewer
- [ ] 10.2.12 Add admin routes for cluster dashboard

### 10.3 Observability Integration
- [ ] 10.3.1 Configure OpenTelemetry Ash instrumentation
- [ ] 10.3.2 Add Ash action tracing
- [ ] 10.3.3 Add policy evaluation metrics
- [ ] 10.3.4 Integrate with existing telemetry module
- [ ] 10.3.5 Add Horde registry metrics export
- [ ] 10.3.6 Add cluster connectivity metrics

## Phase 11: Testing & Documentation

### 11.1 Test Infrastructure
- [ ] 11.1.1 Create Ash test helpers and fixtures
- [ ] 11.1.2 Create multi-tenant test factory
- [ ] 11.1.3 Create policy test macros
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
- [ ] 11.2.9 Write multi-tenant isolation tests
- [ ] 11.2.10 Write policy enforcement tests

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
- [ ] 12.2.1 Remove Ecto-based Accounts context (replaced by Ash)
- [ ] 12.2.2 Remove Ecto-based Inventory context (replaced by Ash)
- [ ] 12.2.3 Remove Ecto-based Infrastructure context (replaced by Ash)
- [ ] 12.2.4 Remove Ecto-based Edge context (replaced by Ash)
- [ ] 12.2.5 Remove custom Jobs.Scheduler (replaced by AshOban)
- [ ] 12.2.6 Remove feature flags once stable
- [ ] 12.2.7 Update all imports and aliases

### 12.3 API Deprecation
- [ ] 12.3.1 Add deprecation warnings to v1 API endpoints
- [ ] 12.3.2 Document migration path for API consumers
- [ ] 12.3.3 Set v1 API sunset date
- [ ] 12.3.4 Remove v1 API after sunset period
