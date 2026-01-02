# Change: Add Edge NATS Leaf Deployment

## Status

**Phases 1-4: COMPLETE** - Core resources, config generation, UI, and collector integration are implemented and working.

**Phase 5 (Health Monitoring): IN PROGRESS** - Being implemented separately via AgentGateway architecture (see Architecture Notes below).

**Phase 6 (CLI Tool): DEFERRED** - Will be addressed in future work.

---

## Why

ServiceRadar supports two deployment scenarios for customers:

### Scenario 1: Direct SaaS Connection
- Collectors (flowgger, trapd, otel, netflow) connect directly to the SaaS NATS cluster
- Simple setup: download bundle, run update script
- **Already implemented** via `CollectorPackage` and `CollectorBundleGenerator`

### Scenario 2: Edge NATS Leaf (On-Prem)
- Customer deploys their own NATS server (`serviceradar-nats`) as a "leaf" node in their network
- Collectors connect to the LOCAL NATS leaf (low latency, survives WAN outages)
- NATS leaf connects upstream to SaaS cluster via leaf node protocol
- **Not yet implemented** - this proposal addresses this gap

The Edge NATS Leaf scenario is critical for:
- **Resilience**: Collectors continue buffering locally when WAN is down
- **Performance**: Low-latency local message delivery
- **Compliance**: Data may need to traverse customer-controlled infrastructure first
- **Network simplicity**: Only one outbound connection (leaf → SaaS) vs. many collector connections

## Current State

The `nats-leaf.conf` template exists in `packaging/nats/config/` but:
- No UI to register edge sites or generate leaf configurations
- No automated certificate generation for leaf nodes
- No way for collectors to know they should connect to a local leaf vs. SaaS
- No visibility into edge site health/connectivity

## What Changes

### 1. EdgeSite Resource (Ash)

New resource representing a customer's edge deployment location:

```elixir
defmodule ServiceRadar.Edge.EdgeSite do
  # Tracks a physical/logical deployment location
  attributes do
    uuid_primary_key :id
    attribute :name, :string           # "NYC Office", "Factory Floor 3"
    attribute :slug, :string           # "nyc-office", "factory-3"
    attribute :status, :atom           # :active, :offline, :provisioning
    attribute :nats_leaf_url, :string  # "nats://10.0.1.50:4222" (local)
    attribute :last_seen_at, :utc_datetime
  end
end
```

### 2. NatsLeafServer Resource (Ash)

Tracks NATS leaf server deployments:

```elixir
defmodule ServiceRadar.Edge.NatsLeafServer do
  attributes do
    uuid_primary_key :id
    attribute :edge_site_id, :uuid
    attribute :status, :atom           # :pending, :provisioned, :connected, :disconnected
    attribute :upstream_url, :string   # SaaS NATS URL for leaf connection
    attribute :local_listen, :string   # "0.0.0.0:4222"
    # mTLS certs for leaf-to-SaaS connection (encrypted)
    attribute :leaf_cert_pem, :string
    attribute :leaf_key_pem_ciphertext, :binary
    attribute :ca_chain_pem, :string
  end
end
```

### 3. Configuration Generation

Generate NATS leaf config based on `packaging/nats/config/nats-leaf.conf`:

```
# Generated NATS Leaf Configuration
server_name: nats-{edge_site_slug}
listen: 0.0.0.0:4222

tls {
    cert_file: "/etc/nats/certs/nats-server.pem"
    key_file: "/etc/nats/certs/nats-server-key.pem"
    ca_file: "/etc/nats/certs/root.pem"
    verify_and_map: true
}

jetstream {
    store_dir: /var/lib/nats/jetstream
    domain: edge
}

leafnodes {
    remotes = [{
        url: "tls://nats.serviceradar.cloud:7422"
        account: "$G"
        tls {
            cert_file: "/etc/nats/certs/nats-leaf.pem"
            key_file: "/etc/nats/certs/nats-leaf-key.pem"
            ca_file: "/etc/nats/certs/root.pem"
        }
    }]
}
```

### 4. UI Components

**Edge Sites Management** (`/admin/edge-sites`):
- List edge sites with status indicators
- "Add Edge Site" wizard
- Site detail page showing:
  - NATS leaf status (connected/disconnected)
  - Collectors registered to this site
  - Configuration download options

**NATS Leaf Setup Wizard**:
1. Name your site
2. Choose deployment method (Docker, package, manual)
3. Download configuration bundle
4. Verify connectivity

### 5. CollectorPackage Enhancement

Add `edge_site_id` field to link collectors to specific sites:

```elixir
attribute :edge_site_id, :uuid, allow_nil?: true

# Bundle generator checks:
# - If edge_site_id set → use site's nats_leaf_url
# - If nil → use SaaS NATS URL (direct connection)
```

### 6. CLI Tool (`serviceradar-cli`)

```bash
# Initialize edge site
serviceradar-cli site init --name "NYC Office" --token <enrollment_token>

# Setup NATS leaf (downloads config, certs, starts service)
serviceradar-cli nats setup

# Add collector to this site
serviceradar-cli collector add flowgger

# Check status
serviceradar-cli status
```

## Architecture

