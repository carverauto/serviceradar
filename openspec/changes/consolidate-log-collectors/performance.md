# Log pipeline performance investigation

Status: design research, not benchmark results or an implementation commitment.
Source checkout: `be23c1d10d`, inspected 2026-11-15. All capacity examples below
are synthetic. No live captures or deployment measurements were used.

## Direction

The product goal is a log collector and processor competitive at tens of
thousands to 100,000 or more high-volume hosts. Optimize sustainable searchable
logs per second per dollar, not just socket receive rate. Preserve Zen,
provenance, redaction, promotion, replay safety, and the NATS-first architecture.

The preferred experiment, incorporating product-owner steering, is:

1. Flowgger drains UDP and TCP concurrently into bounded receive buffers.
2. Bounded workers parse records and run the existing Rust Zen engine in-process.
3. Workers encode normalized records into bounded protobuf batches.
4. A publisher pipelines JetStream acknowledgments with bounded in-flight bytes.
5. EventWriter consumers persist normalized records without repeating Zen.
   Compare an adapted Broadway consumer against standalone Rust consumers if
   consumer processing is a measured bottleneck.
6. Rules come through serviceradar-datasvc from NATS KV, using a cached,
   versioned snapshot. Rule refresh is independent of record processing.

Keep listener consolidation independently shippable. Binary transport, collector
Zen, stream partitioning, and a Rust EventWriter are substantial extensions to
the original proposal and need explicit contracts before implementation. This
document records the proposed direction and evaluation work; it does not change
the existing `logs.syslog` wire contract or select a replacement consumer today.

## Findings in the fork

Paths are relative to the repository root. These are code observations; their
performance impact still needs measurement.

| Priority | Evidence | Candidate improvement |
| --- | --- | --- |
| First | `rust/flowgger/src/flowgger/output/nats_output.rs:458,648`: each worker awaits one publish ACK before receiving another record; `nats_threads` defaults to one | One connection owner with a bounded window of pending publishes. Preserve stable message IDs, retry deadlines, certificate authorization and permanent-error accounting. |
| First | Same file, `receive_record:167`: each record creates a `spawn_blocking` task to lock and receive from `Arc<Mutex<Receiver<Vec<u8>>>>` | Persistent bounded bridge or async-compatible channel; drain small batches per wakeup. Never block the NATS runtime while idle. |
| First | Same file, `run:674`: encoded GELF is decoded into a JSON tree, its source address prefixed, and serialized again | Attach provenance before encoding. Binary mode should build the final protobuf directly. Optimize the retained JSON compatibility path separately. |
| First | `input/udp_input.rs:73`: one socket, one `recv_from`, then decode, encode and blocking queue send | Linux `recvmmsg` batching with reusable slots; measure receiver/worker separation and `SO_REUSEPORT` sharding. Preserve source address, datagram boundaries and compressed-message limits. |
| First | `input/tcp/tcp_input.rs:44`: an OS thread per connection; `splitter/line_splitter.rs` allocates through `lines()` | Async connections, bounded frame parsing and connection admission; reuse buffers and scan delimiters in batches. Test many idle connections separately from a few hot ones. |
| First | `flowgger/mod.rs:116,503`: queue defaults to ten million records, with no byte budget | Budget queued and in-flight bytes, records and age. A queue of ten million 1 KB payloads alone is about 10 GB, excluding allocation overhead. |
| Next | `record.rs`: owned strings throughout; `auto_decoder.rs:48` tries decoders sequentially; `gelf_encoder.rs:60` builds a JSON tree | Borrowed parsing, cheap format discrimination with identical fallback behavior, fewer full-message copies and direct serialization. Preserve field precedence and escaping. |
| Next | `splitter/syslen_splitter.rs` allocates the advertised frame size; line framing has no explicit frame cap | Bound frames and partial-frame buffering before scaling connections. This is a concrete memory-exhaustion path, not a reason to add unrelated hardening. |

