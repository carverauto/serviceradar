# Tasks: Edge NATS Leaf Deployment

## Phase 1: Core Resources

### 1.1 EdgeSite Resource

- [x] 1.1.1 Create `lib/serviceradar/edge/edge_site.ex` Ash resource
- [x] 1.1.2 Add attributes: id, tenant_id, name, slug, status, nats_leaf_url, last_seen_at
- [x] 1.1.3 Add state machine: pending → active → offline
- [x] 1.1.4 Add multitenancy with tenant_id attribute
- [x] 1.1.5 Add unique identity on [:tenant_id, :slug]
- [x] 1.1.6 Add policies for tenant admin access
- [x] 1.1.7 Create database migration for edge_sites table
- [x] 1.1.8 Register resource in `lib/serviceradar/edge.ex` domain

### 1.2 NatsLeafServer Resource

- [x] 1.2.1 Create `lib/serviceradar/edge/nats_leaf_server.ex` Ash resource
- [x] 1.2.2 Add attributes: id, edge_site_id, status, upstream_url, local_listen
- [x] 1.2.3 Add TLS cert attributes: leaf_cert_pem, leaf_key_pem_ciphertext, ca_chain_pem
- [x] 1.2.4 Add AshCloak encryption for leaf_key_pem
- [x] 1.2.5 Add config_checksum attribute for drift detection
- [x] 1.2.6 Add state machine: pending → provisioned → connected → disconnected
- [x] 1.2.7 Add belongs_to relationship to EdgeSite
- [x] 1.2.8 Create database migration for nats_leaf_servers table
- [x] 1.2.9 Register resource in Edge domain

### 1.3 Package Integration

- [x] 1.3.1 Add `edge_site_id` attribute to CollectorPackage
- [x] 1.3.2 Add belongs_to :edge_site relationship
- [ ] 1.3.3 Add `edge_site_id` attribute to OnboardingPackage (deferred - not in scope)
- [x] 1.3.4 Create migration for edge_site_id columns
- [x] 1.3.5 Update CollectorPackage create action to accept edge_site_id

## Phase 2: Certificate and Config Generation

### 2.1 Leaf Certificate Generation

- [x] 2.1.1 Create `lib/serviceradar/edge/workers/provision_leaf_worker.ex` (integrated)
- [x] 2.1.2 Implement `generate_leaf_cert/2` using TenantCA.Generator
- [x] 2.1.3 Use CN format: `leaf.{site_slug}.{tenant_slug}.serviceradar`
- [x] 2.1.4 Generate server cert for local client connections
- [x] 2.1.5 Include SPIFFE URI in SAN for workload identity

### 2.2 NATS Leaf Config Generation

- [x] 2.2.1 Create `lib/serviceradar/edge/nats_leaf_config_generator.ex` module
- [x] 2.2.2 Implement `generate_config/1` based on nats-leaf.conf template
- [x] 2.2.3 Add placeholders for: server_name, upstream_url, cert paths
- [x] 2.2.4 Configure JetStream with domain: edge
- [x] 2.2.5 Configure leafnodes remote with mTLS

### 2.3 Edge Site Bundle Generator

- [x] 2.3.1 Create `lib/serviceradar_web_ng/edge/edge_site_bundle_generator.ex`
- [x] 2.3.2 Implement `create_tarball/2` for edge site bundle
- [x] 2.3.3 Include nats-leaf.conf
- [x] 2.3.4 Include all certificates (server, leaf, CA chain)
- [x] 2.3.5 Include tenant NATS credentials
- [x] 2.3.6 Generate setup.sh script (systemd service creation)
- [x] 2.3.7 Generate README.md with instructions

### 2.4 Provision Leaf Worker

- [x] 2.4.1 Create `lib/serviceradar/edge/workers/provision_leaf_worker.ex` Oban worker
- [x] 2.4.2 Generate leaf certificates on provision
- [x] 2.4.3 Generate NATS config
- [x] 2.4.4 Store certs in NatsLeafServer (encrypted)
- [x] 2.4.5 Update NatsLeafServer status to provisioned
- [x] 2.4.6 Trigger worker on EdgeSite creation

## Phase 3: UI - Edge Sites Management

### 3.1 Edge Sites List Page

- [x] 3.1.1 Create `lib/serviceradar_web_ng_web/live/admin/edge_sites_live/index.ex`
- [x] 3.1.2 List edge sites for tenant with status badges
- [x] 3.1.3 Show connected/disconnected indicators
- [x] 3.1.4 Add "Add Edge Site" button
- [x] 3.1.5 Add search/filter by status (filter by name deferred)

### 3.2 Add Edge Site Wizard

- [x] 3.2.1 Create modal in `index.ex` (simplified single-step modal)
- [x] 3.2.2 Site name and slug input
- [ ] 3.2.3 Choose deployment method (deferred - not in MVP)
- [ ] 3.2.4 Download configuration bundle (on detail page)
- [ ] 3.2.5 Verify connectivity (deferred - Phase 5)
- [x] 3.2.6 Form validation for slug uniqueness

### 3.3 Edge Site Detail Page