```
Customer Network                              ServiceRadar SaaS
┌─────────────────────────────────────┐      ┌─────────────────────────┐
│  EdgeSite: "NYC Office"             │      │                         │
│                                     │      │  NATS JetStream Hub     │
│  ┌─────────┐  ┌─────────┐          │      │  (port 7422 - leaf)     │
│  │flowgger │  │  trapd  │          │      │                         │
│  └────┬────┘  └────┬────┘          │      │                         │
│       │            │                │      │                         │
│       ▼            ▼                │      │                         │
│  ┌──────────────────────────────┐  │      │                         │
│  │   NatsLeafServer             │  │      │                         │
│  │   (serviceradar-nats)        │──┼──────┼──► Leaf Node Connection │
│  │   mTLS + Tenant JWT          │  │      │    (mTLS + Account JWT) │
│  └──────────────────────────────┘  │      │                         │
└─────────────────────────────────────┘      └─────────────────────────┘

Collectors → Local Leaf:    mTLS + Tenant NATS JWT
Leaf → SaaS Cluster:        mTLS + Leaf account credentials
```

## Impact

### Affected Specs
- NEW: `edge-sites` capability spec

### Affected Code

**Elixir Core**:
- NEW: `lib/serviceradar/edge/edge_site.ex`
- NEW: `lib/serviceradar/edge/nats_leaf_server.ex`
- NEW: `lib/serviceradar/edge/workers/provision_leaf_worker.ex`
- NEW: `lib/serviceradar/edge/nats_leaf_config_generator.ex`
- MODIFY: `lib/serviceradar/edge/collector_package.ex` - add `edge_site_id`
- MODIFY: `lib/serviceradar/edge.ex` - add new resources

**Web NG**:
- NEW: `lib/serviceradar_web_ng_web/live/admin/edge_sites_live/index.ex`
- NEW: `lib/serviceradar_web_ng_web/live/admin/edge_sites_live/show.ex`
- NEW: `lib/serviceradar_web_ng_web/live/admin/edge_sites_live/new.ex`
- MODIFY: `lib/serviceradar_web_ng/edge/collector_bundle_generator.ex` - site-aware NATS URL
- MODIFY: `lib/serviceradar_web_ng_web/router.ex` - new routes

**CLI Tool** (future, separate repo or binary):
- `serviceradar-cli` Go binary for edge setup automation

**Packaging**:
- MODIFY: `packaging/nats/` - update config templates

### Breaking Changes
None - this is additive. Existing direct-to-SaaS collectors continue working.

## Sequencing

1. **Phase 1**: EdgeSite and NatsLeafServer resources ✅ COMPLETE
2. **Phase 2**: Certificate and config generation ✅ COMPLETE
3. **Phase 3**: UI for edge site management ✅ COMPLETE
4. **Phase 4**: Collector site integration ✅ COMPLETE
5. **Phase 5**: Health monitoring (via AgentGateway) 🔄 IN PROGRESS (separate branch)
6. **Phase 6**: CLI tool ⏸️ DEFERRED
7. **Phase 7**: Documentation ⏸️ PENDING
8. **Phase 8**: Testing ⏸️ PENDING

## Open Questions

1. **Leaf authentication**: Should leaf use its own NATS account or share the tenant account?
   - **Proposed**: Leaf uses tenant account with special leaf permissions

2. **Certificate management**: Who generates leaf certs?
   - **Proposed**: Platform generates using TenantCA, same as collectors

3. **Offline buffering**: How long should leaf buffer when SaaS unreachable?
   - **Proposed**: Configurable, default 7 days (JetStream limits)

4. **CLI distribution**: How do we distribute serviceradar-cli?
   - **Proposed**: GitHub releases, apt/yum repos alongside other packages

## Architecture Notes

### Health Monitoring via AgentGateway (Phase 5)

The original proposal suggested using GenServers to monitor leaf connections. This approach was **rejected** for security reasons - it would expose the ERTS cluster to customer networks, creating a potential attack vector.

**New Approach: AgentGateway**

Instead, the Go agent will connect **outbound** to an AgentGateway service running in SaaS infrastructure:

```
Customer Network                              ServiceRadar SaaS
┌─────────────────────────────────────┐      ┌─────────────────────────┐
│  EdgeSite: "NYC Office"             │      │                         │
│                                     │      │  AgentGateway           │
│  ┌─────────────────────────────┐    │      │  (gRPC Server)          │
│  │   Go Agent                  │────┼──────┼──► Accepts inbound      │
│  │   - NATS Leaf checker       │    │      │    agent connections    │
│  │   - External checkers       │    │      │                         │
│  │   - Outbound gRPC to GW     │    │      │  Updates:               │
│  └─────────────────────────────┘    │      │  - EdgeSite.last_seen   │
│                                     │      │  - NatsLeafServer.status│
│  ┌──────────────────────────────┐   │      │                         │
│  │   NatsLeafServer             │   │      │                         │
│  │   (serviceradar-nats)        │───┼──────┼──► Leaf Node Connection │
│  └──────────────────────────────┘   │      │                         │
└─────────────────────────────────────┘      └─────────────────────────┘
```

**Key Security Properties:**
- SaaS **never** initiates connections into customer infrastructure
- Agent identity derived from mTLS certificate CN: `agent.{site_slug}.{tenant_slug}.serviceradar`
- Zero inbound firewall rules required at customer sites

**AgentGateway RPCs:**
- `Hello` - Initial registration, returns agent configuration
- `GetConfig` - Periodic config polling (default 30s)
- `PushStatus` - Agent pushes health check results
- `PushResults` - Agent pushes collected data

This work is being implemented in a separate branch/worktree.
