## Context
Short-term spike detection has moved from the retired core-elx raw-stream
analyzer to the native edge `anomaly` add-on. Core-elx now consumes edge spike
verdicts, central seasonal anomaly verdicts, and capacity forecast verdicts
through the causal prediction spine.

This audit focused on:
- `rust/anomaly-addon/src/addon.rs` and `engine.rs`
- `rust/anomaly-core/src/detector.rs` / `window.rs`
- `go/pkg/agent/addon/manager.go` and `metric_feed.go`
- `elixir/serviceradar_core/lib/serviceradar/status_handler.ex`
- `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/causal_signals.ex`
- `elixir/serviceradar_core/lib/serviceradar/observability/seasonal_disposition/worker.ex`
- `elixir/serviceradar_core/lib/serviceradar/plugins/anomaly_addon_profile_seeder.ex`

Focused tests pass today:
- `sfw cargo test -p serviceradar-anomaly-addon -p serviceradar-anomaly-core`
- `mix test test/serviceradar/status_handler_test.exs test/serviceradar/event_writer/processors/causal_signals_test.exs test/serviceradar/observability/seasonal_disposition/worker_test.exs`

Those tests do not cover the gaps below.

## Findings

### F1: Edge add-on emits pending findings and never emits clears
`process_frame/3` emits a telemetry record whenever `verdict.breached ||
verdict.anomalous`. With default `confirm_slots=5`, the first four breached
slots are `pending_anomaly` but still become OCSF Detection Findings and can
enter alert evaluation. Conversely, a clean sample after an active anomaly is not
emitted because clean verdicts are filtered out. This violates the documented
"confirmed anomalies" behavior and leaves no explicit recovery signal.

### F2: Native telemetry stream is single-use and can permanently lose verdicts
`AnomalyAddon.stream_telemetry/1` consumes a single `mpsc::Receiver` from
`verdict_rx`. A later stream call returns an empty stream. If the agent telemetry
stream disconnects while the add-on process stays up, future verdicts have no
receiver. Because `process_frame/3` awaits `verdict_tx.send/1`, a full or closed
telemetry channel can also delay metric-feed acknowledgements even though native
telemetry is meant to be lossy.

### F3: Numeric OCSF timestamps from the add-on are parsed as "now"
The add-on writes OCSF `time` as an integer millisecond timestamp. `CausalSignals`
normalizes time through `DateTime.from_iso8601(to_string(value))`; numeric
milliseconds/nanoseconds fail that parse and fall back to `DateTime.utc_now()`.
Persisted anomaly findings can therefore be timed at ingest rather than at the
sample event time.

### F4: Canonical re-keying leaves precomputed finding identity stale
`StatusHandler` rekeys `anomaly.series_key` and `source_identity.series_key` from
attested `source_identity`, but leaves the add-on's precomputed `finding_info.uid`
and dimensions unchanged. `CausalSignals.anomaly_detection_finding_info/2`
accepts any payload `finding_info.uid` as authoritative, so metadata can contain
a canonical series key and a finding UID built from the provisional edge hint or
raw device id. This weakens dedupe/grouping and makes joins harder to reason
about.

### F5: Central seasonal confirmation state is not persisted in production
`SeasonalDisposition.Worker` loads `consecutive_anomalous` from injected test
state or `:carried_state`, and `persist_state/4` is a no-op unless a test
persister is supplied. Runtime settings map the global anomaly `confirm_slots`
into seasonal disposition options. With `confirm_slots > 1`, production can
reset confirmation to zero every Oban run and never surface sustained seasonal
breaches.

### F6: Operator tuning does not reach edge spike detector defaults
Core refreshes anomaly settings into `AnomalyConfigRuntime`, but the default
edge add-on profile currently seeds only `metric_feed.sources`. Unless an
operator edits add-on assignment params directly, `n_sigma`, `window_size`,
`min_samples`, and `confirm_slots` stay at add-on defaults. The docs and settings
surface imply deployment-level tuning affects edge spike detection, which is not
true today.

### F7: Edge add-on config can silently disable scoring
The add-on schema and `AddonConfig.into_engine_config/1` do not enforce
`min_samples <= window_size`. Setting `min_samples` greater than `window_size`
leaves the baseline permanently not ready. The core Ash resource has this guard,
but assignment-level add-on config does not.

### F8: Edge scoring is O(window) per sample despite O(1) design language
The edge engine clones `window_tail` and `anomaly-core` recomputes Welford state
from the bounded window on every evaluation. Existing benchmarks show this is
acceptable for current per-host caps, so it is not the first fix. It should be
documented as the current performance envelope or replaced with a provenance-safe
stateful accumulator if the cap/window targets grow.

Post-F9/F20 decision: keep the current stateless recompute for this change. The
important reliability fix is that F9 now bounds the number of retained per-series
windows and counter states through `max_series` plus staleness eviction; it does
not change the per-live-sample CPU class. The accepted envelope is therefore
`O(live_series * window_size)` memory for retained rolling tails and `O(window_size)`
CPU per evaluated sample in the stateless core path. That tradeoff is deliberate:
`compact_rolling_state` rebuilds from the window so the transported accumulator
cannot corrupt a baseline when provenance is not guaranteed. Revisit this only if
benchmarks at the intended `max_series`, `window_size`, and feed cadence show the
window scan is material, or if the core grows a provenance-safe stateful runtime
API that can update/remove Welford samples without trusting cross-boundary state.
At current defaults, the edge cap is `max_series=50_000` and
`window_size=300`, so the worst-case steady retained tail is roughly 15 million
sample values per add-on process plus the counter-state map, and each evaluated
sample performs a 300-value stats rebuild before scoring.

## Decisions
- Treat F1-F7 as implementation blockers for reliable anomaly rollout.
- Treat F8 as a measured performance follow-up unless new benchmarks show it is
  material at intended `max_series`, `window_size`, and feed cadence.
- Keep all anomaly and capacity findings on the causal prediction spine. Do not
  reintroduce the retired central raw-stream spike analyzer.
- Preserve `serviceradar-anomaly-core` as the single scoring implementation.

## Risks / Trade-offs
- Adding active-state tracking changes edge add-on checkpoint shape. Mitigate by
  version-tolerant checkpoint restore that defaults missing active state to
  inactive.
- Recomputing finding identity in core can alter deterministic IDs for existing
  edge findings. Mitigate by documenting the one-time dedupe improvement and
  using canonical fields consistently.
- Persisting seasonal confirmation state adds storage. Mitigate with a bounded
  table or existing resource keyed by `(source, series_key, dow, hod)` and TTL for
  stale series.
- Broadcast/drop telemetry can lose intermediate duplicate anomalous samples.
  That is acceptable because production should emit transitions, not every
  breached sample.

## Open Questions
- Should edge add-on tuning be updated by reconciling every anomaly profile from
  `AnomalyDetectionConfig`, or should the UI split "edge spike defaults" from
  "central seasonal/capacity settings" explicitly?
- Should edge anomaly-open and anomaly-clear use the same `finding_info.uid`
  with status transitions, or distinct event IDs with a shared `group_uid`?
- Should seasonal confirmation state live in a dedicated Ash/Postgres table, or
  reuse a compact key/value runtime table if one already exists for worker state?

## Additional Findings (Deep Multi-Agent Audit, 2026-06-18)

A second, exhaustive audit (13 scoped finders + adversarial verification across
`rust/anomaly-addon`, `rust/anomaly-core`, `rust/causal-disposition`,
`go/pkg/agent/addon`, and the core-elx ingestion/seasonal/capacity/config path)
surfaced 62 additional verified issues. They are consolidated below as F9-F20.
F15 is a **blocker**: the central seasonal path's data feed does not exist.

### F9: Edge detector state is unbounded and never evicted (HIGH)
`DetectorEngine` enforces `max_series` only when inserting into `self.series`
(`engine.rs:223-235`). The parallel `self.counters` map — written on every
counter warmup/reset/gap/advance branch (`engine.rs:141-203`) — has **no cap and
no eviction**, and `restore_checkpoint` reseeds counters with no cap either
(`engine.rs:387-399`). Because cumulative counters (per-interface SNMP octets) are
the dominant high-cardinality case and are rate-normalized *before* `evaluate`
runs, `counters` is the map most likely to grow without bound, yet the
`dropped_at_capacity` shed report (`addon.rs:344-356`) reflects only `series`, so
the growth is invisible. Separately, **neither map is ever pruned by staleness**:
once `max_series` distinct keys have *ever* been seen, every genuinely new series
is permanently shed and the detector goes deaf to new series while re-firing the
capacity-shed alarm every frame until the add-on is restarted. The struct is
doc-commented "Bounded map" — the contract is violated. Fix: cap and
staleness-evict both maps (the `last_observed_at_unix_nano` is already stored);
include counter-map size in the shed report.

