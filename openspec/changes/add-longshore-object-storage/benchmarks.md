# Longshore and NVR benchmark protocol

This is a measurement plan, not a performance result. Sizes, durations and
thresholds below are synthetic test choices. Live camera media, object keys,
credentials, endpoint names, raw deployment metadata and captured results remain
in private operational artifacts, never committed fixtures.

## Baseline sources

Read these files in Longshore at the dependency revision and record their exact
revision with the run:

- `bench/README.md`: repetition, CPU pinning and units.
- `bench/results/m22-client-and-soak.md`: direct versus shared client, checksum
  cost, HTTPS and fault-soak limits. This did not measure a Rustler boundary or
  many BEAM callers sharing a few I/O threads.
- `bench/results/m21-object-sizes.md`: object-size sweep and request overhead.
- `bench/results/m4-s3-linode-us-ord.md`: provider/network-limited Linode runs;
  its plain-HTTP/no-checksum throughput is not a TLS production target.
- `bench/results/m9-s3-ops-linode.md`: conditional writes and range reads;
  bucketed latency upper bounds are not exact percentile samples.
- `bench/results/m19-ipv6-linode.md`: connectivity/correctness, not a throughput
  baseline.

Do not paste their raw observations into ServiceRadar fixtures. Compare
methodology and retain source references. Native and NIF tests must use the same
merged Longshore revision even when published results predate an API addition.

## Three measurements

| Layer | Workload | Question |
| --- | --- | --- |
| Native Longshore client | Synthetic objects against a controlled peer and selected S3 provider | What can this host and network actually sustain? |
| Elixir through Rustler | Identical bytes, operations, limits and destination; many callers sharing the client | What does the bridge add? |
| Recording pipeline | Synthetic encoded media through ingress, spool/seal, upload, verification, publication and playback | Where does useful video throughput or availability stall? |

Record the current provider transport on the same compatible workloads when
available. Compare equivalent verification/authority work; a bare PUT is not an
end-to-end archive completion.

Use a low-latency controlled peer to expose CPU/copy overhead, then real Linode
HTTPS to expose provider/WAN limits. Validate the generator and peer can exceed
the offered load. If either saturates, label the client-ceiling result
inconclusive. Do not use production cameras as a load generator.

## Workload and reproducibility

- Single objects: 4 KiB metadata and 1, 4, 8, 16 MiB payloads where buffer limits
  allow; add measured recorder block sizes. Classify multipart separately.
- Ranged reads: metadata/init and fragment-sized ranges under concurrent upload,
  with the production identity/integrity checks enabled.
- Multipart: fixed known-size synthetic objects, bounded parts of at least 5 MiB
  except the last, explicit completion/abort, and an independently verified
  final object. Report part traffic separately from completed-object goodput.
- Sweep admitted concurrency 1, 4, 8, 16 and 32 only within declared memory and
  connection budgets; measure one and multiple I/O threads where CPU permits.
- Preserve TLS, checksums, encryption, addressing, retries, CPU affinity,
  container CPU/memory limits and object verification settings across paired
  native/NIF runs. Diagnostic checksum-off runs cannot qualify production.
- Preserve registered buffers and zero-copy sends across native/NIF pairs.
  Record effective memlock limits and seccomp profiles and verify initialization
  before measuring. Measure the Rustler bridge's payload copies separately from
  Longshore's kernel send path; do not substitute an unpinned implementation.
- Record CPU/NUMA architecture, kernel, runtime/compiler versions, network path,
  provider placement, release SHA, Longshore SHA and configured limits privately.
- Warm up for 30 seconds, then use at least five interleaved paired runs of
  60 seconds per cell. Retain median/min/max and per-request p50/p95/p99 with
  sample counts. Separate connection/startup cost from steady state.
- Use decimal MB/s and GB/s for throughput, explicit MiB for object sizes.
  Record failed/rejected/timed-out work and physical attempts, not only successes.
  If native retry/attempt telemetry is unavailable, report it as unavailable.

## Instrumentation

Measure successful unique payload bytes per wall-clock second, objects/second,
CPU seconds/GiB, total process and native-thread CPU, RSS/cgroup peak memory,
BEAM binary memory/GC, scheduler utilization and run queues. Measure wrapper
admission wait, queue depth/bytes, buffer waits, actual bytes copied and socket
traffic where instrumentation allows. Do not infer zero-copy from io_uring use.

