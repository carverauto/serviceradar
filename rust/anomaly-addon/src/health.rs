// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Scoring-liveness health tracking and the rolled-up health summary the add-on
//! reports.

use addon_sdk::HealthStatus;

use crate::checkpoint::now_unix_nano;
use crate::config::DEFAULT_SCORING_STALE_AFTER_NS;

#[derive(Clone, Debug)]
pub(crate) struct ScoringHealth {
    pub(crate) frames_seen: u64,
    pub(crate) scored_samples: u64,
    pub(crate) emitted_verdicts: u64,
    pub(crate) last_feed_id: u64,
    pub(crate) last_scored_at_unix_nano: u64,
    pub(crate) last_frame_at_unix_nano: u64,
    pub(crate) stale_after_ns: u64,
}

impl Default for ScoringHealth {
    fn default() -> Self {
        Self {
            frames_seen: 0,
            scored_samples: 0,
            emitted_verdicts: 0,
            last_feed_id: 0,
            last_scored_at_unix_nano: 0,
            last_frame_at_unix_nano: 0,
            stale_after_ns: DEFAULT_SCORING_STALE_AFTER_NS,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct ScoringFrameUpdate {
    pub(crate) feed_id: u64,
    pub(crate) scored_samples: u64,
    pub(crate) emitted_verdicts: u64,
    pub(crate) last_scored_at_unix_nano: u64,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct EngineHealthSnapshot {
    pub(crate) tracked_series: usize,
    pub(crate) tracked_counters: usize,
    pub(crate) max_series: usize,
    pub(crate) dropped_total: u64,
    pub(crate) drift_inactive_no_baseline_total: u64,
    pub(crate) clamped_samples_total: u64,
}

#[derive(Clone, Debug)]
pub(crate) struct HealthSummary {
    pub(crate) status: HealthStatus,
    pub(crate) detail: String,
}

impl ScoringHealth {
    pub(crate) fn set_stale_after_ns(&mut self, stale_after_ns: u64) {
        self.stale_after_ns = stale_after_ns.max(1_000_000_000);
    }

    pub(crate) fn record_frame(&mut self, update: ScoringFrameUpdate) {
        self.frames_seen = self.frames_seen.saturating_add(1);
        self.scored_samples = self.scored_samples.saturating_add(update.scored_samples);
        self.emitted_verdicts = self
            .emitted_verdicts
            .saturating_add(update.emitted_verdicts);
        self.last_feed_id = update.feed_id;
        self.last_frame_at_unix_nano = now_unix_nano();
        self.last_scored_at_unix_nano = self
            .last_scored_at_unix_nano
            .max(update.last_scored_at_unix_nano);
    }

    pub(crate) fn health_summary(&self, engine: EngineHealthSnapshot) -> HealthSummary {
        self.health_summary_at(engine, now_unix_nano())
    }

    pub(crate) fn health_summary_at(
        &self,
        engine: EngineHealthSnapshot,
        now_unix_nano: u64,
    ) -> HealthSummary {
        let cap_pressure = engine.max_series > 0
            && (engine.tracked_series >= engine.max_series
                || engine.tracked_counters >= engine.max_series);
        let last_frame_age_ns = now_unix_nano.saturating_sub(self.last_frame_at_unix_nano);
        let scoring_stalled = self.scored_samples > 0 && last_frame_age_ns > self.stale_after_ns;

        let (status, state) = if self.scored_samples == 0 {
            (HealthStatus::Degraded, "no_scored_samples")
        } else if scoring_stalled {
            (HealthStatus::Degraded, "scoring_stalled")
        } else if cap_pressure && engine.dropped_total > 0 {
            (HealthStatus::Degraded, "capacity_shed")
        } else if cap_pressure {
            (HealthStatus::Degraded, "at_capacity")
        } else {
            (HealthStatus::Healthy, "scoring_active")
        };

        HealthSummary {
            status,
            detail: format!(
                "state={state};frames_seen={};scored_samples={};emitted_verdicts={};last_feed_id={};last_frame_at_unix_nano={};last_scored_at_unix_nano={};last_frame_age_ns={};stale_after_ns={};tracked_series={};tracked_counters={};max_series={};dropped_total={};drift_inactive_no_baseline_total={};clamped_samples_total={}",
                self.frames_seen,
                self.scored_samples,
                self.emitted_verdicts,
                self.last_feed_id,
                self.last_frame_at_unix_nano,
                self.last_scored_at_unix_nano,
                last_frame_age_ns,
                self.stale_after_ns,
                engine.tracked_series,
                engine.tracked_counters,
                engine.max_series,
                engine.dropped_total,
                engine.drift_inactive_no_baseline_total,
                engine.clamped_samples_total
            ),
        }
    }
}