### F10: Edge metric-feed task lifecycle is leaky and not reconnect-safe (HIGH)
`stream_metric_feed` unconditionally `tokio::spawn`s a scoring loop, keeps no
`JoinHandle`, and never aborts a prior task (`addon.rs:215-264`). If the agent
re-opens the metric feed (reconnect / agent restart against a still-running
add-on), the previous scoring task keeps running and **two tasks now race the same
engine mutex and the same checkpoint file** (`write_checkpoint`,
`addon.rs:395-409`), corrupting baselines and double-scoring. Compounding this,
the engine `std::Mutex` is unwrapped with `.expect("engine mutex poisoned")`
(`addon.rs:284`, also `171-174,397,425`): a single panic while the lock is held
**poisons the mutex and permanently kills all future scoring** with no recovery.
Fix: single-owner feed task (abort/replace prior on reopen), and treat lock
poisoning as a recoverable re-init rather than a hard panic.

### F11: Agent-side anomaly delivery never self-heals — F2 fix is necessary but not sufficient (HIGH)
The Rust single-use telemetry receiver (F2) is mirrored by **the same one-shot
pattern on the Go host**, so fixing only the add-on leaves delivery broken:
- The supervisor permanently abandons a circuit-broken add-on:
  `if !r.recordRestart(err) { setState(StateCircuitOpen); return }`
  (`manager.go:456-459`) ends the goroutine; the only revival path is operator
  config reconciliation via `Apply()`. A transient crash storm silently and
  permanently removes spike detection for that node.
- `drainTelemetry`, `drainArtifacts`, and `metricFeedLifecycle.run` each open
  their stream **once** and `return` when the channel closes
  (`manager.go:798-821`, `metric_feed.go:164-222`); they never reconnect while the
  add-on stays alive. `grpc.go` collapses EOF and transport errors into a silent
  bare `return` (`grpc.go:356-375`), so a recoverable stream reset stops all
  verdict/metric flow with the add-on still reporting `Running/Healthy`.
- The metric feed hard-blocks after `maxInFlight=32` frames if the add-on stops
  acking (`metric_feed.go:187-200`), and the backoff reset keys on last-run
  duration, not stability (`manager.go:449-479`), so a fast crash-loop keeps
  resetting backoff.
Fix: reconnect drains with backoff tied to subprocess liveness; re-arm the
breaker after a cooldown; surface stream-loss diagnostics instead of swallowing.

### F12: Verdict identity is not idempotent — redelivery and re-runs create duplicate findings (HIGH)
`ocsf_events` has a composite PK `(id, time)` and both persistence paths dedup on
it (`causal_signals.ex:154` bulk `on_conflict: :nothing`; `192,218-232` Ash
existence guard). Two distinct defects defeat this:
- Edge verdicts: the numeric-timestamp parse bug (F3) makes `time` resolve to
  `now()`, so the same deterministic `id` lands on a different `(id, time)` on
  JetStream redelivery and **inserts a duplicate finding** instead of conflicting.
- Central verdicts: capacity and seasonal `event_id` splice a per-run wall-clock
  timestamp into the stable key (`verdict_emitter.ex:124-136` joins
  `iso8601(forecasted_at)`; seasonal joins `bucket_ended_at||evaluated_at`). The
  derived row `id` changes **every Oban run**, so one sustained condition produces
  an ever-growing pile of distinct "open" findings, defeating downstream alert
  dedup.
Also: `max_deliver=5` on the durable consumer silently drops a persistently
failing (poison) verdict with no dead-letter (`event_writer/config.ex:72-73`); and
there is no clock-skew guard on add-on-supplied timestamps used for ordering/dedup
(`causal_signals.ex:884-893`). Fix: make event identity time-independent (key on
the deterministic finding/series identity) and rely on status transitions for
lifecycle; add a DLQ/alert for max-deliver exhaustion.

### F13: Anomaly identity omits partition and trusts feed-controlled fields (HIGH, security/data-integrity)
`SeriesKey.from_source_identity` builds the canonical `series_key` by `:`-joining
identity components with `series_dimensions` that pull **raw producer-supplied tag
values** with only key-name filtering, not value sanitization
(`series_key.ex:65-72,99-124`), and the key does **not include `partition_id`**.
`StatusHandler.publish_edge_anomaly_verdict` re-keys purely from the add-on's
`source_identity` with no check against the gateway-attested
`agent_id`/`partition` (`status_handler.ex:356-375`). On the edge,
`series_identity_hint` flows verbatim into the `finding_uid` (`addon.rs:589-600`).
A value containing the `:` delimiter (free-form tags, hostnames, IPs) collides two
distinct series onto one finding UID; absent partition scoping, identical
`device_ip`/`if_index` can cross-resolve between tenants. The capacity link-speed
join has the same gap: `InterfaceCapacity.resolve` queries
`discovered_interfaces` with **no `partition_id` predicate**
(`interface_capacity.ex:20-50,95-102`), so a capacity *denominator* (interface
speed) can be resolved from another tenant's row. Fix: scope identity and joins by
partition; hash/escape free-form values before splicing into delimited keys;
validate producer identity against the attested envelope.

### F14: Edge and central verdicts for the same series do not correlate (MEDIUM-HIGH)
Canonical re-keying (F4) exists so an edge spike finding and a central
seasonal/capacity finding about the *same* series can be joined. But the edge
re-key path publishes to an **unsanitized** NATS subject derived from the readable
series_key (dots from IPs/`snmp.ifInOctets`, spaces, possible `*`/`>` wildcards),
while the central emitters sanitize the same key before building their subject
(`status_handler.ex:377-381` vs the capacity/seasonal emitters). The two paths
therefore emit on divergent subjects/keys and never line up — and an unsanitized
subject containing NATS wildcards risks publish failure. Fix: route edge re-keyed
verdicts through the same subject-sanitization helper the central emitters use.

### F15: Central seasonal disposition cannot function as built — data feed is unimplemented (HIGH, BLOCKER)
The seasonal source queries request `stats:profile_hour_of_week(value)` and read
back `dow/hod/center/mad/p05/p95/bucket_count/bucket_sum/bucket_sum_sq`
(`seasonal_disposition/source.ex:79-101`). **No such SRQL stats verb exists.** The
production runner translates via the SRQL NIF (`rust/srql`), whose
`parse_single_stats_agg` supports only `count/sum/avg/min/max`, requires an `as`
alias, and returns `None` for everything else (`parser.rs:669-757`); the seasonal
query has no alias, so it yields **zero aggregations** and none of the columns the
worker consumes. Repo-wide there is no SQL producing `mad/p05/p95/bucket_sum_sq` —
the robust statistics live only in the `causal-disposition` NIF that *consumes*
pre-aggregated buckets. So seasonal detection has no live data feed; existing
worker tests pass only because they inject mock rows. Secondary seasonal defects:
the worker hardcodes `status: "breach"` and `surfaces?/1` returns true only for
`:seasonal_breach`, so **clears are never emitted** (`worker.ex:179-225,357-358`);
the emitted verdict's bucket window is zero-width (`bucket_started_at` and
`bucket_ended_at` both read `source.bucket_field`, `worker.ex:294-296`); Oban
uniqueness is defeated by a per-run `evaluated_at` arg so manual triggers overlap
(`worker.ex:31-34,78-93`); and dow/hod bucketing is UTC, smearing local
seasonality and shifting across DST (`source.ex:79-101`). Fix: implement the
`profile_hour_of_week` SRQL verb (or a dedicated bucket-profile query) that emits
the consumed columns; make the worker fail loudly when the feed returns no profile
columns; emit clears; correct the bucket window, Oban uniqueness key, and TZ.

