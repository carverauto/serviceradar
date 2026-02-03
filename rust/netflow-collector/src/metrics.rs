use crate::listener::Listener;
use log::info;
use std::sync::Arc;
use std::time::Duration;
use tokio::time::interval;

pub struct MetricsReporter;

impl MetricsReporter {
    /// Periodically reports template cache statistics
    ///
    /// This function runs in an infinite loop, logging template cache metrics
    /// every 30 seconds. In the future, these metrics can be exposed via
    /// Prometheus on the metrics endpoint (port 50046).
    ///
    /// # Metrics Tracked
    /// - netflow_v9_template_cache_size: Current number of V9 templates cached
    /// - netflow_v9_template_cache_hits_total: Total cache hits for V9 templates
    /// - netflow_v9_template_cache_misses_total: Total cache misses for V9 templates
    /// - netflow_v9_template_cache_evictions_total: Total evictions from V9 cache
    /// - netflow_ipfix_template_cache_size: Current number of IPFIX templates cached
    /// - netflow_ipfix_template_cache_hits_total: Total cache hits for IPFIX templates
    /// - netflow_ipfix_template_cache_misses_total: Total cache misses for IPFIX templates
    /// - netflow_ipfix_template_cache_evictions_total: Total evictions from IPFIX cache
    pub async fn run(listener: Arc<Listener>) {
        let mut ticker = interval(Duration::from_secs(30));

        loop {
            ticker.tick().await;

            let (v9_stats, ipfix_stats) = listener.get_cache_stats();

            // Log V9 cache stats per source
            for (source, stats) in &v9_stats {
                info!(
                    "V9 Template Cache [{}] - V9: {}/{}, IPFIX: {}/{}, V9 Hits/Misses: {}/{}, IPFIX Hits/Misses: {}/{}",
                    source,
                    stats.v9.current_size,
                    stats.v9.max_size,
                    stats.ipfix.current_size,
                    stats.ipfix.max_size,
                    stats.v9.metrics.hits,
                    stats.v9.metrics.misses,
                    stats.ipfix.metrics.hits,
                    stats.ipfix.metrics.misses
                );
            }

            // Log IPFIX cache stats per source
            for (source, stats) in &ipfix_stats {
                info!(
                    "IPFIX Template Cache [{}] - V9: {}/{}, IPFIX: {}/{}, V9 Hits/Misses: {}/{}, IPFIX Hits/Misses: {}/{}",
                    source,
                    stats.v9.current_size,
                    stats.v9.max_size,
                    stats.ipfix.current_size,
                    stats.ipfix.max_size,
                    stats.v9.metrics.hits,
                    stats.v9.metrics.misses,
                    stats.ipfix.metrics.hits,
                    stats.ipfix.metrics.misses
                );
            }

            if v9_stats.is_empty() && ipfix_stats.is_empty() {
                info!("Template Cache - No sources active yet");
            }

            // Sweep expired pending packets and report stats
            listener.sweep_pending_buffer();
            let (pending_packets, pending_sources) = listener.get_pending_stats();
            if pending_packets > 0 {
                info!(
                    "Pending packet buffer: {} packet(s) across {} source(s)",
                    pending_packets, pending_sources
                );
            }

            // TODO: Expose via Prometheus metrics endpoint on port 50046
            // The current implementation logs metrics, but the structure is ready
            // for Prometheus integration when needed. Example:
            //
            // V9_TEMPLATE_CACHE_SIZE.set(v9_stats.size as i64);
            // V9_TEMPLATE_CACHE_HITS.set(v9_stats.hits as i64);
            // V9_TEMPLATE_CACHE_MISSES.set(v9_stats.misses as i64);
            // V9_TEMPLATE_CACHE_EVICTIONS.set(v9_stats.evictions as i64);
            //
            // IPFIX_TEMPLATE_CACHE_SIZE.set(ipfix_stats.size as i64);
            // IPFIX_TEMPLATE_CACHE_HITS.set(ipfix_stats.hits as i64);
            // IPFIX_TEMPLATE_CACHE_MISSES.set(ipfix_stats.misses as i64);
            // IPFIX_TEMPLATE_CACHE_EVICTIONS.set(ipfix_stats.evictions as i64);
        }
    }
}
