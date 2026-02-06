use crate::dedup::DedupCache;
use log::info;
use std::sync::Arc;
use std::time::Duration;
use tokio::time::interval;

pub struct MetricsReporter;

impl MetricsReporter {
    /// Periodically reports dedup cache statistics and runs cleanup.
    pub async fn run(dedup: Arc<DedupCache>, cleanup_interval_secs: u64) {
        let mut ticker = interval(Duration::from_secs(cleanup_interval_secs));

        loop {
            ticker.tick().await;

            let removed = dedup.cleanup();
            let remaining = dedup.len();

            info!(
                "mDNS Dedup Cache - entries: {}, expired removed: {}",
                remaining, removed
            );
        }
    }
}
