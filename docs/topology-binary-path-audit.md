# ServiceRadar Atlas binary path audit

The tiled overview transports geometry as bounded Arrow IPC and validates typed
detail columns before rendering. It still performs avoidable JSON conversions
on the producer and several CPU copies in the browser. The overview uses the
JavaScript Arrow decoder and deck.gl directly; WASM serves the bounded scene
renderer, not the tiled overview.

## Current ownership and copies

| Boundary | Current behavior | Follow-up |
| --- | --- | --- |
| Native atlas to tile producer | The NIF returns bounded glyph/edge records as BEAM terms. [WorldTile](../elixir/web-ng/lib/serviceradar_web_ng/topology/world_tile.ex) JSON-encodes details; the [Arrow detail encoder](../elixir/web-ng/native/god_view_nif/src/core/snapshot_details.rs) parses those strings back into typed fields. | Provide a typed tile encoder at the native boundary, retaining selection handles and budgets. |
| Arrow encoding | `WorldTile.encode/3` encodes once to derive the revision and again with revision metadata. [vec_into_binary](../elixir/web-ng/native/god_view_nif/src/core/arrow_serde.rs) allocates an OwnedBinary and copies the encoded Vec into it. | Measure and remove duplicate encoding/allocation while preserving deterministic content revisions and ETag validation. |
| HTTP body to Arrow | [readBoundedBody](../elixir/web-ng/assets/js/lib/god_view/world_http.js) collects chunks and copies them into one array, including a single-chunk response. `tableFromIPC` receives that binary. | Reuse a single chunk; retain the streamed byte limit and cancellation behavior for multi-chunk responses. |
| Arrow columns to geometry | [decodeSnapshotTable](../elixir/web-ng/assets/js/lib/god_view/snapshot_columns.js) copies numeric columns through `packInto`. [decodeWorldTile](../elixir/web-ng/assets/js/lib/god_view/world_tile_decode.js) expands UInt16 coordinates into Float64 positions and creates node/edge objects. Valid tiles require `details_irregular=0`, so their details use typed readers. | Use validated column views where types, nullability and lifetimes permit. Avoid materializing fields the overview does not consume. |
| Geometry to render attributes | [WorldTileLayer](../elixir/web-ng/assets/js/lib/god_view/world_tile_layer.js) gathers edge endpoint arrays and node records; [node glyph packing](../elixir/web-ng/assets/js/lib/god_view/rendering_node_frame.js) creates another Float32 position array. Geometry is cached, but cold tiles pay these costs. | Share packed attributes, then evaluate shader-side tile transforms and indexed edge lookup. Preserve picking, precision and label placement. |
| WASM scene operations | [GodViewWasmEngine](../elixir/web-ng/assets/js/wasm/god_view_exec_runtime.js) copies inputs into linear memory and copies outputs before freeing them. | Use explicit owned buffers if measurements justify a WASM operation. Routing overview geometry through WASM alone would add copies. |
| Health and flow | Whenever Atlas is enabled, [WorldOverlays](../elixir/web-ng/assets/js/lib/god_view/world_overlays.js) receives bounded SRTO binary fields for admitted tile rows. The server encodes and caches bytes once; the browser uses lazy DataView readers. There is no separate JSON overlay switch. | Evaluate native Arrow IPC encoding with schema metadata for receipt binding, reusing the browser's Arrow decoder and validity bitmaps. Compare retained bytes, encode/decode cost and GPU staging before replacing the fixed codec. |
| Query membership | Server-side Roaring evaluates one authorized revision; native projection produces bounded SRMO matching/state/count columns for admitted Arrow rows. Three u8 columns view the received buffer; unaligned u32 counts require an aligned copy. | Complete current-policy channel, multi-view and hardware acceptance. Keep native selector scratch separate from wire bytes. |

GPU upload remains an explicit ownership boundary. The portable WebGPU API does
not expose an arbitrary fetched ArrayBuffer as GPU storage; physical placement
and copying depend on the browser and adapter. Optimize application copies and
uploads rather than claiming an end-to-end zero-copy guarantee. See the
[GPUWeb memory and process model](https://gpuweb.github.io/gpuweb/explainer/#memory-visibility).
Label shaping and metadata inspection also have CPU work distinct from numeric
geometry upload.

Filtered glyphs now also set stroke width to zero, alongside radius and minimum
pixel width, because transparent color alone does not remove WebGPU picking
geometry. This reuses the admitted Arrow rows and their original positions;
there is no filtered position-array copy. The per-row Float32 stroke attribute
adds bounded CPU/GPU style storage covered by the existing per-tile allowance.
Retention counters are admission charges, not a JavaScript heap census: Deck's
shared typed-array pool can retain released CPU allocations, and textures are
outside the buffer counters. Actual device/buffer destruction and public picking
are separate executable checks.

## Scale evidence and gaps

The production tile contract limits each response to 128 glyphs, 512 edges and
256 KiB. View selection admits at most 64 tiles and four geometry requests at
once. The browser cache enforces 64 entries and a 32 MiB estimated budget; its
estimate is `encodedBytes * 8 + 4096` per tile, rather than measured retained
JavaScript and GPU allocations. These bounds constrain viewport work as the
inventory grows, but do not establish whole-system throughput or memory use.

The server maintains whole-world indexes. A trusted parent-tree change now
requires a staged full layout, with the accepted world available until atomic
activation. Observation timestamps no longer break equal-trust forest ties.
At large inventory sizes, measure rebuild duration, simultaneous old/new world
memory, publication/reload cost and churn recovery as well as tile latency.

The [existing million-device acceptance report](god-view-world-acceptance.md)
documents a synthetic hierarchy, database persistence and browser navigation.
Its physical-GPU measurements predate the restored ELK geometry and current
edge budget. Its browser transport simulates the channel and telemetry overlays.
Those results therefore leave current full-path ingestion, overlay freshness,
concurrent viewers and sustained topology churn unproven.

Use invented 100k-infrastructure/1M-endpoint workloads for the next acceptance
pass. Record cold and warm tile latency, bytes and allocations per stage,
physical-GPU frame/picking timings, retained CPU/GPU memory after long pan/zoom
sessions, concurrent-viewer latency and rebuild behavior during changes. Bind
results to the commit, fixture parameters, adapter and executor. Include lost
delta/reconnect recovery and a slow consumer so bounded work is observable.

## Implementation order

1. Remove the producer's JSON round trip with a typed native tile encoder and
   verify byte budgets, revision determinism and decoded geometry equivalence.
2. Reuse Arrow numeric views and packed geometry attributes; measure allocations
   and GPU upload counts while exercising eviction and label-buffer retirement.
3. Complete acceptance of the stable-ID bitmap query index and bounded binary
   membership/state transport in #5656. Native set evaluation and typed overlays
   are always available when Atlas is enabled; current source, browser and
   integrated scale gates remain authoritative in its OpenSpec task list. Keep
   Arrow for attributes and preserve deployment-local authorization.
4. Run the complete scale acceptance above before describing the current path
   as carrier-grade or zero-copy.
