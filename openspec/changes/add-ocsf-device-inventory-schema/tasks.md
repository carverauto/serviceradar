# Tasks: OCSF Device Inventory Schema Alignment

## Prerequisites
- [ ] 0.1 Verify `fix-dire-engine` is complete or near-complete
- [ ] 0.2 Review OCSF v1.7.0 Device object specification

## 1. Schema Changes

- [ ] 1.1 Update migration in `pkg/db/cnpg/migrations/00000000000001_schema.up.sql`
  - [ ] 1.1.1 Remove `unified_devices` table definition
  - [ ] 1.1.2 Add `ocsf_devices` table with OCSF-aligned columns
  - [ ] 1.1.3 Add indexes: uid (PK), ip, hostname, type_id, GIN on JSONB columns
  - [ ] 1.1.4 Keep `device_identifiers` table unchanged (DIRE needs it)

- [ ] 1.2 Define OCSF device columns:
  - Core: `uid` (PK), `type_id`, `type`, `name`, `hostname`, `ip`, `mac`
  - Extended: `vendor_name`, `model`, `domain`, `zone`, `subnet_uid`, `vlan_uid`
  - Temporal: `first_seen_time`, `last_seen_time`, `created_time`, `modified_time`
  - Risk: `risk_level_id`, `risk_level`, `risk_score`, `is_managed`, `is_compliant`, `is_trusted`
  - JSONB: `os`, `hw_info`, `network_interfaces`, `groups`, `agent_list`, `owner`, `org`, `metadata`

## 2. Go Models & DIRE Integration

- [ ] 2.1 Create OCSF device models in `pkg/models/ocsf_device.go`
  - [ ] 2.1.1 Define OCSFDevice struct with all OCSF fields
  - [ ] 2.1.2 Define nested structs: OCSFDeviceOS, OCSFDeviceHWInfo, OCSFNetworkInterface
  - [ ] 2.1.3 Add JSON tags aligned with OCSF field names

- [ ] 2.2 Create OCSF type inference in `pkg/registry/ocsf_type_inference.go`
  - [ ] 2.2.1 Implement InferOCSFTypeID(metadata) returning type_id and type string
  - [ ] 2.2.2 Add inference rules for router, switch, firewall, server, IoT
  - [ ] 2.2.3 Add unit tests for type inference

- [ ] 2.3 Create CNPG client for OCSF devices in `pkg/db/cnpg_ocsf_devices.go`
  - [ ] 2.3.1 Implement UpsertOCSFDevice method
  - [ ] 2.3.2 Implement GetOCSFDevice(uid) method
  - [ ] 2.3.3 Implement ListOCSFDevices with filtering
  - [ ] 2.3.4 Implement DeleteOCSFDevice method

- [ ] 2.4 Update DIRE to write OCSF devices
  - [ ] 2.4.1 Update ProcessBatchDeviceUpdates to build OCSFDevice structs
  - [ ] 2.4.2 Map incoming metadata to OCSF fields (os, hw_info, etc.)
  - [ ] 2.4.3 Wire type inference into device processing
  - [ ] 2.4.4 Replace unified_devices upsert with ocsf_devices upsert

## 3. Remove unified_devices References

- [ ] 3.1 Remove `pkg/db/cnpg_unified_devices.go` or refactor to ocsf_devices
- [ ] 3.2 Update all registry code referencing unified_devices
- [ ] 3.3 Update any remaining Go code with unified_devices imports

## 4. SRQL Updates

- [ ] 4.1 Update SRQL schema in `rust/srql/`
  - [ ] 4.1.1 Remove unified_devices from Diesel schema
  - [ ] 4.1.2 Add ocsf_devices table to Diesel schema
  - [ ] 4.1.3 Define OCSFDevice model struct

- [ ] 4.2 Update query planner for OCSF table
  - [ ] 4.2.1 Update device queries to use ocsf_devices
  - [ ] 4.2.2 Support JSONB path queries for nested objects (os, hw_info)
  - [ ] 4.2.3 Add type_id filtering support

## 5. API Layer

- [ ] 5.1 Update device API responses
  - [ ] 5.1.1 Return OCSF-shaped device JSON from device endpoints
  - [ ] 5.1.2 Ensure field names match OCSF spec (camelCase)

- [ ] 5.2 Add OCSF export endpoint
  - [ ] 5.2.1 Create `/api/devices/ocsf/export` endpoint
  - [ ] 5.2.2 Support filtering by type_id, time range
  - [ ] 5.2.3 Add pagination for large exports

## 6. Web-ng Updates

- [ ] 6.1 Update device list component
  - [ ] 6.1.1 Display `type` instead of legacy device_type
  - [ ] 6.1.2 Add vendor_name and model columns
  - [ ] 6.1.3 Add risk_level indicator

- [ ] 6.2 Update device detail view
  - [ ] 6.2.1 Display OS information from `os` JSONB
  - [ ] 6.2.2 Display hardware info from `hw_info` JSONB
  - [ ] 6.2.3 Display network interfaces
  - [ ] 6.2.4 Display compliance/management status flags

- [ ] 6.3 Add device type filtering
  - [ ] 6.3.1 Add type_id filter dropdown with OCSF types
  - [ ] 6.3.2 Add type icons for visual identification

## 7. Documentation

- [ ] 7.1 Document OCSF schema in `docs/docs/ocsf-device-schema.md`
- [ ] 7.2 Update architecture docs with new data model
- [ ] 7.3 Document OCSF export endpoint usage

## 8. Testing

- [ ] 8.1 Add DIRE integration tests for OCSF writes
- [ ] 8.2 Add SRQL tests for OCSF device queries
- [ ] 8.3 Add type inference unit tests
- [ ] 8.4 E2E test: device discovery flows to OCSF table correctly