### F16: Capacity forecasting has correctness and dead-path defects (MEDIUM)
- The flow-capacity source labels raw bytes-per-hour as `"bps"` and sets **no
  threshold**, so that forecast can never produce an alert
  (`capacity_forecasting/source.ex:92-102`).
- Holt-Winters can report a negative `slope_per_second` yet still emit an
  exhaustion ETA via the projected value (`causal-disposition/.../holt_winters.rs:75-93`).
- Counter-wrap handling **deletes interior points**, desynchronizing the
  Holt-Winters seasonal phase/step instead of inserting a gap
  (`capacity_forecasting/worker.ex:627-638`).
- `warning_horizon_seconds` can be set larger than the forecast `horizon_seconds`,
  so a near-term exhaustion never warns (`worker.ex:559-568`).

### F17: Detector numeric edge cases produce false breaches and undefined stats (MEDIUM)
- **Zero-variance breach is unconditional.** When `effective_stddev <= EPSILON`,
  `z_score` returns `(threshold + 1.0) + magnitude.ln_1p()`, which breaches for
  *any* nonzero deviation (`stats.rs:177-188`). Rate-normalized counters use
  `SeriesProfile::default()` (no dispersion floor, `addon.rs:304-308`), so a
  near-constant counter rate that ticks once produces a Critical regardless of
  `n_sigma`. The `f64::EPSILON` guard is also far too tight: stddev in
  `(2.2e-16, ~1e-3]` still explodes the normal division branch.
- `sample_stats` divides by `count` and `count - 1` with no guard, yielding
  `NaN`/`inf` (or a panic) for windows of length 0 or 1 (`stats.rs:140-156`); this
  is a public API.
- `WelfordAcc::add` silently drops non-finite samples, decoupling `acc.count` from
  the caller's logical sample count and skewing readiness (`stats.rs:59-75`).
- `confirm_slots` accounting is off-by-one relative to its documented meaning
  (`detector.rs:92-105,293`) — worth a spec-level definition so edge and the F5
  central seasonal confirmation agree.

### F18: Config model mismatches between core, edge, and SRQL (MEDIUM)
Extends F6/F7. Core models the window as both a sample count (`window_size`) and a
wall-clock `window_duration_seconds` with a DB `>= 1` constraint
(`anomaly_detection_config.ex:109-115`), but the edge add-on window is purely
count-based — the duration knob has no edge representation. Runtime normalization
invents a `'mem'` override alias that matches neither the seasonal tier names nor
the Rust gauge classes (`anomaly_config_runtime.ex:272-282`). The edge 32-bit
counter-wrap salvage hard-codes `COUNTER32_MODULUS` as the max plausible rate and
silently disqualifies all salvage when `counter_width` is unknown/zero
(`engine.rs:416-434`), diverging from central's per-sample-max approach.

Decision for `window_duration_seconds`: scope it away from edge scoring. It
remains central/operator metadata for target sampling cadence and baseline
planning, while the edge add-on receives and enforces the count-based
`window_size` only.

### F19: No signal tells an operator that scoring is silently broken (MEDIUM, operability)
Almost every failure mode above is silent: swallowed verdict send after a
telemetry disconnect (`addon.rs:359-367`), a circuit-broken add-on, seasonal
emitting nothing, `min_samples > window_size` disabling scoring, and the unbounded
shed storm. Worse, the cgroup memory/pid enforcement that is supposed to contain
the F9 leaks is best-effort and **silently no-ops** on any write failure or when
`cgroupRoot == ""` (`resource_limits_linux.go:27-60`), so the last line of defense
can be inactive with only a log line. There is no end-to-end "scoring alive /
verdicts flowing / state bounded / limits applied" health surface. Fix: add a
liveness/health signal (verdict throughput, tracked-series vs cap, last-scored
timestamp, enforcement-applied flag) so a healthy-but-silent detector is
distinguishable from a working one.

### F20: Verdict-spine and worker performance at fleet scale (MEDIUM, extends F8)
- The verdict spine is N+1: every anomaly/capacity verdict takes the Ash path
  (`ash_recorded_row?`), which runs a synchronous `SELECT 1 ... WHERE time=$1 AND
  id=$2` then a separate per-row `Ash.create` — 2 DB round-trips per verdict,
  serialized, under exactly the correlated-fleet-anomaly load it exists to handle
  (`causal_signals.ex:161-200,218-232`). The existence check is also TOCTOU.
- Each row does a per-row `DeviceCorrelation.resolve` cache lookup inside the
  synchronous build map (`causal_signals.ex:578,1214-1221`).
- Capacity/seasonal workers page up to 100 pages then `List.flatten` the entire
  history into BEAM memory before computing (`capacity_forecasting/worker.ex:141-185`).
- The agent deep-copies the metric-feed payload per subscribed add-on and silently
  drops on queue-full (`metric_feed.go:131-162`).
- Counter normalization clones the prior `CounterState` and re-owns two `String`s
  on every reading (`engine.rs:153-197`), compounding F8's O(window) per-sample cost.
Fix: batch the causal-prediction inserts (`insert_all` + `ON CONFLICT DO NOTHING`),
stream worker history instead of materializing it, and avoid per-reading
allocations in the counter path.

## Decisions (deep-audit addendum)
- F15 is a rollout blocker: central seasonal disposition has no implemented data
  feed. Either implement the `profile_hour_of_week` SRQL profiling verb or replace
  the seasonal source with a query path that produces the consumed bucket
  statistics, before relying on seasonal verdicts.
- F11 broadens F2/delivery: the agent host must self-heal independently of the
  add-on fix. Treat F9 (unbounded state), F11 (agent delivery), F12 (idempotency),
  and F13 (partition/identity) as implementation blockers alongside F1-F7.
- F16-F20 are correctness/operability/perf follow-ups; F17's zero-variance counter
  breach is the highest-priority of them because it generates false Criticals.

## Live End-to-End Validation (demo namespace, 2026-06-19)

The pipeline was traced live in the `demo` namespace against agent
`agent-sr-test-pve04` (host 192.168.1.62, partition `default`). The spike trigger
is the agent control-stream command **`sysmon.debug_spike`** (payload
`{"metric","value","samples"}`, no capability gate), dispatched from core via
`ServiceRadar.Edge.AgentCommandBus.dispatch(agent_id, "sysmon.debug_spike", payload)`.
A 12-sample CPU spike at 99% was injected and followed through to persisted
findings.

### What works
- **Delivery works broadly.** The 0.1.1 add-on (the build with `metric_feed`) is
  installed and signed on 12 agents; `addon_statuses` shows 11 `running`/`active`
  v0.1.1, healthy. Delivery is NOT the primary problem.
- **Edge spike scoring works end to end.** The spike reached central
  `timeseries_metrics` (`cpu.usage_percent=99.0` at 03:35:42) and produced edge
  `anomaly_detection` Detection Findings (one Critical per core, persisted ~03:35:56)
  — add-on -> agent telemetry -> gateway -> core -> DB.

### What is broken (live confirmations + new findings)

**F21 (NEW, HIGH): empty-string numeric config params permanently brick the add-on.**
`agent-k8s-cp2-worker1` is `state=circuit_open, active=false, restart_count=5`,
permanently dead, with `degradation_reason = "addon rejected configuration:
invalid anomaly add-on config: invalid type: string \"\", expected u64 at line 1
column 29"`. Its assignment `params` carry empty strings for every numeric knob
(`%{"confirm_slots" => "", "max_series" => "", "window_size" => "", "n_sigma" =>
"", ...}`). The Rust `AddonConfig` deserializer expects `u64`/`f64` and rejects
`""`, so the add-on refuses to start, crash-loops past the restart limit, trips the
breaker, and never recovers (live F11/N06). Two agents are mis-seeded this way
(`agent-k8s-cp2-worker1`, `k8s-agent`). This is three bugs stacked: a seeder that
writes `""` for unset numerics, a Rust config layer that rejects `""` instead of
coercing empty/absent to a default, and the no-recovery breaker. Fix: seeder must
omit unset keys (or send numbers/null, not `""`); the add-on must treat empty/absent
optional knobs as defaults; the breaker must re-arm (F11).

