## 1. Snapshot schema 3
- [x] 1.1 Widen `edge_source` and `edge_target` to `UInt32`, and bump `GodViewSnapshot` `@schema_version` to 3 along with every exact-version check and fixture.
- [x] 1.2 Emit node rows before edge rows, with `node_count`/`edge_count` schema metadata, so numeric columns are dense.
- [x] 1.3 Promote per-row details keys to typed `node_detail_*`, `edge_detail_*` and `edge_metadata_*` columns derived from the shipped JSON, plus `details_irregular`.
- [x] 1.4 Add a NIF round-trip test for endpoint indexes above 65535, and a snapshot test for schema 3.

## 2. Client columnar path
- [x] 2.1 Decode positions, state and endpoints into typed arrays, and pack positions to `Float32Array` once per snapshot.
- [x] 2.2 Feed node glyph layers deck.gl binary attributes, and pass the state column to the Wasm masks.
- [x] 2.3 Serve column-backed details keys from columns, and parse details JSON only for other keys.
- [x] 2.4 Keep filter, hover, selection and camera changes from rebuilding per-node records, with tests on the decode, first render and filter parse counter.

## 3. WebGPU only
- [x] 3.1 Construct Deck with a WebGPU device request, and record `rendererMode` from the created device.
- [x] 3.2 Remove the WebGL fallback Deck. Show the WebGPU-required and renderer-stopped states on an unsupported client, a failed device request, device loss or an uncaptured device error.
- [x] 3.3 Use device-neutral GPU parameters for every God-View layer.
- [x] 3.4 Run the ELK scene acceptance suite on WebGPU at default device limits with packet flow on, including a live-animation responsiveness test.
- [x] 3.5 Fix WebGPU picking so hover/click resolve the node under the pointer, not its vertically mirrored counterpart, with a test covering the top, bottom, left, right and middle glyphs.

## 4. GPU packet flow
- [x] 4.1 Port the packet-flow layer to WGSL, drawn from per-edge instances within the default vertex-buffer limit.
- [x] 4.2 Animate by advancing a time uniform only, with no per-frame graph or layer-data rebuild.
- [x] 4.3 Pin visual parity with the previous per-particle formulas in a unit test, and compare against staging in real-GPU screenshots.

## 5. Dependencies and verification
- [x] 5.1 Bump `@deck.gl/*` to 9.4.0 and `@luma.gl/*` to 9.4.2, and regenerate `bun.lock` and `pnpm-lock.yaml`.
- [x] 5.2 Verify on a real WebGPU device (Apple Metal): 70,000 nodes and 139,470 edges render, details parse count is 0 until a pick, and packet flow animates at 60 fps at 2,000 nodes.