For a sequential publisher, the ACK-limited ceiling is approximately
`workers / ACK latency`. A synthetic 2 ms ACK latency means roughly 500
messages/sec for one worker before other costs. This is arithmetic, not a
measurement of this installation. Concurrency and batching remove that serial
dependency; they do not guarantee a corresponding throughput multiplier.

Increasing `nats_threads` is a useful diagnostic comparison, not the preferred
architecture: each worker currently creates a runtime, connection and stream
reconciliation. One logical output need not mean one outstanding publish.

## The consumer path contains more work than a protobuf decoder

The current JSON syslog path is:

`syslog -> owned Record -> GELF JSON -> JSON parse/re-encode for partition ->
JetStream -> Jason decode -> Jason encode -> Zen NIF JSON parse -> rule
evaluation -> JSON encode -> Jason decode -> log row -> storage encoding`.

Important verified boundaries:

- `rust/otel/src/nats/publish.rs:227` already publishes protobuf
  `ExportLogsServiceRequest`. Its byte-limited chunker and bounded publish
  admission are reuse candidates, but not drop-in replacements for Flowgger's
  ACK retry contract. The chunker also clones growing requests while packing;
  avoid importing that cost into a high-rate microbatcher.
- `event_writer/processors/logs.ex:95,452` already accepts OTLP protobuf, after
  trying JSON first. Binary migration therefore does not require inventing a
  decoder from scratch. Explicit content/schema metadata can avoid sniffing.
- The protobuf branch bypasses `ZenNormalizer` and its constructed rows omit
  JSON-path fields including `source_ip`, separate `observed_timestamp`,
  `trace_flags`, `event_name`, and scope attributes. A direct format switch is
  not behaviorally equivalent. Preserve syslog-specific timestamp and fallback
  metadata too; complete a field-by-field parity matrix before cutover.
- `observability/zen/normalizer.ex:42` serializes maps to call the NIF and parses
  its returned JSON. `native/zen_nif/src/lib.rs:25` takes a Rust `String`, parses
  it, clones contexts during rule evaluation and serializes the result. Zen can
  consume an in-memory value; its JDM being JSON does not require serializing
  every log as JSON between stages.
- `event_writer/pipeline.ex:200,343` routes in `handle_message` and does parsing,
  normalization and persistence in `process_batch`. More Broadway processor
  concurrency alone does not parallelize this work. Existing consumer-group
  demand isolation is valuable and should survive any refactor.
- `Logs` also attaches ingest attribution, redacts sensitive fields, stabilizes
  record IDs, promotes logs to events, updates the service catalog and notifies
  live-log listeners. A Rust consumer cannot silently omit these services.
- `analytics/starrocks/destination.ex:303` already encodes rows once, sizes loads
  by bytes and rows, and passes the encoded body through to StreamLoad. Do not
  claim there is a second storage encoding on this normal path. It does flatten
  iodata to a binary; retaining replayable iodata is a later measurement candidate.

## Zen in Flowgger, with datasvc as the control path

Prefer one shared Rust normalization library used by Flowgger and the existing
NIF adapter, with identical rule ordering, merge behavior, error handling and
synthetic conformance fixtures. Do not fork the semantics into two engines.
Keep rule authoring and compilation under the current core/UI control plane.

Build Zen's input value directly from parsed fields. Evaluate cached rules and
convert the result to the protobuf schema without a JSON string round-trip.
This removes text serialization, not all allocation: the dynamic Zen value
tree and rule evaluation still allocate and may clone. Unknown/custom rule
output must be representable through typed attributes, not dropped to fit a
fixed schema. Retain the legacy field names expected by existing JDM rules at
the engine boundary.

The follow-up [zero-copy investigation](zero-copy.md) inspects Zen 2.0.1 and
upstream checkout `9c374e1681895261102ba3384d19884e8133be1d` (2.1.7).
Zen already supports shallow value clones and shared string slices. First
remove our adapter's deep JSON-value clones and conversions; investigate a
narrow buffer-owner extension only for retaining NIC receive leases through
evaluation. Preserve our null/merge semantics rather than substituting Zen's
different built-in merge operation.

