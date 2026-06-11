//! Lightweight per-signal delivery accounting for the zen consumer.
//!
//! zen exposes no metrics endpoint, so these are process-global atomic
//! counters logged periodically (and on change) by a background task. They
//! exist so consumed-and-ACKed drops are visible: for every OTEL signal,
//! `received == forwarded + rejected` (modulo in-flight redeliveries).

use log::info;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use crate::config::MessageFormat;

/// How often the background task emits a counter snapshot (only when the
/// counters changed since the previous emission).
const LOG_INTERVAL: Duration = Duration::from_secs(60);

/// Delivery counters for one input signal.
pub struct SignalCounters {
    name: &'static str,
    /// Messages consumed from JetStream (first delivery only).
    received: AtomicU64,
    /// Messages republished to the result subject (includes passthrough).
    forwarded: AtomicU64,
    /// Messages permanently dropped after exhausting redeliveries.
    rejected: AtomicU64,
    /// Forwarded messages that bypassed the rules engine because no decision
    /// rule existed (see `passthrough_when_unmatched`).
    passthrough: AtomicU64,
}

impl SignalCounters {
    const fn new(name: &'static str) -> Self {
        Self {
            name,
            received: AtomicU64::new(0),
            forwarded: AtomicU64::new(0),
            rejected: AtomicU64::new(0),
            passthrough: AtomicU64::new(0),
        }
    }

    pub fn record_received(&self) {
        self.received.fetch_add(1, Ordering::Relaxed);
    }

    pub fn record_forwarded(&self) {
        self.forwarded.fetch_add(1, Ordering::Relaxed);
    }

    pub fn record_rejected(&self) {
        self.rejected.fetch_add(1, Ordering::Relaxed);
    }

    pub fn record_passthrough(&self) {
        self.passthrough.fetch_add(1, Ordering::Relaxed);
    }

    pub fn snapshot(&self) -> [u64; 4] {
        [
            self.received.load(Ordering::Relaxed),
            self.forwarded.load(Ordering::Relaxed),
            self.rejected.load(Ordering::Relaxed),
            self.passthrough.load(Ordering::Relaxed),
        ]
    }

    fn render(&self, snapshot: &[u64; 4]) -> String {
        format!(
            "{} received={} forwarded={} rejected={} passthrough={}",
            self.name, snapshot[0], snapshot[1], snapshot[2], snapshot[3]
        )
    }
}

/// OTEL log messages (`logs.otel`, protobuf `LogsData`).
pub static OTEL_LOGS: SignalCounters = SignalCounters::new("otel_logs");
/// Raw OTLP metric messages (`otel.metrics.raw`).
pub static OTEL_METRICS: SignalCounters = SignalCounters::new("otel_metrics");

/// Maps a configured message format to the counters tracking that signal.
/// Only the OTEL paths are tracked today.
pub fn counters_for_format(format: &MessageFormat) -> Option<&'static SignalCounters> {
    match format {
        MessageFormat::Protobuf => Some(&OTEL_LOGS),
        MessageFormat::OtelMetrics => Some(&OTEL_METRICS),
        MessageFormat::Json | MessageFormat::FlowProtobuf => None,
    }
}

/// Spawns the periodic counter logger. Logs a snapshot whenever any counter
/// changed since the previous emission.
pub fn spawn_periodic_logger() {
    tokio::spawn(async {
        let mut last: Option<([u64; 4], [u64; 4])> = None;
        loop {
            tokio::time::sleep(LOG_INTERVAL).await;
            let logs = OTEL_LOGS.snapshot();
            let metrics = OTEL_METRICS.snapshot();
            if last != Some((logs, metrics)) {
                info!(
                    "delivery counters: {}; {}",
                    OTEL_LOGS.render(&logs),
                    OTEL_METRICS.render(&metrics)
                );
                last = Some((logs, metrics));
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counters_increment_independently() {
        let counters = SignalCounters::new("test_signal");
        counters.record_received();
        counters.record_received();
        counters.record_forwarded();
        counters.record_rejected();
        counters.record_passthrough();
        assert_eq!(counters.snapshot(), [2, 1, 1, 1]);
        assert_eq!(
            counters.render(&counters.snapshot()),
            "test_signal received=2 forwarded=1 rejected=1 passthrough=1"
        );
    }

    #[test]
    fn format_maps_to_otel_signals_only() {
        assert!(std::ptr::eq(
            counters_for_format(&MessageFormat::Protobuf).unwrap(),
            &OTEL_LOGS
        ));
        assert!(std::ptr::eq(
            counters_for_format(&MessageFormat::OtelMetrics).unwrap(),
            &OTEL_METRICS
        ));
        assert!(counters_for_format(&MessageFormat::Json).is_none());
        assert!(counters_for_format(&MessageFormat::FlowProtobuf).is_none());
    }
}
