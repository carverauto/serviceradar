use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr},
    sync::Arc,
    time::Instant,
};

use anyhow::{Context, Result};
use prometheus::{
    Encoder, IntCounter, IntCounterVec, IntGauge, IntGaugeVec, Opts, Registry, TextEncoder,
};
use tokio::{io::AsyncWriteExt, net::TcpListener, sync::watch};

#[derive(Clone)]
pub struct Metrics {
    registry: Registry,
    packets_processed_total: IntCounter,
    packets_dropped_total: IntCounter,
    events_emitted_total: IntCounterVec,
    events_dropped_total: IntCounterVec,
    signature_failures_total: IntCounter,
    p0f_vs_muonfp_disagreement_total: IntCounter,
    encode_buffer_reuses_total: IntCounter,
    external_flow_unmatched_total: IntCounter,
    external_flow_invalid_total: IntCounter,
    external_flow_matched_total: IntCounter,
    attribution_backend_events_total: IntCounterVec,
    attribution_records_total: IntCounterVec,
    attribution_stage_total: IntCounterVec,
    attribution_cache_entries: IntGaugeVec,
    #[allow(dead_code)]
    sampling_budget: IntGauge,
    uptime_seconds: IntGauge,
    started_at: Arc<Instant>,
}

impl Metrics {
    pub fn new() -> Result<Self> {
        let registry = Registry::new();
        let packets_processed_total = IntCounter::with_opts(Opts::new(
            "netprobe_packets_processed_total",
            "Packets processed",
        ))?;
        let packets_dropped_total = IntCounter::with_opts(Opts::new(
            "netprobe_packets_dropped_total",
            "Packets dropped",
        ))?;
        let events_emitted_total = IntCounterVec::new(
            Opts::new("netprobe_events_emitted_total", "Events emitted"),
            &["stream"],
        )?;
        let events_dropped_total = IntCounterVec::new(
            Opts::new("netprobe_events_dropped_total", "Events dropped"),
            &["stream", "reason"],
        )?;
        let signature_failures_total = IntCounter::with_opts(Opts::new(
            "netprobe_signature_failures_total",
            "Signature failures",
        ))?;
        let p0f_vs_muonfp_disagreement_total = IntCounter::with_opts(Opts::new(
            "p0f_vs_muonfp_disagreement_total",
            "TCP-axis OS family disagreements between p0f and MuonFP",
        ))?;
        let encode_buffer_reuses_total = IntCounter::with_opts(Opts::new(
            "serviceradar_netprobe_encode_buffer_reuses_total",
            "IPC protobuf encode buffer reuses after warmup",
        ))?;
        let external_flow_unmatched_total = IntCounter::with_opts(Opts::new(
            "serviceradar_netprobe_external_flow_unmatched_total",
            "External flow records dropped because no local process attribution matched",
        ))?;
        let external_flow_invalid_total = IntCounter::with_opts(Opts::new(
            "serviceradar_netprobe_external_flow_invalid_total",
            "External flow records dropped because their 5-tuple was invalid",
        ))?;
        let external_flow_matched_total = IntCounter::with_opts(Opts::new(
            "serviceradar_netprobe_external_flow_matched_total",
            "External flow records that produced a FlowAttributionEvent",
        ))?;
        let attribution_backend_events_total = IntCounterVec::new(
            Opts::new(
                "serviceradar_netprobe_attribution_backend_events_total",
                "Attribution backend outcomes by backend and outcome",
            ),
            &["backend", "outcome"],
        )?;
        let attribution_records_total = IntCounterVec::new(
            Opts::new(
                "serviceradar_netprobe_attribution_records_total",
                "Flow attribution ring records processed by event kind, protocol, outcome, and service coalescing state",
            ),
            &["event_kind", "protocol", "outcome", "service_coalesced"],
        )?;
        let attribution_stage_total = IntCounterVec::new(
            Opts::new(
                "serviceradar_netprobe_attribution_stage_total",
                "Flow attribution readiness and handoff outcomes by bounded pipeline stage and protocol",
            ),
            &["stage", "protocol", "outcome"],
        )?;
        let attribution_cache_entries = IntGaugeVec::new(
            Opts::new(
                "serviceradar_netprobe_attribution_cache_entries",
                "Attribution cache entry counts by cache name",
            ),
            &["cache"],
        )?;
        let sampling_budget = IntGauge::with_opts(Opts::new(
            "serviceradar_netprobe_sampling_budget",
            "Current AF_XDP per-flow packet redirect budget",
        ))?;
        let uptime_seconds = IntGauge::with_opts(Opts::new(
            "netprobe_uptime_seconds",
            "Process uptime in seconds",
        ))?;

        registry.register(Box::new(packets_processed_total.clone()))?;
        registry.register(Box::new(packets_dropped_total.clone()))?;
        registry.register(Box::new(events_emitted_total.clone()))?;
        registry.register(Box::new(events_dropped_total.clone()))?;
        registry.register(Box::new(signature_failures_total.clone()))?;
        registry.register(Box::new(p0f_vs_muonfp_disagreement_total.clone()))?;
        registry.register(Box::new(encode_buffer_reuses_total.clone()))?;
        registry.register(Box::new(external_flow_unmatched_total.clone()))?;
        registry.register(Box::new(external_flow_invalid_total.clone()))?;
        registry.register(Box::new(external_flow_matched_total.clone()))?;
        registry.register(Box::new(attribution_backend_events_total.clone()))?;
        registry.register(Box::new(attribution_records_total.clone()))?;
        registry.register(Box::new(attribution_stage_total.clone()))?;
        registry.register(Box::new(attribution_cache_entries.clone()))?;
        registry.register(Box::new(sampling_budget.clone()))?;
        registry.register(Box::new(uptime_seconds.clone()))?;

        Ok(Self {
            registry,
            packets_processed_total,
            packets_dropped_total,
            events_emitted_total,
            events_dropped_total,
            signature_failures_total,
            p0f_vs_muonfp_disagreement_total,
            encode_buffer_reuses_total,
            external_flow_unmatched_total,
            external_flow_invalid_total,
            external_flow_matched_total,
            attribution_backend_events_total,
            attribution_records_total,
            attribution_stage_total,
            attribution_cache_entries,
            sampling_budget,
            uptime_seconds,
            started_at: Arc::new(Instant::now()),
        })
    }

