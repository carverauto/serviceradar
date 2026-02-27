## 1. Spec and Contract Alignment
- [x] 1.1 Add `network-discovery` requirements for directional topology edge telemetry fields (`*_ab`, `*_ba`) and fallback semantics when only one side is available.
- [x] 1.2 Add `build-web-ui` requirements for God-View directional rendering and PoC-like particle density/tube-fill behavior.
- [x] 1.3 Validate the change with `openspec validate add-god-view-directional-edge-telemetry --strict`.

## 2. Test-First Coverage (TDD Gate)
- [x] 2.1 Add failing tests that prove SNMP-attributed links (LLDP/CDP/SNMP-L2) win over UniFi-API links for telemetry-bearing canonical edges.
- [x] 2.2 Add failing tests that UniFi-API-only links without interface attribution are marked telemetry-ineligible (still rendered structurally).
- [x] 2.3 Add failing tests for directional A→B/B→A mapping semantics and one-sided fallback.
- [x] 2.4 Add failing tests for discovery bootstrap/reconciliation of required SNMP interface OIDs for topology-linked interfaces.
- [x] 2.5 Execute focused test suites and confirm failures match expected unimplemented behavior.

## 3. Backend Directional Telemetry Pipeline
- [x] 3.1 Keep existing SNMP collection unchanged and update topology edge enrichment to attribute existing `ifIn*`/`ifOut*` rates per edge side instead of only aggregate values.
- [x] 3.2 Extend NIF telemetry structs and Arrow snapshot schema to encode/decode directional edge fields.
- [x] 3.3 Ensure canonical edge deduplication preserves both directional values on the merged edge object.
- [x] 3.4 Add regression tests for: both-sided telemetry, one-sided telemetry, absent directional telemetry, and canonical endpoint-order invariance.
- [x] 3.5 Add regression tests for packet/bit rate unit conversions so interface rates align with expected Mbps/Kbps values in edge telemetry.

## 4. Topology Telemetry Coverage Bootstrap
- [x] 4.1 Add mapper/discovery setting to auto-enable required interface metrics for topology telemetry (default enabled).
- [x] 4.2 Implement reconciliation that ensures topology-linked interfaces have required SNMP OID configs (`ifIn/OutOctets` + `ifIn/OutUcastPkts`, HC variants when supported).
- [x] 4.3 Add tests for bootstrap/reconciliation behavior, including idempotent updates and no-op when already configured.
- [x] 4.4 Ensure SNMP topology discovery runs LLDP/CDP and SNMP-L2 enrichment in the same pass (no LLDP short-circuit).
- [x] 4.5 Add tests proving non-LLDP neighbors are still discovered/attributed when LLDP neighbors exist on the same device.

## 5. God-View Frontend Rendering
- [x] 5.1 Remove synthetic bidirectional flow splitting and render reverse streams only when real directional fields exist.
- [x] 5.2 Implement directional lane rendering using real telemetry ratios while preserving single-direction fallback.
- [x] 5.3 Tune particle generation to maintain PoC-like density and tube coverage across zoom tiers.
- [x] 5.4 Add/adjust tests for directional rendering behavior and density constraints.

## 6. Verification in Demo Namespace
- [x] 6.1 Verify directional metric availability per topology edge side in demo CNPG (`timeseries_metrics` + mapper topology links).
- [x] 6.2 Validate endpoint/interface mapping for known links (e.g. aggregation-switch uplinks) and confirm edge telemetry matches expected interface rates.
- [ ] 6.3 Validate God-View behavior in demo: no fake bidi, correct directional rendering on eligible edges, graceful fallback on incomplete edges.
- [x] 6.4 Verify a reduced count of `UniFi-API` links with `local_if_index=0` for switch/AP and switch/switch paths after SNMP-L2 enrichment changes.
- [x] 6.5 Verify topology-linked interfaces on key devices are auto-provisioned with required packet/octet OIDs without manual per-interface toggles.
- [ ] 6.6 Validate lane centering/split behavior against live telemetry so directional particles stay centered on their tube and render one-lane only when truly one-sided.
- [x] 6.7 Validate link label telemetry (`flow_pps`/`flow_bps`/capacity) is populated from canonical directional totals and no widespread `UNK` rate regressions occur after stream/schema changes.
- [x] 6.8 Run repeated refresh/reconcile soak validation in demo (minimum 30 minutes) to confirm directional animations do not randomly disappear on stable links.

## Verification Notes (2026-02-24)
- Demo CNPG confirms directional interface telemetry exists in `platform.timeseries_metrics` for active topology-linked ports (`ifIn/OutOctets`, `ifIn/OutUcastPkts`) with recent timestamps.
- Aggregation/pro switch uplink checks show mapper topology is currently asymmetric for those links: LLDP rows carry `local_if_index` on Pro24 side (e.g. 25/26), while aggregation side is still largely UniFi rows with `local_if_index=0`.
- Metric values in CNPG for known interfaces are in-family with direct SNMP spot checks (e.g. multi-Mbps octet throughput and hundreds of PPS on active uplinks), indicating unit conversion path is no longer the primary issue.
- Raw topology evidence still includes many UniFi unattributed edges in the last 90 minutes (`switch-switch`: 72 with `if_index=0`; `switch-ap`: 90 with `if_index=0`), so reduction goal is not yet met despite SNMP-L2 coexistence.
- Auto-bootstrap is confirmed on topology-attributed interfaces (settings present with required packet/octet metrics enabled), but interfaces missing topology attribution (no positive `local_if_index` edge evidence) remain unprovisioned.
- Demo agent logs show repeated SNMP timeouts for `192.168.1.87` (`SNMP get failed ... request timeout`), which likely explains missing SNMP-attributed topology evidence from the aggregation side and continued dependence on UniFi unattributed rows for that endpoint.

## Verification Notes (2026-02-27)
- `web-ng` log soak (`--since=35m`) remained stable with no `snapshot build failed`, no `runtime_graph_refresh_failed`, and no `invalid_edge_schema` markers.
- Over the same soak window, all sampled `god_view_pipeline_stats` lines stayed at `connected_components: 1`, `final_nodes: 14`, `final_edges: 13`, `final_direct: 13`, `final_inferred: 0`, `edge_telemetry_interface: 12`, `edge_telemetry_fallback: 0`, and `edge_unresolved_directional: 0`.
- Over the same soak window, all sampled `runtime_graph_refresh` lines stayed at `fetched=13 normalized=13 dropped=0 ingested=13`.
- CNPG canonical-edge telemetry completeness check: `total=45`, `null_flow_pps=0`, `null_flow_bps=0`, `null_capacity=0`, `telemetry_true=44`, `telemetry_false=1`, with only one unattributed UniFi edge (`telemetry_source='none'`, `single_identifier_inference`).
- Canonical label-field population check from AGE: `zero_capacity=2`, `zero_flow_bps=1`, `zero_flow_pps=2`, `telemetry_none=1`; indicates no widespread label telemetry regression after stream/schema updates.
