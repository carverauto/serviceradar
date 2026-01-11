# Design: Edge NATS Leaf Deployment

## Context

ServiceRadar needs to support customers deploying NATS leaf servers in their edge networks. This provides resilience (collectors continue working during WAN outages) and compliance (data traverses customer infrastructure first).

### Stakeholders

- **Tenant admins**: Need simple setup experience for edge infrastructure
- **Operations teams**: Need visibility into edge site health
- **Platform operators**: Need to manage leaf connections at scale
- **Security teams**: Need audit trail and secure credential handling

### Constraints

1. Must work with existing TenantCA certificate infrastructure
2. Must integrate with existing NATS JWT authentication
3. Leaf config must match `packaging/nats/config/nats-leaf.conf` structure
4. Cannot require customers to understand NATS internals

## Goals / Non-Goals

### Goals

- Enable one-click edge site provisioning from UI
- Generate complete leaf configuration bundles
- Provide CLI tool for automated edge setup
- Show edge site health in admin dashboard
- Support multiple edge sites per tenant

### Non-Goals

- Automatic leaf node discovery (customers must register sites explicitly)
- Leaf-to-leaf peering (all leaves connect to SaaS hub only)
- Edge site geographic load balancing
- Multi-hub NATS topology

## Decisions

### Decision 1: EdgeSite as Primary Resource

**Choice**: Create `EdgeSite` as the primary resource representing a deployment location.

**Rationale**:
- A site can have multiple components (NATS leaf, collectors, pollers)
- Sites provide logical grouping for monitoring and config
- Matches how customers think about their network topology

**Alternatives considered**:
- NatsLeafServer as primary: Rejected - too NATS-specific, site concept is broader
- Extend OnboardingPackage: Rejected - packages are one-time, sites are persistent

### Decision 2: Leaf Authentication via Tenant Account

**Choice**: NATS leaf uses the tenant's NATS account credentials for upstream connection.

**Rationale**:
- Reuses existing NATS JWT infrastructure
- Subject mapping already configured per tenant
- No need for separate leaf account management

**Configuration**:
```
leafnodes {
    remotes = [{
        url: "tls://nats.serviceradar.cloud:7422"
        credentials: "/etc/nats/creds/tenant.creds"
    }]
}
```

### Decision 3: Separate Leaf Certificate from Collector Certificates

**Choice**: NATS leaf gets its own certificate distinct from collector certs.

**Rationale**:
- Leaf cert needs different CN pattern for SaaS-side verification
- Allows revoking leaf without affecting collectors
- Clearer audit trail

**CN Format**: `leaf.{site_slug}.{tenant_slug}.serviceradar`

### Decision 4: Collector-to-Leaf Uses Same Credentials

**Choice**: Collectors connecting to local leaf use the same NATS credentials as direct-to-SaaS.

**Rationale**:
- NATS credentials are account-scoped, not connection-scoped
- Simplifies collector bundle - same creds work for both scenarios
- Only the NATS URL changes based on `edge_site_id`

### Decision 5: Config Bundle Structure

**Choice**: Edge site bundle includes all files needed for NATS leaf deployment.

**Bundle contents**:
```
edge-site-{site_id}/
├── nats/
│   ├── nats-leaf.conf       # NATS configuration
│   └── certs/
│       ├── nats-server.pem  # Server cert for local clients
│       ├── nats-server-key.pem
│       ├── nats-leaf.pem    # Leaf cert for upstream connection
│       ├── nats-leaf-key.pem
│       └── ca-chain.pem     # CA chain
├── creds/
│   └── tenant.creds         # NATS account credentials
├── setup.sh                 # Automated setup script
└── README.md
```

### Decision 6: Site-Aware Collector Bundles

**Choice**: `CollectorPackage.edge_site_id` determines NATS URL in generated config.

**Logic**:
```elixir
defp get_nats_url(package) do
  case package.edge_site_id do
    nil -> default_saas_nats_url()
    site_id ->
      site = Ash.get!(EdgeSite, site_id)
      site.nats_leaf_url
  end
end
```

### Decision 7: Deferred CLI Implementation

**Choice**: CLI tool is a later phase, not blocking for initial release.

**Rationale**:
- UI provides all functionality
- CLI is convenience, not requirement
- Avoids scope creep in initial implementation
- Can be done as separate project

## Data Model

```
┌───────────────────┐       ┌────────────────────┐
│     Tenant        │       │     EdgeSite       │
├───────────────────┤       ├────────────────────┤
│ id                │◄──────│ tenant_id          │
│ slug              │       │ id                 │
│ nats_account_*    │       │ name               │
└───────────────────┘       │ slug               │
                            │ status             │
                            │ nats_leaf_url      │
                            │ last_seen_at       │
                            └─────────┬──────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    │                 │                 │
                    ▼                 ▼                 ▼
         ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
         │ NatsLeafServer   │ │ CollectorPackage │ │ OnboardingPackage│
         ├──────────────────┤ ├──────────────────┤ ├──────────────────┤
         │ edge_site_id     │ │ edge_site_id     │ │ edge_site_id     │
         │ status           │ │ collector_type   │ │ component_type   │
         │ leaf_cert_pem    │ │ nats_creds       │ │ join_token       │
         │ leaf_key_pem     │ └──────────────────┘ └──────────────────┘
         │ config_checksum  │
         └──────────────────┘
```

## Risks / Trade-offs

### Risk: Leaf Node Connectivity Monitoring

**Challenge**: How do we know if a leaf is connected to SaaS?

**Mitigation**:
- NATS server publishes `$SYS.SERVER.*.STATSZ` with leaf connection info
- Platform subscribes to system events for tenant's leaf
- Status shown in UI, alert on prolonged disconnect

### Risk: Configuration Drift

**Challenge**: Customer modifies leaf config manually, breaks connectivity.

**Mitigation**:
- Store config checksum in `NatsLeafServer`
- Provide "regenerate config" action in UI
- Document that manual changes are unsupported

### Risk: Certificate Expiration

**Challenge**: Leaf certs expire, breaking upstream connection.

**Mitigation**:
- Default validity: 1 year (same as collector certs)
- `NatsLeafServer.cert_expires_at` field
- Dashboard shows expiring certs
- Future: Auto-renewal via serviceradar-cli

### Trade-off: No Automatic Discovery

**Accepted**: Customers must explicitly register edge sites. This is intentional:
- Security: Prevents unauthorized leaves from connecting
- Clarity: Admin knows exactly what's deployed
- Simplicity: No discovery protocol needed

## Migration Plan

### Phase 1: Resources and Backend
1. Create `EdgeSite` resource
2. Create `NatsLeafServer` resource
3. Add `edge_site_id` to `CollectorPackage`
4. Add `edge_site_id` to `OnboardingPackage`

### Phase 2: Configuration Generation
1. Create `NatsLeafConfigGenerator` module
2. Generate leaf config from template
3. Generate leaf certificates via TenantCA
4. Create edge site bundle tarball

### Phase 3: UI
1. Edge sites list page
2. Add edge site wizard
3. Edge site detail page
4. Download config bundle

### Phase 4: Collector Integration
1. Update `CollectorBundleGenerator` for site-aware NATS URL
2. Update collector creation to optionally specify site
3. Show site assignment in collector list

### Phase 5: Health Monitoring
1. Subscribe to leaf connection events
2. Update `NatsLeafServer.status` based on events
3. Show connectivity in UI
4. Optional: Alert on disconnect

### Rollback

- Delete EdgeSite/NatsLeafServer resources
- Remove `edge_site_id` from packages
- Collectors fall back to direct SaaS connection
- No data migration needed (sites are new concept)
