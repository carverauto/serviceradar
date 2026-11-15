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