**F22 (NEW, HIGH; sharpens F10): the add-on cannot shut down gracefully -> SIGKILL restart storms.**
The agent logged `[WARN] addon.anomaly: plugin failed to exit gracefully` followed
by `[ERROR] ... plugin process exited ... error="signal: killed"` ~40 times in 8
minutes (21:35-21:43 on pve04), then silence for ~4.5h (breaker), then again at
02:16. Every time the manager tries to stop/restart the add-on (reconcile, version
change), the add-on's shutdown path blocks (consistent with F10's un-abortable
scoring task / blocking `verdict_tx.send().await`), so go-plugin SIGKILLs it. This
also corrupts the warm baseline on every kill. Fix: make the add-on's Shutdown
return promptly (abort the scoring task, drop the feed) — directly the F10 fix.

**F23 (NEW, HIGH; sharpens F19/N03): declared resource limits are not enforced.**
The running add-on (PID 916907) is in cgroup
`0::/system.slice/serviceradar-agent.service` — the **agent's own cgroup**, not
`serviceradar-addons.slice`. `memory.max = max` (unlimited), `oom_kill = 0`. The
addon.yaml declares `memory_max_bytes: 268435456` and `slice:
serviceradar-addons.slice`, but none of it is applied, so an add-on memory leak
(F9) would consume the agent's/host's memory with no containment and no signal.
The agent cgroup was already at `memory.current=492MB / peak=520MB`. Fix: actually
place the add-on in its bounded slice and surface a health flag when enforcement is
absent (F19).

**F24 (NEW, MEDIUM; sharpens F4/F13): edge finding identity is incoherent across metric types.**
The spike's sysmon findings carry **`device.hostname = nil`** (only `device.uid =
"sr-test-pve04"`), and their `series_key` is keyed on host_id
(`sysmon.cpu:sysmon:cpu:sr-test-pve04:0:CPU0`), while the same agent's SNMP findings
key on agent_id (`snmp:agent-sr-test-pve04:31`) and DO carry
`hostname="agent-sr-test-pve04"`. So findings from one physical agent split across
two identities and one of them has no hostname — host-level correlation and
dedupe break. Fix: unify device identity (uid + hostname) and series-key host
component across sysmon and SNMP on the canonical re-key path (F4/F13).

**Live confirmations of static findings:**
- **F1 (live):** the 99% spike produced one Critical per core for all 16 cores, with
  duplicate rows for the same core within ~2ms; pve04 has 12,211 sysmon findings
  all-time and edge findings run ~615 rows / 45 series in 90m. No open/clear
  transitions — every breached sample emits.
- **F3 (live):** persisted finding `time` is the ingest time (~03:35:56), not the
  sample/metric event time (03:35:42).
- **F6 (live):** `agent-sr-test-pve04`'s assignment `params` is only
  `%{"metric_feed" => %{"sources" => ["sysmon","snmp"]}}` — no `n_sigma`,
  `window_size`, `min_samples`, or `confirm_slots`; the add-on runs entirely on
  built-in defaults.
- **F12 / N02 (live):** `capacity_forecasting` emitted 2,528 unique-id findings in
  one hour (31,776 in 6h) — a duplicate-per-run flood; it also went stale for a
  stretch around a core restart.
- **F15 (live, decisive):** `seasonal_disposition` findings in production: **0,
  ever** (`count=0, max=nil`). The central seasonal path emits nothing — the
  `profile_hour_of_week` data feed gap is real in production, not just in code.
- **F17 (live):** SNMP interface-counter series fire near-constant `Critical`
  (e.g. `snmp:agent-sr-test-pve04:31` = 58 Critical findings in 90m) — floor-less
  counter-rate breach.

### Operator trigger reference
Reproduce: `ServiceRadar.Edge.AgentCommandBus.dispatch("<agent_id>",
"sysmon.debug_spike", %{"metric" => "cpu", "value" => 99.0, "samples" => 12})` from
a core node (`bin/serviceradar_core_elx rpc`). The agent injects synthetic samples
mirroring the last real sysmon sample so they key to the established baseline series.

## Device-Details UI, Charts & Alerting (Live Triage, 2026-06-19)

Triage of the device-details `/devices/:id` "Anomaly & Capacity" panel and metric
charts on demo, against device `sr:cf8d5471-...` (host 192.168.1.62 =
`agent-sr-test-pve04`, a sysmon-only host). The panel takes ~8-10s to populate and
renders findings an operator cannot act on. Findings F25-F29.

### F25: Device-details anomaly/capacity panel is slow — sequential SRQL fan-out + hypertable seq scans (HIGH, perf)
`AnomalyCapacityData.load/3` runs the anomaly load and the capacity load
sequentially, and each `load_first/4` iterates candidates via `Enum.reduce_while`
issuing one SRQL round-trip per candidate, halting only on the first non-empty
result (`anomaly_capacity_data.ex:36-90`). Worst case ~9 serial SRQL round-trips
(3 anomaly candidates + 6 capacity candidates), each a 2-statement transaction,
all inside one `start_async` (`show.ex:447-465`). Worse, the candidates are
mis-ordered and non-sargable:
- Anomaly candidates must run canonical device UID first. In SRQL today that is
  the `source_device_uid`/`device_id` filter path, which anchors on
  `metadata #>> '{service_radar,device_uid}'` and can use the dedicated partial
  index. Trying `agent_id`/`host_id` before the canonical lookup pushes the
  common path toward OCSF hypertable scans.
- Capacity candidates expand each id into an exact `resource_id` (no usable index)
  plus a leading-wildcard `resource_key '%<id>%'` ILIKE that **cannot use any
  index** (`anomaly_capacity_data.ex:117-137`).
- Each query selects more rows than the panel renders, and events still return
  full OCSF rows (metadata/raw_data/unmapped JSONB).
Fix: query canonical `source_device_uid` first through the indexed equality path;
drop the `%id%` ILIKE; add a btree index on capacity `resource_id`; run anomaly +
capacity concurrently (`Task.async`); lower the limits and add projection when SRQL
supports it for these entities.

### F26: Anomaly & capacity findings are not operator-actionable (HIGH, ux)
`anomaly_capacity_components.ex` renders each finding as a static `<article>`
(line 59) and each capacity forecast as a plain `<tr>` (line 113) with **no
`phx-click`, no link, no drill-down modal** (UI-1). Beyond that, the rows are
nearly content-free:
- The finding "title" is the raw detector reason string `breach pending
  confirmation at N/M consecutive anomalous slots` — `finding_title/1` prefers
  `message` (= `verdict.reason`, `signal.rs:205-208` via `addon.rs:899`) over the
  human `finding_info.title` (UI-4).
- The only metadata shown is the metric-class label and timestamp; `"snmp"` is the
  literal `metric_type` leaking through the `other -> other` catch-all in
  `metric_class/1` (`anomaly_capacity_components.ex:184-216`). The payload carries
  `source_identity.metric_name`, `if_index`, `interface_uid`, tags, `anomaly.value`,
  `anomaly.score`, `series_key` — **none are rendered** (UI-3, UI-6). For interface
  findings the operator cannot see which interface/OID/metric fired.
- Resource/device IDs are `max-w-48 truncate` with **no `title` attribute and no
  human name** (`anomaly_capacity_components.ex:114`) — the full id isn't even
  available on hover (UI-2).
- Capacity "Projected" is a bare number (`format_number(projected_value)`) with **no
  unit, no metric type, no threshold, no horizon** — "19.92 / now 13.29" is
  unreadable (UI-7); and `status: "skipped"` rows render as all-`n/a` noise because
  a skipped forecast nulls every numeric field (`worker.ex` skipped_attrs; DB CHECK
  allows only `projected`/`skipped`) (UI-8).
Note inconsistency: a `"snmp"` finding shows `"snmp"` in the row but is counted
under the RED chip, because `anomaly_capacity_data.ex:264-275` buckets unknown
classes into `red` while the component prints them verbatim.
Fix: make rows clickable to a detail modal (`phx-click` + `phx-value-uid`); prefer
`finding_info.title`; render metric_name + interface/ifIndex + value/score; add
`title=` to truncated ids and resolve a friendly device label; label capacity with
units/metric/threshold/headroom and hide or aggregate skipped rows.

