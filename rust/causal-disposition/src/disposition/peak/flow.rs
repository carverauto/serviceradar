// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The peak disposition `CausalFlow`: drive the UASB band kernel on the shared
//! `deep_causality_core::CausalFlow` substrate (the same model the seasonal/
//! capacity dispositions use — deterministic, O(1) — NOT `Uncertain<T>` sampling),
//! then apply the leaky-bucket confirm counter.
//!
//! Confirm counter (invariant I7): unlike the seasonal kernel — which **resets** on
//! `Suppress` and so can hold a real recurring anomaly suppressed forever — the
//! peak counter only **decays** on `Suppress`, so a series that escalates more than
//! it suppresses still climbs to confirmation.

use super::band::decide;
use super::types::{PassReason, PeakConfig, PeakDisposition, PeakOutcome, PeakRow};
use deep_causality_core::{CausalFlow, CausalityError, CausalityErrorEnum};

/// Internal flow state (the `State` channel).
struct PeakState {
    row: PeakRow,
}

/// The flow `Value` channel.
enum PeakValue {
    Evaluate,
    Disposed(PeakDisposition),
}

/// Dispose one spike through the peak `CausalFlow` and the leaky-bucket confirm
/// counter. `carried` is the previous slot's counter (round-tripped by the worker).
pub fn dispose_peak(row: PeakRow, carried: usize, config: &PeakConfig) -> PeakOutcome {
    let series_key = row.series_key.clone();

    let disposition = run_peak_flow(row, config).unwrap_or(PeakDisposition::PassThrough {
        reason: PassReason::Internal,
    });

    let next_carried = next_confirm_counter(carried, &disposition, config);
    // The report-only gate: the counter still accumulates so calibration can observe
    // what the band would do, but nothing surfaces until report_only is lifted.
    let surfaced =
        !config.report_only && config.confirm_slots > 0 && next_carried >= config.confirm_slots;
    let score = disposition_score(&disposition);

    PeakOutcome {
        series_key,
        disposition,
        next_carried,
        surfaced,
        score,
    }
}

/// Drive the peak `CausalFlow`: process state, run the band decision into the
/// `Value` channel, finalize. Mirrors the seasonal flow's shape.
fn run_peak_flow(row: PeakRow, config: &PeakConfig) -> Result<PeakDisposition, String> {
    let value = CausalFlow::process(PeakState { row })
        .context(*config)
        .map(|()| PeakValue::Evaluate)
        .update_value_state_context(run_decide)
        .finish()
        .map_err(|err| err.to_string())?;

    match value {
        PeakValue::Disposed(disposition) => Ok(disposition),
        PeakValue::Evaluate => {
            Err(CausalityError::new(CausalityErrorEnum::ValueNotAvailable).to_string())
        }
    }
}

/// The single flow stage: run the UASB band kernel into the `Value` channel.
fn run_decide(
    _value: PeakValue,
    state: PeakState,
    context: Option<PeakConfig>,
) -> (PeakValue, PeakState, Option<PeakConfig>) {
    let disposition = match context.as_ref() {
        Some(config) => decide(&state.row, config),
        None => PeakDisposition::PassThrough {
            reason: PassReason::Internal,
        },
    };
    (PeakValue::Disposed(disposition), state, context)
}

/// The leaky-bucket confirm counter. Invariant **I7**: `Suppress` does NOT reset
/// it. Escalate/Downgrade are concern slots (`+1`, capped at `confirm_slots`);
/// `Suppress` decays by one; `PassThrough` (a guard) preserves it.
fn next_confirm_counter(
    carried: usize,
    disposition: &PeakDisposition,
    config: &PeakConfig,
) -> usize {
    match disposition {
        PeakDisposition::Escalate { .. } | PeakDisposition::Downgrade { .. } => {
            carried.saturating_add(1).min(config.confirm_slots)
        }
        PeakDisposition::Suppress => carried.saturating_sub(1),
        PeakDisposition::PassThrough { .. } => carried,
    }
}

