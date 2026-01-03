# Change: OCSF Device Inventory Schema Alignment

## Why

ServiceRadar's device inventory system currently uses a proprietary schema (`unified_devices`) that is incompatible with industry-standard security tooling. The OCSF (Open Cybersecurity Schema Framework) provides a vendor-agnostic, standardized schema for security events and objects that enables interoperability with SIEMs, SOARs, and other security tools.

Aligning our device inventory with OCSF v1.7.0 Device object schema will:
1. Enable data export/import compatibility with OCSF-based tooling (Splunk, AWS Security Lake, etc.)
2. Provide richer device metadata (hardware info, OS details, risk scoring, compliance state)
3. Support standard device type classifications (server, router, firewall, IoT, etc.)
4. Future-proof the schema for security event correlation

## What Changes

### Phase 1: Schema Replacement
- **BREAKING**: Drop `unified_devices` table (no historical data preservation needed)
- Create new `ocsf_devices` table aligned with OCSF Device object schema
- Core columns: `uid` (PK), `type_id`, `type`, `name`, `hostname`, `ip`, `mac`
- Extended columns: `vendor_name`, `model`, `domain`, `zone`, `subnet_uid`
- Temporal columns: `first_seen_time`, `last_seen_time`, `created_time`, `modified_time`
- Risk/compliance columns: `risk_level_id`, `risk_score`, `is_managed`, `is_compliant`, `is_trusted`
- JSONB columns for nested objects: `os`, `hw_info`, `network_interfaces`, `groups`, `agent_list`, `owner`, `org`

### Phase 2: DIRE Integration
- Update DIRE to write directly to `ocsf_devices` (replaces `unified_devices` writes)
- `device_identifiers` table remains as DIRE's identity resolution mechanism (not legacy - this IS how DIRE works)
- `ocsf_devices.uid` = canonical device ID from DIRE's identity engine
- Add OCSF type inference from discovery signals (SNMP sysDescr, port scan, Armis category, etc.)
- Map source metadata to OCSF fields during ingestion

### Phase 3: Query Layer
- Update SRQL to query `ocsf_devices` table
- Update device search to leverage new indexed fields and JSONB paths
- Add OCSF export endpoint (`/api/devices/ocsf/export`) for JSON bulk export

### Phase 4: Web UI
- Update web-ng to consume OCSF-shaped device data
- Display new OCSF fields (device type, vendor, model, risk level)
- Update device detail views with OS and hardware info

### Phase 5: Cleanup
- Remove all `unified_devices` references from codebase
- Update documentation

## Impact

- **Affected specs**: `device-inventory` (NEW)
- **Affected code**:
  - `pkg/db/cnpg/migrations/` - Drop unified_devices, create ocsf_devices
  - `pkg/registry/registry.go` - DIRE writes to ocsf_devices
  - `pkg/registry/identity_engine.go` - OCSF type inference
  - `pkg/db/cnpg_unified_devices.go` - Replace with cnpg_ocsf_devices.go
  - `rust/srql/` - Query planner for ocsf_devices
  - `web-ng/` - Device UI components
  - `docs/docs/` - Schema documentation
- **Dependencies**:
  - `fix-dire-engine` should be substantially complete (37/41 tasks done)
- **Risk**: Medium - breaking change but no production data to preserve
- **Migration**: Clean cutover - drop old, create new, let data flow in
