use crate::listener::Listener;
use log::info;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;
use tokio::time::interval;

pub struct MetricsReporter;

impl MetricsReporter {
    pub async fn run(listener: Arc<Listener>) {
        let mut ticker = interval(Duration::from_secs(30));

        loop {
            ticker.tick().await;

            let packets = listener.packets_received.load(Ordering::Relaxed);
            let flows = listener.flows_converted.load(Ordering::Relaxed);
            let dropped = listener.flows_dropped.load(Ordering::Relaxed);
            let errors = listener.parse_errors.load(Ordering::Relaxed);

            info!(
                "sFlow Metrics - packets_received: {}, flows_converted: {}, flows_dropped: {}, parse_errors: {}",
                packets, flows, dropped, errors
            );
        }
    }
}