Existing distribution components:

- `observability/zen_rule_sync.ex:303` writes compiled JDM through
  `DataService.Client`, followed by an ordered `_rules.json` index. Its keys
  include agent, stream and subject. The current index names rules and order,
  but does not pin each document revision. Core's normalizer currently selects
  active rules by subject and stream. Resolve this scope difference explicitly
  when moving evaluation to collectors.
- `proto/kv.proto` exposes `Get`, `BatchGet`, `Update` and streaming `Watch`.
  `Get` returns a revision, while `WatchResponse` only carries value bytes.
- `go/pkg/datasvc/nats.go:357` creates a backing KV watch per watch call and
  reconnects it. The server forwards values; it does not expose snapshot
  completion, delete operation or revision metadata through that response.
- `rust/kvutil/src/lib.rs` already supplies an mTLS datasvc client. Its `get`
  drops revision information; `watch_apply` spawns a task that terminates on
  stream end/error without reporting completion or reconnecting.

Proposed contract:

1. Use datasvc to fetch and watch a versioned ruleset manifest. Keep direct
   NATS connections for log publication; do not proxy high-volume logs through
   datasvc. No RPC, KV lookup, JDM parse or engine compilation per log.
2. Prefer a single bounded bundle when it fits the KV/gRPC limits. Otherwise
   publish immutable content-addressed rule documents, then atomically update
   a small manifest that references their hashes. `PutMany` is not evidence of
   a multi-key transaction. Load and validate the complete referenced snapshot
   before activation. This prevents a routine multi-rule edit from exposing a
   mixture of old and new rules to a collector.
3. Compile outside receive workers; activate an immutable cached snapshot at a
   record or batch boundary. Carry a ruleset ID/version with normalized output.
   Bind a batch to one ruleset, or carry the version per record.
4. Supervise the datasvc watch, reconnect with jitter, and periodically fetch
   the authoritative manifest. A self-versioned manifest plus `Get` can work
   with today's value-only watch; an additive revision/operation field is a
   separate option if other clients need it. Do not invent a resume cursor
   that the current protocol does not support.
5. Define cold-start, deletion, disabled-rule and invalid-update behavior.
   Proposed initial policy: do not advertise normalization readiness without a
   validated snapshot; retain last-known-good on invalid/unavailable updates,
   report stale revision and age, and treat an explicit empty ruleset as a valid
   control-plane decision. Persisted snapshots need the same validation. This
   is proposed policy, not an assertion of existing behavior.
6. Watch per collector/ruleset, not per sending host or record. Measure datasvc
   watch fanout and update convergence before adding shared watchers. Reuse
   existing component identity/RBAC and verify permission for intended keys.

Collector-side Zen changes the processing time boundary: replay normally uses
the normalization result and rule version from receipt, not today's rules.
Choose whether raw data is retained for explicit reprocessing. Do not run Zen
again on already-normalized records. Legacy JSON continues through the existing
normalizer during migration; external record fields cannot assert that trusted
normalization has already occurred.

Receive workers must not execute arbitrary rule work inline on the only UDP
draining thread. Benchmark expensive/custom JDM separately. A full bounded
queue means TCP can backpressure; UDP cannot and must expose loss. Kernel TCP
ACKs are not application durability acknowledgments. Surviving collector crashes
before JetStream ACK requires a separately designed spool/reliable sender
contract, not just a large RAM queue.

## Binary transport and zero-copy boundaries

Use OTLP protobuf as the first comparator because both sides already implement
it. Consider a small versioned envelope for encoding, normalization revision,
batch identity and provenance; use standard attributes/headers where sufficient.
Do not assume generated owned-string protobuf structs are zero-copy. Compare
OTLP against a compact project-owned protobuf only if its overhead is measured.