For the full pipeline record ingest-to-seal, seal-to-upload, upload-to-verified,
verified-to-catalog and first playable frame latency separately. Include disk
flush latency, spool backlog, verification read traffic, S3 operation/byte
amplification and concurrent playback startup/seek latency. This distinguishes
TLS/copy CPU, scheduler contention, disk, provider latency and publication waits.
Product telemetry follows JetStream; benchmark artifacts do not write directly
to telemetry database tables.

## Explicit gates

The initial wrapper regression budget is at least 90% of matched native median
goodput and no more than 15% additional total CPU seconds/GiB. These are design
targets, not published capability claims. A noisy or provider-limited result
cannot establish low bridge overhead: repeat with a controlled peer and profile.
Report a miss and investigate; do not relax the budget after seeing the result.

Before each end-to-end run declare offered encoded rate R, outage window W,
backlog B, recovery deadline T, resource ceilings and latency budgets in the
private run manifest. Require sustained useful archival goodput U to satisfy
U >= R + B/T for the declared catch-up case. Missing budgets make qualification
inconclusive. Keep the broader recorder capacity ladder independent of this
initial single-camera milestone.

Run a 30-minute steady-state soak and a bounded synthetic outage/recovery phase.
Fail on silent media gaps/duplicates, mismatched readback, lost preserved data,
queue/byte limit violations, failure to recover the declared backlog, breached
latency budgets or continuing resource growth after warm-up. Verify generated
ground truth independently of the writer's success counters. Inject faults only
into dedicated test processes/scopes, never host-wide shared-network rules.
Larger/longer capacity claims still require the recorder plan's qualification.

Every report states PASS, FAIL or INCONCLUSIVE per gate, the measured limiting
stage, unresolved telemetry gaps and the next targeted change. Use profiles to
justify optimizations; repeat the same paired cases after changes. Do not claim
that no bottleneck exists: report the limiting stage and remaining headroom.

## Measured synthetic RBE results (`8759583fd1888f292f290a5adbe883c8c6eb6aee`)

### Methodology alignment with pinned Longshore reports

