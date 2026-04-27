use crate::observation::SidekickObservation;
use crate::spectrum::SpectrumSummary;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};
use tokio::task::JoinHandle;

const RF_OBSERVATION_TTL: Duration = Duration::from_secs(30);
const SPECTRUM_SCORE_TTL: Duration = Duration::from_secs(15);
const MIN_HOP_INTERVAL: Duration = Duration::from_millis(100);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdaptiveChannelHopRequest {
    pub interface_name: String,
    pub fallback_frequencies_mhz: Vec<u32>,
    pub interval: Duration,
}

#[derive(Debug, Clone, Default)]
pub struct AdaptiveScanState {
    inner: Arc<RwLock<AdaptiveScanInner>>,
}

#[derive(Debug, Default)]
struct AdaptiveScanInner {
    spectrum_by_frequency: HashMap<u32, SpectrumChannelActivity>,
    rf_by_frequency: HashMap<u32, RfChannelActivity>,
}

#[derive(Debug, Clone)]
struct SpectrumChannelActivity {
    interference_score: u8,
    average_power_dbm: f32,
    peak_power_dbm: f32,
    observed_at: Instant,
}

#[derive(Debug, Clone)]
struct RfChannelActivity {
    bssids: HashSet<String>,
    strongest_rssi_dbm: Option<i16>,
    observed_at: Instant,
}

impl AdaptiveScanState {
    pub fn observe_spectrum_summary(&self, summary: &SpectrumSummary) {
        let now = Instant::now();
        let Ok(mut inner) = self.inner.write() else {
            return;
        };

        inner.prune(now);
        for score in &summary.channel_scores {
            let frequency = u32::from(score.center_frequency_mhz);
            inner.spectrum_by_frequency.insert(
                frequency,
                SpectrumChannelActivity {
                    interference_score: score.interference_score,
                    average_power_dbm: score.average_power_dbm,
                    peak_power_dbm: score.peak_power_dbm,
                    observed_at: now,
                },
            );
        }
    }

    pub fn observe_rf_observation(&self, observation: &SidekickObservation) {
        if observation.frequency_mhz == 0 || observation.bssid.trim().is_empty() {
            return;
        }

        let now = Instant::now();
        let Ok(mut inner) = self.inner.write() else {
            return;
        };
        inner.prune(now);
        let activity = inner
            .rf_by_frequency
            .entry(observation.frequency_mhz)
            .or_insert_with(|| RfChannelActivity {
                bssids: HashSet::new(),
                strongest_rssi_dbm: None,
                observed_at: now,
            });

        activity.bssids.insert(observation.bssid.clone());
        activity.strongest_rssi_dbm = observation
            .rssi_dbm
            .or(activity.strongest_rssi_dbm)
            .max(activity.strongest_rssi_dbm);
        activity.observed_at = now;
    }

    pub fn weighted_plan(&self, fallback_frequencies_mhz: &[u32]) -> Vec<u32> {
        let mut fallback = dedupe_frequencies(fallback_frequencies_mhz);
        if fallback.is_empty() {
            return Vec::new();
        }

        let now = Instant::now();
        let Ok(mut inner) = self.inner.write() else {
            return fallback;
        };

        inner.prune(now);
        fallback.sort_unstable();
        fallback.sort_by_key(|frequency| std::cmp::Reverse(inner.frequency_weight(*frequency)));

        let mut weighted = Vec::with_capacity(fallback.len() * 4);
        for frequency in &fallback {
            let repeats = inner.frequency_weight(*frequency).clamp(1, 5);
            for _ in 0..repeats {
                weighted.push(*frequency);
            }
        }

        // Keep one full pass in the tail so quiet channels are still checked
        // periodically and newly visible APs can enter the weighted plan.
        weighted.extend(fallback);
        weighted
    }
}

impl AdaptiveScanInner {
    fn prune(&mut self, now: Instant) {
        self.spectrum_by_frequency
            .retain(|_, activity| now.duration_since(activity.observed_at) <= SPECTRUM_SCORE_TTL);
        self.rf_by_frequency
            .retain(|_, activity| now.duration_since(activity.observed_at) <= RF_OBSERVATION_TTL);
    }

    fn frequency_weight(&self, frequency_mhz: u32) -> usize {
        let mut weight = 1_usize;

        if let Some(activity) = self.spectrum_by_frequency.get(&frequency_mhz) {
            weight += usize::from(activity.interference_score / 25).min(4);
            if activity.peak_power_dbm - activity.average_power_dbm >= 8.0 {
                weight += 1;
            }
        }

        if let Some(activity) = self.rf_by_frequency.get(&frequency_mhz) {
            weight += activity.bssids.len().min(4);
            if activity.strongest_rssi_dbm.is_some_and(|rssi| rssi >= -72) {
                weight += 1;
            }
        }

        weight
    }
}