Batch by encoded bytes, record count and maximum age. Preserve stable record
identity within stable retry batches; budget expanded records in Broadway, not
only NATS message counts. Keep below the negotiated NATS payload limit including
headers. Partial rejection, replay, order and ACK semantics need explicit cases.
Roll consumers out first, accept both formats, switch producers, drain retained
old messages, and only then consider removing JSON. A new versioned subject also
requires routing, stream ownership, ACL, Zen format validation and tooling
changes; `logs.>` matching alone does not establish compatibility.

| Boundary | Feasible approach | Limit |
| --- | --- | --- |
| Receive buffer -> parser | Borrow slices/ranges; reuse TCP and UDP buffers | Escaped fields and decompression still need materialization. |
| Parser -> Zen | Construct native values with shared string slices; avoid JSON text and repeated value conversion | Containers and transformed fields allocate; NIC-buffer ownership needs an additional integration contract. |
| Zen -> publisher | Encode once into an owned batch, hand off by ownership/shared `Bytes` | Protobuf encoding and TLS still do work. Existing `Vec` queue sends move ownership already. |
| Kernel -> receiver | Compare recvmmsg to io_uring multishot with provided buffers | Multishot amortizes submission; it is not kernel receive zero-copy. |
| NIC -> userspace | Explicit AF_XDP UDP and io_uring ZC Rx TCP prototypes alongside a supported conventional receive backend; see `zero-copy.md` | Verify host, VM and pod capabilities separately. Support ordinary Kubernetes workers and edge VMs; expose acceleration when available. |
| Consumer -> warehouse | One final batch encoding, optional CSV comparison | StarRocks Stream Load does not accept arbitrary OTLP protobuf. |

Pool ownership must last until all relevant operations finish. Release receive
slots after parsing/encoding rather than holding scarce kernel buffers through
JetStream ACK retries. Small slices may pin a large batch; measure retained
capacity as well as copied bytes. A bounded copy can outperform cross-core
reference counting and long-lived pinned buffers.

## Runtime and systems options

- **recvmmsg + SO_REUSEPORT:** first Linux comparator. Receive a batch without
  waiting to fill it (`MSG_WAITFORONE` or a nonblocking drain), preserve source
  metadata and detect truncation. Add receive-buffer sizing and socket drop
  counters. Test one hot sender as well as many flows; flow hashing does not
  guarantee even distribution. RSS/IRQ/NUMA locality is a separate host concern.
- **Compio:** credible io_uring candidate. Current APIs include pooled
  `recv_from_multi` and `recv_msg_multi`. Compare exactly which backend and
  multishot operations run on the target kernel and under its pod seccomp policy.
  Keep a supported conventional backend for environments without acceleration. Its
  runtime compatibility layer is not proof that async-nats, tonic, TLS and
  certificate renewal work unchanged. Keep Tokio control/publish tasks behind
  a bounded bridge if needed and measure that bridge.
- **Tokio async TCP:** reuse the existing runtime ecosystem for many concurrent
  connections. Measure against Compio; asynchronous I/O is not automatically
  faster for a few busy connections.
- **Raw io-uring, tokio-uring, Monoio, Glommio:** alternatives if the controlled
  receive experiment identifies a runtime limitation. Do not maintain four
  production backends just to compare runtime names.
- **SIMD delimiter scanning, borrowed decoding, allocator and PGO experiments:**
  useful once profiles identify parsing/allocation/branch costs. Cargo already
  requests opt-level 3 and LTO; inspect the shipped Bazel flags separately.
  Prefer removing a JSON pass to accelerating that unnecessary pass with SIMD.
- **Batch compression:** compare uncompressed protobuf with LZ4/Zstd only when
  bandwidth/storage outweighs CPU and latency. This needs a codec contract;
  consumers cannot infer compressed protobuf by attempting JSON decode.
- **AF_XDP/DPDK, busy polling and SQPOLL:** dedicated-host experiments, not
  defaults. Include reserved CPU, idle power, packet handling and operational
  costs. They cannot cure serialized publishing or warehouse saturation.
