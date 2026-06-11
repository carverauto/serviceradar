/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//! Spool usage monitoring: a 30-second sampler feeds a pure threshold state
//! machine; only **state transitions** (rising past warn/critical,
//! clearing back down with hysteresis) and a slow heartbeat while elevated
//! become OCSF events on the SDK's native-telemetry stream — never
//! per-sample spam.
//!
//! Event shape: OCSF **Event Log Activity** (class_uid 1008, category_uid 1
//! System Activity, activity_id 1 Create) — the same envelope
//! serviceradar-core publishes for its own operational state events
//! (`go/pkg/natsutil/events.go buildOCSFEvent`), so `events.ocsf` ingestion
//! (`db-event-writer parseOCSFEvent`) and the existing event-to-alert rules
//! treat spool pressure like any other platform state event. OCSF has no
//! canonical "resource pressure" class; this choice mirrors the platform's
//! precedent and is documented in `addons/otel-collector/README.md`. The
//! spool usage attributes ride in `unmapped`.

use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use addon_sdk::pb::TelemetryBatch;
use addon_sdk::{
    SignalSchemaRef, TelemetryBatchBuilder, attach_signal_schema_ref, ocsf_event_record,
};
use log::info;
use otel::agent_forward::spool::{EvictionCounters, Spool};
use serde_json::{Value, json};
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use uuid::Uuid;

use crate::addon::ADDON_ID;

/// How often the monitor samples [`Spool::stats`].
pub const SAMPLE_INTERVAL: Duration = Duration::from_secs(30);

/// Heartbeat cadence while the spool stays in an elevated state (5 min).
pub const HEARTBEAT_INTERVAL_SECS: u64 = 5 * 60;

/// Rising thresholds (percent of `max_bytes`) and their clearing
/// counterparts. Each clear threshold sits below its rise threshold
/// (hysteresis) so utilization hovering at a boundary cannot flap events.
pub const WARN_RISE_PCT: f64 = 80.0;
pub const WARN_CLEAR_PCT: f64 = 75.0;
pub const CRITICAL_RISE_PCT: f64 = 95.0;
pub const CRITICAL_CLEAR_PCT: f64 = 90.0;

/// OCSF Event Log Activity envelope constants (see module docs).
const OCSF_CLASS_EVENT_LOG_ACTIVITY: i64 = 1008;
const OCSF_CATEGORY_SYSTEM_ACTIVITY: i64 = 1;
const OCSF_ACTIVITY_CREATE: i64 = 1;
/// Matches `ocsfVersion` in `go/pkg/natsutil/events.go`.
const OCSF_VERSION: &str = "1.7.0";

/// Reported spool pressure state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpoolState {
    Ok,
    Warn,
    Critical,
}

impl SpoolState {
    pub fn as_str(self) -> &'static str {
        match self {
            SpoolState::Ok => "ok",
            SpoolState::Warn => "warn",
            SpoolState::Critical => "critical",
        }
    }

    fn rank(self) -> u8 {
        match self {
            SpoolState::Ok => 0,
            SpoolState::Warn => 1,
            SpoolState::Critical => 2,
        }
    }

    /// OCSF severity: ok→1 Informational, warn→3 Medium, critical→5
    /// Critical (the same mapping core's `severityForState` uses for
    /// healthy/degraded/unhealthy).
    fn severity_id(self) -> i64 {
        match self {
            SpoolState::Ok => 1,
            SpoolState::Warn => 3,
            SpoolState::Critical => 5,
        }
    }

    fn severity_name(self) -> &'static str {
        match self {
            SpoolState::Ok => "Informational",
            SpoolState::Warn => "Medium",
            SpoolState::Critical => "Critical",
        }
    }
}

/// One observation fed to the machine (pure data: testable without clocks).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Sample {
    /// Spool bytes used as a percentage of the configured bound.
    pub utilization_pct: f64,
    /// Whether records were evicted since the previous sample.
    pub eviction_active: bool,
    /// Wall-clock seconds, used only for heartbeat pacing.
    pub now_secs: u64,
}

