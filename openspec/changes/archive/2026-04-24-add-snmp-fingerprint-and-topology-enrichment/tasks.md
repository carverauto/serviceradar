## 1. Mapper SNMP fingerprint collection
- [x] 1.1 Define canonical `snmp_fingerprint` struct and protobuf payload fields.
- [x] 1.2 Collect system fields (`sysName`, `sysDescr`, `sysObjectID`, `sysContact`, `sysLocation`, `ipForwarding`) with resilient type conversion.
- [x] 1.3 Collect bridge fields (`dot1dBaseBridgeAddress`, bridge port/stp summaries).
- [x] 1.4 Collect VLAN evidence (`dot1q` table summaries and per-port membership evidence when available).
- [x] 1.5 Emit partial fingerprints when some tables are unsupported; never fail the whole device discovery for missing optional tables.

## 2. Core ingestion and enrichment integration
- [x] 2.1 Ingest `snmp_fingerprint` into mapper results pipeline and persist normalized metadata.
- [x] 2.2 Update enrichment rule evaluation inputs to consume fingerprint fields directly.
- [x] 2.3 Populate inventory SNMP metadata fields consistently (`snmp_name`, `snmp_owner`, `snmp_location`, `snmp_description`).
- [x] 2.4 Add deterministic fallback vendor/type/model derivation path when explicit rule result is absent.

## 3. Topology confidence and AGE projection
- [x] 3.1 Add topology confidence scoring for LLDP/CDP/bridge-derived links.
- [x] 3.2 Project only eligible confidence tiers to AGE and keep low-confidence links as evidence only.
- [x] 3.3 Ensure idempotent upserts and stale-link cleanup by observation timestamp.

## 4. UI changes
- [x] 4.1 Update device details to present SNMP identity fields with clear provenance.
- [x] 4.2 Update inventory list fallback rendering for vendor/type/model quality.
- [x] 4.3 Add/adjust tests for device list/detail rendering of enrichment and SNMP fallback states.

## 5. Validation and tests
- [x] 5.1 Add unit tests for SNMP fingerprint extraction and conversion edge cases.
- [x] 5.2 Add integration tests for Ubiquiti router/switch/AP differentiation using real captured payload fixtures.
- [x] 5.3 Add regression tests for duplicate-device prevention when multiple interface/IP aliases are present.
- [x] 5.4 Add topology tests for confidence scoring, idempotent edge upsert, and stale edge pruning.
- [x] 5.5 Run `openspec validate add-snmp-fingerprint-and-topology-enrichment --strict`.
