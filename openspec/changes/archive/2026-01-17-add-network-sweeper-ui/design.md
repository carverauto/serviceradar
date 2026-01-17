# Design: Network Sweeper UI and Config Distribution

## Context

The serviceradar-agent has a high-performance network sweeper but configuration is file-based or via KV store (being deprecated). We need:
1. A UI for configuring sweep jobs
2. A reusable pattern for generating and distributing configs to agents
3. Validation of sweep results flowing through the new architecture

**Stakeholders**: Platform team, Operations, DevOps
**Constraints**: Must use Ash for all resources, must be tenant-aware, must not require direct KV/datasvc access from agents

## Goals / Non-Goals

**Goals:**
- Create reusable `ServiceRadar.AgentConfig` domain for any config type (sweep, poller, checker)
- Provide admin UI for sweep job management in Settings > Networks
- Enable bulk device operations for sweep configuration
- Maintain backward compatibility with file-based fallback

**Non-Goals:**
- Replace all existing config mechanisms immediately (incremental adoption)
- Real-time config push to agents (polling is sufficient)
- Custom DSL for device queries (use existing SRQL)

## Decisions

### 1. Config Distribution Architecture

**Decision**: Create a `ServiceRadar.AgentConfig` Ash domain with pluggable compilers.

**Structure:**
```
ServiceRadar.AgentConfig
├── Resources
│   ├── ConfigTemplate       # Reusable config templates (admin-managed)
│   ├── ConfigInstance       # Compiled config for agent+partition
│   └── ConfigVersion        # Version history for audit
├── Compilers
│   ├── Behaviour            # Compiler behaviour definition
│   ├── SweepCompiler        # Compiles SweepJob → sweep.json
│   ├── PollerCompiler       # Future: poller config
│   └── CheckerCompiler      # Future: checker config
└── Services
    ├── ConfigCache          # ETS-based config cache
    ├── ConfigPublisher      # NATS event publisher
    └── ConfigServer         # GenServer for compilation
```

**Why**:
- Behaviour-based compilers allow adding new config types without changing core logic
- Ash resources provide tenant isolation via context scopes
- ETS cache provides fast lookups with NATS-driven invalidation

**Alternatives considered:**
- Direct gRPC service without Ash: Rejected - loses tenant isolation guarantees
- Store compiled configs in database: Considered - adds latency, ETS is faster
- Push-based distribution: Rejected - requires persistent connections, polling is simpler

### 2. Config Compilation Flow

**Decision**: Compile on-demand with caching and event-driven invalidation.

```
[Ash Resource Change]
        │
        ▼
[NATS: config.invalidated.{tenant}.{type}]
        │
        ├──► [Core ETS Cache: invalidate]
        │
        └──► [Gateway Cache: invalidate]

[Agent GetConfig Request]
        │
        ▼
[Gateway] ─cache hit?─► Return cached config
        │ miss
        ▼
[Core RPC: compile_config(tenant, agent, type)]
        │
        ▼
[ConfigServer.compile/3]
        │
        ├──► Query Ash resources (SweepJob, SweepProfile, etc.)
        │
        ├──► Evaluate device queries (SRQL)
        │
        ├──► Build config JSON matching agent schema
        │
        └──► Cache in ETS with content hash
        │
        ▼
[Return to Gateway] ─► [Cache locally] ─► [Return to Agent]
```

**Why**:
- On-demand compilation avoids unnecessary work
- ETS cache provides sub-millisecond lookups
- NATS events ensure cache coherence across cluster

### 3. Sweep Data Model

**Decision**: Four Ash resources for sweep management with groups as the primary organizational unit.