/// Why an event is being emitted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EmitKind {
    /// The state escalated (ok→warn, warn→critical, ok→critical).
    Rise,
    /// The state de-escalated past the clear threshold.
    Clear,
    /// Still elevated; periodic reminder while in warn/critical.
    Heartbeat,
}

impl EmitKind {
    pub fn as_str(self) -> &'static str {
        match self {
            EmitKind::Rise => "rise",
            EmitKind::Clear => "clear",
            EmitKind::Heartbeat => "heartbeat",
        }
    }
}

/// An emission decision from [`ThresholdMachine::observe`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Emit {
    pub kind: EmitKind,
    pub state: SpoolState,
    pub previous: SpoolState,
}

/// The pure threshold state machine. `observe` returns at most one
/// [`Emit`] per sample; identical consecutive states emit nothing except
/// the slow heartbeat while elevated.
#[derive(Debug)]
pub struct ThresholdMachine {
    state: SpoolState,
    last_emit_secs: Option<u64>,
    heartbeat_secs: u64,
}

impl Default for ThresholdMachine {
    fn default() -> Self {
        Self::with_heartbeat(HEARTBEAT_INTERVAL_SECS)
    }
}

impl ThresholdMachine {
    pub fn with_heartbeat(heartbeat_secs: u64) -> Self {
        Self {
            state: SpoolState::Ok,
            last_emit_secs: None,
            heartbeat_secs,
        }
    }

    pub fn observe(&mut self, sample: Sample) -> Option<Emit> {
        let next = next_state(self.state, &sample);
        if next != self.state {
            let previous = self.state;
            self.state = next;
            self.last_emit_secs = Some(sample.now_secs);
            let kind = if next.rank() > previous.rank() {
                EmitKind::Rise
            } else {
                EmitKind::Clear
            };
            return Some(Emit {
                kind,
                state: next,
                previous,
            });
        }
        if self.state != SpoolState::Ok
            && self
                .last_emit_secs
                .is_none_or(|last| sample.now_secs.saturating_sub(last) >= self.heartbeat_secs)
        {
            self.last_emit_secs = Some(sample.now_secs);
            return Some(Emit {
                kind: EmitKind::Heartbeat,
                state: self.state,
                previous: self.state,
            });
        }
        None
    }
}

/// Pure transition function. Active eviction (records lost since the last
/// sample) is always critical regardless of utilization — eviction below
/// `max_bytes` means the free-disk floor is doing the bounding.
fn next_state(current: SpoolState, sample: &Sample) -> SpoolState {
    let critical = sample.eviction_active || sample.utilization_pct >= CRITICAL_RISE_PCT;
    match current {
        SpoolState::Ok => {
            if critical {
                SpoolState::Critical
            } else if sample.utilization_pct >= WARN_RISE_PCT {
                SpoolState::Warn
            } else {
                SpoolState::Ok
            }
        }
        SpoolState::Warn => {
            if critical {
                SpoolState::Critical
            } else if sample.utilization_pct < WARN_CLEAR_PCT {
                SpoolState::Ok
            } else {
                SpoolState::Warn
            }
        }
        SpoolState::Critical => {
            if critical || sample.utilization_pct >= CRITICAL_CLEAR_PCT {
                SpoolState::Critical
            } else if sample.utilization_pct < WARN_CLEAR_PCT {
                SpoolState::Ok
            } else {
                SpoolState::Warn
            }
        }
    }
}

/// Everything one spool-usage OCSF event reports.
#[derive(Debug, Clone)]
pub struct SpoolUsageSnapshot {
    pub spool_bytes_used: u64,
    pub spool_max_bytes: u64,
    pub utilization_pct: f64,
    /// Available bytes on the spool volume (`null` when unprobeable).
    pub free_disk_bytes: Option<u64>,
    pub min_free_disk_bytes: u64,
    pub evicted: EvictionCounters,
    pub spool_dir: String,
}