### F27: SNMP anomalies are attributed to the polling agent host, not the polled device (HIGH, data-integrity)
The concrete root cause of "a sysmon-only host shows SNMP anomalies": the edge
`verdict_record()` sets `device_uid = first_non_empty([resource.device_id,
host_id, agent_id, host_ip])` and **never considers `resource.target_device_ip`**
(`addon.rs:857-862`), so an SNMP poll of remote gear is stamped with the agent
host's identity (and `series_key = snmp:<agent_id>:<ifIndex>`). Core actually
detects this (`anomaly_detection_correlation_candidate/2` sets `snmp_target_poll?`
and drops `agent_id`, `causal_signals.ex:1342-1354`) but **line 1357 still passes
the agent-host `device_uid` as the leading resolution candidate**, defeating the
re-key. `target_device_ip` is also only emitted under `source_identity`
(fragile). The web-ng device page then matches findings by `agent_id` FIRST
(`anomaly_capacity_data.ex:106-115`), amplifying the mis-attribution onto the host
page. Confirmed in data: these findings carry `device.uid = "agent-sr-test-pve04"`,
`hostname = nil`; `sr:cf8d5471` has `discovery_sources` without `snmp`. Fix: at the
edge prefer `target_device_ip` for non-self SNMP polls; in core, for
`snmp_target_poll?` rows set the leading `device_uid` candidate to the target (not
the agent host); emit `target_device_ip` at a stable top-level path; scope the UI
query by canonical device/series once attribution is correct. (Sharpens F13/F24.)

### F28: Device CPU/memory/disk charts hide the per-core, short-duration spikes the detector fires on (HIGH, data-correctness)
The metric charts query `in:timeseries_metrics ... bucket:5m agg:avg` with
**`series_field = nil`** (`sysmon_metrics.ex:153-161, 626-656`), i.e. the line is
averaged over 5-minute buckets AND across all cores. The detector scores **per-core
raw samples** (`sysmon.cpu:...:CPUn`), so:
- A single pegged core (1 of 16 at 100%) shows as ~6% on the chart while the
  detector fires Critical on that core; the operator sees a flat line under a
  Critical finding.
- A short severe spike is averaged away by `agg:avg` over 5m. The verified example:
  an injected all-core 99% spike rendered as a ~54% bucket peak with the line/hover
  near it showing ~1.3%.
- The headline `min/avg/max` (`metric_stats/2`) is computed over the same diluted
  5m-avg buckets, so "max 54.1%" cannot be reconciled with the plotted line.
- Findings are not annotated on the chart, so there is no visual link between a
  Critical finding and the metric that triggered it.
Fix: for per-core metrics, render per-core series (or at least a max-across-cores
line) and offer `agg:max` (or an avg+max band) so spikes are visible; make the
headline stat match the plotted aggregation; annotate finding timestamps/series on
the chart and let a finding click focus the chart on its series/time.

### F29: alert_generator does not handle anomaly or capacity findings — and must be wired carefully (HIGH, operability)
Live: **0 alerts in 6h** despite hundreds of CPU findings, thousands of SNMP
findings, and ~31k capacity findings. `Monitoring.AlertGenerator` only emits alerts
for service/device/gateway/agent-offline and metric `threshold_violation`; there is
no path turning class-2004 anomaly or capacity findings into `alerts` rows. So
today the findings are non-actionable noise that never reaches an operator. The
requested fix is to make `alert_generator.ex` handle anomaly + capacity findings —
but this MUST be gated, or it becomes the alert storm the flood findings imply:
- Alert only on a confirmed anomaly-OPEN transition (after F1) and a CLEAR, never
  on `pending_anomaly` (today pending breaches are emitted as `severity_id: 4`
  Critical — confirmed in finding metadata) and never per-sample.
- Dedup/coalesce per canonical series with a cooldown/suppression window (the
  generator already has a 5-min stats-alert cooldown pattern) so one ongoing
  condition is one alert, not 2,528/hour (depends on F12 idempotency).
- Exclude floor-less counter false-criticals until F17 lands; map detector severity
  to alert severity; for capacity, alert on a real exhaustion-ETA crossing a
  warning horizon, not on every `projected` re-emit.
Sequence F29 AFTER F1/F12/F17 so anomaly alerting turns on only once the findings
are trustworthy. (Also observed: a CPU-usage finding's `finding_info.uid` is keyed
on `cpu.frequency_hz` — a metric meant to be excluded — suggesting either an
excluded-metric leak or a mis-built finding UID; verify under F17/F24.)

## Decisions (UI/alerting addendum)
- Delivery and edge scoring work; the device-details experience is the gap. Treat
  F25 (perf) and F27 (SNMP attribution) as the highest-impact UI/data fixes, and
  F29 (alerting) as gated on F1/F12/F17.
- F26/F28 are presentation fixes but F28 is data-correctness-adjacent: the chart
  must be able to show what the detector scored, or operators cannot validate any
  finding.

## Chart UX & SNMP Rendering Audit (2026-06-19)

A 7-surface audit (shared timeseries renderer, sysmon/process, SNMP interface,
NetFlow, MTR/BGP, the JS chart hooks, and SNMP data semantics) found 67 verified
chart issues (9 high, 30 medium). The CPU-chart problem (F28) is not isolated —
spike-hiding aggregation, unreadable scales, missing annotation, and two
quantitative NetFlow errors are fleet-wide. Consolidated as F30-F37. Ground truth:
SNMP interface metrics are stored as RAW monotonic counters (`ifInOctets` reaching
~10^13, `metric_type="snmp"`, `unit` empty), so every interface chart depends
entirely on correct rate derivation.

### F30: Chart aggregation hides the spikes the detector fires on — renderer-wide (HIGH)
Beyond F28's CPU case, the shared renderer and several queries destroy extremes:
- `limit_points` downsamples by `take_every` stride decimation
  (`timeseries.ex:629-655`), so on dense windows real peaks between kept indices
  never render — fleet-wide.
- `bytes_per_sec` series are densified by linear interpolation and box-smoothed
  before plotting (`timeseries.ex:528-595`), fabricating samples and shaving real
  traffic spikes.
- Per-series collapse: the device Disk chart averages ALL mount points into one
  line (`sysmon_metrics.ex:235-263`) — a full partition is invisible; CPU averages
  across cores (F28); the backend supports `series:series_key`/`mount_point` but the
  query passes `series=nil`.
- Interface traffic is `bucket:5m agg:max` then an Elixir delta/300s
  (`interface_data.ex:315-317`, `timeseries.ex:323-336`) — a 5-minute-averaged rate
  that smooths microbursts and saturation.
Fix: min/max-envelope (LTTB) downsampling instead of stride; never interpolate
measured samples; split per-core/per-mount/per-series; offer finer buckets / a raw
window for counters; compute header min/max from raw, not bucketed, data.

### F31: Axis scale and units make many signals unreadable (HIGH)
- The Y axis is hardcoded to `0..max*1.1` (and a fixed `0..100` for percent), with
  no min-based zoom and no log option (`timeseries.ex:186-221, 378-384`). A series
  clustered in a narrow band high above zero (steady 900 Mb/s, CPU pinned at 54%,
  memory near full) renders as a flat band and the header peak/avg cannot be
  reconciled with the line — the same "flat line under a Critical" confusion,
  fleet-wide.
- The axis unit is inferred from the y-field NAME substring (`percent`/`bytes`/`hz`)
  and never from the metric's DB `unit` column, which is carried on the row but
  discarded in `extract_series_points` (`timeseries.ex:91-126, 685-711`). Any SNMP
  gauge outside the hard-coded set gets a bare `:number` axis.
- NetFlow grid panels have no y ticks/gridlines/labels and each panel auto-scales
  independently (`NetflowGridChart.js:99-126`); BGP and stacked-area charts plot raw
  bytes with no unit (`BGPTimeSeriesChart.js:33-46`).
Fix: scale Y to the data band (min..max + padding) with an opt-in log scale; thread
`metric.unit` into the panel spec and prefer it; add axis ticks/labels.

### F32: NetFlow traffic numbers are quantitatively WRONG (HIGH, data-correctness)
Two independent errors make headline bandwidth figures incorrect, not just ugly:
- The NetFlow/sFlow **sampling-rate multiplier is never applied**
  (`netflow_live/dashboard.ex:792-829,...`, `flow_data.ex:138-215`). On any sampled
  exporter (1:100, 1:1000, 1:4096 are normal) Total Bandwidth, Top
  Talkers/Listeners/Conversations, interface gauges, p95, and subnet distribution
  all under-report true traffic by the sampling factor.
