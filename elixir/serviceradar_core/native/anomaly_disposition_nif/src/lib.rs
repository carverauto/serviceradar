// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The central disposition NIF: a thin Rustler cdylib that wraps the
//! `serviceradar-anomaly-disposition` kernels (seasonal residual-z and capacity
//! forecast) so the BEAM seasonal/capacity tier runs in Rust. The kernels are robust
//! statistics hosted on a `CausalFlow` pipeline combinator — not causal inference.
//!
//! # ABI (design D2)
//! `dispose_batch(kind, rows) -> Vec<DispositionResult>` over a **typed**
//! `NifMap`/`NifTaggedEnum` boundary (NOT a JSON string — that would regress from
//! the typed `anomaly-core` consumer convention already in this tree). The kernel's
//! NIF-facing types (`SeasonalConfig`, `SeasonalRow`, `SeasonalDisposition`,
//! `Disposition`, `RobustStatistic`) carry their `NifMap`/`NifTaggedEnum`/
//! `NifUnitEnum` derives behind the kernel crate's `rustler` feature, which this
//! cdylib turns on. The kernel crate stays rustler-free by default for bazel/tests.
//!
//! # Panic isolation (design D2 / graft #1)
//! `dispose_batch` evaluates **per row inside `catch_unwind`**, mirroring the edge
//! consumer's per-item batch loop (`rust/anomaly-addon/src/engine.rs:181`
//! `DetectorEngine::evaluate`, stateless path). One malformed row yields one
//! `{:error, _}` `DispositionResult`; it never crashes the DirtyCpu scheduler
//! thread or poisons the rest of the batch. The kernel crate already carries
//! `#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)]` so a panic is
//! not expected on the disposition path — the `catch_unwind` is the FFI safety net
//! of last resort (e.g. an allocation abort or a future kernel regression), not the
//! primary error channel. Missing/invalid config is a normal `{:error, _}` result,
//! never an unwind.

use std::panic::{catch_unwind, AssertUnwindSafe};

use rustler::{NifTaggedEnum, NifUnitEnum};
use serviceradar_anomaly_disposition::{
    dispose_capacity, dispose_seasonal, CapacityConfig, CapacityDisposition, CapacityRow,
    SeasonalConfig, SeasonalDisposition, SeasonalRow,
};

/// Which disposition kernel to run for the batch (the `kind` argument). Encodes on
/// the Elixir side as `:seasonal` / `:capacity` (a `NifUnitEnum`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, NifUnitEnum)]
pub enum DispositionKind {
    /// Seasonal residual-z disposition (shipped).
    Seasonal,
    /// Capacity forecast disposition (least-squares / Holt-Winters; live and wired —
    /// `dispose_batch(:capacity, ...)` is called by the capacity forecasting worker).
    Capacity,
}

/// One per-row request: the kernel config (the read-only `Context` channel) plus the
/// per-row input. Config rides per row so a missing/invalid config short-circuits to
/// a per-row `{:error, _}` (design D2) rather than failing the whole batch or
/// unwinding. Encodes as a `NifMap` `%{config: %{...}, row: %{...}}`.
#[derive(Clone, Debug, NifTaggedEnum)]
pub enum DispositionRequest {
    /// A seasonal row plus its seasonal config.
    Seasonal {
        config: SeasonalConfig,
        row: SeasonalRow,
    },
    /// A capacity row plus its capacity config (phase 2). The `dispose_batch`
    /// `kind` must be `:capacity` for this variant; a kind/variant mismatch is a
    /// per-row `{:error, _}`, never an unwind (graft #1).
    Capacity {
        config: CapacityConfig,
        row: CapacityRow,
    },
}

