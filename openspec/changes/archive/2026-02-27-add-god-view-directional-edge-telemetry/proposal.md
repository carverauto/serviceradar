# Change: Add real directional edge telemetry for God-View topology flows

## Why
God-View currently animates topology flow using aggregate edge telemetry (`flow_pps`, `flow_bps`, `capacity_bps`). This prevents true per-direction rendering and has forced temporary UI-side synthetic splitting for bidirectional effects. We already collect directional interface counters (`ifIn*` / `ifOut*`) for these links, so the gap is attribution and propagation, not collection. In addition, visual parity with the deckgl PoC requires denser, tube-aligned particle streams with consistent behavior across zoom levels.

Recent demo investigation confirmed two additional root causes that must be captured in scope:
- Topology discovery currently treats SNMP-L2 as a fallback behind LLDP/CDP in a way that can skip additional neighbors that do not advertise LLDP/CDP.
- SNMP OID coverage is largely driven by per-interface `interface_settings` selections, leaving many topology-linked ports without packet/octet counters and therefore without usable edge telemetry.

## What Changes
- Keep existing SNMP interface metric collection unchanged.
- Treat SNMP-derived topology evidence (LLDP/CDP/SNMP-L2 with interface attribution) as authoritative for telemetry-bearing topology edges.
- Keep UniFi-API topology evidence as discovery/enrichment context and only use it for telemetry when usable interface attribution is present.
- Add directional edge telemetry fields to the God-View topology telemetry contract (A→B and B→A packet/bit rates).
- Attribute existing interface directional counters to canonical topology edge directions and preserve those values through enrichment/snapshot encoding rather than collapsing to a single aggregate edge flow.
- Require God-View UI to render directional particle streams only from real directional telemetry (no synthetic bidirectional splitting).
- Add visual parity requirements for packet density/tube fill behavior so production God-View matches PoC readability.
- Define explicit fallback behavior when directional telemetry is incomplete on an edge.
- Add mapper/discovery controls to auto-bootstrap required SNMP interface metrics for topology edges so links are telemetry-eligible without per-interface manual setup.
- Require SNMP topology discovery to publish LLDP/CDP evidence and still execute SNMP-L2 enrichment in the same pass (no LLDP short-circuit), so non-LLDP neighbors can still be telemetry-attributed.

## Impact
- Affected specs:
  - `network-discovery`
  - `build-web-ui`
- Affected code (expected):
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex`
  - `elixir/web-ng/native/god_view_nif/src/lib.rs`
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/*`
  - `elixir/serviceradar_core/lib/serviceradar/inventory/changes/sync_snmp_interface_config.ex`
  - `elixir/web-ng/assets/js/lib/god_view/*`
  - `elixir/web-ng/assets/js/lib/deckgl/PacketFlowLayer.js`
- Data model impact:
  - God-View edge telemetry payload shape expands with directional fields.
  - No new telemetry collectors or polling jobs are introduced.
  - UniFi-API-only edges without interface attribution are modeled as non-telemetry edges in God-View payload semantics.
  - Mapper topology discovery behavior is tightened to always include SNMP-L2 enrichment alongside LLDP/CDP when available.

## Follow-up Focus (2026-02-26)
- Complete demo validation for real-bidi rendering parity on all telemetry-eligible links.
- Close remaining UX regressions tied to directional rendering stability (lane centering, intermittent animation loss, `UNK` rate labels).
- Keep directional behavior backend-driven only; no synthetic front-end bidirectional reconstruction.
