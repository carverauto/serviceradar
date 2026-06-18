## 1. Proposal
- [ ] 1.1 Validate with `openspec validate add-core-causal-disposition-nif --strict`.

## 2. Disposition substrate crate (`rust/causal-disposition`)
- [ ] 2.1 Create `rust/causal-disposition/` as a plain rlib (`name = "serviceradar_causal_disposition"`, edition 2024) that path-deps `serviceradar-anomaly-core = { path = "../anomaly-core" }`, reusing its DeepCausality streaming substrate (`reason_impl`, `CausalFlow`, `ReasonContext`/`ReasonVerdict`; `rust/anomaly-core/src/lib.rs:42-44`). No `rustler` dep in this crate — keep it dependency-light for bazel/tests.
- [ ] 2.2 Add crate-root `#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)]` so no disposition closure can unwind across the future NIF/FFI boundary (graft #1). Every gate must return through the verdict/error channel, never panic — the `corrective_ddos_detector` template's `.expect("DetectorConfig present")` antipattern is forbidden here.
- [ ] 2.3 Add `rust/causal-disposition/BUILD.bazel` with a `rust_library` target (mirroring `rust/anomaly-core/BUILD.bazel`) plus a `filegroup`. No cdylib bazel rule (the NIF is built by Rustler/mix, not bazel).

## 3. Seasonal disposition kernel (`disposition/seasonal.rs`)
- [ ] 3.1 Implement the seasonal `CausalFlow`: Value = `Disposition ∈ {Suppress, SeasonalBreach{score}, SeasonalDrift{score}, InsufficientSeasonalBaseline}`; State = per-`(dow,hod)` bucket accumulators (mean/stddev/count) plus `consecutive_anomalous` carried in; Context = `{seasonal_n_sigma, min_bucket_samples, confirm_slots, robust_statistic}`. The withhold-clean arm maps to the existing clean branch (`rust/anomaly-core/src/detector.rs:80-86`).
- [ ] 3.2 Deseasonalized residual scoring: `z = |v - seasonal_mean| / seasonal_stddev` for the latest complete bucket; breach at `seasonal_n_sigma`; `InsufficientSeasonalBaseline` when `bucket_samples < min_bucket_samples`.
- [ ] 3.3 Enforce the **bucket-exclusion invariant** (graft #2): the latest complete bucket under test MUST be excluded from the mean/stddev it is scored against, because the seasonal baseline is the historical hour-of-week profile (not a self-masking sliding window). Name it as an invariant in `seasonal.rs` and cover it with a unit test.
- [ ] 3.4 Robust-statistic selection: support mean/stddev (default), median/MAD, and p05-p95 band per metric class. When the class needs robust bands, consume the per-bucket order statistics the SQL layer already computed (`percentile_cont`/MAD), not raw points (graft #3) — keep the boundary small.
- [ ] 3.5 Zero-variance / non-finite guards return a disposition variant (`Skipped`/`InsufficientSeasonalBaseline`), never a panic (graft #1).

## 4. Disposition NIF + facade (`causal_disposition_nif`)
- [ ] 4.1 Create `elixir/serviceradar_core/native/causal_disposition_nif/` cdylib crate: `crate-type = ["cdylib"]`, bare `[workspace]` table, `rustler = "0.38"` (mirroring `native/zen_nif/Cargo.toml`; core mix pins `{:rustler, "~> 0.37"}` at `mix.exs:119`), path-dep `serviceradar-causal-disposition = { path = "../../../../rust/causal-disposition" }`.
- [ ] 4.2 Implement `#[rustler::nif(schedule = "DirtyCpu")] fn dispose_batch(kind, rows) -> Vec<DispositionResult>` with **per-row panic isolation** mirroring the edge consumer's per-item batch loop (`rust/anomaly-addon/src/engine.rs:181` `DetectorEngine::evaluate`, stateless `rolling_acc: None` / `window_tail: Some(...)` path). Missing config short-circuits to an `{:error, _}` result, never an unwind. `rustler::init!(...)`.
- [ ] 4.3 Use a `NifMap`/`NifStruct` boundary (graft: feature-gate the rustler derives behind a `rustler` feature on the NIF-facing types so `causal-disposition` stays linkable by bazel/tests and by `causal-engine` without rustler). **Reject the JSON-string ABI** — it would regress from the typed `anomaly-core` consumer convention already in this tree.
- [ ] 4.4 Add `ServiceRadar.Observability.CausalReasoner` facade (`use Rustler, otp_app: :serviceradar_core, crate: "causal_disposition_nif"`, `:erlang.nif_error(:nif_not_loaded)` stubs, mirroring `lib/serviceradar/observability/zen/native.ex`) exposing `dispose_batch(:seasonal | :capacity, inputs)`.

## 5. Seasonal worker + orchestration (Elixir stays orchestration)
- [ ] 5.1 Add `ServiceRadar.Observability.SeasonalDisposition.Worker` (Oban cron, unique guard) mirroring `CapacityForecasting.Worker` (`worker.ex:6-9`); iterate per-`Source`, page CAGG reads via `SRQLRunner` (`worker.ex:141` `fetch_rows`).
- [ ] 5.2 Keep the 168-bucket hour-of-week profile aggregation in SRQL/SQL (`GROUP BY extract(dow)/extract(hour)` over the hourly CAGGs) — data gravity (graft #3). For robust classes, have SQL emit per-bucket order statistics.
- [ ] 5.3 `SeasonalDisposition.Source` defining the profile + latest-bucket SRQL queries (mirroring `CapacityForecasting.Source`).
- [ ] 5.4 Per cycle: read CAGG profile rows → call `CausalReasoner.dispose_batch(:seasonal, rows)` → emit `verdict_source: central-seasonal` verdicts via the existing `VerdictEmitter` onto the signal path, carrying `series_key` + time window; persist returned `consecutive_anomalous`.
- [ ] 5.5 Telemetry: per-source evaluated / breached / insufficient counts, NIF call timing, run coverage.

## 6. Build wiring (release image)
- [ ] 6.1 `docker/compose/Dockerfile.core-elx`: add `COPY rust/causal-disposition ./rust/causal-disposition` and `COPY rust/anomaly-core ./rust/anomaly-core` before `mix compile` (alongside existing `COPY rust/srql` / `rust/kvutil` at lines 50-51, before line 65), since Rustler builds the cdylib during `mix compile`.
- [ ] 6.2 Confirm no bazel cdylib rule is needed; the core-elx app `filegroup` already globs `native/**` (target/ excluded). `rust/causal-disposition` keeps a `rust_library` bazel target for non-NIF consumers/tests.

## 7. Capacity port (gated behind parity) — second phase
- [ ] 7.1 Port `CapacityForecasting.Model` (`model.ex:1-396`) verbatim into `disposition/capacity.rs`: Value = `Disposition ∈ {Projected{eta, ttl, confidence, bounds}, Inactive, Skipped{reason}}`; State = the fit accumulators (least-squares / Holt-Winters level/trend/seasonals, residuals/RMSE, projection cursor); Context = `{capacity_threshold, horizon_seconds, model_kind, min_history, period}`. Preserve `@exhaustion_horizon_multiplier 10` (`model.ex:21`) and the `>150%`/`>10x` plausibility guards.
- [ ] 7.2 Convert the `{:skip, "insufficient_history"}` gate (`model.ex:47`) into a `Skipped{reason}` verdict via the error channel (graft #1) — no panic.
- [ ] 7.3 Golden-fixture parity gate (graft #4): seed CAGG slices, run old `Model.forecast/2` vs `dispose_batch(:capacity, ...)`, assert agreement within `1e-9` on every numeric field (slope, intercept, projected_value, confidence, bounds, exhaustion ETA).
- [ ] 7.4 Rewire `CapacityForecasting.Worker` to call `CausalReasoner.dispose_batch(:capacity, rows)`; keep all orchestration in Elixir — `fetch_rows`/paging (`worker.ex:141`), interface bytes→percent bound to its I/O-resolved `speed_bps` (`worker.ex:488-507`, runs before the NIF), `at_risk?`/warning-horizon policy (`worker.ex:412`), Ash `CapacityForecast` upsert, telemetry, config merge, `VerdictEmitter`.
- [ ] 7.5 **Only after parity passes**, delete `model.ex:1-396` and its now-dead aliases.

## 8. Tests
- [ ] 8.1 Seasonal kernel unit tests: busy-Tuesday ramp does NOT breach (deseasonalized residual ~0); a Sunday-3am value at Tuesday-9am levels DOES breach; thin bucket → `InsufficientSeasonalBaseline`; latest-bucket-excluded-from-own-profile invariant holds.
- [ ] 8.2 Capacity kernel parity test (task 7.3) and `Skipped{insufficient_history}` test.
- [ ] 8.3 NIF boundary tests: per-row panic isolation (one bad row does not crash the batch); missing config → `{:error, _}` per row.
- [ ] 8.4 Worker integration test over seeded CAGG fixtures for `SeasonalDisposition.Worker`.
- [ ] 8.5 `cargo test -p serviceradar-causal-disposition` and `cargo clippy --all-targets` (must pass the `deny(unwrap/expect/panic)` lint).
- [ ] 8.6 `./scripts/elixir_quality.sh --project elixir/serviceradar_core`.

## 9. Delivery
- [ ] 9.1 Document the move (central seasonal+capacity stats now in the NIF on `anomaly-core`; Elixir keeps orchestration) and the seasonal-first/capacity-second ordering in the PR.
- [ ] 9.2 Open a Forgejo PR against `staging`.