- **MSG_ZEROCOPY:** a send optimization, not the UDP receive solution. Kernel
  documentation warns of page-accounting overhead and generally favors writes
  above roughly 10 KB; benchmark batched writes rather than tiny log messages.

## EventWriter and storage alternatives

Compare these under identical normalization and persistence contracts:

| Option | Why consider it | What must be preserved |
| --- | --- | --- |
| Adapt Broadway to normalized protobuf | Smallest change; removes Zen and JSON input conversion for new records | Field parity, redaction, stable IDs, promotion, live updates, service catalog, CNPG backend, ACK after required durable work |
| Parallelize CPU preparation in Broadway | Existing message handlers currently only route | Byte bounds, per-source order where promised, group isolation, load admission; do not merely increase database writers |
| Standalone Rust EventWriter consumers | Fewer cross-language conversions; direct protobuf-to-storage batches; independent scaling | The same logical persistence ownership, retries, quarantine, deduplication, schema and side effects; do not run both writers for the same records |

The preferred Zen location remains Flowgger. Retain consumer-side normalization
for old/unprocessed inputs, not a second pass on trusted normalized batches.
Factor shared parsing/normalization contracts before deciding language based on
benchmarks. A Rust storage worker invoked by EventWriter is another staged
experiment, but adds an IPC hop that must justify itself.

`Destination.store` already selects one backend. Preserve the configured
warehouse/CNPG mode and never introduce collector-to-database writes. Current
StarRocks `Rows.encode(:logs)` projects scalar columns. A CSV Stream Load
experiment could remove JSON from that storage body, but must preserve nulls,
empty strings, Unicode, multiline bodies, quoting and filtering semantics.
It remains serialization, not protobuf passthrough or zero-copy. Nested
attributes and their query/storage contract need a separate parity check.

StarRocks 4.1 documentation lists CSV/JSON for Stream Load. Arrow Flight SQL's
documented fast columnar query retrieval is not evidence of an applicable
binary bulk-ingest API. Verify a supported write API on the pinned release
before selecting Arrow. Parquet through object storage/FILES is a viable bulk
loading research direction with a different latency/commit model, not a drop-in
real-time endpoint. Do not use undocumented internal StarRocks protobuf RPCs.

The current load client intentionally closes each HTTP connection to avoid stale
responses after early FE/BE replies. Measure handshake costs, but do not enable
pooling without fixing and validating that protocol interaction. Likewise,
asynchronous load acceptance must not replace confirmed persistence before ACK.

## Scale beyond a fast process

| Synthetic workload, 100,000 hosts | Records/sec | Payload at 1,000 bytes/record | Raw payload/day |
| --- | ---: | ---: | ---: |
| 10 records/sec/host | 1 million | 1 GB/sec | 86.4 TB |
| 100 records/sec/host | 10 million | 10 GB/sec | 864 TB |
| 1,000 records/sec/host | 100 million | 100 GB/sec | 8.64 PB |

These are offered-load examples, not performance claims or required defaults.
Add protocol, normalization expansion, TLS, replication, indexes and retention
to capacity planning. Compression and selective indexing may materially change
cost; sampling/drop policies are product decisions, not silent optimizations.

At the larger targets, evaluate multiple non-overlapping JetStream streams with
independently placed leaders, not just more collectors feeding one `events`
stream. More subject tokens in one stream do not partition its write leader.
The current wildcard ownership, budgets, consumer routing, management UI and
permissions must migrate together; new streams cannot overlap existing subject
ownership. This conflicts with the consolidation proposal's current fixed
stream/subject non-goal and must be approved as a follow-up architecture change.

Partition on a stable source identity where ordering matters; explicitly handle
hot sources and resharding. Avoid per-host streams/consumers. Scale pull workers
on the intended durable work distribution; independent durables can duplicate
the entire workload instead of sharing it. Keep database load admission bounded
across all consumer replicas. Measure storage ingest and query latency together
under retention/compaction work, not on an otherwise idle warehouse.

## Evaluation sequence and acceptance evidence