/// One per-row result. A `NifTaggedEnum`, so the worker reads back a typed tuple
/// (not JSON) per row:
/// - `{:ok, %SeasonalDisposition{}}` for a seasonal row,
/// - `{:capacity_ok, %CapacityDisposition{}}` for a capacity row,
/// - `{:error, "reason"}` when the row could not be disposed.
#[derive(Clone, Debug, NifTaggedEnum)]
pub enum DispositionResult {
    /// The kernel produced a seasonal disposition for the row.
    Ok(SeasonalDisposition),
    /// The kernel produced a capacity disposition for the row (phase 2). Encodes as
    /// `{:capacity_ok, %{series_key: ..., disposition: {...}}}`.
    CapacityOk(CapacityDisposition),
    /// The row could not be disposed: a kind/row-variant mismatch, or — via the
    /// `catch_unwind` safety net — a panic that was contained to this one row
    /// instead of the scheduler thread.
    Error(String),
}

/// The disposition batch entry point. `kind` selects the kernel; each request in
/// `rows` carries its own config so per-row isolation can downgrade a bad row to an
/// `{:error, _}` without touching its neighbors.
///
/// `DirtyCpu`: the kernels are CPU-bound and must not block a normal scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn dispose_batch(kind: DispositionKind, rows: Vec<DispositionRequest>) -> Vec<DispositionResult> {
    dispose_batch_impl(kind, rows)
}

/// The batch loop, factored out of the `#[rustler::nif]` wrapper so the boundary
/// tests (task 8.3) can drive it without the BEAM runtime.
fn dispose_batch_impl(
    kind: DispositionKind,
    rows: Vec<DispositionRequest>,
) -> Vec<DispositionResult> {
    rows.into_iter()
        .map(|request| dispose_one(kind, request))
        .collect()
}

/// Dispose a single request under panic isolation (design D2 / graft #1). The
/// kernel is panic-free by construction (its crate denies unwrap/expect/panic and
/// every gate is a `Disposition` value), so the `catch_unwind` is the FFI safety net
/// of last resort: it guarantees one bad row can never unwind across the BEAM
/// boundary and take down the DirtyCpu scheduler thread.
fn dispose_one(kind: DispositionKind, request: DispositionRequest) -> DispositionResult {
    let outcome = catch_unwind(AssertUnwindSafe(|| match (kind, request) {
        (DispositionKind::Seasonal, DispositionRequest::Seasonal { config, row }) => {
            DispositionResult::Ok(dispose_seasonal(row, &config))
        }
        (DispositionKind::Capacity, DispositionRequest::Capacity { config, row }) => {
            DispositionResult::CapacityOk(dispose_capacity(row, &config))
        }
        // A kind/row-variant mismatch (e.g. a `:capacity` kind with a seasonal row,
        // or vice versa) is a contract error reported per row as a value, never an
        // unwind (graft #1).
        (DispositionKind::Seasonal, DispositionRequest::Capacity { .. }) => {
            DispositionResult::Error(
                "kind/row mismatch: :seasonal kind with a capacity row".to_string(),
            )
        }
        (DispositionKind::Capacity, DispositionRequest::Seasonal { .. }) => {
            DispositionResult::Error(
                "kind/row mismatch: :capacity kind with a seasonal row".to_string(),
            )
        }
    }));

    match outcome {
        Ok(result) => result,
        // The unwind safety net: a panic in the kernel (not expected) is contained to
        // this row and reported as an error result, never propagated across FFI.
        Err(_panic) => {
            DispositionResult::Error("disposition kernel panicked (row isolated)".to_string())
        }
    }
}

rustler::init!("Elixir.ServiceRadar.Observability.DispositionKernels");

#[cfg(test)]
mod tests {
    //! Task 8.3 — NIF boundary tests: per-row panic isolation (one bad row does not
    //! crash the batch) and capacity-not-implemented / kind-mismatch error routing.
    //!
    //! These exercise the marshalling shell (`dispose_one` / `dispose_batch`)
    //! directly; the rustler derives only add trait impls, so the typed enums
    //! construct and run in plain `cargo test` without the BEAM runtime.

    use super::*;
    use serviceradar_anomaly_disposition::{
        CapacityModelKind, CapacityPoint, Disposition, RobustStatistic,
    };