```elixir
# SweepProfile - Admin-managed scanner profiles (reusable templates)
defmodule ServiceRadar.SweepJobs.SweepProfile do
  use Ash.Resource

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :description, :string
    attribute :ports, {:array, :integer}, default: []
    attribute :sweep_modes, {:array, :string}, default: ["tcp"]
    attribute :concurrency, :integer, default: 50
    attribute :timeout, :string, default: "3s"
    attribute :icmp_settings, :map, default: %{}
    attribute :tcp_settings, :map, default: %{}
    attribute :admin_only, :boolean, default: false
  end
end

# SweepGroup - User-configured sweep groups with custom schedules
defmodule ServiceRadar.SweepJobs.SweepGroup do
  use Ash.Resource

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :description, :string
    attribute :partition, :string, default: "default"
    attribute :agent_id, :string  # nil = any agent in partition
    attribute :enabled, :boolean, default: true

    # Schedule (independent per group)
    attribute :interval, :string, allow_nil?: false  # "5m", "2h", "1d"
    attribute :schedule_type, :atom, default: :interval
    # constraints: [one_of: [:interval, :cron]]
    attribute :cron_expression, :string  # For cron-based scheduling

    # Device targeting (DSL-based)
    attribute :target_criteria, :map, default: %{}
    # Example: %{
    #   "tags" => %{"has_any" => ["critical", "prod"]},
    #   "tags.env" => %{"eq" => "prod"},
    #   "ip" => %{"in_cidr" => "10.0.0.0/8"},
    #   "partition" => %{"eq" => "datacenter-1"}
    # }

    attribute :static_targets, {:array, :string}  # Explicit CIDRs/IPs (merged with query)

    # Scan configuration (can override profile)
    attribute :ports, {:array, :integer}  # Override profile ports
    attribute :sweep_modes, {:array, :string}  # Override profile modes
    attribute :overrides, :map, default: %{}  # Other setting overrides
  end

  relationships do
    belongs_to :profile, SweepProfile  # Base profile (optional)
    has_many :executions, SweepGroupExecution
  end
end

# SweepGroupExecution - Execution tracking per group
defmodule ServiceRadar.SweepJobs.SweepGroupExecution do
  use Ash.Resource

  attributes do
    uuid_primary_key :id
    attribute :status, :atom, constraints: [one_of: [:pending, :running, :completed, :failed]]
    attribute :started_at, :utc_datetime
    attribute :completed_at, :utc_datetime
    attribute :hosts_total, :integer
    attribute :hosts_available, :integer
    attribute :duration_ms, :integer
    attribute :error_message, :string
    attribute :agent_id, :string  # Which agent executed
  end

  relationships do
    belongs_to :sweep_group, SweepGroup
  end
end

# SweepHostResult - Per-host results from sweep executions
defmodule ServiceRadar.SweepJobs.SweepHostResult do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "sweep_host_results"
    repo ServiceRadar.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :ip, :string, allow_nil?: false
    attribute :hostname, :string
    attribute :is_available, :boolean, default: false
    attribute :icmp_available, :boolean
    attribute :icmp_response_time_ms, :integer
    attribute :open_ports, {:array, :integer}, default: []
    attribute :port_results, :map, default: %{}  # {port: {available, response_time_ms}}
    attribute :swept_at, :utc_datetime
  end

  relationships do
    belongs_to :execution, SweepGroupExecution
    belongs_to :device, ServiceRadar.Inventory.Device  # Link to OCSF device if matched
  end
end
```

**Why**:
- SweepGroup is the primary unit with its own schedule (not inherited from profile)
- `target_criteria` map enables flexible DSL-based targeting
- Profile is optional - groups can define everything inline or inherit from profile
- Host results link to both execution and device for enrichment

**Device Targeting DSL**:
```elixir
# Targeting criteria operators
%{
  "tags" => %{"has_any" => ["critical", "prod"]},      # Tag key match
  "tags.env" => %{"eq" => "prod"},                     # Tag key/value match
  "ip" => %{"in_cidr" => "10.0.0.0/8"},                # CIDR match (or in_range)
  "partition" => %{"eq" => "datacenter-1"}             # Partition match
}
```

Criteria are compiled to SRQL at evaluation time, enabling reuse of existing query infrastructure.
Tag operators support boolean grouping (any/all) to keep the UI simple while allowing expressive targeting.

### 3.1 Device Tags

**Decision**: Add `ocsf_devices.tags` as a JSONB map of user-applied labels (key/value).

**Why**:
- Tags provide a durable, user-controlled targeting mechanism for sweep groups.
- Key/value maps allow lightweight grouping without expanding schema columns.

### 4. UI Structure

**Decision**: Add "Networks" section to Settings with sweep groups as primary entity.

