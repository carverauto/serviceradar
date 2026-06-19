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
