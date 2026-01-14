## Context

The current architecture has SNMP monitoring as a standalone `snmp-checker` service that agents communicate with via gRPC. This was originally designed when the agent was simpler, but now with embedded sysmon and dynamic configuration from the control plane, SNMP should follow the same pattern.

**Stakeholders**: Platform operators (simpler deployment), developers (consistent architecture)

**Constraints**:
- Must remain backwards compatible with existing SNMP checker deployments during migration
- SNMP targets may be external network devices (not agents), requiring special handling
- SNMPv3 authentication requires secure credential storage

## Goals / Non-Goals

**Goals**:
- Embed SNMP collector into agent for simplified deployment
- Enable dynamic SNMP configuration through profiles (like sysmon)
- Use SRQL for targeting devices to monitor
- Provide UI for creating and managing SNMP profiles

**Non-Goals**:
- SNMP trap receiver (future work)
- SNMP write operations (GET only)
- MIB browser/editor in UI
- Auto-discovery of OIDs

## Decisions

### Decision 1: SNMP as Agent Capability, Not Separate Service

**Choice**: Embed SNMP collector as `pkg/agent/snmp_service.go`

**Rationale**:
- Matches sysmon pattern already proven to work
- Reduces operational complexity (one binary to deploy)
- Enables dynamic configuration from control plane
- Agent already has config refresh infrastructure

**Alternatives considered**:
- Keep standalone service: Rejected - adds deployment complexity
- Sidecar container: Rejected - still requires separate configuration

### Decision 2: SNMP Profiles with SRQL Targeting

**Choice**: SNMPProfile resource with `target_query` field for SRQL-based interface/device targeting

**Rationale**:
- Consistent with sysmon profile targeting (just implemented)
- Leverages existing SRQL infrastructure
- Interface-level targeting for network device monitoring
- Supports complex targeting like "interfaces on routers in production"

**Example targeting**:
- `in:interfaces type:ethernet status:up` - All active ethernet interfaces
- `in:interfaces device.type:Router` - Interfaces on router devices
- `in:devices tags.snmp:enabled` - All devices tagged for SNMP monitoring
- `in:interfaces speed:>1000000000` - High-speed interfaces (>1Gbps)

### Decision 3: SNMPConfig in AgentConfigResponse

**Choice**: Add `SNMPConfig` field to existing `AgentConfigResponse` proto message

**Rationale**:
- Single config fetch for all agent capabilities (sysmon, snmp, sweep, etc.)
- No additional gRPC calls needed
- Compiler framework already handles multi-config responses

### Decision 4: Profile-Based Target Sets

**Choice**: Each SNMP profile contains a set of SNMP targets (network devices to poll)

**Rationale**:
- Different devices may need to poll different SNMP targets
- A "core router monitoring" profile includes core router targets
- An "access switch monitoring" profile includes access switch targets

**Structure**:
```
SNMPProfile
  ├── target_query: "in:devices role:network-monitor"  # Which agents get this profile
  ├── poll_interval: 60s
  ├── snmp_targets:                                     # What SNMP devices to poll
  │   ├── name: "core-router-1"
  │   │   ├── host: 192.168.1.1
  │   │   ├── community: "public"
  │   │   └── oids: [...]
  │   └── name: "core-switch-1"
  │       └── ...
  └── ...
```

### Decision 5: Vendor-Based OID Template Library

**Choice**: OID templates organized by vendor with user-creatable custom templates

**Rationale**:
- Most users want standard metrics (interface stats, CPU, memory)
- Vendor-specific OIDs vary significantly (Cisco vs Juniper vs Arista)
- Templates reduce configuration errors
- Users need ability to create and share custom templates

**Template Structure**:
```
OID Templates (sorted by vendor)
├── Standard (RFC/MIB-II)
│   ├── interface-stats: ifInOctets, ifOutOctets, ifOperStatus, ifSpeed
│   ├── system-info: sysDescr, sysUpTime, sysName, sysLocation
│   └── ip-stats: ipInReceives, ipOutRequests, ipInDiscards
├── Cisco
│   ├── cpu-memory: cpmCPUTotal5sec, ciscoMemoryPoolUsed
│   ├── environment: ciscoEnvMonTemperature, ciscoEnvMonVoltage
│   └── bgp-stats: cbgpPeerState, cbgpPeerPrefixAccepted
├── Juniper
│   ├── cpu-memory: jnxOperatingCPU, jnxOperatingBuffer
│   └── environment: jnxOperatingTemp, jnxOperatingState
├── Arista
│   └── environment: aristaEnvMonTemp, aristaEnvMonFan
└── Custom (user-created)
    └── [tenant-specific templates]
```