- Top-N tables and "Total Bandwidth" label **cumulative window totals as a
  per-second rate** (bps / B/s) without dividing by the window
  (`netflow_live/dashboard.ex:1241-1246, 1283-1302`), so every rate value is wrong
  by `time_window_seconds` (3600× for 1h, up to 2.6M× for 30d).
- The interface bandwidth gauge uses a window-average "current" bps that hides peaks
  and disagrees with its own p95 column, and p95 is hard-pinned to `last_30d/1h`
  regardless of the selected window (`dashboard.ex:594-621, 1006-1034`).
Fix: carry `sampling_rate` into flow rows and weight every sum by it; divide window
sums by the window seconds before labeling a rate; align gauge/p95 to the selected
window; make peak vs average explicit.

### F33: SNMP counter rendering is semantically wrong (HIGH, snmp-semantics)
Interface counters are rate-derived in hand-rolled Elixir rather than SRQL's native
`agg:rate`, with several defects:
- Width 32 vs 64-bit is guessed from the series-name substring `"HC"` (or
  prev-value>2^32) instead of the SNMP PDU type (`timeseries.ex:358-366`). A 64-bit
  counter below 2^32 whose label lacks `HC` is treated as 32-bit; on a real reset
  this fabricates a `2^32 - prev + cur` **phantom traffic spike** (which can itself
  look like an anomaly). SRQL's native `agg:rate` already NULLs on `value < prev`.
- Counter reset/gap emits a real `0 B/s` instead of a no-data gap, and the first
  sample is always 0 (`timeseries.ex:319-321, 338-346`).
- The per-second rate is clamped to the link's BYTE speed for ALL series, including
  packet/error/discard counters whose natural scale is unrelated to byte speed
  (`timeseries.ex:335, 368-376`).
Fix: carry counter width/PDU kind from the collector and use it (or just use SRQL
`agg:rate`); render resets/gaps as gaps not 0; clamp only octet series to link
speed; render rate vs count units on separate axes.

### F34: Charts cannot annotate findings, thresholds, or events (HIGH, missing-annotation)
The shared renderer has **no event/marker layer** in the SVG or the panel config
(`timeseries.ex:1175-1323`); interface charts draw no threshold line despite
per-metric thresholds existing (`interface_live/show.ex:242, 277-291`); no sysmon
chart or process row carries a finding marker. So when an anomaly or capacity
finding fires at time t, the operator has no way to see WHERE on the timeline it
fired and must mentally correlate a separate findings table with the x-axis. This
is the missing half of F26's drill-down. Fix: add an `annotations` list to the
panel assigns ({dt, label, severity}) rendered as vertical marker lines/bands using
the existing `idx_to_x`/time mapping, plus a threshold reference line; clicking a
finding focuses/marks its time+series.

### F35: Hover/tooltip readouts are misaligned and incomplete (MEDIUM, interaction)
The only way to read exact values off these charts is broken:
- `TimeseriesChart.js` (and `TimeseriesCombinedChart.js`) invert mouse-x over the
  full container width while the SVG plots inside an 8px pad with
  `preserveAspectRatio="none"` (`TimeseriesChart.js:55-78`, geometry in
  `timeseries.ex:657-663`), so the crosshair and the reported value point at a
  different x than the vertex under the cursor — worst at the edges where spikes
  live. The netflow `util.js` tooltip has the same left-margin x-inversion error
  (`util.js:65-98`) and `NetflowGridChart` uses a full-width x-scale against a
  grid layout so hover hits the wrong panel (`NetflowGridChart.js:99,129-139`).
- BGP charts have no tooltip/hover at all and a legend of bare `AS <n>`
  (`BGPTimeSeriesChart.js:48-87`); several tooltips have no crosshair/marker.
Fix: invert mouse-x with the same geometry as `idx_to_x` (or render the crosshair
inside the SVG); add per-series crosshair markers; give BGP a tooltip.

### F36: Gaps and errors are silently fabricated into signal (MEDIUM, empty/error)
- Non-finite points are filtered out so gaps are silently bridged
  (`FlowRateChart.js:19-27`), and a sparse/missing AS in a bucket is drawn as a hard
  drop to zero, **fabricating traffic-collapse spikes** (`BGPTimeSeriesChart.js:53-62`).
- BGP empty-state cannot distinguish a query error (returns empty series+data) from
  genuine no-data (`bgp_live/components.ex:438-457`); favorited-interface empty
  states never link to SNMP polling config (`interface_components.ex:390-409`).
Fix: use `null` sentinels with `.defined()` so gaps render as breaks; distinguish
error vs empty vs disabled and link empty states to the relevant config action.

### F37: Collected signal is never charted + accessibility gaps (MEDIUM/LOW)
- `process.count` is collected and presence-probed but never charted
  (`sysmon_metrics.ex:576, 140-151`); the process table is a single latest snapshot
  with no per-process history, so process CPU/mem spikes are invisible
  (`sysmon_metrics.ex:76-103`).
- `NetflowStacked100Chart` normalizes every timestamp to 100% so absolute volume is
  invisible and an all-zero bucket still looks full (`NetflowStacked100Chart.js:60-82`).
- Series identity/legend is color-only with no shape/pattern and tooltips rely on a
  single series, hurting color-blind operators (`timeseries.ex:665-677`,
  `util.js:157-163`).
Fix: chart process.count and add per-process history/sparklines; show absolute
volume alongside the 100% view; add non-color series encoding.

## Decisions (chart audit addendum)
- The chart layer systematically hides the exact signal the anomaly engine scores
  (F30/F31/F33/F34); fixing the engine (F1-F24) without fixing the charts leaves
  operators unable to validate or triage any finding.
- F32 (NetFlow sampling + rate mislabel) is a correctness bug independent of
  anomalies and should be fixed regardless — the headline bandwidth numbers are
  quantitatively wrong today.

### F38: The shared chart renderer is a 1544-line god-module (MEDIUM, maintainability)
`dashboard/plugins/timeseries.ex` (~1544 lines) mixes point
extraction/normalization, downsampling, counter-rate derivation, scale/unit
inference, SVG path geometry, hover, and the LiveComponent shell in one file — well
over a sane ~300-line module size, and the locus of F30/F31/F33/F34/F35. The size
makes the bugs above hard to see and risky to fix. Sibling oversized modules
(`device_live/sysmon_metrics.ex`, `netflow_live/dashboard.ex`) have the same
problem. Fix: split into focused sub-modules (each < ~300 lines) as a
behavior-preserving refactor first, then land the chart fixes against the smaller
modules.

## Flow Pipeline & Dashboard-Authoring Audit (2026-06-19)

A 6-surface end-to-end audit (flow collection -> ingest/storage -> netflow
visualize/dashboard -> device flow -> dashboard authoring -> dashboard data layer
+ table/topology plugins) found 48 verified issues (14 high). Consolidated as
F39-F46. The headline is that NetFlow traffic is wrong from the wire up, and the
dashboard-authoring layer has a security hole.

### F39: Flow sampling-rate is broken end to end — the full F32 root cause (HIGH, sampling-accuracy)
F32 (UI never multiplies) is the last link of a broken chain:
- The collector never populates `sampling_rate` for NetFlow v5/v9/IPFIX — only
  sFlow sets it (`flow-collector/src/netflow/converter.rs`; the sampling IEs
  SamplingInterval/SamplerRandomInterval/etc. are parseable but unmatched), so
  every sampled NetFlow/IPFIX record ships `sampling_rate=0`.
- Core decodes it but **never persists it to a flow column** — `flows.ex` runs
  `zero_to_nil` and drops it into the OCSF `unmapped` blob, storing bytes/packets
  raw (`flows.ex:313-441,715-744`). So F32 is literally unfixable downstream: there
  is no column to multiply by.
- The hierarchical continuous aggregates bake raw (un-sampled) `SUM(bytes_total)`
  into materialized rollups (`migrations/...flow_traffic_hierarchical_caggs`), so
  even after a schema fix the historical 7d/30d capacity rollups stay wrong.
- sFlow ships `packets=1` with unscaled bytes and mixes L2 (`frame_length`) vs L3
  (`ipv4.length`) byte counts across record types (`sflow/converter.rs:78,97-116`),
  so byte totals differ by record type for identical traffic.