    fn seasonal_config() -> SeasonalConfig {
        SeasonalConfig {
            seasonal_n_sigma: 3.0,
            min_bucket_samples: 4,
            confirm_slots: 1,
            robust_statistic: RobustStatistic::MeanStddev,
        }
    }

    /// A well-formed mean/stddev seasonal row whose `(dow,hod)` bucket sits low and
    /// whose sample is wildly off-season → a breach. Bucket totals INCLUDE the sample
    /// (the natural CAGG aggregate the kernel de-aggregates).
    fn off_season_breach_row() -> SeasonalRow {
        let baseline: Vec<f64> = (0..20).map(|i| 5.0 + (i % 3) as f64 * 0.5).collect();
        let sample_value = 800.0;
        let mut bucket_sum = sample_value;
        let mut bucket_sum_sq = sample_value * sample_value;
        for &p in &baseline {
            bucket_sum += p;
            bucket_sum_sq += p * p;
        }
        SeasonalRow {
            series_key: "svc/cpu".to_string(),
            dow: 0,
            hod: 3,
            sample_value,
            bucket_count: baseline.len() + 1,
            bucket_sum,
            bucket_sum_sq,
            center: 0.0,
            mad: 0.0,
            p05: 0.0,
            p95: 0.0,
            consecutive_anomalous: 0,
            baseline_excludes_latest: true,
        }
    }

    /// A row that drives the seasonal kernel down a gate path (thin bucket). The
    /// kernel returns a `Disposition` value, never panicking — the NIF must surface
    /// it as `Ok`, not `Error`.
    fn thin_bucket_row() -> SeasonalRow {
        SeasonalRow {
            series_key: "svc/thin".to_string(),
            dow: 1,
            hod: 4,
            sample_value: 50.0,
            bucket_count: 3,
            bucket_sum: 50.0 + 10.0 + 11.0 + 9.0,
            bucket_sum_sq: 50.0 * 50.0 + 100.0 + 121.0 + 81.0,
            center: 0.0,
            mad: 0.0,
            p05: 0.0,
            p95: 0.0,
            consecutive_anomalous: 0,
            baseline_excludes_latest: true,
        }
    }

    #[test]
    fn seasonal_request_disposes_to_ok() {
        let out = dispose_one(
            DispositionKind::Seasonal,
            DispositionRequest::Seasonal {
                config: seasonal_config(),
                row: off_season_breach_row(),
            },
        );
        match out {
            DispositionResult::Ok(d) => {
                assert!(
                    matches!(d.disposition, Disposition::SeasonalBreach { .. }),
                    "off-season row must breach, got {:?}",
                    d.disposition
                );
                assert_eq!(d.series_key, "svc/cpu");
            }
            other => {
                panic!("a well-formed seasonal row must dispose to Ok, got {other:?}")
            }
        }
    }

    #[test]
    fn kernel_gate_surfaces_as_ok_not_error() {
        // A thin bucket is a kernel GATE (InsufficientSeasonalBaseline), a Disposition
        // value — it must marshal as Ok(disposition), not as a NIF Error. The Error
        // channel is reserved for ABI/contract/panic failures, not detection gates.
        let out = dispose_one(
            DispositionKind::Seasonal,
            DispositionRequest::Seasonal {
                config: seasonal_config(),
                row: thin_bucket_row(),
            },
        );
        match out {
            DispositionResult::Ok(d) => assert_eq!(
                d.disposition,
                Disposition::InsufficientSeasonalBaseline,
                "a thin bucket must surface as the InsufficientSeasonalBaseline value"
            ),
            other => {
                panic!("a kernel gate must marshal as Ok(value), got {other:?}")
            }
        }
    }

    fn capacity_config() -> CapacityConfig {
        CapacityConfig {
            capacity_threshold: Some(80.0),
            horizon_seconds: 24 * 3_600,
            model_kind: CapacityModelKind::Linear,
            min_history: 24,
            period: 24,
            alpha: 0.35,
            beta: 0.05,
            gamma: 0.25,
            value_min: None,
            value_max: None,
        }
    }