/// Builds the OCSF Event Log Activity JSON for one emission (see module
/// docs for the class choice). Spool usage attributes ride in `unmapped`.
pub fn build_spool_usage_event(
    emit: Emit,
    snap: &SpoolUsageSnapshot,
    event_id: &str,
    time_unix_nano: i64,
) -> Value {
    let message = match emit.kind {
        EmitKind::Rise => format!(
            "OTEL edge relay spool {}: utilization {:.1}% ({} of {} bytes){}",
            emit.state.as_str(),
            snap.utilization_pct,
            snap.spool_bytes_used,
            snap.spool_max_bytes,
            if snap.evicted.total() > 0 {
                "; eviction active"
            } else {
                ""
            }
        ),
        EmitKind::Clear => format!(
            "OTEL edge relay spool recovered to {}: utilization {:.1}% ({} of {} bytes)",
            emit.state.as_str(),
            snap.utilization_pct,
            snap.spool_bytes_used,
            snap.spool_max_bytes
        ),
        EmitKind::Heartbeat => format!(
            "OTEL edge relay spool still {}: utilization {:.1}%, {} record(s) evicted since open",
            emit.state.as_str(),
            snap.utilization_pct,
            snap.evicted.total()
        ),
    };

    json!({
        "id": event_id,
        "time": time_unix_nano,
        "class_uid": OCSF_CLASS_EVENT_LOG_ACTIVITY,
        "category_uid": OCSF_CATEGORY_SYSTEM_ACTIVITY,
        "type_uid": OCSF_CLASS_EVENT_LOG_ACTIVITY * 100 + OCSF_ACTIVITY_CREATE,
        "activity_id": OCSF_ACTIVITY_CREATE,
        "activity_name": "Create",
        "severity_id": emit.state.severity_id(),
        "severity": emit.state.severity_name(),
        "status_id": 1,
        "status": "Success",
        "status_code": format!("otel_spool_{}", emit.state.as_str()),
        "message": message,
        "log_name": "otel.spool",
        "log_provider": ADDON_ID,
        "actor": { "app_name": "serviceradar-otel-addon" },
        "device": {},
        "observables": [],
        "metadata": {
            "version": OCSF_VERSION,
            "product": {
                "name": "ServiceRadar OTEL Collector Add-on",
                "vendor_name": "Carver Automation"
            }
        },
        "unmapped": {
            "addon_id": ADDON_ID,
            "event_kind": emit.kind.as_str(),
            "state": emit.state.as_str(),
            "previous_state": emit.previous.as_str(),
            "spool_bytes_used": snap.spool_bytes_used,
            "spool_max_bytes": snap.spool_max_bytes,
            "utilization_pct": (snap.utilization_pct * 10.0).round() / 10.0,
            "free_disk_bytes": snap.free_disk_bytes,
            "min_free_disk_bytes": snap.min_free_disk_bytes,
            "evicted_records": {
                "traces": snap.evicted.traces,
                "logs": snap.evicted.logs,
                "metrics": snap.evicted.metrics,
                "derived_metrics": snap.evicted.derived_metrics,
                "other": snap.evicted.other,
                "total": snap.evicted.total()
            },
            "spool_dir": snap.spool_dir
        }
    })
}

/// Wraps one emission into a `TelemetryBatch` carrying a single
/// `TELEMETRY_PAYLOAD_KIND_OCSF_EVENT` record (the agent attaches its own
/// identity/site context when it forwards native telemetry upstream).
pub fn spool_usage_batch(
    emit: Emit,
    snap: &SpoolUsageSnapshot,
    addon_version: &str,
) -> TelemetryBatch {
    let now_nanos = unix_nanos();
    let event_id = Uuid::new_v4().to_string();
    let event = build_spool_usage_event(emit, snap, &event_id, now_nanos);
    let payload = serde_json::to_vec(&event).unwrap_or_default();
    let record = attach_signal_schema_ref(
        ocsf_event_record(event_id, now_nanos, now_nanos, payload),
        &SignalSchemaRef {
            producer_id: ADDON_ID.to_owned(),
            producer_version: addon_version.to_owned(),
            schema_id: "ocsf.event_log_activity".to_owned(),
            schema_version: "1.0.0".to_owned(),
            signal_type: "event".to_owned(),
            payload_kind: "ocsf_event".to_owned(),
            ..Default::default()
        },
    );
    TelemetryBatchBuilder::new(ADDON_ID, "default")
        .push_record(record)
        .build()
}

