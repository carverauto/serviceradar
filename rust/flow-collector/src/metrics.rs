use log::info;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::RwLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::time::interval;

pub struct ListenerMetrics {
    pub protocol: &'static str,
    pub listen_addr: String,
    pub packets_received: AtomicU64,
    pub flows_converted: AtomicU64,
    /// Total flows discarded *before* the publisher channel (currently only
    /// degenerate flows with 0 bytes and 0 packets).
    pub flows_dropped: AtomicU64,
    /// Flows rejected by `mpsc::try_send` because the per-listener publisher
    /// channel was at capacity. Tracked separately from `flows_dropped` so
    /// operators can tell parser-side filtering from backpressure overflow.
    pub channel_full_drops: AtomicU64,
    pub parse_errors: AtomicU64,
    /// Datagrams that could not be recognised as this protocol at all (wrong
    /// version, too short to scope). A UDP listener on a well-known port
    /// receives arbitrary internet noise -- a stray DNS reply, a port scan --
    /// so this is expected traffic, not a fault, and is counted apart from
    /// `parse_errors` so one stray packet cannot make a healthy listener look
    /// permanently broken.
    pub undecodable_datagrams: AtomicU64,
}

impl ListenerMetrics {
    pub fn new(protocol: &'static str, listen_addr: String) -> Self {
        Self {
            protocol,
            listen_addr,
            packets_received: AtomicU64::new(0),
            flows_converted: AtomicU64::new(0),
            flows_dropped: AtomicU64::new(0),
            channel_full_drops: AtomicU64::new(0),
            parse_errors: AtomicU64::new(0),
            undecodable_datagrams: AtomicU64::new(0),
        }
    }
}

/// Per-subject drop counter. Records how many messages destined for a given
/// NATS subject were rejected because the per-listener publisher channel was
/// full. Operators consult this to identify which listener/subject combo is
/// overflowing.
///
/// This is intentionally a separate registry from `HostSliceMetricsRegistry`
/// because we want to track drops on *any* subject (the raw protocol subject
/// as well as host-slice fan-out subjects), not just the host-slice subset
/// that has a pre-allocated `HostSliceMetrics`.
#[derive(Default)]
pub struct SubjectDropRegistry {
    counters: RwLock<HashMap<String, Arc<AtomicU64>>>,
}

impl SubjectDropRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Increment the drop counter for `subject`, creating it if it does not
    /// yet exist. Returns the new value.
    pub fn record_drop(&self, subject: &str) -> u64 {
        // Fast path: subject already known.
        if let Some(counter) = self
            .counters
            .read()
            .expect("subject drop lock poisoned")
            .get(subject)
        {
            return counter.fetch_add(1, Ordering::Relaxed) + 1;
        }

        // Slow path: insert a new counter under the write lock.
        let mut guard = self.counters.write().expect("subject drop lock poisoned");
        let counter = guard
            .entry(subject.to_string())
            .or_insert_with(|| Arc::new(AtomicU64::new(0)))
            .clone();
        drop(guard);
        counter.fetch_add(1, Ordering::Relaxed) + 1
    }

    /// Returns a sorted snapshot of `(subject, total_drops)` pairs.
    pub fn snapshot(&self) -> Vec<(String, u64)> {
        let guard = self.counters.read().expect("subject drop lock poisoned");
        let mut entries: Vec<(String, u64)> = guard
            .iter()
            .map(|(subject, counter)| (subject.clone(), counter.load(Ordering::Relaxed)))
            .collect();
        drop(guard);
        entries.sort_by(|left, right| left.0.cmp(&right.0));
        entries
    }
}

pub struct HostSliceMetrics {
    pub agent_id: String,
    pub subject: String,
    pub records_published: AtomicU64,
    pub bytes_published: AtomicU64,
    pub subscribers_active: AtomicU64,
}

impl HostSliceMetrics {
    pub fn new(agent_id: String, subject: String, subscribers_active: u64) -> Self {
        Self {
            agent_id,
            subject,
            records_published: AtomicU64::new(0),
            bytes_published: AtomicU64::new(0),
            subscribers_active: AtomicU64::new(subscribers_active),
        }
    }

    pub fn record_published(&self, bytes: usize) {
        self.records_published.fetch_add(1, Ordering::Relaxed);
        self.bytes_published
            .fetch_add(bytes as u64, Ordering::Relaxed);
    }
}