**Template Storage**:
- Built-in templates: Code (shipped with release)
- Custom templates: Database (SNMPOIDTemplate resource)
- Templates are copyable - users can copy built-in and customize

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Control Plane (Elixir)                   │
├─────────────────────────────────────────────────────────────┤
│  SNMPProfile Resource                                       │
│  ├── name: "Core Network Monitoring"                        │
│  ├── target_query: "in:devices role:network-monitor"        │
│  ├── poll_interval: 60s                                     │
│  ├── is_default: false                                      │
│  └── snmp_targets: [{host, community, oids}, ...]          │
├─────────────────────────────────────────────────────────────┤
│  SNMPCompiler                                               │
│  └── Resolves profile for device → generates SNMPConfig    │
└───────────────────────────┬─────────────────────────────────┘
                            │ gRPC AgentConfigResponse
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    Agent (Go)                               │
├─────────────────────────────────────────────────────────────┤
│  SNMPService (pkg/agent/snmp_service.go)                    │
│  ├── Receives SNMPConfig from control plane                 │
│  ├── Creates SNMPCollectors for each target                 │
│  ├── Polls SNMP targets on interval                         │
│  └── Reports metrics via agent status                       │
├─────────────────────────────────────────────────────────────┤
│  SNMPCollector (pkg/checker/snmp/collector.go)              │
│  ├── Connects to SNMP device                                │
│  ├── Polls configured OIDs                                  │
│  └── Returns DataPoints                                     │
└───────────────────────────┬─────────────────────────────────┘
                            │ SNMP GET
                            ▼
                    ┌───────────────┐
                    │ Network       │
                    │ Devices       │
                    │ (routers,     │
                    │  switches)    │
                    └───────────────┘
```

## Data Model

### SNMPProfile (Elixir/Ash)

```elixir
attributes do
  uuid_v7_primary_key :id
  attribute :name, :string, allow_nil?: false
  attribute :description, :string
  attribute :target_query, :string  # SRQL query for device targeting
  attribute :priority, :integer, default: 0
  attribute :is_default, :boolean, default: false
  attribute :is_enabled, :boolean, default: true

  # Polling configuration
  attribute :poll_interval, :integer, default: 60  # seconds
  attribute :timeout, :integer, default: 5  # seconds
  attribute :retries, :integer, default: 3

  timestamps()
end
```

### SNMPTarget (Elixir/Ash)

```elixir
attributes do
  uuid_v7_primary_key :id
  attribute :name, :string, allow_nil?: false
  attribute :host, :string, allow_nil?: false
  attribute :port, :integer, default: 161
  attribute :version, :atom, constraints: [one_of: [:v1, :v2c, :v3]]
  attribute :community, :string  # For v1/v2c

  # SNMPv3 auth (encrypted at rest)
  attribute :security_level, :atom  # noAuthNoPriv, authNoPriv, authPriv
  attribute :auth_protocol, :atom   # md5, sha, sha256
  attribute :auth_password_encrypted, :binary
  attribute :priv_protocol, :atom   # des, aes, aes256
  attribute :priv_password_encrypted, :binary
  attribute :username, :string

  timestamps()
end

relationships do
  belongs_to :snmp_profile, SNMPProfile
  has_many :oid_configs, SNMPOIDConfig
end
```

### SNMPOIDConfig (Elixir/Ash)

```elixir
attributes do
  uuid_v7_primary_key :id
  attribute :oid, :string, allow_nil?: false
  attribute :name, :string, allow_nil?: false
  attribute :data_type, :atom, constraints: [one_of: [:counter, :gauge, :boolean, :bytes, :string, :float]]
  attribute :scale, :float, default: 1.0
  attribute :delta, :boolean, default: false  # Calculate rate of change

  timestamps()
end

relationships do
  belongs_to :snmp_target, SNMPTarget
end
```

### SNMPOIDTemplate (Elixir/Ash) - User-Created Templates

```elixir
attributes do
  uuid_v7_primary_key :id
  attribute :name, :string, allow_nil?: false
  attribute :description, :string
  attribute :vendor, :string  # "cisco", "juniper", "arista", "custom"
  attribute :category, :string  # "cpu-memory", "interface", "environment"
  attribute :oids, {:array, :map}  # [{oid, name, data_type, scale, delta}, ...]
  attribute :is_builtin, :boolean, default: false  # true for shipped templates

  timestamps()