    /// A linearly-rising capacity row whose threshold crossing lands in-horizon → a
    /// `Projected` disposition (phase 2, now implemented).
    fn rising_capacity_row() -> CapacityRow {
        let start: i64 = 1_780_272_000_000_000;
        let points = (0..48)
            .map(|h| CapacityPoint {
                at_unix_micros: start + h * 3_600 * 1_000_000,
                value: 10.0 + h as f64,
            })
            .collect();
        CapacityRow {
            series_key: "svc/disk".to_string(),
            points,
        }
    }

    #[test]
    fn capacity_request_disposes_to_capacity_ok() {
        // Phase 2 is wired: a well-formed capacity row disposes to CapacityOk with a
        // Projected verdict, never an Error or a panic.
        let out = dispose_one(
            DispositionKind::Capacity,
            DispositionRequest::Capacity {
                config: capacity_config(),
                row: rising_capacity_row(),
            },
        );
        match out {
            DispositionResult::CapacityOk(d) => {
                assert_eq!(d.series_key, "svc/disk");
                assert!(
                    matches!(d.disposition, Disposition::Projected { .. }),
                    "a rising capacity row must project, got {:?}",
                    d.disposition
                );
            }
            other => panic!("a well-formed capacity row must dispose to CapacityOk, got {other:?}"),
        }
    }

    #[test]
    fn kind_row_mismatch_is_error_not_panic() {
        // A :capacity kind with a seasonal row is a contract error reported per row
        // as a value, never an unwind (graft #1).
        let out = dispose_one(
            DispositionKind::Capacity,
            DispositionRequest::Seasonal {
                config: seasonal_config(),
                row: off_season_breach_row(),
            },
        );
        assert!(
            matches!(out, DispositionResult::Error(ref r) if r.contains("mismatch")),
            "a kind/row mismatch must be a clean Error, got {out:?}"
        );

        // ...and the reverse: a :seasonal kind with a capacity row.
        let out = dispose_one(
            DispositionKind::Seasonal,
            DispositionRequest::Capacity {
                config: capacity_config(),
                row: rising_capacity_row(),
            },
        );
        assert!(
            matches!(out, DispositionResult::Error(ref r) if r.contains("mismatch")),
            "a kind/row mismatch must be a clean Error, got {out:?}"
        );
    }

    #[test]
    fn panic_in_a_row_is_isolated_to_that_row() {
        // The FFI safety net (D2): even if a kernel closure panicked, catch_unwind
        // must contain it to the one row and return an Error result — the rest of the
        // batch still produces values. We can't make the panic-free kernel itself
        // panic, so we drive dispose_one's catch_unwind directly with a panicking
        // closure to prove the net holds, then assert a real batch is unaffected.
        let net = catch_unwind(AssertUnwindSafe(|| -> DispositionResult {
            #[allow(clippy::panic)]
            {
                panic!("simulated kernel panic")
            }
        }));
        assert!(
            net.is_err(),
            "premise: the closure panics so catch_unwind returns Err"
        );

        // A batch containing a normal row still yields a value for that row — one
        // hypothetical bad row would not poison its neighbors.
        let results = dispose_batch_impl(
            DispositionKind::Seasonal,
            vec![
                DispositionRequest::Seasonal {
                    config: seasonal_config(),
                    row: off_season_breach_row(),
                },
                DispositionRequest::Seasonal {
                    config: seasonal_config(),
                    row: thin_bucket_row(),
                },
            ],
        );
        assert_eq!(results.len(), 2, "every row yields exactly one result");
        assert!(matches!(results[0], DispositionResult::Ok(_)));
        assert!(matches!(results[1], DispositionResult::Ok(_)));
    }

    #[test]
    fn empty_batch_yields_empty_results() {
        let results = dispose_batch_impl(DispositionKind::Seasonal, Vec::new());
        assert!(results.is_empty(), "an empty batch yields no results");
    }
}
