# Tasks: OCSF Device Inventory Schema Alignment

## Prerequisites
- [x] 0.1 Verify `fix-dire-engine` is complete or near-complete
- [x] 0.2 Review OCSF v1.7.0 Device object specification

## 1. Schema Changes

- [x] 1.1 Update migration in `pkg/db/cnpg/migrations/00000000000001_schema.up.sql`
  - [x] 1.1.1 Remove `unified_devices` table definition
  - [x] 1.1.2 Add `ocsf_devices` table with OCSF-aligned columns
  - [x] 1.1.3 Add indexes: uid (PK), ip, hostname, type_id, GIN on JSONB columns
  - [x] 1.1.4 Keep `device_identifiers` table unchanged (DIRE needs it)

- [x] 1.2 Define OCSF device columns:
  - Core: `uid` (PK), `type_id`, `type`, `name`, `hostname`, `ip`, `mac`
  - Extended: `vendor_name`, `model`, `domain`, `zone`, `subnet_uid`, `vlan_uid`
  - Temporal: `first_seen_time`, `last_seen_time`, `created_time`, `modified_time`
  - Risk: `risk_level_id`, `risk_level`, `risk_score`, `is_managed`, `is_compliant`, `is_trusted`
  - JSONB: `os`, `hw_info`, `network_interfaces`, `groups`, `agent_list`, `owner`, `org`, `metadata`

## 2. Go Models & DIRE Integration

- [x] 2.1 Create OCSF device models in `pkg/models/ocsf_device.go`
  - [x] 2.1.1 Define OCSFDevice struct with all OCSF fields
  - [x] 2.1.2 Define nested structs: OCSFDeviceOS, OCSFDeviceHWInfo, OCSFNetworkInterface
  - [x] 2.1.3 Add JSON tags aligned with OCSF field names
  - [x] 2.1.4 Add ToLegacyDevice() method for backwards compatibility

- [x] 2.2 Create OCSF type inference in `pkg/registry/ocsf_type_inference.go`
  - [x] 2.2.1 Implement InferOCSFTypeID(metadata) returning type_id and type string
  - [x] 2.2.2 Add inference rules for router, switch, firewall, server, IoT
  - [x] 2.2.3 Add unit tests for type inference
  - [x] 2.2.4 Use exported DeviceTypeName* constants for string names

- [x] 2.3 Create CNPG client for OCSF devices in `pkg/db/cnpg_ocsf_devices.go`
  - [x] 2.3.1 Implement UpsertOCSFDevice method
  - [x] 2.3.2 Implement GetOCSFDevice(uid) method
  - [x] 2.3.3 Implement GetOCSFDevicesByIP and GetOCSFDevicesByIPsOrIDs methods
  - [x] 2.3.4 Implement ListOCSFDevices with filtering
  - [x] 2.3.5 Implement DeleteOCSFDevice method (delegates to DeleteDevices)
  - [x] 2.3.6 Refactor scanOCSFDevice to reduce cyclomatic complexity

- [x] 2.4 Update code to use OCSF methods
  - [x] 2.4.1 Update pkg/core/identity_lookup.go to use GetOCSFDevice/GetOCSFDevicesByIPsOrIDs
  - [x] 2.4.2 Update pkg/core/alias_events.go to use OCSF methods and fields
  - [x] 2.4.3 Update pkg/core/result_processor.go with canonicalSnapshotFromOCSFDevice
  - [x] 2.4.4 Update pkg/core/stats_aggregator.go to use OCSF methods
  - [x] 2.4.5 Update pkg/core/metrics.go to use OCSF methods
  - [x] 2.4.6 Update pkg/db/devices.go to use OCSF methods with ToLegacyDevice()
  - [x] 2.4.7 Update pkg/core/api/device_registry.go with populateFromOCSF helper

## 3. Unified Devices Migration Status

- [x] 3.1 pkg/db/cnpg_unified_devices.go KEPT for in-memory registry compatibility
  - The DeviceRegistry in pkg/registry/ still uses UnifiedDevice type for in-memory cache
  - unifiedDevicesSelection query provides backward-compat SQL aliases
  - Functions cnpgGetUnifiedDevice, cnpgGetUnifiedDevicesByIP still needed for registry
- [x] 3.2 All pkg/core code migrated to OCSF methods
  - Verified: `grep GetUnifiedDevicesByIPsOrIDs pkg/core` returns NO matches
- [x] 3.3 All test mocks updated to use OCSF methods
  - pkg/core/alias_events_test.go
  - pkg/core/identity_lookup_test.go
  - pkg/core/metrics_test.go
  - pkg/core/stats_aggregator_test.go
  - pkg/core/performance_integration_test.go
  - pkg/core/server_test.go

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

- [x] 8.1 All pkg/core tests passing with OCSF mocks
- [x] 8.2 All pkg/db tests passing
- [x] 8.3 Type inference tests working
- [ ] 8.4 Add SRQL tests for OCSF device queries
- [ ] 8.5 E2E test: device discovery flows to OCSF table correctly