end

relationships do
  belongs_to :tenant, Tenant  # nil for built-in templates
end
```

## Proto Messages

```protobuf
message SNMPConfig {
  bool enabled = 1;
  string profile_id = 2;
  repeated SNMPTargetConfig targets = 3;
}

message SNMPTargetConfig {
  string name = 1;
  string host = 2;
  uint32 port = 3;
  SNMPVersion version = 4;
  string community = 5;  // Decrypted for v1/v2c
  SNMPv3Auth v3_auth = 6;  // For v3
  uint32 poll_interval_seconds = 7;
  uint32 timeout_seconds = 8;
  uint32 retries = 9;
  repeated OIDConfig oids = 10;
}

message SNMPv3Auth {
  string username = 1;
  SNMPSecurityLevel security_level = 2;
  SNMPAuthProtocol auth_protocol = 3;
  string auth_password = 4;  // Decrypted
  SNMPPrivProtocol priv_protocol = 5;
  string priv_password = 6;  // Decrypted
}

message OIDConfig {
  string oid = 1;
  string name = 2;
  OIDDataType data_type = 3;
  double scale = 4;
  bool delta = 5;
}
```

## UI Components

### Settings Page: /settings/snmp-profiles

**Layout** (modal-driven, consistent with existing settings pages):

1. **Profile List View**
   - Table: Name, Enabled, Targets Count, Matched Interfaces, Actions
   - "New Profile" button opens create modal
   - Row click or edit button opens edit modal

2. **Profile Modal** (create/edit)
   - Basic info tab: name, description, enabled toggle
   - Targeting tab: SRQL query builder for interface targeting
   - Targets tab: list of SNMP targets with add/remove
   - Preview panel: matched interfaces count

3. **Target Modal** (nested, opens from profile modal)
   - Connection: host, port, SNMP version selector
   - Auth tab (v1/v2c): community string input
   - Auth tab (v3): username, security level, auth/priv protocols
   - OIDs tab: template selector + custom OID list

4. **OID Template Modal**
   - Vendor filter/tabs (Standard, Cisco, Juniper, Arista, Custom)
   - Template list with description and OID count
   - Preview OIDs in template
   - "Use Template" adds OIDs to target
   - "Create Custom" for user templates

**Components to reuse**:
- `SRQLComponents.srql_query_bar/1` - Query input
- `SRQLComponents.srql_query_builder/1` - Visual query builder
- Modal patterns from sysmon profiles, alert rules settings
- Form field components from existing settings pages

## Risks / Trade-offs

### Risk 1: Credential Security
- **Risk**: SNMP community strings and SNMPv3 passwords stored in database
- **Mitigation**: Encrypt at rest using Cloak, decrypt only when generating agent config

### Risk 2: Network Device Unreachable
- **Risk**: Agent assigned to poll network device that's unreachable from agent's network
- **Mitigation**: Health status per target, clear error reporting, admin can reassign profiles

### Risk 3: Backwards Compatibility
- **Risk**: Breaking existing snmp-checker deployments
- **Mitigation**: Keep standalone snmp-checker working during transition, document migration path

## Migration Plan

### Phase 1: Parallel Operation
1. Implement embedded SNMP service in agent
2. Keep standalone snmp-checker working
3. New installations use embedded SNMP

### Phase 2: UI and Profiles
1. Create SNMP profiles UI
2. Implement SNMP compiler
3. Agents start receiving dynamic config

### Phase 3: Deprecation
1. Document migration from standalone to embedded
2. Deprecation warnings in standalone checker
3. Eventually remove standalone service

**Rollback**: If issues, agents fall back to cached config or local override file

## Open Questions

1. **OID template management**: Should templates be stored in database or code?
   - **Resolved**: Hybrid approach
     - Built-in templates: Code (shipped with release, vendor-organized)
     - Custom templates: Database (SNMPOIDTemplate resource, per-tenant)
     - Users can copy built-in templates to customize

2. **SNMP polling from specific agent**: How to handle when only certain agents can reach certain network devices?
   - **Resolved**: SRQL targeting - profile targets interfaces/devices that can reach network devices

3. **Rate limiting**: Should we limit number of SNMP targets per agent?
   - Leaning: Soft limit with warning, configurable per-tenant
