## Context
The operator directive is to stop running seasonal and capacity statistics in the
BEAM and run them in Rust on DeepCausality instead. This checkout already holds the
right substrate:

- `rust/anomaly-core` (`serviceradar-anomaly-core`, `deep_causality_core 0.10` +
  `deep_causality_data_structures 0.10.14`, no rustler) is the single per-series
  DeepCausality **streaming** detector. `reason_impl(context, sample) -> Result<ReasonVerdict>`
  drives `CausalFlow::process(state).context(thresholds).update_value_state_context(...)
  .branch_with(breach, clean).update_value_state_context(...).finish()`
  (`rust/anomaly-core/src/detector.rs:58-97`). Inputs/outputs are `ReasonContext`,
  `ReasonSample`, `ReasonVerdict` (`rust/anomaly-core/src/types.rs:12,34,41`),
  re-exported at `lib.rs:42-44`.
- `rust/anomaly-addon` is the **edge** consumer: a standalone go-plugin binary whose
  `DetectorEngine::evaluate` (`rust/anomaly-addon/src/engine.rs:181`) loops `reason_impl`
  per series on the **stateless path** (`rolling_acc: None`, `window_tail: Some(state.window_tail.clone())`,
  `engine.rs:207-208`). This is the batch-loop reference shape.
