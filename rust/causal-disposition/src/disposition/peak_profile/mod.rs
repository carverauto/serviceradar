// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Robust peak-profile disposition kernel.
//!
//! This is the matched-resolution companion to the seasonal mean disposition:
//! edge detects a spike and forwards its peak/window; core scores that peak
//! against the series' normal hour-of-day peak profile built from hourly
//! `max_value`.
//!
//! The kernel is intentionally report-only by default. It records what the robust
//! profile would recommend, but the surfaced action remains `PassThrough` until
//! constants and per-class coverage are calibrated on real data.

#[cfg(test)]
mod tests;
mod types;

pub use types::{
    PeakProfileAction, PeakProfileBand, PeakProfileConfig, PeakProfileDisposition, PeakProfileRow,
};

use deep_causality_core::{CausalFlow, CausalityError, CausalityErrorEnum};
use types::{PeakProfileEvaluation, PeakProfileState, PeakProfileValue};

/// Score one edge spike against a robust peak profile.
pub fn dispose_peak_profile(
    row: PeakProfileRow,
    config: &PeakProfileConfig,
) -> PeakProfileDisposition {
    let series_key = row.series_key.clone();
    let carried_consecutive_anomalous = row.consecutive_anomalous;

    match run_peak_profile_flow(row, config) {
        Ok(evaluation) => PeakProfileDisposition {
            series_key,
            recommended_action: evaluation.recommended_action,
            surfaced_action: evaluation.surfaced_action,
            reason: evaluation.reason,
            score: evaluation.score,
            next_consecutive_anomalous: evaluation.next_consecutive_anomalous,
            band: evaluation.band,
        },
        Err(err) => peak_profile_error_disposition(series_key, carried_consecutive_anomalous, &err),
    }
}

fn peak_profile_error_disposition(
    series_key: String,
    carried_consecutive_anomalous: usize,
    err: &str,
) -> PeakProfileDisposition {
    PeakProfileDisposition {
        series_key,
        recommended_action: PeakProfileAction::PassThrough,
        surfaced_action: PeakProfileAction::PassThrough,
        reason: format!("peak profile flow error: {err}"),
        score: 0.0,
        next_consecutive_anomalous: carried_consecutive_anomalous,
        band: None,
    }
}

fn run_peak_profile_flow(
    row: PeakProfileRow,
    config: &PeakProfileConfig,
) -> Result<PeakProfileEvaluation, String> {
    let state = PeakProfileState { row, band: None };

    let value = CausalFlow::process(state)
        .context(*config)
        .map(|()| PeakProfileValue::Evaluate)
        .update_value_state_context(evaluate_peak_profile)
        .update_value_state_context(finalize_peak_profile)
        .finish()
        .map_err(|err| err.to_string())?;

    match value {
        PeakProfileValue::Disposed(evaluation) => Ok(evaluation),
        PeakProfileValue::Evaluate => {
            Err(CausalityError::new(CausalityErrorEnum::ValueNotAvailable).to_string())
        }
    }
}

fn evaluate_peak_profile(
    _value: PeakProfileValue,
    mut state: PeakProfileState,
    context: Option<PeakProfileConfig>,
) -> (
    PeakProfileValue,
    PeakProfileState,
    Option<PeakProfileConfig>,
) {
    let Some(config) = context.as_ref() else {
        return gate("peak profile config missing", state, context);
    };

    if let Some(reason) = validate_config(config) {
        return gate(reason, state, context);
    }

    let row = &state.row;
    if !row.peak_value.is_finite() || !row.cell_center.is_finite() || !row.cell_q95.is_finite() {
        return gate(
            "peak profile row contains non-finite values",
            state,
            context,
        );
    }

    if row.cell_sample_count < config.min_cell_samples {
        return gate("cold peak profile cell", state, context);
    }

    let Some(cell_scale) = robust_scale_or_floor(row.cell_scale, config.absolute_scale_floor)
    else {
        return gate("invalid peak profile cell scale", state, context);
    };
    let Some(prior_scale) =
        robust_scale_or_floor(row.series_prior_scale, config.absolute_scale_floor)
    else {
        return gate("invalid peak profile series prior scale", state, context);
    };

    if cell_scale > config.over_dispersion_ratio * prior_scale {
        return gate("over-dispersed peak profile cell", state, context);
    }

    let n = row.cell_sample_count as f64;
    let low_n_multiplier = 1.0 + config.low_n_inflation / n.sqrt();
    let inner_scale = cell_scale.min(config.cap_scale * prior_scale);
    let outer_scale = cell_scale.max(prior_scale);

    let inner_width = config.suppress_n_sigma * inner_scale * low_n_multiplier;
    let outer_width = config.escalate_n_sigma * outer_scale * low_n_multiplier;

    if config.ceiling.is_finite() && row.cell_q95 + inner_width >= config.ceiling {
        return gate("ceiling-proximity peak profile cell", state, context);
    }

    let band = PeakProfileBand {
        center: row.cell_center,
        inner_scale,
        outer_scale,
        low_n_multiplier,
        inner_lower: row.cell_center - inner_width,
        inner_upper: row.cell_center + inner_width,
        outer_lower: row.cell_center - outer_width,
        outer_upper: row.cell_center + outer_width,
    };
    state.band = Some(band);

    let peak = row.peak_value;
    let recommended_action = if peak < band.outer_lower || peak > band.outer_upper {
        PeakProfileAction::Escalate
    } else if peak < band.inner_lower || peak > band.inner_upper {
        PeakProfileAction::Downgrade
    } else {
        PeakProfileAction::Suppress
    };

    let score = signed_inner_score(peak, band);
    let reason = match recommended_action {
        PeakProfileAction::Suppress => "peak within matched-resolution profile",
        PeakProfileAction::Downgrade => "peak outside suppression band but inside escalation band",
        PeakProfileAction::Escalate => "peak outside matched-resolution escalation band",
        PeakProfileAction::PassThrough => "peak profile passed through",
    };

    let evaluation = PeakProfileEvaluation {
        recommended_action,
        surfaced_action: recommended_action,
        reason: reason.to_string(),
        score,
        next_consecutive_anomalous: row.consecutive_anomalous,
        band: Some(band),
    };

    (PeakProfileValue::Disposed(evaluation), state, context)
}

