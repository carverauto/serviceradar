# Design: OCSF Device Inventory Schema Alignment

## Context

ServiceRadar stores device inventory in the `unified_devices` table with a proprietary schema. The OCSF (Open Cybersecurity Schema Framework) v1.7.0 defines a standardized Device object that enables interoperability with security tooling. This change aligns our device inventory with OCSF to enable data portability and richer device metadata.

**Stakeholders:**
- Security teams wanting OCSF-compatible exports
- Integration partners expecting standard schemas
- Internal teams maintaining DIRE, SRQL, and web-ng

**Constraints:**
- DIRE engine changes (fix-dire-engine) should land first
- Performance must remain acceptable for 50k+ device inventories
- JSONB columns for nested objects to avoid schema explosion

## Goals / Non-Goals

### Goals
- Align device inventory schema with OCSF v1.7.0 Device object
- Support OCSF device type classification (0-15, 99)
- Enable OCSF-compatible JSON data export
- DIRE writes directly to OCSF schema (single data format)

### Non-Goals
- Full OCSF event schema implementation (only Device object)
- Real-time OCSF event streaming (batch export is sufficient)
- Historical data preservation (clean cutover is acceptable)
- Implementing every optional OCSF field immediately

## Decisions

### D1: Clean Cutover (No Migration)

**Decision:** Drop `unified_devices`, create `ocsf_devices`, let new data flow in.

**Rationale:**
- No production data worth preserving
- Eliminates migration complexity and shadow-write overhead
- Clean schema without legacy cruft
- Faster implementation

### D2: Nested Objects Storage

**Decision:** Store complex OCSF objects (os, hw_info, network_interfaces, owner, org, groups, agent_list) as JSONB columns.

**Rationale:**
- OCSF nested objects are variable-structure (optional fields)
- JSONB enables flexible querying with GIN indexes
- Avoids schema explosion (30+ additional tables for normalization)
- TimescaleDB/CNPG has excellent JSONB support

**Schema excerpt:**
```sql
os              JSONB,  -- {name, type, version, build, edition, kernel_release, cpu_bits, sp_name, sp_ver, lang}
hw_info         JSONB,  -- {cpu_architecture, cpu_bits, cpu_cores, cpu_count, cpu_speed_mhz, cpu_type, ram_size, serial_number, chassis, bios_manufacturer, bios_ver, bios_date, uuid}
network_interfaces JSONB,  -- [{mac, ip, hostname, name, uid, type, type_id, namespace_pid}]
owner           JSONB,  -- {uid, name, email, type, type_id, org}
org             JSONB,  -- {uid, name, ou_uid, ou_name}
groups          JSONB,  -- [{uid, name, type, desc}]
agent_list      JSONB,  -- [{uid, name, type, type_id, version, vendor_name, policies}]
```

### D3: OCSF Type Inference

**Decision:** Infer OCSF `type_id` from discovery signals when not explicitly provided.

**Inference rules:**
| Signal | Inferred type_id |
|--------|-----------------|
| SNMP sysDescr contains "router" | 12 (Router) |
| SNMP sysDescr contains "switch" | 10 (Switch) |
| Open port 80/443 + web fingerprint | 1 (Server) |
| Armis category "Firewall" | 9 (Firewall) |
| Armis category "IoT" | 7 (IOT) |
| MAC OUI in IoT vendor list | 7 (IOT) |
| No strong signals | 0 (Unknown) |

**Location:** `pkg/registry/ocsf_type_inference.go`

### D4: DIRE Identity Resolution (Unchanged)

**Decision:** `device_identifiers` table remains as DIRE's identity resolution mechanism.

**Rationale:**
- `device_identifiers` IS how DIRE works - it's not legacy, it's the identity engine
- Maps strong identifiers (armis_device_id, mac, netbox_device_id) → canonical device ID
- OCSF `uid` = the canonical `device_id` that DIRE resolves
- No duplication - `device_identifiers` stores identity mappings, `ocsf_devices` stores device attributes

**Flow:**
```
Device arrives (armis_id=123, ip=10.0.0.1, hostname=foo)
    ↓
DIRE looks up device_identifiers for armis_id=123
    ↓
Returns canonical uid = sr:abc123 (or generates if new)
    ↓
DIRE upserts ocsf_devices with uid=sr:abc123, ip, hostname, OCSF fields
```

### D5: Risk Scoring

**Decision:** Pass through risk scores from source systems (Armis, etc.).

**Mapping:**
- `risk_score`: Raw numeric score from source (e.g., Armis risk score 0-100)
- `risk_level_id`: Normalized OCSF level derived from score thresholds:
  - 0-20 → 0 (Info)
  - 21-40 → 1 (Low)
  - 41-60 → 2 (Medium)
  - 61-80 → 3 (High)
  - 81-100 → 4 (Critical)

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| JSONB query performance | Add GIN indexes on frequently-queried paths |
| OCSF schema changes | Pin to v1.7.0; can add version column later if needed |
| SRQL query changes | Planner abstracts table name; focused changes |

## Execution Plan

1. Drop `unified_devices` table
2. Create `ocsf_devices` table with OCSF schema
3. Update DIRE to write to `ocsf_devices`
4. Update SRQL to query `ocsf_devices`
5. Update web-ng for OCSF response shape
6. Remove dead code referencing `unified_devices`
