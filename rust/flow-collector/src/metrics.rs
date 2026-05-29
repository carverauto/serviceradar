use log::info;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::time::interval;

pub struct ListenerMetrics {
    pub protocol: &'static str,
    pub listen_addr: String,
    pub packets_received: AtomicU64,
    pub flows_converted: AtomicU64,
    pub flows_dropped: AtomicU64,
    pub parse_errors: AtomicU64,
}

impl ListenerMetrics {
    pub fn new(protocol: &'static str, listen_addr: String) -> Self {
        Self {
            protocol,
            listen_addr,
            packets_received: AtomicU64::new(0),
            flows_converted: AtomicU64::new(0),
            flows_dropped: AtomicU64::new(0),
            parse_errors: AtomicU64::new(0),
        }
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
    ) {
        let mut ticker = interval(Duration::from_secs(30));

        loop {
            ticker.tick().await;

            for metrics in &listeners {
                let packets = metrics.packets_received.load(Ordering::Relaxed);
                let flows = metrics.flows_converted.load(Ordering::Relaxed);
                let dropped = metrics.flows_dropped.load(Ordering::Relaxed);
                let errors = metrics.parse_errors.load(Ordering::Relaxed);

                info!(
                    "[{}@{}] packets_received: {}, flows_converted: {}, flows_dropped: {}, parse_errors: {}",
                    metrics.protocol, metrics.listen_addr, packets, flows, dropped, errors
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
}
