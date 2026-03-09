use log::info;
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

pub struct MetricsReporter;

impl MetricsReporter {
    pub async fn run(listeners: Vec<Arc<ListenerMetrics>>) {
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
        }
    }
}