/// Spawns the periodic sampler: every [`SAMPLE_INTERVAL`] a [`Sample`] runs
/// through the machine and any emission becomes an OCSF batch on the
/// native-telemetry broadcast. A send with no subscriber drops the batch —
/// native-telemetry:v1 is the lossy path by contract (the durable relay is
/// otlp-relay:v1).
pub fn spawn_spool_monitor(
    spool: Arc<Spool>,
    telemetry_tx: broadcast::Sender<TelemetryBatch>,
    addon_version: &'static str,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut machine = ThresholdMachine::default();
        let mut last_evicted_total = spool.stats().evicted.total();
        let mut ticker = tokio::time::interval(SAMPLE_INTERVAL);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            ticker.tick().await;
            let stats = spool.stats();
            let config = spool.config();
            let evicted_total = stats.evicted.total();
            let eviction_active = evicted_total > last_evicted_total;
            last_evicted_total = evicted_total;
            let utilization_pct = if config.max_bytes > 0 {
                stats.total_bytes as f64 * 100.0 / config.max_bytes as f64
            } else {
                0.0
            };
            let sample = Sample {
                utilization_pct,
                eviction_active,
                now_secs: unix_secs(),
            };
            let Some(emit) = machine.observe(sample) else {
                continue;
            };
            let snap = SpoolUsageSnapshot {
                spool_bytes_used: stats.total_bytes,
                spool_max_bytes: config.max_bytes,
                utilization_pct,
                free_disk_bytes: spool.disk_free_bytes(),
                min_free_disk_bytes: config.min_free_disk_bytes,
                evicted: stats.evicted,
                spool_dir: config.dir.display().to_string(),
            };
            info!(
                "spool usage {}: state={} utilization={:.1}% evicted={}",
                emit.kind.as_str(),
                emit.state.as_str(),
                utilization_pct,
                evicted_total
            );
            let _ = telemetry_tx.send(spool_usage_batch(emit, &snap, addon_version));
        }
    })
}

