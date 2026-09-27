# Change: Adopt columnar snapshots and WebGPU-only rendering for God-View

## Why
God-View threw its Arrow snapshot away before drawing it. The client turned every node and
edge into a JavaScript object and parsed each row's `node_details` / `edge_details` JSON.
deck.gl then walked those objects to build its attribute buffers. `edge_source` and
`edge_target` were `UInt16`, so a snapshot could not name node 65536. `rendererMode` said
`webgpu` whenever `navigator.gpu` existed, but Deck was built without `deviceProps` and ran on
WebGL, so the label was not true (carverauto/serviceradar#4749).

The existing spec already asks for WebGPU, Wasm over Arrow-backed memory and no per-node
JavaScript on the interaction path. This change makes the implementation meet that. The
product decision is to render God-View with WebGPU only; maintaining a WebGL mode as well is
not wanted.

## What Changes
- **Snapshot schema version 3.**
  - `edge_source` and `edge_target` widen to `UInt32`.
  - Node rows come first and edge rows follow. `node_count` and `edge_count` in the schema
    metadata make every numeric column dense, so positions, states and endpoints are sliced
    without branching on `row_type`.
  - The details keys that render, filter, cluster, label and layout read for every row are
    promoted to typed `node_detail_*`, `edge_detail_*` and `edge_metadata_*` columns.
    `details_irregular` flags a row whose value a column cannot carry exactly.
  - Layout coordinates stay quantized `UInt16`.
- **Client decode into typed columns.**
  - Positions are packed to `Float32Array` once per snapshot.
  - Node glyph layers take deck.gl binary attributes.
  - The Wasm masks receive the state column directly.
  - `details` JSON is parsed only when a key outside the columns is read, which in practice
    means for the picked node or edge.
  - The object graph ELK needs is still built once per snapshot.
- **WebGPU only.**
  - Deck is constructed with a WebGPU `deviceProps` request, and `rendererMode` reflects the
    device actually created.
  - An unsupported browser, a failed adapter or device request, a lost device, or an
    uncaptured device error shows a "WebGPU required" / renderer-stopped state. There is no
    WebGL fallback renderer.
- **GPU packet flow.**
  - The packet-flow layer is WGSL and draws each edge's particles from a per-edge instance.
  - Each particle's placement, speed, size, colour and jitter follow the formulas of the
    previous per-particle builder, so the look is unchanged.
  - The layer uses at most the WebGPU default of 8 vertex buffers.
  - Animation advances a time uniform and never rebuilds the graph or layer data per frame.
  - The previous global 60,000-particle cap, which left later edges without particles, is
    removed. Density is thinned evenly past a per-frame budget instead.
- **Hover and select** reuse the last render's node records and edge data and re-issue only
  the affected layers.
- **Dependencies:** deck.gl 9.4.0 and luma.gl 9.4.2 for all web-ng deck consumers.

## Impact
- Affected specs: `topology-god-view`: Versioned Binary Topology Snapshots, GPU Rendering
  Engine and JavaScript GC Pressure Guardrail are MODIFIED; GPU Packet Flow Rendering is ADDED.
- Affected code:
  - `elixir/web-ng/native/god_view_nif/src/core/{arrow_serde,snapshot_details}.rs`
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/{god_view_snapshot,god_view_stream}.ex`
  - `elixir/web-ng/assets/js/lib/god_view/*`
  - `elixir/web-ng/assets/js/lib/deckgl/PacketFlowLayer.js`
  - `elixir/web-ng/assets/package.json` and the lockfiles
- **Breaking:** snapshot schema 2 clients are rejected by the exact-version check, and
  browsers without WebGPU no longer render God-View.
- **Coordination:** `refactor-god-view-elk-scene` carries a MODIFIED copy of "Versioned
  Binary Topology Snapshots". This change updates that copy to the same schema-3 text, so
  whichever change archives last does not restore schema 1.
- **Follow-up:** scaling past bounded snapshots to 200k–1M+ devices is carverauto/serviceradar#4774 (tile engine).
