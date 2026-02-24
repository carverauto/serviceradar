# Change: Add real directional edge telemetry for God-View topology flows

## Why
God-View currently animates topology flow using aggregate edge telemetry (`flow_pps`, `flow_bps`, `capacity_bps`). This prevents true per-direction rendering and has forced temporary UI-side synthetic splitting for bidirectional effects. In addition, visual parity with the deckgl PoC requires denser, tube-aligned particle streams with consistent behavior across zoom levels.

## What Changes
- Add directional edge telemetry fields to the God-View topology telemetry contract (A→B and B→A packet/bit rates).
- Preserve directional values through enrichment and snapshot encoding rather than collapsing to a single aggregate edge flow.
- Require God-View UI to render directional particle streams only from real directional telemetry (no synthetic bidirectional splitting).
- Add visual parity requirements for packet density/tube fill behavior so production God-View matches PoC readability.
- Define explicit fallback behavior when directional telemetry is incomplete on an edge.

## Impact
- Affected specs:
  - `network-discovery`
  - `build-web-ui`
- Affected code (expected):
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex`
  - `elixir/web-ng/native/god_view_nif/src/lib.rs`
  - `elixir/web-ng/assets/js/lib/god_view/*`
  - `elixir/web-ng/assets/js/lib/deckgl/PacketFlowLayer.js`
- Data model impact:
  - God-View edge telemetry payload shape expands with directional fields.
