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

## 3. Legacy UnifiedDevice Removal (COMPLETED)

- [x] 3.1 Migrate registry to use OCSF types
  - [x] 3.1.1 Update pkg/registry/device_transform.go to use OCSFDevice converters
  - [x] 3.1.2 Remove legacy DeviceRecordFromUnified, UnifiedDeviceFromRecord functions
  - [x] 3.1.3 Add DeviceRecordFromOCSF, OCSFDeviceFromRecord, OCSFDeviceSlice functions
  - [x] 3.1.4 Update device_transform_test.go with OCSF-focused tests
- [x] 3.2 Update database interface
  - [x] 3.2.1 Replace LockUnifiedDevices with LockOCSFDevices in interfaces.go
  - [x] 3.2.2 Remove legacy GetUnifiedDevice, GetUnifiedDevicesByIP methods
  - [x] 3.2.3 Remove CountUnifiedDevices (use CountOCSFDevices)
  - [x] 3.2.4 Regenerate mocks with go generate
- [x] 3.3 Delete legacy database files
  - [x] 3.3.1 Create pkg/db/cnpg_device_updates.go with needed helpers
  - [x] 3.3.2 Delete pkg/db/cnpg_unified_devices.go
  - [x] 3.3.3 Delete pkg/db/unified_devices.go
  - [x] 3.3.4 Remove legacy error definitions from errors.go
- [x] 3.4 Consolidate model files
  - [x] 3.4.1 Merge DiscoverySource types from unified_device.go into discovery.go
  - [x] 3.4.2 Delete pkg/models/unified_device.go
- [x] 3.5 Update all tests to use OCSF methods
  - [x] 3.5.1 Update pkg/registry/retraction_processing_test.go (LockOCSFDevices)
  - [x] 3.5.2 Update pkg/registry/batch_optimization_test.go (LockOCSFDevices)
  - [x] 3.5.3 Update pkg/registry/hydrate_test.go (LockOCSFDevices)
  - [x] 3.5.4 Update pkg/registry/service_device_test.go (LockOCSFDevices)
  - [x] 3.5.5 Update tests/e2e/inventory/inventory_test.go (CountOCSFDevices)
- [x] 3.6 Verify no UnifiedDevice references remain
  - grep confirms zero matches in .go files

## 4. SRQL Updates

- [x] 4.1 Update SRQL schema in `rust/srql/`
  - [x] 4.1.1 Remove unified_devices from Diesel schema
  - [x] 4.1.2 Add ocsf_devices table to Diesel schema
  - [x] 4.1.3 Define OCSFDevice model struct

- [x] 4.2 Update query planner for OCSF table
  - [x] 4.2.1 Update device queries to use ocsf_devices
  - [x] 4.2.2 Support JSONB path queries for nested objects (os, hw_info)
    - Added `os.name`, `os.version`, `os.type` filters
    - Added `hw_info.serial_number`, `hw_info.cpu_type`, `hw_info.cpu_architecture` filters
    - Added dynamic `metadata.*` filters for arbitrary JSONB keys
    - Supports equality (=), inequality (!=), and LIKE operations
  - [x] 4.2.3 Add type_id filtering support

## 5. API Layer

- [x] 5.1 Update device API responses
  - [x] 5.1.1 Return OCSF-shaped device JSON from device endpoints
  - [x] 5.1.2 Ensure field names match OCSF spec (snake_case per OCSF standard)

- [x] 5.2 Add OCSF export endpoint
  - [x] 5.2.1 Create `/api/devices/ocsf/export` endpoint
  - [x] 5.2.2 Support filtering by type_id, time range
  - [x] 5.2.3 Add pagination for large exports

## 6. Web-ng Updates

- [x] 6.1 Update device list component
  - [x] 6.1.1 Display `type` instead of legacy device_type
  - [x] 6.1.2 Add vendor_name and model columns
  - [x] 6.1.3 Add risk_level indicator

- [x] 6.2 Update device detail view
  - [x] 6.2.1 Display OS information from `os` JSONB
  - [x] 6.2.2 Display hardware info from `hw_info` JSONB
  - [x] 6.2.3 Display network interfaces
  - [x] 6.2.4 Display compliance/management status flags

- [x] 6.3 Add device type filtering
  - [x] 6.3.1 Add type_id filter dropdown with OCSF types (via SRQL)
  - [x] 6.3.2 Add type icons for visual identification

## 7. Documentation

- [x] 7.1 Document OCSF schema in `docs/docs/ocsf-device-schema.md`
- [x] 7.2 Update architecture docs with new data model (included in ocsf-device-schema.md)
- [x] 7.3 Document OCSF export endpoint usage (included in ocsf-device-schema.md)

## 8. Testing

- [x] 8.1 All pkg/core tests passing with OCSF mocks
- [x] 8.2 All pkg/db tests passing
- [x] 8.3 Type inference tests working
- [x] 8.4 Add SRQL tests for OCSF device queries
  - Added 7 new test cases in comprehensive_queries.rs
  - Tests cover: os.name, os.version, metadata.site, metadata.packet_loss_bucket
  - Tests cover: JSONB equality, LIKE patterns, combined filters
- [x] 8.5 E2E test: device discovery flows to OCSF table correctly
  - tests/e2e/inventory/inventory_test.go uses CountOCSFDevices
  - Added validateOCSFDeviceStructure() for OCSF field validation
  - Verifies UID, temporal fields, type_id, vendor_name are populated