    pub fn registry(&self) -> &Registry {
        &self.registry
    }

    pub fn refresh_uptime(&self) {
        self.uptime_seconds
            .set(self.started_at.elapsed().as_secs() as i64);
    }

    #[allow(dead_code)]
    pub fn inc_fingerprint_events(&self) {
        self.events_emitted_total
            .with_label_values(&["fingerprint"])
            .inc();
    }

    #[allow(dead_code)]
    pub fn inc_dpi_events(&self) {
        self.events_emitted_total.with_label_values(&["dpi"]).inc();
    }

    #[allow(dead_code)]
    pub fn inc_flow_attribution_events(&self) {
        self.events_emitted_total
            .with_label_values(&["flow_attribution"])
            .inc();
    }

    #[allow(dead_code)]
    pub fn inc_process_snapshot_events(&self) {
        self.events_emitted_total
            .with_label_values(&["process_snapshot"])
            .inc();
    }

    #[allow(dead_code)]
    pub fn inc_fingerprint_events_dropped(&self, reason: &str, count: u64) {
        self.events_dropped_total
            .with_label_values(&["fingerprint", reason])
            .inc_by(count);
    }

    pub fn inc_dpi_events_dropped(&self, reason: &str, count: u64) {
        self.events_dropped_total
            .with_label_values(&["dpi", reason])
            .inc_by(count);
    }

    #[allow(dead_code)]
    pub fn inc_flow_attribution_events_dropped(&self, reason: &str, count: u64) {
        self.events_dropped_total
            .with_label_values(&["flow_attribution", reason])
            .inc_by(count);
    }