pub fn build_adaptive_channel_hop_request(
    interface_name: &str,
    raw_frequencies_mhz: &str,
    interval_ms: u64,
) -> Result<Option<AdaptiveChannelHopRequest>, String> {
    let interface = interface_name.trim();
    if interface.is_empty() {
        return Err("interface_name is required".to_string());
    }

    let fallback_frequencies_mhz = crate::radio::parse_frequency_list(raw_frequencies_mhz)?;
    if fallback_frequencies_mhz.len() < 2 {
        return Ok(None);
    }

    if interval_ms < MIN_HOP_INTERVAL.as_millis() as u64 {
        return Err("hop_interval_ms must be at least 100".to_string());
    }

    Ok(Some(AdaptiveChannelHopRequest {
        interface_name: interface.to_string(),
        fallback_frequencies_mhz,
        interval: Duration::from_millis(interval_ms),
    }))
}

pub fn spawn_adaptive_channel_hopper(
    request: AdaptiveChannelHopRequest,
    state: AdaptiveScanState,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut plan = request.fallback_frequencies_mhz.to_vec();
        let mut index = 0usize;
        let mut interval = tokio::time::interval(request.interval);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            if index == 0 {
                let next_plan = state.weighted_plan(&request.fallback_frequencies_mhz);
                if !next_plan.is_empty() {
                    plan = next_plan;
                }
            }

            let frequency_mhz = plan[index % plan.len()];
            let _ =
                crate::radio::set_interface_frequency(&request.interface_name, frequency_mhz).await;
            index = (index + 1) % plan.len();
            interval.tick().await;
        }
    })
}

fn dedupe_frequencies(frequencies: &[u32]) -> Vec<u32> {
    let mut deduped = Vec::with_capacity(frequencies.len());
    for frequency in frequencies {
        if !deduped.contains(frequency) {
            deduped.push(*frequency);
        }
    }
    deduped
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::observation::ManagementFrameType;
    use crate::spectrum::{SpectrumChannelScore, SpectrumSummary};

    fn summary(scores: Vec<SpectrumChannelScore>) -> SpectrumSummary {
        SpectrumSummary {
            sidekick_id: "sidekick-1".to_string(),
            sdr_id: "hackrf-1".to_string(),
            device_kind: "hackrf".to_string(),
            serial_number: None,
            sweep_id: 1,
            captured_at_unix_nanos: 1,
            start_frequency_hz: 5_000_000_000,
            stop_frequency_hz: 5_900_000_000,
            bin_width_hz: 1_000_000.0,
            sample_count: 1,
            average_power_dbm: -80.0,
            peak_power_dbm: -50.0,
            peak_frequency_hz: 5_180_000_000,
            sweep_rate_hz: Some(8.0),
            channel_scores: scores,
        }
    }

    fn score(
        channel: u16,
        center_frequency_mhz: u16,
        interference_score: u8,
    ) -> SpectrumChannelScore {
        SpectrumChannelScore {
            band: "5GHz".to_string(),
            channel,
            center_frequency_mhz,
            average_power_dbm: -75.0,
            peak_power_dbm: -55.0,
            interference_score,
            sample_count: 10,
        }
    }

    fn observation(frequency_mhz: u32, bssid: &str, rssi_dbm: i16) -> SidekickObservation {
        SidekickObservation {
            sidekick_id: "sidekick-1".to_string(),
            radio_id: "wlan1".to_string(),
            interface_name: "wlan1".to_string(),
            bssid: bssid.to_string(),
            ssid: Some("freeman".to_string()),
            hidden_ssid: false,
            frame_type: ManagementFrameType::Beacon,
            rssi_dbm: Some(rssi_dbm),
            noise_floor_dbm: None,
            snr_db: None,
            frequency_mhz,
            channel: Some(36),
            channel_width_mhz: None,
            captured_at_unix_nanos: 1,
            captured_at_monotonic_nanos: None,
            parser_confidence: 0.9,
        }
    }

    #[test]
    fn adaptive_plan_prioritizes_spectrum_and_confirmed_aps() {
        let state = AdaptiveScanState::default();
        state.observe_spectrum_summary(&summary(vec![score(36, 5_180, 90)]));
        state.observe_rf_observation(&observation(5_180, "aa:bb:cc:dd:ee:01", -60));
        state.observe_rf_observation(&observation(5_180, "aa:bb:cc:dd:ee:02", -66));

        let plan = state.weighted_plan(&[5_180, 5_200, 5_220]);
        let first_5180 = plan
            .iter()
            .position(|frequency| *frequency == 5_180)
            .unwrap();
        let first_5200 = plan
            .iter()
            .position(|frequency| *frequency == 5_200)
            .unwrap();

        assert!(first_5180 < first_5200);
        assert!(plan.iter().filter(|frequency| **frequency == 5_180).count() > 1);
        assert!(plan.contains(&5_220));
    }

    #[test]
    fn adaptive_hop_request_rejects_too_fast_interval() {
        let err =
            build_adaptive_channel_hop_request("wlan1", "5180,5200", 50).expect_err("should fail");

        assert!(err.contains("hop_interval_ms"));
    }
}
