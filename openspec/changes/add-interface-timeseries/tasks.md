## 1. Design + Schema
- [x] 1.1 Define the interface observation schema (columns, types, required fields).
- [x] 1.2 Decide the interface identity key (device_id + if_index + if_name fallback) and document it.
- [x] 1.3 Add a migration to create/extend the interface observations table and convert it to a TimescaleDB hypertable.
- [x] 1.4 Add a 3-day retention policy for the interface hypertable.

## 2. Ingestion
- [x] 2.1 Update mapper payloads to include interface type fields (if_type, if_type_name, interface_kind) plus system interface metadata.
- [x] 2.2 Update core ingestion to store interface observations in the time-series table.
- [x] 2.3 Ensure interface ingestion still registers MAC identifiers for DIRE reconciliation.

## 3. SRQL
- [x] 3.1 Update `in:interfaces` to read from the interface time-series table.
- [x] 3.2 Add filters for the new interface fields (if_type, if_type_name, interface_kind, mtu, duplex, speed, admin_status, oper_status).
- [x] 3.3 Add a “latest snapshot per interface” query path for the UI use-case.

## 4. Web UI
- [x] 4.1 Update device details to fetch interfaces via SRQL `in:interfaces device_id:"<uid>"`.
- [x] 4.2 Show the Interfaces tab only when SRQL returns interface rows.

## 5. Documentation
- [x] 5.1 Document OCSF version alignment in README (device inventory only).
- [x] 5.2 Document the custom interface schema and retention behavior.

## 6. Tests
- [ ] 6.1 Add SRQL tests for interface filters and latest snapshot query.
- [ ] 6.2 Add ingestion test coverage for interface fields (mapper -> core -> CNPG).
