# Change: Unify sweep/MTR results on native protobuf

## Why

Results reach core through **three** independently-grown pipelines with two
different serializations:

1. **Sweep results** — the agent JSON-encodes each `models.HostResult` and
   ships it as opaque bytes inside `proto.ResultsChunk.data`; core's
   event-writer `Jason.decode`s it (`processors/sweep.ex`) into
   `sweep_host_results` / `ocsf_network_activity`.
2. **Metrics** — the agent emits a protobuf `MetricBatch` on JetStream
   `metrics.>`; the scheduled MTR checker rides this, encoding hop data as
   metric attributes.
3. **Command results** — on-demand MTR returns JSON in
   `CommandResult.payload_json`, written directly via Ash.

This has two problems at scale:

- **JSON in the hot path.** Sweep results are JSON-encoded on the agent and
  JSON-decoded in core for **every host**. JSON repeats field names per record
  and can't varint-pack, so it inflates agent CPU, wire bytes, JetStream
  payload/retention, and core decode cost. At hundreds of thousands of results
  this is a material, avoidable tax. The `proto.MtrTraceResult` /
  `proto.MtrHopResult` messages that *should* carry the heavy per-hop data are
  **defined but never populated** — the structured binary path exists on paper
  and is unused.
- **A single logical result is split across pipelines.** Adding MTR to sweeps
  would put one host's reachability on path (1) and its trace on path (2) —
  one result, two pipelines, decoded twice. That incoherence is a symptom of
  the JSON/proto split, not a feature.

This change makes a host's sweep result a **single native-protobuf message**
that carries ICMP + TCP **and** the full MTR trace together, decoded once by
core and fanned out to the right tables. It removes JSON from the sweep hot
path and gives MTR (and the forthcoming sweep-profile MTR mode) a scalable,
coherent home instead of building it on the JSON path and migrating later.

## What Changes

### Proto: one message per host result
- **ADD** `proto.SweepHostResult` carrying everything for one host:
  `host`, `available`, `first_seen`, `last_seen`, `response_time_ns`,
  `sweep_modes`, an `IcmpStatus`, repeated `PortResult`, and an optional
  `MtrTraceResult` (the existing message, finally used) for the full per-hop
  trace. **ADD** a `SweepResultBatch` (repeated `SweepHostResult` +
  execution/group/partition metadata) as the on-the-wire unit.
- The heavy per-hop trace lives in the typed `MtrTraceResult` sub-message (not
  JSON, not metric attributes); the cheap reachability summary is just scalar
  fields on `SweepHostResult`.

### Agent: emit proto, not JSON
- **CHANGE** the sweep results emission (`sweep_service.go` /
  `push_loop_sweep_results.go`) to marshal `SweepResultBatch` protobuf instead
  of JSON-in-`ResultsChunk.data`. Keep a bounded transition: emit proto with a
  clear content marker so a mixed fleet is safe (see rollout).

### Core: decode proto once, fan out
- **CHANGE** the event-writer sweep path to decode `SweepResultBatch` protobuf
  and write `sweep_host_results` / `ocsf_network_activity`, and — for hosts
  carrying an `MtrTraceResult` — `mtr_traces` / `mtr_hops`, from the **same
  decoded message**. No second pipeline for the trace.
- **KEEP** the JSON decode path during rollout (detect format), then remove it
  once the fleet is on proto.

### Backward-compatible rollout
- Agents and core deploy independently, so both formats MUST be accepted during
  transition. Approach (finalized in design.md): a format discriminator on the
  chunk/subject so core routes JSON to the legacy decoder and proto to the new
  one; agents flip to proto behind the existing config-version gate; JSON
  support is removed in a later release once no agent emits it.

## Impact

- **Affected specs**: `ingestion-routing` (MODIFIED — sweep results become
  native protobuf; MTR trace carried in-band).
- **Affected code**:
  - `proto/monitoring.proto` (new `SweepHostResult` / `SweepResultBatch`;
    reuse `MtrTraceResult`) + generated Go/Elixir.
  - Go agent: `sweep_service.go`, `push_loop_sweep_results.go`, result builders.
  - Elixir core: `event_writer/processors/sweep.ex` (+ a proto decoder),
    `results_router.ex`, `mtr` ingestion reuse.
- **Compatibility**: staged. During rollout both JSON and proto are accepted;
  no data loss. This is a **prerequisite** for `add-sweep-profile-mtr-mode`
  (3b) — MTR sweep results build on the proto foundation instead of JSON, so
  they are not built twice.
- **Relationship**: unblocks and reorders ahead of 3b. The standalone
  MTR-checker/on-demand-MTR paths (metrics + command-result) can converge onto
  the same typed trace later (#4669).
