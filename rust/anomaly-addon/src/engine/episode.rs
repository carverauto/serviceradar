// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Edge anomaly-episode lifecycle bookkeeping: the spike-preserving aggregation
//! slot plus the pending/active episode peak tracking and reset helpers that the
//! transition layer drives over a series' retained [`SeriesState`].

use serviceradar_anomaly_core::ReasonVerdict;

use super::state::SeriesState;
use super::types::AnomalyEpisode;

pub(crate) fn store_aggregation_slot(
    state: &mut SeriesState,
    slot_start_unix_nano: u64,
    value: f64,
    peak_at_unix_nano: u64,
) {
    state.aggregation_slot_start_unix_nano = Some(slot_start_unix_nano);
    state.aggregation_slot_value = Some(value);
    state.aggregation_slot_peak_at_unix_nano = Some(peak_at_unix_nano);
}

pub(crate) fn update_aggregation_slot(
    state: &mut SeriesState,
    value: f64,
    observed_at_unix_nano: u64,
) {
    if state
        .aggregation_slot_value
        .is_none_or(|current| value > current)
    {
        state.aggregation_slot_value = Some(value);
        state.aggregation_slot_peak_at_unix_nano = Some(observed_at_unix_nano);
    }
}

pub(crate) fn observe_pending_breach(
    state: &mut SeriesState,
    value: f64,
    observed_at_unix_nano: u64,
) {
    if state.pending_episode_started_at_unix_nano.is_none() {
        state.pending_episode_started_at_unix_nano = Some(observed_at_unix_nano);
    }

    update_peak(
        &mut state.pending_episode_peak_value,
        &mut state.pending_episode_peak_at_unix_nano,
        value,
        observed_at_unix_nano,
    );
}

pub(crate) fn observe_active_breach(
    state: &mut SeriesState,
    value: f64,
    observed_at_unix_nano: u64,
) {
    update_peak(
        &mut state.active_episode_peak_value,
        &mut state.active_episode_peak_at_unix_nano,
        value,
        observed_at_unix_nano,
    );
}

/// Promote a confirmed spike while optionally preserving an earlier episode
/// start. Reopens within the flap window use the original start so the stable
/// finding UID derives the same episode UID across every flap cycle.
pub(crate) fn promote_pending_episode_with_start(
    state: &mut SeriesState,
    value: f64,
    observed_at_unix_nano: u64,
    previous_episode_started_at_unix_nano: Option<u64>,
) {
    state.active_episode_started_at_unix_nano =
        Some(previous_episode_started_at_unix_nano.unwrap_or_else(|| {
            state
                .pending_episode_started_at_unix_nano
                .unwrap_or(observed_at_unix_nano)
        }));
    state.active_episode_peak_value = Some(state.pending_episode_peak_value.unwrap_or(value));
    state.active_episode_peak_at_unix_nano = Some(
        state
            .pending_episode_peak_at_unix_nano
            .unwrap_or(observed_at_unix_nano),
    );
    reset_pending_episode(state);
}

pub(crate) fn active_episode(
    state: &SeriesState,
    ended_at_unix_nano: u64,
) -> Option<AnomalyEpisode> {
    Some(AnomalyEpisode {
        started_at_unix_nano: state.active_episode_started_at_unix_nano?,
        ended_at_unix_nano,
        peak_value: state.active_episode_peak_value?,
        peak_at_unix_nano: state.active_episode_peak_at_unix_nano?,
    })
}

fn update_peak(
    peak_value: &mut Option<f64>,
    peak_at: &mut Option<u64>,
    value: f64,
    observed_at_unix_nano: u64,
) {
    if peak_value.is_none_or(|current| value > current) {
        *peak_value = Some(value);
        *peak_at = Some(observed_at_unix_nano);
    }
}

pub(crate) fn reset_pending_episode(state: &mut SeriesState) {
    state.pending_episode_started_at_unix_nano = None;
    state.pending_episode_peak_value = None;
    state.pending_episode_peak_at_unix_nano = None;
}

pub(crate) fn reset_active_episode(state: &mut SeriesState) {
    state.active_episode_started_at_unix_nano = None;
    state.active_episode_peak_value = None;
    state.active_episode_peak_at_unix_nano = None;
}

pub(crate) fn is_clean_verdict(verdict: &ReasonVerdict) -> bool {
    !verdict.anomalous && verdict.next_consecutive_anomalous == 0
}