    pub fn inc_device_census_snapshot_events(&self) {
        self.events_emitted_total
            .with_label_values(&["device_census_snapshot"])
            .inc();
    }

    pub fn inc_device_census_snapshot_events_dropped(&self, reason: &str, count: u64) {
        self.events_dropped_total
            .with_label_values(&["device_census_snapshot", reason])
            .inc_by(count);
    }

    #[allow(dead_code)]
    pub fn inc_process_snapshot_events_dropped(&self, reason: &str, count: u64) {
        self.events_dropped_total
            .with_label_values(&["process_snapshot", reason])
            .inc_by(count);
    }

    #[allow(dead_code)]
    pub fn inc_packets_processed(&self) {
        self.packets_processed_total.inc();
    }

    #[allow(dead_code)]
    pub fn inc_packets_dropped(&self) {
        self.packets_dropped_total.inc();
    }

    #[allow(dead_code)]
    pub fn inc_signature_failures(&self) {
        self.signature_failures_total.inc();
    }

    #[allow(dead_code)]
    pub fn inc_p0f_vs_muonfp_disagreement(&self) {
        self.p0f_vs_muonfp_disagreement_total.inc();
    }

    pub fn inc_encode_buffer_reuses(&self) {
        self.encode_buffer_reuses_total.inc();
    }

    pub fn inc_external_flow_unmatched(&self) {
        self.external_flow_unmatched_total.inc();
    }

    pub fn inc_external_flow_invalid(&self) {
        self.external_flow_invalid_total.inc();
    }

    pub fn inc_external_flow_matched(&self) {
        self.external_flow_matched_total.inc();
    }

    #[allow(dead_code)]
    pub fn inc_attribution_backend_events(&self, backend: &str, outcome: &str, count: u64) {
        self.attribution_backend_events_total
            .with_label_values(&[backend, outcome])
            .inc_by(count);
    }

    #[allow(dead_code)]
    pub fn inc_attribution_records(
        &self,
        event_kind: &str,
        protocol: &str,
        outcome: &str,
        service_coalesced: bool,
        count: u64,
    ) {
        self.attribution_records_total
            .with_label_values(&[
                event_kind,
                protocol,
                outcome,
                if service_coalesced { "true" } else { "false" },
            ])
            .inc_by(count);
    }

    #[allow(dead_code)]
    pub fn inc_attribution_stage(&self, stage: &str, protocol: &str, outcome: &str) {
        self.attribution_stage_total
            .with_label_values(&[stage, protocol, outcome])
            .inc();
    }

    #[allow(dead_code)]
    pub fn set_attribution_cache_entries(&self, cache: &str, entries: usize) {
        self.attribution_cache_entries
            .with_label_values(&[cache])
            .set(entries as i64);
    }

    #[allow(dead_code)]
    pub fn set_sampling_budget(&self, budget: u32) {
        self.sampling_budget.set(i64::from(budget));
    }
}

pub async fn serve_metrics(
    port: u16,
    metrics: Metrics,
    mut shutdown: watch::Receiver<bool>,
) -> Result<()> {
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port);
    let listener = TcpListener::bind(addr)
        .await
        .with_context(|| format!("failed to bind metrics endpoint on {addr}"))?;

    loop {
        tokio::select! {
            _ = shutdown.changed() => {
                if *shutdown.borrow() {
                    return Ok(());
                }
            }
            accepted = listener.accept() => {
                let (mut stream, _) = accepted?;
                let metrics = metrics.clone();
                tokio::spawn(async move {
                    metrics.refresh_uptime();
                    let encoder = TextEncoder::new();
                    let metric_families = metrics.registry().gather();
                    let mut body = Vec::new();
                    if encoder.encode(&metric_families, &mut body).is_err() {
                        body = b"metrics encode error\n".to_vec();
                    }
                    let headers = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        encoder.format_type(),
                        body.len()
                    );
                    let _ = stream.write_all(headers.as_bytes()).await;
                    let _ = stream.write_all(&body).await;
                    let _ = stream.shutdown().await;
                });
            }
        }
    }
}