1. Establish baseline on controlled Linux hardware: release/Bazel artifact,
   recorded kernel/NIC/CPU/cgroups, TLS, stream replicas and storage settings.
   Separate generator, collector, NATS and storage bottlenecks. Use synthetic
   fixtures only and dedicated load environments; this review ran no load.
2. Fix the serial output experiment first: ACK windows 1/32/128/512, byte
   budgets, persistent queue bridge. Compare JSON single-encode and protobuf
   microbatches. Values are experimental sweep points, not recommended defaults.
3. Compare existing central Zen with collector Zen using the same ordered JDM
   and output equivalence. Exercise rule changes, deletion, datasvc disconnects,
   reconnect storms, cold start and expensive rules. Measure update convergence.
4. Compare receive backends: current sockets, recvmmsg, then Compio multishot.
   Sweep batch sizes and receive shards independently from publish windows.
   Test UDP-only, TCP-only and mixed listeners with concurrent OTLP.
5. Compare adapted Broadway against Rust consumers only after profiling the
   normalized binary path. Compare storage JSON/CSV separately so results show
   whether gains came from language, codec, batching or reduced semantics.
6. Scale across hosts, streams and consumers. Include long-lived TCP connection
   counts up to the target, skewed hot senders, burst traffic, recovery catch-up,
   restarts and sustained ingestion with concurrent queries.

Measure offered/received/decoded/normalized/publish-ACKed/persisted/searchable
records separately; bytes/sec, records/core-sec, CPU, allocations, RSS, queue
bytes/age, NATS ACK latency, kernel UDP drops, parse rejection and duplicates.
Report p50/p95/p99 event-to-query latency and drain time after outages. Use
open-loop generation and count gaps so backpressure does not hide latency or
loss. Account for records inside protobuf batches, not just NATS messages.

Declare the operating envelope and pass/fail budgets before each run. Reject an
optimization that loses fields, skips Zen/redaction, changes durability, leaks
memory under saturation, or wins only by deferring work beyond the measurement.
ACK evidence is not a row-count proof: query synthetic IDs after persistence.
Distinguish publisher ACK from final searchable storage. UDP cannot promise
lossless delivery; report its maximum sustainable rate at a stated loss budget.

A claim of being the fastest needs a reproducible like-for-like comparison:
same hardware, parsing/rules, payload distribution, durability, indexing and
query load. This investigation establishes candidates, not a Datadog comparison
or a worldwide performance ranking.

## Primary references

- [async-nats 0.50 publish API](https://docs.rs/async-nats/0.50.0/async_nats/jetstream/context/struct.Context.html)
- [Linux recvmmsg](https://man7.org/linux/man-pages/man2/recvmmsg.2.html), [socket options](https://man7.org/linux/man-pages/man7/socket.7.html)
- [Compio UDP APIs](https://docs.rs/compio-net/latest/compio_net/struct.UdpSocket.html), [runtime compatibility](https://docs.rs/compio-compat/latest/compio_compat/)
- [Multishot recvmsg](https://man7.org/linux/man-pages/man3/io_uring_prep_recvmsg_multishot.3.html), [io_uring ZC Rx](https://docs.kernel.org/networking/iou-zcrx.html)
- [AF_XDP](https://docs.kernel.org/networking/af_xdp.html), [MSG_ZEROCOPY](https://docs.kernel.org/networking/msg_zerocopy.html), [RSS and CPU scaling](https://docs.kernel.org/networking/scaling.html)
- [Rust PGO](https://doc.rust-lang.org/rustc/profile-guided-optimization.html), [Zen engine](https://docs.rs/zen-engine/latest/zen_engine/)
- [StarRocks Stream Load](https://docs.starrocks.io/docs/loading/StreamLoad/), [format support](https://docs.starrocks.io/docs/loading/loading_introduction/feature-support-loading-and-unloading/), [Arrow Flight SQL](https://docs.starrocks.io/docs/unloading/arrow_flight/)
- [JetStream clustering](https://docs.nats.io/learn/topologies/jetstream-in-a-cluster)