fn disposition_score(disposition: &PeakDisposition) -> f64 {
    match disposition {
        PeakDisposition::Escalate { score } | PeakDisposition::Downgrade { score } => *score,
        _ => 0.0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Calibration-mode config: report_only OFF so the surfacing tests exercise the
    // confirm-slot path. The default ships with report_only ON (observe-only).
    fn cfg() -> PeakConfig {
        PeakConfig {
            report_only: false,
            ..PeakConfig::default()
        }
    }

    fn warm_row(peak: f64) -> PeakRow {
        PeakRow {
            series_key: "s".into(),
            hod: 3,
            peak,
            n: 8,
            cell_center: 20.0,
            cell_scale: 2.0,
            prior_scale: 2.0,
            q95: 24.0,
        }
    }

    #[test]
    fn suppress_decays_counter_does_not_reset() {
        // I7: a Suppress slot decays the counter by one, never to zero, so
        // confirmation progress survives an intervening normal slot.
        assert_eq!(
            next_confirm_counter(2, &PeakDisposition::Suppress, &cfg()),
            1
        );
        assert_eq!(
            next_confirm_counter(0, &PeakDisposition::Suppress, &cfg()),
            0
        );
    }

    #[test]
    fn escalate_increments_and_caps() {
        let c = cfg(); // confirm_slots = 2
        assert_eq!(
            next_confirm_counter(0, &PeakDisposition::Escalate { score: 5.0 }, &c),
            1
        );
        assert_eq!(
            next_confirm_counter(1, &PeakDisposition::Escalate { score: 5.0 }, &c),
            2
        );
        // Capped at confirm_slots.
        assert_eq!(
            next_confirm_counter(2, &PeakDisposition::Escalate { score: 5.0 }, &c),
            2
        );
    }

    #[test]
    fn passthrough_preserves_counter() {
        assert_eq!(
            next_confirm_counter(
                1,
                &PeakDisposition::PassThrough {
                    reason: PassReason::Cold
                },
                &cfg()
            ),
            1
        );
    }

    #[test]
    fn i7_oscillating_anomaly_still_confirms() {
        // Two escalates confirm; one suppress decays to 1 (not 0 — the seasonal
        // bug); the next escalate re-confirms immediately. A reset-on-suppress
        // kernel would have needed two fresh escalates.
        let c = cfg();
        let mut carried = 0;
        for (peak, want_surfaced) in [
            (60.0, false), // escalate -> 1
            (60.0, true),  // escalate -> 2, surfaced
            (20.0, false), // suppress -> 1 (decay, not reset)
            (60.0, true),  // escalate -> 2, surfaced again (fast re-arm)
        ] {
            let out = dispose_peak(warm_row(peak), carried, &c);
            assert_eq!(out.surfaced, want_surfaced, "peak={peak}");
            carried = out.next_carried;
        }
    }

    #[test]
    fn flow_normal_peak_suppresses_and_does_not_surface() {
        let out = dispose_peak(warm_row(20.0), 0, &cfg());
        assert_eq!(out.disposition, PeakDisposition::Suppress);
        assert!(!out.surfaced);
        assert_eq!(out.score, 0.0);
    }

    #[test]
    fn report_only_default_gates_surfacing() {
        // The shipped default (report_only = true): even repeated confirming
        // escalates never surface — the worker observes, nothing auto-escalates.
        let c = PeakConfig::default();
        assert!(c.report_only, "the default must ship observe-only");
        let mut carried = 0;
        for _ in 0..3 {
            let out = dispose_peak(warm_row(60.0), carried, &c);
            assert!(matches!(out.disposition, PeakDisposition::Escalate { .. }));
            assert!(!out.surfaced, "report_only must gate surfacing");
            carried = out.next_carried;
        }
        // The counter still accumulated (so calibration can observe the band).
        assert_eq!(carried, c.confirm_slots);
    }
}
