## 1. Native
- [x] 1.1 Classify transient Dgraph failures in `dgraph-topology` (`TopologyError::Transient`, `is_transient/0`)
- [x] 1.2 Make every `dgraph_nif` operation asynchronous: submit on a normal scheduler, reply by message, `cancel/1`
- [x] 1.3 Bound in-flight calls with a tokio `Semaphore`; queue wait counts against the deadline
- [x] 1.4 Deadline every call (connect 10 s; item 30 s; bulk 300 s) and isolate panics at the poll boundary
- [x] 1.5 Make `topology_atlas_nif` `read_graph` asynchronous with `cancel_read/1`, holding its admission permit in the task
- [x] 1.6 Pass `-Cpanic=unwind` and reject `panic=abort` at compile time for every Bazel-built NIF
- [x] 1.7 Separate in-flight pools for per-item (8) and bulk (2) calls
- [x] 1.8 Cancel a call when its caller exits (monitored call handle; also the atlas read handle)
- [x] 1.9 Batched `upsert_canonical_edges/3`, `stale_canonical_keys/3` and `delete_canonical_edges/3` (one Dgraph transaction per chunk)

## 2. Elixir
- [x] 2.1 `ServiceRadar.Dgraph.Call`: selective receive with deadline plus margin, cancel on backstop, collect a claimed reply
- [x] 2.2 Bounded jittered retry for idempotent upserts only; final failure returned as `{:error, _}`
- [x] 2.3 `:telemetry` events for queue wait, latency, timeout and retry
- [x] 2.4 Route `ServiceRadar.Dgraph` and `TopologyAtlas.read_graph` through `Call`
- [x] 2.5 `ServiceRadar.Dgraph.CanonicalRebuild`: chunked upsert/delete phases with a CNPG cursor (fingerprint, phase, next chunk), cleared on success

## 3. Verification
- [x] 3.1 Rust: deadline cut-off, backpressure wait, queue wait against the deadline, panic release, classification, black-holed connect
- [x] 3.2 Elixir: more stalled calls than dirty-IO schedulers leave file I/O responsive; cancelled call never replies; idempotent retry and no retry for unsafe operations; telemetry
