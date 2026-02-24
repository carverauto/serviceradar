## 1. Spec and Contract Alignment
- [ ] 1.1 Add `network-discovery` requirements for directional topology edge telemetry fields (`*_ab`, `*_ba`) and fallback semantics when only one side is available.
- [ ] 1.2 Add `build-web-ui` requirements for God-View directional rendering and PoC-like particle density/tube-fill behavior.
- [ ] 1.3 Validate the change with `openspec validate add-god-view-directional-edge-telemetry --strict`.

## 2. Test-First Coverage (TDD Gate)
- [ ] 2.1 Add failing tests that prove SNMP-attributed links (LLDP/CDP/SNMP-L2) win over UniFi-API links for telemetry-bearing canonical edges.
- [ ] 2.2 Add failing tests that UniFi-API-only links without interface attribution are marked telemetry-ineligible (still rendered structurally).
- [ ] 2.3 Add failing tests for directional A→B/B→A mapping semantics and one-sided fallback.
- [ ] 2.4 Add failing tests for discovery bootstrap/reconciliation of required SNMP interface OIDs for topology-linked interfaces.
- [ ] 2.5 Execute focused test suites and confirm failures match expected unimplemented behavior.

## 3. Backend Directional Telemetry Pipeline
- [ ] 3.1 Keep existing SNMP collection unchanged and update topology edge enrichment to attribute existing `ifIn*`/`ifOut*` rates per edge side instead of only aggregate values.
- [ ] 3.2 Extend NIF telemetry structs and Arrow snapshot schema to encode/decode directional edge fields.
- [ ] 3.3 Ensure canonical edge deduplication preserves both directional values on the merged edge object.
- [ ] 3.4 Add regression tests for: both-sided telemetry, one-sided telemetry, absent directional telemetry, and canonical endpoint-order invariance.
- [ ] 3.5 Add regression tests for packet/bit rate unit conversions so interface rates align with expected Mbps/Kbps values in edge telemetry.

## 4. Topology Telemetry Coverage Bootstrap
- [ ] 4.1 Add mapper/discovery setting to auto-enable required interface metrics for topology telemetry (default enabled).
- [ ] 4.2 Implement reconciliation that ensures topology-linked interfaces have required SNMP OID configs (`ifIn/OutOctets` + `ifIn/OutUcastPkts`, HC variants when supported).
- [ ] 4.3 Add tests for bootstrap/reconciliation behavior, including idempotent updates and no-op when already configured.
- [ ] 4.4 Ensure SNMP topology discovery runs LLDP/CDP and SNMP-L2 enrichment in the same pass (no LLDP short-circuit).
- [ ] 4.5 Add tests proving non-LLDP neighbors are still discovered/attributed when LLDP neighbors exist on the same device.

## 5. God-View Frontend Rendering
- [ ] 5.1 Remove synthetic bidirectional flow splitting and render reverse streams only when real directional fields exist.
- [ ] 5.2 Implement directional lane rendering using real telemetry ratios while preserving single-direction fallback.
- [ ] 5.3 Tune particle generation to maintain PoC-like density and tube coverage across zoom tiers.
- [ ] 5.4 Add/adjust tests for directional rendering behavior and density constraints.

## 6. Verification in Demo Namespace
- [ ] 6.1 Verify directional metric availability per topology edge side in demo CNPG (`timeseries_metrics` + mapper topology links).
- [ ] 6.2 Validate endpoint/interface mapping for known links (e.g. aggregation-switch uplinks) and confirm edge telemetry matches expected interface rates.
- [ ] 6.3 Validate God-View behavior in demo: no fake bidi, correct directional rendering on eligible edges, graceful fallback on incomplete edges.
- [ ] 6.4 Verify a reduced count of `UniFi-API` links with `local_if_index=0` for switch/AP and switch/switch paths after SNMP-L2 enrichment changes.
- [ ] 6.5 Verify topology-linked interfaces on key devices are auto-provisioned with required packet/octet OIDs without manual per-interface toggles.
