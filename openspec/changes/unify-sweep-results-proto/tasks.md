# Tasks: Unify sweep/MTR results on native protobuf

## 1. Proto messages
- [ ] 1.1 `proto/monitoring.proto`: add `SweepHostResult` (host, available,
  timestamps, response_time_ns, sweep_modes, `IcmpStatus`, repeated
  `PortResult`, optional `MtrTraceResult`) and `SweepResultBatch` (repeated
  hosts + execution/group/partition/agent/gateway).
- [ ] 1.2 Add `IcmpStatus` / `PortResult` messages mirroring the Go structs;
  reuse the existing `MtrTraceResult` / `MtrHopResult`.
- [ ] 1.3 Regenerate Go + Elixir protobuf; update BUILD/MODULE as needed.

## 2. Agent: emit proto
- [ ] 2.1 Map `models.HostResult` -> `SweepHostResult` (incl. `MtrTraceResult`
  when present) in the sweep results builder.
- [ ] 2.2 `push_loop_sweep_results.go` / `sweep_service.go`: emit
  `SweepResultBatch` protobuf with the explicit format marker (distinct
  subject or `content_type`), behind the config-version gate; JSON remains the
  default until flipped.
- [ ] 2.3 Go round-trip tests: HostResult -> proto -> HostResult parity
  (incl. MTR trace); `bazel build` the agent + proto targets.

## 3. Core: decode proto + fan out
- [ ] 3.1 Add a protobuf sweep decoder in the event-writer sweep path; route by
  format marker (proto vs legacy JSON).
- [ ] 3.2 Fan out one decoded `SweepHostResult` to sweep_host_results /
  ocsf_network_activity and (when `mtr` present) mtr_traces / mtr_hops.
- [ ] 3.3 Keep the JSON decoder intact during rollout; add telemetry counting
  proto vs JSON so the fleet flip is observable.
- [ ] 3.4 ExUnit (integration): proto batch -> rows in the right tables; mixed
  JSON+proto batch both persist.

## 4. Rollout + cleanup plan
- [ ] 4.1 Document the flip: config-gate agents to proto gradually; watch the
  proto/JSON telemetry; only remove JSON after the fleet reports 0 JSON.
- [ ] 4.2 File the JSON-removal follow-up (separate release) + note the
  MTR-checker/on-demand convergence (#4669).

## 5. Verification
- [ ] 5.1 `bazel build //proto/... //go/pkg/agent/... //go/pkg/sweeper/...`.
- [ ] 5.2 `mix compile --warnings-as-errors` (core) + integration tests vs
  srql-fixtures.
- [ ] 5.3 e2e: agent (proto) -> gateway passthrough -> core -> tables, with a
  mixed-format check.
- [ ] 5.4 `openspec validate unify-sweep-results-proto --strict`.