fn unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn unix_nanos() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_nanos()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(pct: f64, eviction: bool, now: u64) -> Sample {
        Sample {
            utilization_pct: pct,
            eviction_active: eviction,
            now_secs: now,
        }
    }

    #[test]
    fn rises_once_past_warn_threshold_without_per_sample_spam() {
        let mut machine = ThresholdMachine::default();
        assert_eq!(machine.observe(sample(50.0, false, 0)), None);
        let emit = machine.observe(sample(81.0, false, 30)).expect("rise");
        assert_eq!(emit.kind, EmitKind::Rise);
        assert_eq!(emit.state, SpoolState::Warn);
        assert_eq!(emit.previous, SpoolState::Ok);
        // Staying warm emits nothing (heartbeat not yet due).
        assert_eq!(machine.observe(sample(83.0, false, 60)), None);
        assert_eq!(machine.observe(sample(88.0, false, 90)), None);
    }

    #[test]
    fn warn_clears_with_hysteresis() {
        let mut machine = ThresholdMachine::default();
        machine.observe(sample(85.0, false, 0)).expect("rise");
        // 78% is below the 80% rise threshold but above the 75% clear
        // threshold: still warn, no flapping.
        assert_eq!(machine.observe(sample(78.0, false, 30)), None);
        let emit = machine.observe(sample(74.0, false, 60)).expect("clear");
        assert_eq!(emit.kind, EmitKind::Clear);
        assert_eq!(emit.state, SpoolState::Ok);
        assert_eq!(emit.previous, SpoolState::Warn);
    }

    #[test]
    fn critical_rises_at_95_and_steps_down_through_warn() {
        let mut machine = ThresholdMachine::default();
        let emit = machine.observe(sample(96.0, false, 0)).expect("rise");
        assert_eq!(emit.kind, EmitKind::Rise);
        assert_eq!(emit.state, SpoolState::Critical);
        assert_eq!(emit.previous, SpoolState::Ok);
        // 92% is below 95 but above the 90% clear threshold: still critical.
        assert_eq!(machine.observe(sample(92.0, false, 30)), None);
        let emit = machine.observe(sample(89.0, false, 60)).expect("clear");
        assert_eq!(emit.kind, EmitKind::Clear);
        assert_eq!(emit.state, SpoolState::Warn);
        let emit = machine.observe(sample(60.0, false, 90)).expect("clear");
        assert_eq!(emit.kind, EmitKind::Clear);
        assert_eq!(emit.state, SpoolState::Ok);
    }

    #[test]
    fn critical_clears_straight_to_ok_when_pressure_vanishes() {
        let mut machine = ThresholdMachine::default();
        machine.observe(sample(99.0, false, 0)).expect("rise");
        let emit = machine.observe(sample(10.0, false, 30)).expect("clear");
        assert_eq!(emit.state, SpoolState::Ok);
        assert_eq!(emit.previous, SpoolState::Critical);
    }

    #[test]
    fn active_eviction_is_critical_even_at_low_utilization() {
        // Eviction below max_bytes means the free-disk floor is bounding:
        // utilization alone must not mask data loss.
        let mut machine = ThresholdMachine::default();
        let emit = machine.observe(sample(40.0, true, 0)).expect("rise");
        assert_eq!(emit.kind, EmitKind::Rise);
        assert_eq!(emit.state, SpoolState::Critical);
        // Eviction continuing keeps it critical without re-emitting.
        assert_eq!(machine.observe(sample(40.0, true, 30)), None);
        // Eviction stopping at low utilization clears.
        let emit = machine.observe(sample(40.0, false, 60)).expect("clear");
        assert_eq!(emit.kind, EmitKind::Clear);
        assert_eq!(emit.state, SpoolState::Ok);
    }

    #[test]
    fn heartbeat_fires_only_while_elevated_and_only_when_due() {
        let mut machine = ThresholdMachine::with_heartbeat(300);
        machine.observe(sample(85.0, false, 1_000)).expect("rise");
        assert_eq!(machine.observe(sample(85.0, false, 1_299)), None);
        let emit = machine
            .observe(sample(85.0, false, 1_301))
            .expect("heartbeat");
        assert_eq!(emit.kind, EmitKind::Heartbeat);
        assert_eq!(emit.state, SpoolState::Warn);
        // The heartbeat resets the timer.
        assert_eq!(machine.observe(sample(85.0, false, 1_400)), None);
        let emit = machine
            .observe(sample(85.0, false, 1_602))
            .expect("second heartbeat");
        assert_eq!(emit.kind, EmitKind::Heartbeat);

        // Never a heartbeat in the ok state.
        machine.observe(sample(10.0, false, 1_700)).expect("clear");
        assert_eq!(machine.observe(sample(10.0, false, 9_999)), None);
    }

    #[test]
    fn ocsf_event_payload_carries_required_fields_and_usage_attributes() {
        let snap = SpoolUsageSnapshot {
            spool_bytes_used: 220 * 1024 * 1024,
            spool_max_bytes: 256 * 1024 * 1024,
            utilization_pct: 85.94,
            free_disk_bytes: Some(700 * 1024 * 1024),
            min_free_disk_bytes: 512 * 1024 * 1024,
            evicted: EvictionCounters {
                traces: 3,
                logs: 2,
                metrics: 1,
                derived_metrics: 0,
                other: 0,
            },
            spool_dir: "/var/lib/serviceradar/otel-spool".to_string(),
        };
        let emit = Emit {
            kind: EmitKind::Rise,
            state: SpoolState::Warn,
            previous: SpoolState::Ok,
        };
        let event = build_spool_usage_event(emit, &snap, "evt-1", 1_750_000_000_000_000_000);

        // The five fields db-event-writer's parseOCSFEvent requires non-zero.
        assert_eq!(event["id"], "evt-1");
        assert_eq!(event["class_uid"], 1008);
        assert_eq!(event["category_uid"], 1);
        assert_eq!(event["type_uid"], 100801);
        assert_eq!(event["activity_id"], 1);

        assert_eq!(event["severity_id"], 3);
        assert_eq!(event["severity"], "Medium");
        assert_eq!(event["status_code"], "otel_spool_warn");
        assert_eq!(event["log_name"], "otel.spool");
        assert_eq!(event["log_provider"], "otel-collector");
        assert_eq!(event["time"], 1_750_000_000_000_000_000i64);
        assert!(event["message"].as_str().unwrap().contains("85.9%"));

        let unmapped = &event["unmapped"];
        assert_eq!(unmapped["addon_id"], "otel-collector");
        assert_eq!(unmapped["event_kind"], "rise");
        assert_eq!(unmapped["state"], "warn");
        assert_eq!(unmapped["previous_state"], "ok");
        assert_eq!(unmapped["spool_bytes_used"], 220 * 1024 * 1024);
        assert_eq!(unmapped["spool_max_bytes"], 256 * 1024 * 1024);
        assert_eq!(unmapped["utilization_pct"], 85.9);
        assert_eq!(unmapped["free_disk_bytes"], 700 * 1024 * 1024);
        assert_eq!(unmapped["min_free_disk_bytes"], 512 * 1024 * 1024);
        assert_eq!(unmapped["evicted_records"]["traces"], 3);
        assert_eq!(unmapped["evicted_records"]["logs"], 2);
        assert_eq!(unmapped["evicted_records"]["metrics"], 1);
        assert_eq!(unmapped["evicted_records"]["derived_metrics"], 0);
        assert_eq!(unmapped["evicted_records"]["total"], 6);
        assert_eq!(unmapped["spool_dir"], "/var/lib/serviceradar/otel-spool");
    }

    #[test]
    fn free_disk_bytes_serializes_null_when_unprobeable() {
        let snap = SpoolUsageSnapshot {
            spool_bytes_used: 0,
            spool_max_bytes: 1,
            utilization_pct: 0.0,
            free_disk_bytes: None,
            min_free_disk_bytes: 0,
            evicted: EvictionCounters::default(),
            spool_dir: String::new(),
        };
        let emit = Emit {
            kind: EmitKind::Clear,
            state: SpoolState::Ok,
            previous: SpoolState::Warn,
        };
        let event = build_spool_usage_event(emit, &snap, "evt-2", 1);
        assert!(event["unmapped"]["free_disk_bytes"].is_null());
        assert_eq!(event["severity_id"], 1);
    }

    #[test]
    fn spool_usage_batch_is_an_ocsf_event_record_from_this_addon() {
        let snap = SpoolUsageSnapshot {
            spool_bytes_used: 10,
            spool_max_bytes: 100,
            utilization_pct: 10.0,
            free_disk_bytes: Some(1_000),
            min_free_disk_bytes: 500,
            evicted: EvictionCounters::default(),
            spool_dir: "/tmp/spool".to_string(),
        };
        let emit = Emit {
            kind: EmitKind::Heartbeat,
            state: SpoolState::Critical,
            previous: SpoolState::Critical,
        };
        let batch = spool_usage_batch(emit, &snap, "9.9.9");

        let source = batch.source.expect("source set");
        assert_eq!(source.source_type, ADDON_ID);
        assert_eq!(batch.records.len(), 1);
        let record = &batch.records[0];
        assert_eq!(
            record.payload_kind,
            addon_sdk::pb::TelemetryPayloadKind::OcsfEvent as i32
        );
        assert!(!record.event_id.is_empty());
        assert!(record.event_time_unix_nano > 0);

        let event: Value = serde_json::from_slice(&record.payload).unwrap();
        assert_eq!(event["id"], record.event_id.as_str());
        assert_eq!(event["class_uid"], 1008);
        assert_eq!(event["unmapped"]["event_kind"], "heartbeat");
        assert_eq!(event["unmapped"]["state"], "critical");

        // Schema metadata mirrors the other OCSF-producing add-ons.
        assert_eq!(
            record
                .metadata
                .get(addon_sdk::SIGNAL_SCHEMA_METADATA_PRODUCER_ID)
                .map(String::as_str),
            Some("otel-collector")
        );
        assert_eq!(
            record
                .metadata
                .get(addon_sdk::SIGNAL_SCHEMA_METADATA_PAYLOAD_KIND)
                .map(String::as_str),
            Some("ocsf_event")
        );
    }
}