- [x] 3.3.1 Create `lib/serviceradar_web_ng_web/live/admin/edge_sites_live/show.ex`
- [x] 3.3.2 Show site details and status
- [x] 3.3.3 Show NATS leaf server status
- [x] 3.3.4 List collectors assigned to this site
- [x] 3.3.5 Add "Download Bundle" button
- [x] 3.3.6 Add "Regenerate Config" action
- [ ] 3.3.7 Show certificate expiration warning (deferred)

### 3.4 Router Updates

- [x] 3.4.1 Add routes for edge sites pages
- [x] 3.4.2 Add Edge Sites tab to admin nav
- [ ] 3.4.3 Add bundle download endpoint (uses existing infrastructure)

## Phase 4: Collector Site Integration

### 4.1 Bundle Generator Updates

- [x] 4.1.1 Update `CollectorBundleGenerator` to use edge_site from package
- [x] 4.1.2 Implement `get_nats_url/2` - returns site URL or SaaS URL
- [x] 4.1.3 Update config templates with dynamic NATS URL
- [x] 4.1.4 Update README to mention local NATS leaf

### 4.2 Collector UI Updates

- [x] 4.2.1 Add edge site selector to collector creation form
- [x] 4.2.2 Show assigned site in collector list
- [ ] 4.2.3 Filter collectors by edge site (deferred)

### 4.3 API Updates

- [x] 4.3.1 Update CollectorController.create to accept edge_site_id
- [x] 4.3.2 Include edge_site info in collector JSON response

## Phase 5: Health Monitoring (via AgentGateway)

> **Architecture Change**: Original GenServer approach was rejected for security reasons.
> Health monitoring will be implemented via AgentGateway - agents connect outbound to SaaS.
> This work is being done in a separate branch/worktree.

### 5.1 AgentGateway Proto & Server

- [ ] 5.1.1 Add AgentGateway service to `proto/monitoring.proto`
- [ ] 5.1.2 Implement AgentGateway gRPC server in poller-elx
- [ ] 5.1.3 Add mTLS cert CN parsing for agent identity
- [ ] 5.1.4 Implement Hello RPC (agent registration)
- [ ] 5.1.5 Implement GetConfig RPC (config polling)
- [ ] 5.1.6 Implement PushStatus RPC (health check results)
- [ ] 5.1.7 Implement PushResults RPC (collected data)

### 5.2 Go Agent Gateway Client

- [ ] 5.2.1 Add NATS Leaf checker to Go agent
- [ ] 5.2.2 Add gateway client for outbound gRPC connections
- [ ] 5.2.3 Implement config polling scheduler
- [ ] 5.2.4 Implement status/results push scheduler
- [ ] 5.2.5 Support streaming for large payloads

### 5.3 EdgeSite Status Updates

- [ ] 5.3.1 Update EdgeSite.last_seen_at on agent activity
- [ ] 5.3.2 Update NatsLeafServer.status based on checker results
- [ ] 5.3.3 Add real-time status updates to edge site detail page

### 5.4 Alerts (Optional)

- [ ] 5.4.1 Create alert rule for prolonged disconnect
- [ ] 5.4.2 Send notification via configured channels

## Phase 6: CLI Tool (Future)

### 6.1 CLI Binary

- [ ] 6.1.1 Create `cmd/serviceradar-cli/` Go binary
- [ ] 6.1.2 Implement `site init` command
- [ ] 6.1.3 Implement `nats setup` command
- [ ] 6.1.4 Implement `collector add` command
- [ ] 6.1.5 Implement `status` command

### 6.2 Distribution

- [ ] 6.2.1 Add Bazel build targets for CLI
- [ ] 6.2.2 Create GitHub release workflow
- [ ] 6.2.3 Add to apt/yum repositories

## Phase 7: Documentation

### 7.1 User Documentation

- [ ] 7.1.1 Write edge site deployment guide
- [ ] 7.1.2 Document NATS leaf architecture
- [ ] 7.1.3 Add troubleshooting section
- [ ] 7.1.4 Create video walkthrough (optional)

### 7.2 Operations Guide

- [ ] 7.2.1 Document certificate renewal process
- [ ] 7.2.2 Document config regeneration
- [ ] 7.2.3 Add monitoring/alerting setup guide

## Phase 8: Testing

### 8.1 Unit Tests

- [ ] 8.1.1 Test EdgeSite resource actions
- [ ] 8.1.2 Test NatsLeafServer resource actions
- [ ] 8.1.3 Test NatsLeafConfigGenerator output
- [ ] 8.1.4 Test EdgeSiteBundleGenerator tarball

### 8.2 Integration Tests

- [ ] 8.2.1 Test full edge site provisioning flow
- [ ] 8.2.2 Test collector creation with edge site
- [ ] 8.2.3 Test bundle download with site-specific NATS URL

### 8.3 End-to-End Tests

- [ ] 8.3.1 Deploy NATS leaf in test environment
- [ ] 8.3.2 Verify leaf connects to hub
- [ ] 8.3.3 Verify collectors connect to leaf
- [ ] 8.3.4 Verify messages flow through to SaaS