- `CapacityForecasting.Model` (`model.ex:1-396`) is the pure-math capacity kernel
  (its own moduledoc states "The scheduled worker owns I/O. This module only turns
  ordered aggregate samples into a forecast snapshot." `model.ex:5-7`).
- `add-seasonal-anomaly-detection` planned the central seasonal tier as **Elixir+SQL,
  "No NIF, no Rust"** (`add-seasonal-anomaly-detection/design.md:79`).

The directive collapses these: make the **central** disposition tier a second consumer
of `anomaly-core` via a thin Rustler NIF (the edge add-on being the first), so the
seasonal residual-z and the whole capacity kernel run in Rust on DeepCausality. The
BEAM keeps only orchestration.

## Goals / Non-Goals
- Goals:
  - Move seasonal (residual-z / baseline-sufficiency / robust-statistic) and capacity
    (full `Model`) compute out of Elixir into a Rust NIF on `anomaly-core`'s
    DeepCausality substrate.
  - One implementation of the streaming detector for both delivery shapes (edge binary +
    core-elx NIF); no third copy of DeepCausality infra.
  - Keep edge + central composing into recall + precision, with the `source` join contract
    intact.
- Non-Goals:
  - Real-time central detection. Seasonal/capacity run over CAGG buckets on a schedule;
    the edge owns real-time. (`add-seasonal-anomaly-detection/design.md:28-32`.)
  - Merging into `rust/causal-engine`. Disposition stays a composed input feed.
  - Moving the 168-bucket profile aggregation into the NIF. That stays SQL (data gravity).
  - Replacing the edge spike detector or the `causal_signals.ex` OCSF sink.
  - A holiday/event calendar (inherited known limitation).

## Decisions

### D1. Crate / NIF boundary — extend `anomaly-core`, do not fork it
- NEW `rust/causal-disposition` (plain rlib) path-deps `rust/anomaly-core` and adds
  `disposition/seasonal.rs` + `disposition/capacity.rs` on the same `CausalFlow`
  substrate. It contains **zero** new detector math beyond the seasonal/capacity
  kernels; the streaming primitives come from `anomaly-core`.
- NEW `elixir/serviceradar_core/native/causal_disposition_nif/` is a thin cdylib that
  path-deps `causal-disposition`, mirroring `native/zen_nif/` (`crate-type = ["cdylib"]`,
  bare `[workspace]`, `rustler = "0.38"`; core mix pins `{:rustler, "~> 0.37"}` at
  `mix.exs:119`). The NIF is the *only* crate that depends on rustler.
- The `NifMap`/`NifStruct` derives are **feature-gated behind a `rustler` feature** on
  the NIF-facing types so `causal-disposition` stays dependency-light and linkable by
  bazel, by tests, and (in principle) by `causal-engine` without pulling rustler.

### D2. NIF signature and ABI — typed batch, not JSON
- `#[rustler::nif(schedule = "DirtyCpu")] fn dispose_batch(kind, rows) -> Vec<DispositionResult>`,
  inside `causal_disposition_nif`. `DirtyCpu` because the kernels are CPU-bound and must
  not block a normal scheduler.
- The boundary is **`NifMap`/`NifStruct`**, mirroring the typed `anomaly-core` consumer
  convention (`ReasonContext`/`ReasonVerdict`), **not** a JSON string. A JSON ABI would
  be a regression from the sibling consumer's typed shape.
- **Per-row panic isolation** mirroring the edge consumer's per-item batch loop
  (`engine.rs:181`): one malformed row yields one `{:error, _}` `DispositionResult`, not a
  crashed scheduler thread. Missing config short-circuits to an error result, never an
  unwind — enforced by D3.
- Facade: `ServiceRadar.Observability.CausalReasoner.dispose_batch(:seasonal | :capacity, inputs)`
  (`use Rustler`, `:erlang.nif_error(:nif_not_loaded)` stubs, mirroring
  `lib/serviceradar/observability/zen/native.ex`).

### D3. Panic-deny lint (graft from the panic-safety analysis)
- `rust/causal-disposition` carries `#![deny(clippy::unwrap_used, clippy::expect_used,
  clippy::panic)]`. Any `unwrap`/`expect`/`panic` in a disposition closure would unwind
  across FFI and take down a BEAM scheduler thread. The `corrective_ddos_detector`
  template's `.expect("DetectorConfig present")` is exactly the antipattern this forbids.
- Every gate (`insufficient_history`, `insufficient_seasonal_baseline`, zero-variance
  bucket, non-finite sample) returns through the verdict/error channel as a disposition
  variant (`Skipped` / `InsufficientSeasonalBaseline`), composing with `dispose_batch`'s
  per-row `catch`.

### D4. Seasonal `CausalFlow` channels (the carrier mapping)
- **Value** = `Disposition ∈ {Suppress, SeasonalBreach{score}, SeasonalDrift{score},
  InsufficientSeasonalBaseline}` — the only channel the intervene arm writes.
- **State** = per-`(dow,hod)` bucket accumulators (mean/stddev/count, **with the latest
  bucket excluded**, see D6), sign-run, `consecutive_anomalous` carried in from Postgres.
- **Context** = `{seasonal_n_sigma, min_bucket_samples, confirm_slots, robust_statistic}`
  (read-only).
- The breach arm emits the disposed verdict; the withhold-clean arm maps to the existing
  clean branch (`rust/anomaly-core/src/detector.rs:80-86`, `consecutive_anomalous = 0` +
  admit clean sample).

### D5. Capacity `CausalFlow` channels (the 1:1 `Model` port)
- **Value** = `Disposition ∈ {Projected{eta, ttl, confidence, bounds}, Inactive,
  Skipped{reason}}`.
- **State** = the fit accumulators — least-squares accumulators or Holt-Winters
  level/trend/seasonals, residuals/RMSE, projection cursor — a verbatim port of
  `model.ex` including `@exhaustion_horizon_multiplier 10` (`model.ex:21`) and the
  `>150%` / `>10x` plausibility guards.
- **Context** = `{capacity_threshold, horizon_seconds, model_kind, min_history, period}`.
- The `{:skip, "insufficient_history"}` gate (`model.ex:47`) becomes `Skipped{reason}`
  via the error channel (D3), not a panic.

### D6. SQL-vs-NIF split and the bucket-exclusion invariant
- **STAYS SQL** (data gravity): the 168-bucket hour-of-week profile aggregation
  (`GROUP BY extract(dow)/extract(hour)` over the hourly CAGGs). This is orchestration
  over data at rest; shipping ~1344 raw buckets x thousands of series across the boundary
  to re-bucket in Rust would move an aggregation to where the data isn't.
- **MOVES to NIF**: residual-z, breach, baseline-sufficiency gate, robust-statistic
  selection.
- For metric classes needing MAD / percentile bands (awkward in SQL), SQL passes the
  per-bucket **order statistics** it can already compute (`percentile_cont`, MAD via
  `percentile_disc` of abs-deviation) rather than raw points — small boundary, robust stats.
- **Bucket-exclusion invariant** (named in `seasonal.rs`, asserted by a `#### Scenario:`):
  because the seasonal baseline is the historical hour-of-week profile (not a self-masking
  sliding window), the withhold-from-baseline trick does not apply automatically. The
  latest complete bucket under test MUST be excluded from the mean/stddev it is scored
  against, or real drift inflates its own baseline and hides.

## Moves vs. stays (the disposition boundary)

| Concern | MOVES → NIF (`causal-disposition` on `anomaly-core`) | STAYS → Elixir (orchestration) | Ref |
|---|---|---|---|
| Seasonal 168-bucket profile aggregation | — | `GROUP BY extract(dow/hour)` over CAGGs in SRQL | D6 |
| Seasonal residual-z, breach, baseline-sufficiency, robust-statistic | **YES** | which bucket is "latest complete"; cadence | D4, D6 |
| Capacity fit (linear / Holt-Winters / seasonal), RMSE/confidence/bounds | **YES** — full `model.ex` | — | `model.ex:1-396` |
| Capacity exhaustion-ETA + plausibility guards + skip gate | **YES** | — | `model.ex:21,47,252-308` |
| Oban cron + unique guard | — | `SeasonalDisposition.Worker` / `CapacityForecasting.Worker` | `worker.ex:6-9` |
| SRQL/CAGG reads + cursor paging, row→point adapters | — | **STAYS** | `worker.ex:141` `fetch_rows` |
| Interface bytes→percent (bound to I/O-resolved `speed_bps`) | — | **STAYS** — runs before the NIF | `worker.ex:488-507` |
| `at_risk?` / warning-horizon DateTime policy | — | **STAYS** | `worker.ex:412` |
| Ash `CapacityForecast` upsert, telemetry, config merge, `VerdictEmitter` | — | **STAYS** | `worker.ex:319,406-432` |
| OCSF re-key + alert-enqueue sink | — | **STAYS, untouched** | `causal_signals.ex:272-280` |

## Reuse of `anomaly-core`
The disposition crate path-deps `serviceradar-anomaly-core` exactly as `rust/anomaly-addon`
does (`engine.rs` imports `ReasonContext, ReasonSample, ReasonVerdict, reason_impl`,
`engine.rs:13`). The disposition kernels reuse the `CausalFlow` carrier, the clean/breach
branch semantics, and the Welford/baseline stats from `anomaly-core::{stats, window,
signal}`. New code is the two disposition `Value` enums + their flows + the NIF marshalling
shell — not new detector math. This keeps the edge add-on and the core NIF on **one**
DeepCausality streaming implementation.

## Relationship to `causal-engine` — composed, not merged
- `rust/causal-engine` is a different DeepCausality surface (`deep_causality 0.13.10` +
  `ultragraph 0.9`, `causal-engine/Cargo.toml:13,24`) used as a **graph-structure** engine
  (articulation/bridge/betweenness over `CONNECTS_TO`), running as a fused long-running
  daemon over a whole-fleet `Context`. `anomaly-core` is `deep_causality_core 0.10` used as
  a **streaming SlidingWindow** engine, per-series, stateless.
- They differ in DeepCausality version, invocation model (daemon vs batch NIF call), and
  granularity (entity/topology vs series). Merging would force one crate to carry both
  dependency trees and two paradigms.
- The integration contract already exists and is clean: disposition emits
  `signals.causal.predictions.*` with `event_type ∈ {anomaly, capacity_forecast}`, and
  causal-engine ingests those as **C12 evidence** via `causal_evidence.rs` (`rust/causal-engine/src/causal_evidence.rs:34-35`).
  That NATS/OCSF envelope seam **is** the separation boundary — disposition output is an
  input feed to causal reasoning, composed not embedded. No `SlidingWindow` detector is
  added inside causal-engine (that would re-fork the substrate).

## Risks / Trade-offs
- **FFI panic safety** → the `deny(unwrap/expect/panic)` lint (D3) + per-row isolation (D2);
  any gate returns a verdict variant, never unwinds.
- **Capacity deletion is high-stakes** (operator-facing math, 396 trusted lines) → gated on
  a `1e-9` golden-fixture parity diff (old `Model` vs NIF over seeded CAGG slices); `model.ex`
  is deleted only after parity passes. This is why capacity is the *second* phase.
- **Substrate-extraction churn** on a tested reasoner → seasonal ships first (net-new, no
  parity gate) to de-risk the ABI and crate wiring before touching capacity.
- **mean/stddev fragility for bursty metrics** (inherited) → robust-statistic selection
  (MAD / p05-p95) per metric class, fed per-bucket order statistics from SQL (D6).
- **Holidays / concept drift** (inherited) → out of scope; trailing-window length trades
  stability vs adaptation.
- **Build wiring footgun**: Rustler builds the cdylib during `mix compile`, so any path-dep
  crate must be COPY'd into the Docker build context, or the release build fails →
  `Dockerfile.core-elx` COPYs both `rust/causal-disposition` and `rust/anomaly-core` before
  `mix compile` (lines 50-51, 65). No bazel cdylib rule is needed; the app `filegroup`
  already globs `native/**`.

## Phased rollout (seasonal first, then capacity)
1. **Seasonal (net-new, low blast radius).** Build `rust/causal-disposition` + the
   `dispose_batch` NIF + the `CausalReasoner` facade + `SeasonalDisposition.{Worker,Source}`.
   Profile aggregation stays SQL. This proves the substrate reuse, the typed ABI, the
   per-row isolation, and the `verdict_source = central-seasonal` join/suppress/surface
   path end-to-end — with **no** existing Elixir to supersede and no parity gate.
2. **Capacity (gated follow-up).** Port `Model` into `disposition/capacity.rs`, prove the
   `1e-9` parity diff, rewire `CapacityForecasting.Worker` to call the NIF, **then** delete
   `model.ex:1-396` — on a substrate and ABI already proven by seasonal.

## Migration Plan
- Seasonal phase is purely additive; rollback = disable the `SeasonalDisposition.Worker`
  cron and the edge spike signal carries detection (cold-start mode).
- Capacity phase: keep `model.ex` until the parity gate is green; the worker can be
  feature-flagged between `Model.forecast/2` and `CausalReasoner.dispose_batch(:capacity, ...)`
  during validation, then `model.ex` is deleted in the same change once the NIF path is the
  default and parity holds.

## Open Questions
- Whether interface bytes→percent conversion (`worker.ex:488-507`) ever moves into the NIF;
  current decision is no (it is bound to an I/O-resolved `speed_bps`, so it runs in the
  worker before the NIF call).
- Whether the seasonal worker should batch across `Source`s in a single `dispose_batch` call
  or one call per source; default is bounded per-source chunks within the run budget.