Fix: capture sampling IEs (incl. options/sampler records) at the collector for a
per-exporter rate; persist `sampling_rate` (and a configured per-exporter fallback)
to a real flow column; scale bytes/packets by it in queries; rebuild/learn the
caggs with scaling; normalize sFlow byte layer.

### F40: Dashboard variables are interpolated into SRQL with no escaping — viewer authz bypass / injection (HIGH, security)
`authored_dashboard_live/dashboard_variables.ex:35-41` string-interpolates
user-supplied variable values straight into the panel SRQL. A user with only
VIEW access to a shared/public dashboard can supply a crafted variable value that
rewrites the query structure (e.g. change the `in:` collection or inject filters)
and read data outside the dashboard's intended scope. Compounding it, authored
panel queries have no default time window or enforced `LIMIT`
(`runtime_data.ex:39-57`), allowing unbounded table scans. Fix: parameterize/escape
variable values (never interpolate into the query grammar), validate against the
variable's declared type/allowed set, and enforce a default time bound + max LIMIT
on every authored query.

### F41: Authored-panel readouts are quantitatively wrong (HIGH, data-correctness)
- The Stat/Count **trend arrow is reversed**: it compares first vs last row in the
  returned order with no enforced sort (`panel_components.ex:639-674`), so a rising
  metric shows trending down and the delta sign is wrong.
- KPI **sparklines show the OLDEST buckets**: `ORDER BY bucket ASC LIMIT N`
  (`dashboard_live/data.ex:1959-2090`) selects the start of a 7d/30d window, so the
  "recent trend" is stale history.
- Pivot/stat **aggregations are computed over the 250-row client-truncated set**,
  not the full result (`panel_components.ex:227-256`), so totals/averages are wrong
  on large queries; field types are inferred from a 100-row sample (mistyping); the
  auto-synthesized trend query only rewrites the time token, leaving
  `limit`/`bucket`/`stats` intact.
Fix: enforce sort and compare true first/last by time; sparklines `ORDER BY bucket
DESC LIMIT N` then reverse; compute aggregations in the query (server side), not the
truncated client set.

### F42: Table & topology dashboard plugins distort or drop data (HIGH/MEDIUM)
- The table plugin renders **every row with no pagination, cap, or sort**
  (`plugins/table.ex:21-48`) — a large result balloons the LiveView payload and
  freezes the tab; columns are derived from the **first row only and sorted
  alphabetically** (`srql_components.ex:485-522`), so authored column order is lost
  and columns vanish when the first row lacks a key; numeric cells are raw
  `to_string` (no units/separators, full float).
- Topology **silently drops nodes beyond 120 and all their edges**
  (`plugins/topology.ex:216-245`) with no truncation indicator, and a fallback node
  id of `phash2(raw_map)` gives equal nodes different ids so dedupe/edges break.
Fix: paginate/cap + server sort the table, preserve SELECT column order, format
numbers; cap topology with an explicit "+N more" and a stable node id.

### F43: NetFlow visualize/dashboard aggregation & attribution errors (HIGH/MEDIUM)
Beyond sampling (F39) and the F32 rate items:
- The interface bandwidth gauge divides **whole-exporter aggregate bytes by one
  interface's link speed** (`netflow_live/dashboard.ex:594-602,947-1004`) — a 48-port
  switch vs one uplink reads far over 100%; the gauge "current" is a window average
  labeled instantaneous.
- The Sankey **drops the long tail at the DB (`limit:max_edges`) before computing
  "Other"** (`visualize.ex:1782-1866`), so "Other" understates omitted traffic and
  the diagram misrepresents the decomposition; the timeseries chart uses a flat
  `limit:` with sort stripped, dropping arbitrary buckets.
- **Bidirectional double-counting**: Top Conversations aren't canonicalized (A→B and
  B→A counted twice, `dashboard.ex:813-829`); the device flow panel sums both
  ingress and egress representations into one device's total
  (`srql/.../flows.rs:2120-2152`); Top Talkers use raw endpoint-IP grouping while the
  device tab uses alias/exporter-resolved scoping (inconsistent numbers).
- Reverse-DNS/Geo enrichment is read with no expiry filter (stale cache shown as
  current); a chart query failure renders as an empty chart indistinguishable from
  "no traffic" (`visualize.ex:810-906`).
Fix: scope the gauge to the interface, canonicalize bidirectional flows, compute
"Other" from the full set, filter enrichment by expiry, and distinguish error from
empty.

### F44: Flow ingest defaults distort direction/rate (MEDIUM, data-correctness)
`bytes_in/out`/`packets_in/out` default to `0` (not NULL) for protocols that don't
carry directional counts (`flows.ex:404-441`), so directional charts read a real 0
instead of "unknown"; `flow_summary` bps/pps divide by the full wall-clock window
even when data covers only part of it (`dashboard_live/data.ex:530-540`), and an
interface sparkline conflates in+out into one bps using `MAX(value)` per bucket.

### F45: Dashboard load is slow and the data layer is a god-module (MEDIUM, performance/maintainability)
The dashboard runs ~20 data queries + ~30 schema probes strictly sequentially with
no concurrency (`dashboard_live/data.ex:86-159, 2703-2759`); `data.ex` is a
3148-line module mixing flow, topology, MTR, survey geometry, threat-intel, and
rendering. Fix: parallelize independent queries; split the module (ties F38/§32).

### F46: Data-volume growth is driven by missing retention + the finding flood (MEDIUM, operability)
Live (2026-06-19): the `serviceradar` DB is ~217 GB (3 CNPG instances ≈ 304 GB
disk each incl. ~65 GB pg_wal). Retention IS running (41 TimescaleDB policies,
~0 failures), and WAL/replication are healthy (slots retain KB, archiver
`failed=0`) — so this is NOT the prior stuck-slot WAL incident. But growth has two
real drivers: (1) `otel_traces` (36 GB) and `ocsf_network_activity` (17 GB) had **no
retention policy until today** (`total_runs=1`), so they grew unbounded; (2) the
anomaly/capacity finding flood (F1 pending-as-Critical, F12 capacity ~2,528 unique
findings/hour, F17 counter false-criticals) and the un-sampled raw flow rows
(F39) inflate `ocsf_events`/`capacity_forecasts`/flow tables. Note: scheduled CNPG
base backups are FAILING (Longhorn throughput) — separate, no recovery point. Fix:
own retention for every high-volume hypertable (verify coverage), and the F1/F12/
F17/F39 fixes cut write volume at the source.

## Decisions (flow/dashboard addendum)
- F39 (sampling) and F40 (variable injection) are the priorities: traffic numbers
  are wrong from the wire and a view-only user can read out-of-scope data. Both are
  independent of the anomaly engine and should be fixed regardless.
- F46: pruning is not broken; the DB growth is missing-retention-coverage plus the
  finding/flow write floods — fixing F1/F12/F17/F39 and adding retention to all
  high-volume hypertables addresses it.

## Subsystem Bug Hunt: Mapper, Sweep, Topology, MTR, SRQL, UI (2026-06-19)

A 9-subsystem fan-out (discovery/mapper, sweep/scan, topology, MTR, SRQL engine +
query modules, UI) found 51 verified bugs (12 high, 9 medium, 30 low) plus 20
oversized files. Consolidated as F47-F55. Two SRQL DoS panics and a Cypher
injection are reachable from untrusted input.

### F47: Mapper SNMP discovery (HIGH)
- **[HIGH] ifXTable ifName/ifAlias silently dropped**: `processIfXTablePDU` dispatches
  via `updateInterfaceFromPDU` which only handles `ifHighSpeed`; the ifName/ifAlias
  handlers live in `updateInterfaceFromOID`, never called on the ifXTable walk
  (`snmp_polling.go:1472-1516`). Every SNMP-discovered switch/router shows ifDescr or
  synthetic `Interface-N` names. Fix: dispatch ifXTable through `updateInterfaceFromOID`.
- **[HIGH] SNMP client connected twice per target -> UDP FD leak**: `setupSNMPClient`
  already `Connect()`s, then `connectSNMPClient` `Connect()`s again, orphaning the
  first socket (`snmp_polling.go:280-285,1690-1803`). One leaked FD per target per
  job -> mapper eventually hits ulimit. Fix: connect once.