fn finalize_peak_profile(
    value: PeakProfileValue,
    state: PeakProfileState,
    context: Option<PeakProfileConfig>,
) -> (
    PeakProfileValue,
    PeakProfileState,
    Option<PeakProfileConfig>,
) {
    let PeakProfileValue::Disposed(mut evaluation) = value else {
        return (value, state, context);
    };

    let Some(config) = context.as_ref() else {
        evaluation.surfaced_action = PeakProfileAction::PassThrough;
        evaluation.reason = "peak profile config missing".to_string();
        return (PeakProfileValue::Disposed(evaluation), state, context);
    };

    evaluation.next_consecutive_anomalous = next_counter(
        state.row.consecutive_anomalous,
        evaluation.recommended_action,
        config,
    );

    evaluation.surfaced_action = surfaced_action(evaluation.recommended_action, config);

    (PeakProfileValue::Disposed(evaluation), state, context)
}

fn gate(
    reason: impl Into<String>,
    state: PeakProfileState,
    context: Option<PeakProfileConfig>,
) -> (
    PeakProfileValue,
    PeakProfileState,
    Option<PeakProfileConfig>,
) {
    let evaluation = PeakProfileEvaluation {
        recommended_action: PeakProfileAction::PassThrough,
        surfaced_action: PeakProfileAction::PassThrough,
        reason: reason.into(),
        score: 0.0,
        next_consecutive_anomalous: state.row.consecutive_anomalous,
        band: None,
    };

    (PeakProfileValue::Disposed(evaluation), state, context)
}

fn validate_config(config: &PeakProfileConfig) -> Option<&'static str> {
    if !config.suppress_n_sigma.is_finite()
        || !config.escalate_n_sigma.is_finite()
        || !config.cap_scale.is_finite()
        || !config.low_n_inflation.is_finite()
        || !config.over_dispersion_ratio.is_finite()
        || !config.absolute_scale_floor.is_finite()
    {
        return Some("peak profile config contains non-finite values");
    }
    if config.suppress_n_sigma <= 0.0 || config.escalate_n_sigma <= 0.0 {
        return Some("peak profile sigma must be positive");
    }
    if config.escalate_n_sigma < config.suppress_n_sigma {
        return Some("peak profile escalation sigma must be >= suppression sigma");
    }
    if config.cap_scale <= 0.0 || config.over_dispersion_ratio <= 0.0 {
        return Some("peak profile scale ratios must be positive");
    }
    if config.low_n_inflation < 0.0 || config.absolute_scale_floor <= 0.0 {
        return Some("peak profile inflation and floor must be valid");
    }
    None
}

fn robust_scale_or_floor(raw_scale: f64, absolute_floor: f64) -> Option<f64> {
    if !raw_scale.is_finite() {
        return None;
    }
    if raw_scale > f64::EPSILON {
        return Some(raw_scale);
    }
    Some(absolute_floor)
}

fn signed_inner_score(peak: f64, band: PeakProfileBand) -> f64 {
    if band.inner_scale <= f64::EPSILON {
        return 0.0;
    }
    (peak - band.center) / band.inner_scale
}

fn surfaced_action(action: PeakProfileAction, config: &PeakProfileConfig) -> PeakProfileAction {
    if config.report_only {
        return PeakProfileAction::PassThrough;
    }

    match action {
        PeakProfileAction::Suppress | PeakProfileAction::Downgrade
            if !config.suppression_enabled =>
        {
            PeakProfileAction::PassThrough
        }
        other => other,
    }
}

fn next_counter(carried: usize, action: PeakProfileAction, config: &PeakProfileConfig) -> usize {
    match action {
        PeakProfileAction::Escalate => carried.saturating_add(1),
        PeakProfileAction::Suppress | PeakProfileAction::Downgrade => {
            carried.saturating_sub(config.suppress_decay_slots)
        }
        PeakProfileAction::PassThrough => carried,
    }
}