All paired native and Rustler NIF runs used Longshore commit
`8759583fd1888f292f290a5adbe883c8c6eb6aee` (PR #28) on the dedicated Linux
`io_uring` remote executor pool (Linux 6.8 x86_64, `memlock` soft/hard
`unlimited`, OTP 28 / ERTS 16.1, 30 online and dirty-CPU schedulers):

- `bench/README.md` and `bench/results/m21-object-sizes.md`: matched decimal
  `MB/s` goodput, `MiB` payload sizes (`4 KiB`, `1 MiB`, `4 MiB`, `16 MiB`),
  five interleaved native/NIF repetitions per cell after warm-up, and median /
  min / max plus per-operation `p50` / `p99` latency reporting. Bounded CI test
  runs used 1-second steady-state windows per interleaved repetition rather than
  60-second standalone soak windows; full 60-second windows remain part of the
  dedicated soak gate.
- `bench/results/m22-client-and-soak.md`: enabled `Put { no_clobber: true,
  sse_s3_aes256: true, sha256: Some(...) }` and `Budget::once` on both native
  and NIF paths so SigV4 canonical-request hashing and `x-amz-checksum-sha256`
  header emission match archive writes. Unlike `m22`, multiple BEAM caller
  tasks contend through one supervised `ServiceRadarObjectStorage.Session` and
  Rustler `DirtyCpu` admission path.
- `bench/results/m4-s3-linode-us-ord.md`, `m9-s3-ops-linode.md` and
  `m19-ipv6-linode.md`: the controlled loopback HTTP S3 peer isolates CPU,
  memory-allocation and Rustler copy overhead (`3.5-7.7 GB/s` native ceiling)
  without WAN variance; it does not establish TLS/WAN provider limits, which
  remain gated on live S3-compatible HTTPS execution.

### Profiled bottleneck fixes (`tasks.md` 4.5)

Initial paired run `b1937bb1` exposed two avoidable bridge bottlenecks:

1. **Per-call multi-MiB `Vec<u8>` allocation inside `queue_us`**: copying the
   caller `Binary` via `bytes.as_slice().to_vec()` after `admitted = Instant::now()`
   triggered OS `mmap`, soft page faults and `munmap` TLB shootdowns on every
   `1-16 MiB` `PUT`, inflating `PUT 16 MiB (c=1)` `queue_p50` to `13,650 us` and
   limiting NIF goodput to `587.2 MB/s` (`0.35x` native). Fix: added a bounded
   `ScratchBuf` pool (`concurrency` reusable `Vec<u8>` slots capped at
   `buffer_size`) and separated `DirtyCpu` input preparation from worker queue
   wait while keeping `Budget::once` anchored to admission start.
2. **Double payload copy on `GET`**: copying `Buffer -> Vec<u8>` on the worker
   thread and then `Vec<u8> -> OwnedBinary` in `OwnedEnv::send_and_clear` limited
   `GET 4 MiB (c=1)` to `1,017.3 MB/s` (`0.24x` native, `1.00 CPU s/GiB`). Fix:
   allocated `OwnedBinary` once directly from Longshore's registered `Buffer`
   slice (only when HTTP status is `200` or `206`) and transferred ownership via
   zero-copy `OwnedBinary::release(env)`. Also enabled `TCP_QUICKACK` on the
   Linux loopback benchmark peer before body reads to eliminate artificial 40 ms
   Nagle + delayed-ACK stalls on sub-MSS `4 KiB` writes in both layers.

### Paired native vs Rustler NIF loopback summary (5 interleaved runs/cell)

Pre-optimization invocation `b1937bb1` vs post-optimization invocation
`d6272abe` / `e882b7d0` (`//elixir/serviceradar_object_storage:object_storage_bench_test`):

| Workload | Conc | Pre NIF MB/s (ratio) | Post Native MB/s | Post NIF MB/s | Post Ratio | Native CPU s/GiB | Post NIF CPU s/GiB | Post Queue p50 / Op p50 (us) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| PUT 4 KiB | 1 | 0.10 (1.02) | 54.9 | 33.3 | 0.61 | 11.38 | 84.17 | 9 / 73 |
| PUT 4 KiB | 8 | 0.79 (0.98) | 149.1 | 125.7 | 0.84 | 8.93 | 33.78 | 9 / 160 |
| PUT 1 MiB | 1 | 306.2 (0.22) | 2,585.6 | 1,878.0 | 0.73 | 0.39 | 1.06 | 11 / 406 |
| PUT 1 MiB | 4 | 944.0 (0.58) | 3,693.9 | 3,519.6 | 0.95 | 0.37 | 0.82 | 13 / 983 |
| PUT 4 MiB | 1 | 406.6 (0.44) | 2,969.4 | 2,306.3 | 0.78 | 0.30 | 0.57 | 15 / 1,400 |
| PUT 4 MiB | 4 | 1,155.0 (0.53) | 3,690.8 | 3,693.9 | 1.00 | 0.32 | 0.59 | 17 / 3,777 |
| PUT 4 MiB | 16 | 956.6 (0.42) | 3,460.1 | 3,292.6 | 0.95 | 0.43 | 0.65 | 25 / 17,537 |
| PUT 16 MiB | 1 | 587.2 (0.35) | 2,600.3 | 2,042.5 | 0.79 | 0.25 | 0.43 | 21 / 6,511 |
| PUT 16 MiB | 4 | 1,492.5 (0.48) | 3,808.1 | 3,789.6 | 1.00 | 0.31 | 0.45 | 25 / 15,201 |
| HEAD (4 MiB obj) | 4 | 23,828 ops/s (0.71) | 46,313 ops/s | 27,257 ops/s | 0.59 | n/a | n/a | 9 / 74 |
| GET range 4 KiB | 4 | 84.6 (0.62) | 166.4 | 99.7 | 0.60 | 7.87 | 26.07 | 9 / 91 |
| GET range 1 MiB | 4 | 3,133.7 (0.46) | 7,660.3 | 5,741.1 | 0.75 | 0.15 | 0.42 | 11 / 644 |
| GET range 4 MiB | 1 | 1,017.3 (0.24) | 5,187.9 | 3,027.9 | 0.58 | 0.15 | 0.34 | 14 / 1,279 |
| GET range 4 MiB | 4 | 2,427.7 (0.59) | 5,640.9 | 5,430.1 | 0.96 | 0.18 | 0.36 | 14 / 2,977 |

BEAM binary memory remained bounded across all cells (`16.8 MiB` baseline,
`29.4 MiB` peak at `4 x 4 MiB` concurrent reads, `25.2 MiB` immediately after
sweep GC; zero leaked NIF resources or late caller messages).

### End-to-end `CameraStorage` archive & concurrent playback (`e882b7d0`)

`//elixir/serviceradar_core_elx:camera_storage_bench_test` runs 5 synthetic
iterations per adapter (`:longshore` vs `:http`), each executing Core authority
`prepare` -> `grant` -> single-attempt `PUT` (`If-None-Match: *`, `AES256`,
`*-put-canonical-v1` or `*-put-wire-v1` evidence) -> `HEAD` -> `4 MiB` ranged
`GET` SHA-256 verification -> `verify` across `4 KiB` init, `4 MiB` media,
`16 KiB` manifest, plus a concurrent `4 MiB` media upload paired with a `1 MiB`
`ReadService` `/v1/archive-ranges` playback fetch:

| Transport | Median 4 KiB Init (ms) | Median 4 MiB Media (ms) | Concurrent 4 MiB Media (ms) | Concurrent 1 MiB Playback (ms) | Useful Media MB/s | CPU s / Useful GiB | Provider Ops / Byte Amp |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `:longshore` (loopback HTTP peer) | 232.7 | 231.3 | 226.2 | 52.5 | 18.13 | 51.17 | 13 ops / 2.125x |
| `:http` (synthetic TLS + CONNECT proxy) | 366.9 | 382.1 | 372.8 | 99.5 | 10.98 | 79.32 | 13 ops / 2.125x |

Controlled transport note: `:http` traverses synthetic-CA TLS over the test
`CONNECT` proxy fixture, whereas `:longshore` uses the test-only loopback HTTP
peer because `longshore_s3::Client` enforces public WebPKI roots on HTTPS
targets. Exact TLS parity requires the live S3-compatible HTTPS benchmark.

### Gate classification, limiting stages and next actions

- **Concurrent multi-MiB goodput gate (`>= 0.90` of native median)**: **PASS**
  for archive-sized concurrent streaming (`PUT 1 MiB c=4` at `0.95`, `PUT 4 MiB
  c=4` at `1.00`, `PUT 4 MiB c=16` at `0.95`, `PUT 16 MiB c=4` at `1.00`, and
  `GET range 4 MiB c=4` at `0.96`, sustaining `3.3-5.4 GB/s` through BEAM).
  **FAIL** at `concurrency=1` (`0.58-0.79`) and `4 KiB` / `HEAD` metadata rates
  (`0.59-0.84`, `24.3k-30.7k ops/s`), where serial `Session` GenServer hop
  (`~30-45 us/op`) and non-overlapped FFI copy latency are exposed against
  sub-millisecond loopback RTTs.
- **Relative CPU overhead gate (`<= 1.15x` native CPU s/GiB)**: **FAIL** on
  synthetic loopback (`1.44x` at `PUT 16 MiB c=4` [`0.45` vs `0.31 CPU s/GiB`]
  and `2.05x` at `GET 4 MiB c=4` [`0.36` vs `0.18 CPU s/GiB`]). Limiting stage:
  native `longshore_bench` reuses one pre-registered buffer with zero payload
  copies (`0.15-0.39 CPU s/GiB`), whereas crossing the BEAM/Rustler boundary
  performs one mandatory payload `memcpy` (`Binary -> ScratchBuf -> Buffer` on
  `PUT`; `Buffer -> OwnedBinary` on `GET`) plus BEAM refc-binary lifecycle,
  costing a fixed `~0.14-0.27 CPU s/GiB` (`> 15%` of a zero-copy loopback
  baseline, though small relative to TLS + WAN budgets). Next targeted change
  if CPU becomes limiting on sealed segments: pass sealed spool file descriptors
  or chunked `pread` directly into registered buffers (`design.md` line 26).
- **Bounded memory, correlation & error-body isolation**: **PASS** (`queue_p50`
  `9-25 us`, zero caller mailbox leaks on timeout/kill, HTTP `200`/`206`-only
  body extraction, flat post-GC BEAM binary memory).
- **Live S3-compatible HTTPS benchmark, multipart NIF & 30-minute soak**:
  **INCONCLUSIVE** (unexecuted in RBE; gated on cluster rollout, node `memlock`
  provisioning, and real-provider multipart qualification).
- **Remaining telemetry gaps**: native `longshore_s3::Client` does not expose
  internal socket-byte counters or kernel ring-submission counts (`Budget::once`
  bounds attempts to `1`), and synthetic pipeline benchmarks use in-memory
  test payloads rather than live camera RTSP/WebRTC ingest-to-spool disk flush.