```
Settings > Networks
├── Scanner Profiles (Admin only)
│   ├── List profiles with usage counts
│   ├── Create/Edit profile form
│   └── Delete with confirmation (warn if in use)
├── Sweep Groups
│   ├── List groups with:
│   │   ├── Name, description
│   │   ├── Schedule (interval or cron)
│   │   ├── Target count (devices matching criteria)
│   │   ├── Last run / next run
│   │   ├── Status indicator (enabled/disabled/error)
│   ├── Create/Edit group form with:
│   │   ├── Basic: name, description, enabled toggle
│   │   ├── Schedule: interval picker or cron builder
│   │   ├── Targeting: visual query builder
│   │   │   ├── Tag selector (key + optional value)
│   │   │   ├── Static targets (IP/CIDR/range list)
│   │   │   ├── Match mode (all/any groups)
│   │   │   ├── Partition selector
│   │   │   └── Preview: "12 devices match this criteria"
│   │   ├── Scan config: ports, modes, profile selector (optional)
│   │   └── Assignment: partition + optional agent
│   └── Group detail view:
│       ├── Current target devices list
│       ├── Execution history with results
│       └── Quick actions: run now, disable, delete
└── Active Scans (Dashboard)
    ├── Currently running scans by group
    ├── Recent completions with success/failure
    └── Aggregate stats: hosts scanned, available, response times
```

**Device Inventory Integration:**
```
Device Inventory
├── Bulk Actions dropdown
│   └── "Bulk Edit"
│       └── Apply tags to selected devices
├── Device Detail panel
│   └── Sweep Status section
│       ├── Groups targeting this device (list)
│       ├── Last sweep time per group
│       ├── Availability status (ICMP, TCP ports)
│       └── Response time trends
└── Filters sidebar
    └── Tag filter (key/value)
```

**Visual Query Builder Component:**
```
┌─────────────────────────────────────────────────────────┐
│ Target Devices                                          │
├─────────────────────────────────────────────────────────┤
│ Tags:             [env=prod] [critical] [region=us]    │
│ Static Targets:   [10.0.0.0/8, 10.0.2.10-10.0.2.50]     │
│ Match Mode:       (all tags) (any tag)                 │
│ Partition:        [datacenter-1 ▾]                     │
├─────────────────────────────────────────────────────────┤
│ ✓ 47 devices match these criteria          [Preview]   │
└─────────────────────────────────────────────────────────┘
```

### 5. Agent Config Polling Protocol

**Decision**: Extend existing `GetConfig` RPC with config type routing.

```protobuf
message AgentConfigRequest {
  string agent_id = 1;
  string partition = 2;
  string config_type = 3;  // "sweep", "poller", "checker"
  string current_hash = 4;  // For change detection
}

message AgentConfigResponse {
  bool has_changes = 1;
  bytes config = 2;        // JSON config
  string config_hash = 3;
  int64 version = 4;
  string next_poll_hint = 5;  // Suggested poll interval
}
```

**Why**:
- Single RPC endpoint for all config types
- Hash-based change detection minimizes bandwidth
- Version tracking enables audit and rollback

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Config compilation latency | ETS cache + async compilation |
| Cache coherence in cluster | NATS pub/sub for invalidation |
| Agent offline during config change | Poll-based model ensures eventual delivery |
| Large device queries slow compilation | Query result caching, pagination |
| Breaking existing file-based configs | Fallback to file when gateway unavailable |

## Migration Plan

1. **Phase 1: Foundation**
   - Create `AgentConfig` domain with Ash resources
   - Implement `SweepCompiler` behaviour
   - Add `GetConfig` handling to gateway

2. **Phase 2: UI**
   - Add Settings > Networks section
   - Implement scanner profile CRUD
   - Implement sweep job CRUD with device query

3. **Phase 3: Agent Integration**
   - Update agent to poll gateway for config
   - Implement file-based fallback
   - Remove KV/datasvc dependencies

4. **Phase 4: Results Flow**
   - Validate agent → gateway sweep results push
   - Implement gateway → core forwarding
   - Update DIRE to process sweep results

**Rollback**: Each phase is independently deployable. Agents can fall back to file config if gateway config fails.

## Open Questions

1. Should sweep profiles be shareable across tenants (platform-level templates)?
2. What is the maximum device query result size before pagination is required?
3. Should we support real-time config push for urgent updates, or is polling always sufficient?
4. How long should execution history be retained?
