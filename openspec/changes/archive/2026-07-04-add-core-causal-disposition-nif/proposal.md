# Change: Move seasonal + capacity disposition compute into a DeepCausality Rustler NIF

## Why
Operator directive: **stop computing seasonal and capacity statistics in the BEAM.**
Today the capacity planner does all of its float math in Elixir
(`CapacityForecasting.Model`, `model.ex:1-396` — least-squares, Holt-Winters,
RMSE/confidence/bounds, exhaustion-ETA, seasonal-strength autodetect), and the
planned central seasonal tier (`add-seasonal-anomaly-detection`) was about to add
a second pile of residual-z / baseline-sufficiency stats in Elixir+SQL. That is
two hand-rolled statistical kernels in a garbage-collected VM, drifting from the
one DeepCausality streaming detector the edge already runs.

This checkout already has the right substrate to consolidate onto: `rust/anomaly-core`
(`serviceradar-anomaly-core`) is the single per-series DeepCausality streaming detector
(`reason_impl` over `CausalFlow::process(...).update_value_state_context(...).branch_with(...).finish()`,
`detector.rs:58-97`), consumed today only by the edge binary `rust/anomaly-addon`
(`engine.rs:181`). The directive is to make the **central** disposition tier a
second consumer of that same crate via a thin Rustler NIF, so the seasonal/capacity
numeric kernels live in Rust on DeepCausality — one implementation, two delivery
shapes (edge binary + core-elx NIF) — and the BEAM is left owning only orchestration
(Oban, SRQL/CAGG reads, Ash persistence, NATS verdict emission, the OCSF sink).

The two anomaly tiers still compose into **recall + precision**: the edge proposes
fast spike candidates (high recall), and the central NIF-backed seasonal disposition
disposes them (suppress seasonal-expected spikes, escalate spikes that are *also*
off-baseline for the time, surface slow seasonal deviations the edge never sees).
What changes is *where the central stats run*: a `DirtyCpu` NIF on `anomaly-core`,
not Elixir+SQL.

## What Changes
- **Add `rust/causal-disposition`** — a plain rlib that path-depends on
  `rust/anomaly-core` and adds two disposition kernels on its DeepCausality
  `CausalFlow` substrate: `disposition/seasonal.rs` (deseasonalized residual-z,
  breach, baseline-sufficiency, robust-statistic selection) and
  `disposition/capacity.rs` (a 1:1 port of `model.ex` — linear/seasonal/Holt-Winters
  fit, RMSE/confidence/bounds, exhaustion-ETA, the `insufficient_history` skip gate).
  The crate carries `#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)]`
  so no closure can unwind across the FFI boundary.
- **Add `dispose_batch` to a Rustler NIF** in core-elx
  (`elixir/serviceradar_core/native/causal_disposition_nif/`), mirroring the
  per-item-isolated batch ABI of the edge consumer — `dispose_batch(kind, rows) -> Vec<DispositionResult>`,
  `schedule = "DirtyCpu"`, `NifMap`/`NifStruct` boundary (gated behind a `rustler`
  feature on the NIF-facing types), per-row panic isolation, missing-config →
  `{:error, _}` result rather than a panic. **BREAKING (internal ABI):** reject the
  JSON-string ABI — the boundary is typed maps, mirroring the existing
  `serviceradar-anomaly-core` consumer convention, not the `srql_nif` JSON pattern.
- **Add `ServiceRadar.Observability.CausalReasoner.dispose_batch(:seasonal | :capacity, inputs)`**
  facade over the NIF, and add `ServiceRadar.Observability.SeasonalDisposition.{Worker,Source}`
  (Oban cron + unique guard) mirroring `CapacityForecasting.Worker`.
- **Keep the 168-bucket hour-of-week profile aggregation in SRQL/SQL** (data gravity:
  it is `GROUP BY extract(dow/hour)` over CAGGs at rest). Only the residual-z, breach,
  baseline-sufficiency gate, and robust-statistic selection move to the NIF. Where a
  metric class needs MAD / percentile bands, SQL passes per-bucket order statistics
  (`percentile_cont`, MAD via `percentile_disc` of abs-deviation), keeping the boundary small.
- **Seasonal-first, capacity-second rollout.** Seasonal ships net-new on this checkout
  (no Elixir to supersede), proving the substrate extraction + ABI at low blast radius.
  Capacity follows: port `Model` into `disposition/capacity.rs`, gate on a `1e-9`
  golden-fixture parity diff (old `Model` vs NIF over seeded CAGG slices), rewire
  `CapacityForecasting.Worker`, **then** delete `model.ex:1-396`. Do not delete before parity passes.
- **`add-seasonal-anomaly-detection` is SUPERSEDED / RE-TARGETED:** its central seasonal
  tier is retained, but its explicit "No NIF, no Rust" decision (`design.md:79`) is reversed —
  the residual-z / baseline-sufficiency / robust-statistic compute moves into this NIF.
  The edge↔central verdict join, `source` (`edge-spike` | `central-seasonal`) contract,
  cold-start defer-to-edge behavior, and `VerdictEmitter` onto the signal path are kept.

## Impact
- Affected specs: `causal-disposition` (new), `observability-signals` (re-targets the
  seasonal join/source contract to the NIF-backed disposition)
- Affected code:
  - NEW `rust/causal-disposition/` (rlib, path-deps `rust/anomaly-core`); NEW
    `elixir/serviceradar_core/native/causal_disposition_nif/` (cdylib, `rustler ~> 0.37`,
    bare `[workspace]`, mirrors `native/zen_nif/`)
  - NEW `ServiceRadar.Observability.CausalReasoner` facade; NEW
    `ServiceRadar.Observability.SeasonalDisposition.{Worker,Source}`
  - MOVED-then-DELETED `CapacityForecasting.Model` (`model.ex:1-396`) → `disposition/capacity.rs`;
    `CapacityForecasting.Worker` (`worker.ex`) rewired to call the NIF, retained as orchestration
  - `docker/compose/Dockerfile.core-elx`: `COPY rust/causal-disposition` **and** `COPY rust/anomaly-core`
    before `mix compile` (lines 50-51, 65), since Rustler builds the cdylib there
- Reuses: `rust/anomaly-core` (`reason_impl`, `CausalFlow`, `ReasonContext`/`ReasonVerdict`,
  `lib.rs:42-44`) as the one DeepCausality streaming substrate; `rust/anomaly-addon`
  (`engine.rs:181`, `DetectorEngine::evaluate`, stateless `window_tail` path) as the batch-loop
  reference; the `CapacityForecasting.Worker` Oban/SRQL/Ash orchestration pattern
- Untouched sinks: `causal_signals.ex` (the OCSF re-key + alert-enqueue spine,
  `causal_prediction_row?` `:272-280`, class_uid 2004 `:30`, type 200_401 `:33`) and
  `rust/causal-engine` (`causal_evidence.rs:34-35`, event_type ∈ {anomaly, capacity_forecast})
- Related changes: SUPERSEDES / RE-TARGETS `add-seasonal-anomaly-detection`
  (reverses its "No NIF, no Rust" stance; keeps its join + emitter); related to
  `add-causal-engine` (disposition output stays **composed, not merged** — it feeds
  causal-engine as C12 evidence over `signals.causal.predictions.*`, distinct
  DeepCausality line: `anomaly-core` 0.10 streaming vs causal-engine 0.13 + ultragraph 0.9);
  related to `move-anomaly-detection-to-edge` (this is the central tier built on the
  same shared core the edge add-on uses)