#[derive(Default)]
pub struct HostSliceMetricsRegistry {
    by_subject: HashMap<String, Arc<HostSliceMetrics>>,
}

impl HostSliceMetricsRegistry {
    pub fn new(slices: Vec<(String, String)>) -> Self {
        let by_subject = slices
            .into_iter()
            .map(|(agent_id, subject)| {
                (
                    subject.clone(),
                    Arc::new(HostSliceMetrics::new(agent_id, subject, 1)),
                )
            })
            .collect();

        Self { by_subject }
    }

    pub fn record_publish(&self, subject: &str, bytes: usize) {
        if let Some(metrics) = self.by_subject.get(subject) {
            metrics.record_published(bytes);
        }
    }

    pub fn all(&self) -> Vec<Arc<HostSliceMetrics>> {
        let mut metrics: Vec<_> = self.by_subject.values().cloned().collect();
        metrics.sort_by(|left, right| left.subject.cmp(&right.subject));
        metrics
    }
}

pub struct MetricsReporter;

impl MetricsReporter {
    pub async fn run(
        listeners: Vec<Arc<ListenerMetrics>>,
        host_slices: Arc<HostSliceMetricsRegistry>,
        subject_drops: Arc<SubjectDropRegistry>,
    ) {
        let mut ticker = interval(Duration::from_secs(30));

        loop {
            ticker.tick().await;

            for metrics in &listeners {
                let packets = metrics.packets_received.load(Ordering::Relaxed);
                let flows = metrics.flows_converted.load(Ordering::Relaxed);
                let dropped = metrics.flows_dropped.load(Ordering::Relaxed);
                let channel_full = metrics.channel_full_drops.load(Ordering::Relaxed);
                let errors = metrics.parse_errors.load(Ordering::Relaxed);
                let undecodable = metrics.undecodable_datagrams.load(Ordering::Relaxed);

                info!(
                    "[{}@{}] packets_received: {}, flows_converted: {}, flows_dropped: {}, channel_full_drops: {}, parse_errors: {}, undecodable_datagrams: {}",
                    metrics.protocol,
                    metrics.listen_addr,
                    packets,
                    flows,
                    dropped,
                    channel_full,
                    errors,
                    undecodable
                );
            }

            for metrics in host_slices.all() {
                let records = metrics.records_published.load(Ordering::Relaxed);
                let bytes = metrics.bytes_published.load(Ordering::Relaxed);
                let subscribers = metrics.subscribers_active.load(Ordering::Relaxed);

                info!(
                    "[host-slice:{}@{}] records_published_total: {}, bytes_published_total: {}, subscribers_active: {}",
                    metrics.agent_id, metrics.subject, records, bytes, subscribers
                );
            }

            for (subject, drops) in subject_drops.snapshot() {
                if drops > 0 {
                    info!(
                        "[subject-drop:{}] channel_full_drops_total: {}",
                        subject, drops
                    );
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_slice_registry_records_published_bytes_by_subject() {
        let registry = HostSliceMetricsRegistry::new(vec![(
            "agent-1".to_string(),
            "flow.host-slice.agent-1".to_string(),
        )]);

        registry.record_publish("flow.host-slice.agent-1", 128);
        registry.record_publish("flows.raw.netflow", 1024);

        let metrics = registry.all();

        assert_eq!(metrics.len(), 1);
        assert_eq!(metrics[0].agent_id, "agent-1");
        assert_eq!(metrics[0].records_published.load(Ordering::Relaxed), 1);
        assert_eq!(metrics[0].bytes_published.load(Ordering::Relaxed), 128);
        assert_eq!(metrics[0].subscribers_active.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn subject_drop_registry_accumulates_per_subject() {
        let registry = SubjectDropRegistry::new();

        assert_eq!(registry.record_drop("flows.raw.sflow"), 1);
        assert_eq!(registry.record_drop("flows.raw.sflow"), 2);
        assert_eq!(registry.record_drop("flow.host-slice.agent-1"), 1);

        let snapshot = registry.snapshot();
        assert_eq!(
            snapshot,
            vec![
                ("flow.host-slice.agent-1".to_string(), 1),
                ("flows.raw.sflow".to_string(), 2),
            ]
        );
    }

    #[test]
    fn subject_drop_registry_snapshot_empty_when_no_drops() {
        let registry = SubjectDropRegistry::new();
        assert!(registry.snapshot().is_empty());
    }
}
