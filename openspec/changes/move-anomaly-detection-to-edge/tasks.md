## 1. Proposal
- [x] 1.1 Validate with `openspec validate move-anomaly-detection-to-edge --strict`.

## 2. Add-on input primitive (agent → add-on metric feed)
- [x] 2.1 Add an agent→add-on metric-feed RPC to `proto/agent/addon/v1/addon.proto` (stream of `MetricBatch` from agent to add-on, with backpressure/flow control mirroring the gateway path).
- [x] 2.2 Regenerate Go/Rust stubs and wire the agent to tap its local sample stream (`go/pkg/agent/metric_envelope.go`, `push_loop_status.go`, `go/pkg/sysmon/collector.go`) and fan it to subscribed add-ons before the gateway push.
- [x] 2.3 Make the feed opt-in per add-on capability and per metric source (sysmon/snmp/icmp/timeseries), so an add-on only receives the sources it declares.

## 3. Native anomaly add-on
- [ ] 3.1 Create `rust/anomaly-addon` using `rust/addon-sdk`; consume the local metric feed.
- [ ] 3.2 Reuse the existing per-series Welford z-score detector (the anomaly NIF / `causal-engine` detector math) so edge verdicts are byte-identical to central verdicts for the same input.
- [ ] 3.3 Bound per-host state: fixed-size sliding window per series, capped series count, drop process/PID series (already excluded centrally), and emit a drop/cap telemetry counter.
- [ ] 3.4 Emit anomaly verdicts (and optional 1m/5m rollups) upstream via `StreamTelemetry`; map them onto the existing signal/verdict path so central treats an edge verdict identically to a central one.
- [ ] 3.5 Local per-series checkpoint + re-warm/reseed on add-on restart; no central ownership/lease at the edge.

## 4. Resource governance (edge-node safety)
- [x] 4.1 Add CPU/memory (and cgroup/slice) limit fields to `addons/native-addon-manifest.schema.json` and the manifest validator.
- [ ] 4.2 Enforce the limits in the add-on supervisor (go-plugin sidecar) and the systemd unit generator (`MemoryMax`, `CPUQuota`, slice).
- [ ] 4.3 Add an add-on self-throttle + shed path: under limit pressure the add-on sheds analysis (and reports it) rather than impacting the host or the agent.

## 5. Central coordination (edge vs central coverage)
- [ ] 5.1 Make central anomaly analysis skip series covered by an edge add-on; keep central analysis as the fallback for uncovered sources and during rollout.
- [ ] 5.2 Add coverage telemetry: per-source edge-covered vs central-analyzed series counts, and a verdict-source label (edge|central).
- [ ] 5.3 Document the rollout/runback: enable per cohort via `add-native-addon-edge-ops` targeting; disabling the add-on returns those series to central analysis with no verdict gap.

## 6. Tests and benchmarks
- [ ] 6.1 Parity test: same captured `MetricBatch` fixtures produce identical verdicts edge vs central.
- [ ] 6.2 Edge resource benchmark: CPU/RSS of the anomaly add-on at a realistic per-host series count (post process-cap), proving it stays within a conservative budget.
- [ ] 6.3 Restart/re-warm test: add-on restart re-warms baselines without false-positive storms.
- [ ] 6.4 Measure central load delta: anomaly durable lag/CPU with edge coverage on vs off.

## 7. Delivery
- [ ] 7.1 Summarize parity + edge-resource + central-offload results in the PR.
- [ ] 7.2 Open a Forgejo PR against `staging`.
