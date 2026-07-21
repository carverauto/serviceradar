# Design: Unify sweep/MTR results on native protobuf

## Context

Sweep results are JSON-in-`ResultsChunk.data` decoded per-host in core; MTR
rides the metrics/command paths; `MtrTraceResult` proto is defined but unused.
Goal: one native-proto message per host that carries ICMP + TCP + the full MTR
trace, decoded once, fanned out to the right tables — removing JSON from the
sweep hot path and collapsing the split MTR delivery.

## Decisions

### D1: `SweepHostResult` is the single per-host result
```proto
message SweepHostResult {
  string host = 1;
  bool available = 2;
  int64 first_seen_unix_ns = 3;
  int64 last_seen_unix_ns = 4;
  int64 response_time_ns = 5;
  repeated string sweep_modes = 6;         // "icmp","tcp","mtr"
  IcmpStatus icmp = 7;                      // reachability
  repeated PortResult ports = 8;            // tcp
  MtrTraceResult mtr = 9;                   // full per-hop trace (existing msg)
}
message SweepResultBatch {
  repeated SweepHostResult hosts = 1;
  string execution_id = 2;
  string sweep_group_id = 3;
  string partition = 4;
  string agent_id = 5;
  string gateway_id = 6;
}
```
`IcmpStatus` / `PortResult` mirror the Go structs. `MtrTraceResult` is the
already-defined message, finally populated. One message = one host's full
result across all modes; the heavy hop data is a typed sub-message, never JSON.

### D2: Core decodes once, fans out
The event-writer sweep path decodes `SweepResultBatch` and, per host, writes:
- `sweep_host_results` / `ocsf_network_activity` (reachability + ports), and
- `mtr_traces` / `mtr_hops` when `mtr` is set — from the **same** decoded
  message. No separate MTR pipeline for the sweep case.

### D3: Rollout format discriminator (agents and core deploy independently)
Both formats MUST be accepted during transition. Chosen mechanism: a **format
marker** so core routes without guessing:
- Preferred: publish proto sweep batches on a distinct subject
  (`sweep.results.proto.>` or a `content_type` field on the chunk/status),
  keeping the legacy JSON path on its current subject. Core runs both decoders;
  each is unambiguous.
- Agents switch to proto behind the existing config-version/rollout gate so a
  fleet can be flipped gradually. Once telemetry shows no agent emits JSON, the
  JSON decoder + `ResultsChunk`-JSON emission are removed in a follow-up
  release. (No silent dual-decode heuristics — the marker is explicit.)

### D4: Keep the change surgical
This change migrates the **sweep results** path only. The scheduled MTR checker
(metrics path) and on-demand MTR (command-result path) are **not** migrated
here; converging them onto the typed `MtrTraceResult` is the #4669 follow-on.
Scope is: proto messages + agent sweep emit + core sweep decode + rollout.

## Risks / Trade-offs

- **Wire-format migration is the risky part.** A mismatched agent/core during
  rollout must never drop or corrupt results — hence the explicit format marker
  (D3) and dual-accept window, not a heuristic sniff.
- **Proto schema churn.** Sweep result fields have historically evolved (banner
  grab, now MTR); protobuf's additive field rules handle this fine, but the
  team loses JSON's "just add a key" freedom. Accepted: the scale win and
  single-path coherence outweigh it, and additive proto fields are cheap.
- **Bigger blast radius than a feature change.** This touches the core
  ingestion path every sweep uses. Mitigated by the dual-accept window + strong
  round-trip tests (agent proto encode -> core proto decode -> tables) before
  flipping any fleet.

## Migration / Sequencing

1. Land proto messages + generated code (no behavior change).
2. Core: add the proto decoder alongside the JSON one (dual-accept).
3. Agent: emit proto behind the config gate (still JSON by default).
4. Round-trip + integration tests; flip a canary agent; then the fleet.
5. Remove JSON emit/decode in a later release.
6. **Then** `add-sweep-profile-mtr-mode` (3b) adds the MTR sweep mode on this
   proto foundation.

## Out of scope
- Migrating the MTR checker / on-demand MTR paths (#4669 follow-on).
- The MTR sweep *mode* itself (3b, built on this).