- [LOW] FDB MAC-to-port collapses to last-walked port (`snmp_polling.go:2777-2838`);
  `querySysInfo` never returns `ErrNoSNMPDataReturned` for wrong-community
  (`:293-315`); `selectDensePortNeighbors` is a no-op despite the cap comment
  (`:2545-2553`); non-blocking worker-result send undercounts progress
  (`discovery.go:1322-1326`).

### F48: UniFi / UBNT polling (HIGH)
- **[HIGH] /clients fetch has no pagination/limit** -> wireless client lists silently
  truncated on busy sites (`ubnt_poller.go:582-632`).
- **[HIGH] /devices fetch hard-caps at 500 (topology) / 100 (inventory)** with no
  pagination -> large-site devices silently lost (`ubnt_poller.go:514,1435`).
- [LOW] uplink `parentPortIndex` preference can pick wrong port and treats index 0 as
  missing (`ubnt_poller.go:87-104`); full response bodies logged at Debug (PII/secrets
  exposure) (`:544-546`); site vs device fetch use inconsistent ctx (`:1300-1311`);
  Protect WS caps at 4 reads (`unifi-protect/main.go:1124-1138`); `trimBody` splits a
  UTF-8 rune (`:1375-1382`).

### F49: Sweeper / SYN scanner
- [LOW] SYN reply attributed to wrong port after source-port reuse within a scan
  (`syn_scanner.go:2945-2974`); per-scan stats counters never reset between scans
  (cumulative telemetry/drop-rate) (`:243-261`); `runSweep` prunes results then scans
  concurrently so `GetStatus` sees a partial set (`sweeper.go:1306-1436`); ICMPv6
  dest-unreachable clears Available but isn't a clean closed result (`:2810-2853`);
  retry packets bypass `enqueueRetriesForBatch` accounting and can be silently dropped
  (`:2246-2294`).

### F50: Topology graph (HIGH security)
- **[HIGH/security] `Graph.escape` does not escape backslashes** -> Cypher string-literal
  injection via attacker-controlled LLDP/CDP port description, system name, or SNMP
  ifAlias (`graph.ex:106-110`). A malicious device on the monitored network can break
  out of the literal. Fix: escape backslashes (and audit all Cypher literal building).
- [MED] Parallel links (LAG/redundant) collapse to a single CANONICAL edge
  (`topology_graph.ex:1988-2048`); reverse `CONNECTS_TO` edges not pruned when one
  endpoint re-reports (stale asymmetry) (`:730-755`).
- [LOW] IPv6 device-id/IP fallback broken by naive `:` split (`:1588-1604`); Cypher
  read-only guard flags keywords inside string literals/comments
  (`graph_cypher.rs:114-136`); device-graph `peer_interfaces` returns peer Interface
  nodes with no link to owning Device.

### F51: MTR consensus / baseline / UI (HIGH)
- **[HIGH] "avg RTT" actually takes MAX over all hops** (`mtr_consensus_worker.ex:232-259`),
  so a healthy destination is classified `:degraded_path` and emitted as a causal
  signal whenever any transit hop ICMP-deprioritizes - false anomaly signals. Fix:
  use destination-hop RTT (or true avg), not max-over-hops.
- [MED] Non-incident (manual/baseline) cohorts never re-emit on escalation, so
  degraded-to-outage transitions are missed (`mtr_consensus_worker.ex:110-146`).
- [LOW] Confidence reflects dominant probability, not the chosen class
  (`mtr_consensus_evaluator.ex:100-104`); "Page Reachability" KPI computed only over
  the current page (`mtr.ex:1831-1862`); MTR timestamps rendered with no tz
  (`mtr.ex:1784-1794`).

### F52: SRQL engine - parser / time / pagination / downsample (HIGH DoS)
- **[HIGH/DoS] Panic on multibyte trailing char in bucket duration**: `bucket:5<micro>`
  crashes the request thread via a non-char-boundary slice (`parser.rs:550`).
- **[HIGH/DoS] Panic on large relative time**: `time:last5000000000d` overflows an
  unchecked `DateTime` subtraction (`time.rs:42-50`).
- [MED] Unstable ORDER BY in downsample queries -> duplicate/skipped rows across pages
  (`downsample.rs:167-198`).
- [LOW] Empty IN/NOT-IN list returns ALL rows in the main path (and diverges from
  downsample) (`mod.rs:20-34`); unbounded/unauthenticated deep-offset cursor
  (`pagination.rs:13-27`); a `%` anywhere in a scalar forces LIKE even for exact-match
  fields (`parser.rs:777-787`).

### F53: SRQL query modules - devices / interfaces / events / flows (HIGH)
- **[HIGH] `discovery_sources` list filter uses contains-ALL (`@>`) not overlap** ->
  multi-source device filters return far fewer (often zero) rows, no error
  (`devices/filters.rs:178-193`). Powers the device list quick-filters.
- **[HIGH] Events query has no stable tie-breaker** -> time-ordered pagination
  drops/duplicates rows across pages (`events.rs:1085-1113`), affecting the
  device-details anomaly/event panels.
- **[HIGH] `field != x` / `not like` drops NULL rows in row queries but keeps them in
  stats** -> same filter yields different populations in table vs aggregate
  (`mod.rs:8-19`).
- [MED] Interfaces non-latest query paginates over a non-unique sort (drop/dup)
  (`interfaces.rs:646-679`); error-metric LATERAL joins run per history row before
  LIMIT (unbounded) (`:200-224`); CAGG routing truncates partial buckets so widening
  the window changes totals (`flows.rs:1518-1558`).
- [LOW] Interfaces drop empty IN/NotIn lists, widening NotIn (`interfaces.rs:460-479`);
  user stats expression can panic the worker via non-ASCII case-fold slice
  (`flows.rs:1340-1342`) - a third SRQL DoS.

### F54: UI device list & settings (HIGH)
- **[HIGH] Bulk-edit "Apply tags" always fails**: the Ash update runs with no
  actor/scope so policy denies it (`device_live/index.ex:1246-1271`) - tags never
  written; feature effectively dead.
- [MED] SNMP Profiles index N+1 of synchronous count queries on mount and every toggle
  (`snmp_profiles_live/index.ex:3029-3039`); interface target-count fails open on
  unsupported filter fields (over-counts), inconsistent with device count which fails
  closed (`:3311-3326`).
- [LOW] Sweep-group form runs a synchronous count query per keystroke (no debounce)
  (`networks_live/index.ex:621-625`); "Run Task" disabled under select-all-matching
  while Bulk Edit/Delete honor it (`device_live/index.ex:1473-1475`); CSV import splits
  on raw commas (mis-parses quoted fields) (`:3805-3811`); `get_all_matching_uids`
  unbounded fetch with a stale 10k guard (`:3594-3639`); SNMP test-connection blocks the
  LiveView synchronously in `handle_info` (`snmp_profiles_live/index.ex:642-648`).

### F55: Oversized files to break up (<~300 lines each, behavior-preserving)
Beyond Section 32, the audit flagged: `device_live/index.ex` (3931), `go/pkg/scan/syn_scanner.go`
(3831), `snmp_profiles_live/index.ex` (3596), `go/pkg/sweeper/sweeper.go` (3007),
`go/pkg/mapper/snmp_polling.go` (2996), `rust/srql/.../flows.rs` (2914),
`go/pkg/mapper/discovery.go` (2741), `networks_live/index.ex` (2726),
`network_discovery/topology_graph.ex` (2356), `diagnostics_live/mtr.ex` (2023),
`go/pkg/mapper/ubnt_poller.go` (1728), `unifi-protect/main.go` (1385),
`rust/srql/.../parser.rs` (1306), `rust/srql/.../query/mod.rs` (1091),
`diagnostics_live/mtr_data.ex` (1000), and the SRQL `interfaces.rs`/`events.rs`/
`devices/filters.rs`/`downsample.rs`/`devices/stats.rs` modules.

## Decisions (subsystem bug-hunt addendum)
- Prioritize the reachable-from-untrusted-input bugs: F50 Cypher injection (malicious
  device on the monitored network) and the F52/F53 SRQL DoS panics (any query client).
- F51 (MTR avg=MAX) and F47 (ifName dropped) are high-impact correctness bugs that
  also degrade the anomaly/topology signal quality this proposal otherwise improves.
- SRQL pagination instability (F52/F53: events, interfaces, downsample) is a recurring
  class - fix by always appending a unique tie-breaker to ORDER BY.
