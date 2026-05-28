use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use tokio::{
    net::{UnixListener, UnixStream},
    sync::{broadcast, watch},
};

use crate::{
    capabilities,
    fingerprint::{
        FINGERPRINT_ENGINE_VERSION, JA4_BASE_SPEC_REVISION, P0F_CORPUS_REVISION,
        SERVICERADAR_ADDITIONS_REVISION,
    },
    framing::{read_frame, write_frame},
    metrics::Metrics,
    proto::netprobe::{
        netprobe_frame, ConfigAck, DpiEvent, ErrorFrame, FingerprintEvent, FlowAttributionEvent,
        NetprobeFrame, PingAck, ProcessSnapshot,
    },
    runtime_config::RuntimeConfig,
};

pub struct IpcServer {
    socket_path: PathBuf,
    active_client: Arc<AtomicBool>,
    fingerprint_events: broadcast::Sender<FingerprintEvent>,
    dpi_events: broadcast::Sender<DpiEvent>,
    flow_attribution_events: broadcast::Sender<FlowAttributionEvent>,
    process_snapshots: broadcast::Sender<ProcessSnapshot>,
    runtime_config: RuntimeConfig,
    metrics: Metrics,
}

impl IpcServer {
    pub fn new(
        socket_path: impl Into<PathBuf>,
        fingerprint_events: broadcast::Sender<FingerprintEvent>,
        dpi_events: broadcast::Sender<DpiEvent>,
        flow_attribution_events: broadcast::Sender<FlowAttributionEvent>,
        process_snapshots: broadcast::Sender<ProcessSnapshot>,
        runtime_config: RuntimeConfig,
        metrics: Metrics,
    ) -> Self {
        Self {
            socket_path: socket_path.into(),
            active_client: Arc::new(AtomicBool::new(false)),
            fingerprint_events,
            dpi_events,
            flow_attribution_events,
            process_snapshots,
            runtime_config,
            metrics,
        }
    }

    pub async fn run(self, mut shutdown: watch::Receiver<bool>) -> Result<()> {
        prepare_socket(&self.socket_path)?;
        let listener = UnixListener::bind(&self.socket_path)
            .with_context(|| format!("failed to bind {}", self.socket_path.display()))?;

        loop {
            tokio::select! {
                _ = shutdown.changed() => {
                    if *shutdown.borrow() {
                        return Ok(());
                    }
                }
                accepted = listener.accept() => {
                    let (stream, _) = accepted?;
                    if self.active_client.swap(true, Ordering::SeqCst) {
                        tokio::spawn(async move {
                            let _ = reject_concurrent_client(stream).await;
                        });
                        continue;
                    }

                    let active_client = Arc::clone(&self.active_client);
                    let fingerprint_rx = self.fingerprint_events.subscribe();
                    let dpi_rx = self.dpi_events.subscribe();
                    let flow_attribution_rx = self.flow_attribution_events.subscribe();
                    let process_snapshot_rx = self.process_snapshots.subscribe();
                    let runtime_config = self.runtime_config.clone();
                    let metrics = self.metrics.clone();
                    tokio::spawn(async move {
                        let _guard = ActiveClientGuard(active_client);
                        let result = handle_client(stream, fingerprint_rx, dpi_rx, flow_attribution_rx, process_snapshot_rx, runtime_config, metrics).await;
                        if let Err(err) = result {
                            log::warn!("netprobe IPC client disconnected with error: {err:#}");
                        }
                    });
                }
            }
        }
    }
}

struct ActiveClientGuard(Arc<AtomicBool>);

impl Drop for ActiveClientGuard {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

fn prepare_socket(path: &Path) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create socket dir {}", parent.display()))?;
    }

    if path.exists() {
        std::fs::remove_file(path)
            .with_context(|| format!("failed to remove stale socket {}", path.display()))?;
    }

    Ok(())
}

async fn reject_concurrent_client(mut stream: UnixStream) -> Result<()> {
    let frame = NetprobeFrame {
        sequence: 0,
        payload: Some(netprobe_frame::Payload::Error(ErrorFrame {
            code: "client_already_connected".to_string(),
            message: "netprobe accepts only one agent client".to_string(),
        })),
    };
    write_frame(&mut stream, &frame).await?;
    Ok(())
}

async fn handle_client(
    stream: UnixStream,
    mut fingerprint_events: broadcast::Receiver<FingerprintEvent>,
    mut dpi_events: broadcast::Receiver<DpiEvent>,
    mut flow_attribution_events: broadcast::Receiver<FlowAttributionEvent>,
    mut process_snapshots: broadcast::Receiver<ProcessSnapshot>,
    runtime_config: RuntimeConfig,
    metrics: Metrics,
) -> Result<()> {
    let (mut reader, mut writer) = stream.into_split();

    loop {
        tokio::select! {
            frame = read_frame(&mut reader) => {
                let Some(frame) = frame? else {
                    return Ok(());
                };
                let response = response_for_frame(frame, &runtime_config);
                write_frame(&mut writer, &response).await?;
            }
            event = fingerprint_events.recv() => {
                match event {
                    Ok(event) => {
                        let frame = NetprobeFrame {
                            sequence: 0,
                            payload: Some(netprobe_frame::Payload::FingerprintEvent(event)),
                        };
                        write_frame(&mut writer, &frame).await?;
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        metrics.inc_fingerprint_events_dropped("lagged_receiver", skipped);
                        log::warn!("netprobe IPC client lagged; skipped {skipped} fingerprint event(s)");
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        return Ok(());
                    }
                }
            }
            event = dpi_events.recv() => {
                match event {
                    Ok(event) => {
                        let frame = NetprobeFrame {
                            sequence: 0,
                            payload: Some(netprobe_frame::Payload::DpiEvent(event)),
                        };
                        write_frame(&mut writer, &frame).await?;
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        metrics.inc_dpi_events_dropped("lagged_receiver", skipped);
                        log::warn!("netprobe IPC client lagged; skipped {skipped} DPI event(s)");
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        return Ok(());
                    }
                }
            }
            event = flow_attribution_events.recv() => {
                match event {
                    Ok(event) => {
                        let frame = NetprobeFrame {
                            sequence: 0,
                            payload: Some(netprobe_frame::Payload::FlowAttributionEvent(event)),
                        };
                        write_frame(&mut writer, &frame).await?;
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        metrics.inc_flow_attribution_events_dropped("lagged_receiver", skipped);
                        log::warn!("netprobe IPC client lagged; skipped {skipped} flow attribution event(s)");
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        return Ok(());
                    }
                }
            }
            snapshot = process_snapshots.recv() => {
                match snapshot {
                    Ok(snapshot) => {
                        let frame = NetprobeFrame {
                            sequence: 0,
                            payload: Some(netprobe_frame::Payload::ProcessSnapshot(snapshot)),
                        };
                        write_frame(&mut writer, &frame).await?;
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        metrics.inc_process_snapshot_events_dropped("lagged_receiver", skipped);
                        log::warn!("netprobe IPC client lagged; skipped {skipped} process snapshot(s)");
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        return Ok(());
                    }
                }
            }
        }
    }
}

fn response_for_frame(frame: NetprobeFrame, runtime_config: &RuntimeConfig) -> NetprobeFrame {
    match frame.payload {
        Some(netprobe_frame::Payload::Ping(ping)) => NetprobeFrame {
            sequence: frame.sequence,
            payload: Some(netprobe_frame::Payload::PingAck(PingAck {
                sent_at_unix_nano: ping.sent_at_unix_nano,
                acked_at_unix_nano: now_unix_nano(),
                fingerprint_engine_version: FINGERPRINT_ENGINE_VERSION.to_string(),
                running_as_root: capabilities::running_as_root(),
                p0f_corpus_revision: P0F_CORPUS_REVISION.to_string(),
                serviceradar_additions_revision: SERVICERADAR_ADDITIONS_REVISION.to_string(),
                ja4_spec_revision: JA4_BASE_SPEC_REVISION.to_string(),
            })),
        },
        Some(netprobe_frame::Payload::ApplyConfig(apply)) => {
            match apply
                .config
                .and_then(|config| runtime_config.apply(config).ok())
            {
                Some(config_hash) => NetprobeFrame {
                    sequence: frame.sequence,
                    payload: Some(netprobe_frame::Payload::ConfigAck(ConfigAck {
                        config_hash,
                    })),
                },
                None => NetprobeFrame {
                    sequence: frame.sequence,
                    payload: Some(netprobe_frame::Payload::Error(ErrorFrame {
                        code: "invalid_config".to_string(),
                        message: "visibility config is missing or invalid".to_string(),
                    })),
                },
            }
        }
        _ => NetprobeFrame {
            sequence: frame.sequence,
            payload: Some(netprobe_frame::Payload::Error(ErrorFrame {
                code: "unsupported_frame".to_string(),
                message: "frame type is not supported by the Phase 1 skeleton".to_string(),
            })),
        },
    }
}

fn now_unix_nano() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as i64)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use tempfile::TempDir;
    use tokio::{
        net::UnixStream,
        sync::{broadcast, watch},
    };

    use super::IpcServer;
    use crate::{
        config::Config,
        fingerprint::{
            JA4_BASE_SPEC_REVISION, P0F_CORPUS_REVISION, SERVICERADAR_ADDITIONS_REVISION,
        },
        framing::{read_frame, write_frame},
        metrics::Metrics,
        proto::netprobe::{
            fingerprint_event, netprobe_frame, ApplyConfig, DpiEvent, FingerprintEvent,
            FlowAttributionEvent, NetprobeFrame, Ping, ProcessSnapshot, TcpFingerprint,
            VisibilityAgentConfig,
        },
        runtime_config::RuntimeConfig,
    };

    #[tokio::test]
    async fn responds_to_ping() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (event_tx, _) = broadcast::channel(16);
        let (dpi_tx, _) = broadcast::channel(16);
        let (flow_tx, _) = broadcast::channel(16);
        let (process_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            event_tx,
            dpi_tx,
            flow_tx,
            process_tx,
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        write_frame(
            &mut client,
            &NetprobeFrame {
                sequence: 1,
                payload: Some(netprobe_frame::Payload::Ping(Ping {
                    sent_at_unix_nano: 99,
                })),
            },
        )
        .await
        .unwrap();

        let response = read_frame(&mut client).await.unwrap().unwrap();
        assert_eq!(response.sequence, 1);
        let Some(netprobe_frame::Payload::PingAck(ack)) = response.payload else {
            panic!("expected ping ack");
        };
        assert_eq!(ack.p0f_corpus_revision, P0F_CORPUS_REVISION);
        assert_eq!(
            ack.serviceradar_additions_revision,
            SERVICERADAR_ADDITIONS_REVISION
        );
        assert_eq!(ack.ja4_spec_revision, JA4_BASE_SPEC_REVISION);

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn rejects_concurrent_client() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (event_tx, _) = broadcast::channel(16);
        let (dpi_tx, _) = broadcast::channel(16);
        let (flow_tx, _) = broadcast::channel(16);
        let (process_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            event_tx,
            dpi_tx,
            flow_tx,
            process_tx,
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let _first = UnixStream::connect(&socket).await.unwrap();
        let mut second = UnixStream::connect(&socket).await.unwrap();
        let response = read_frame(&mut second).await.unwrap().unwrap();
        assert!(matches!(
            response.payload,
            Some(netprobe_frame::Payload::Error(_))
        ));

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn streams_fingerprint_events_to_connected_client() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (event_tx, _) = broadcast::channel(16);
        let (dpi_tx, _) = broadcast::channel(16);
        let (flow_tx, _) = broadcast::channel(16);
        let (process_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            event_tx.clone(),
            dpi_tx,
            flow_tx,
            process_tx,
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        wait_for_event_receiver(&event_tx).await;
        event_tx.send(fingerprint_event()).unwrap();

        let response = read_frame(&mut client).await.unwrap().unwrap();
        assert_eq!(response.sequence, 0);
        let Some(netprobe_frame::Payload::FingerprintEvent(event)) = response.payload else {
            panic!("expected fingerprint event");
        };
        assert_eq!(event.ip, "192.0.2.10");
        assert_eq!(event.interface_name, "eth0");

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn streams_dpi_events_to_connected_client() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (event_tx, _) = broadcast::channel(16);
        let (dpi_tx, _) = broadcast::channel(16);
        let (flow_tx, _) = broadcast::channel(16);
        let (process_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            event_tx,
            dpi_tx.clone(),
            flow_tx,
            process_tx,
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        wait_for_event_receiver(&dpi_tx).await;
        dpi_tx.send(dpi_event()).unwrap();

        let response = read_frame(&mut client).await.unwrap().unwrap();
        assert_eq!(response.sequence, 0);
        let Some(netprobe_frame::Payload::DpiEvent(event)) = response.payload else {
            panic!("expected DPI event");
        };
        assert_eq!(event.protocol, "dns");
        assert_eq!(event.interface_name, "eth0");

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn streams_flow_attribution_events_to_connected_client() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (event_tx, _) = broadcast::channel(16);
        let (dpi_tx, _) = broadcast::channel(16);
        let (flow_tx, _) = broadcast::channel(16);
        let (process_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            event_tx,
            dpi_tx,
            flow_tx.clone(),
            process_tx,
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        wait_for_event_receiver(&flow_tx).await;
        flow_tx.send(flow_attribution_event()).unwrap();

        let response = read_frame(&mut client).await.unwrap().unwrap();
        assert_eq!(response.sequence, 0);
        let Some(netprobe_frame::Payload::FlowAttributionEvent(event)) = response.payload else {
            panic!("expected flow attribution event");
        };
        assert_eq!(event.local_ip, "192.0.2.10");
        assert_eq!(event.pid, 123);

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn streams_process_snapshots_to_connected_client() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (event_tx, _) = broadcast::channel(16);
        let (dpi_tx, _) = broadcast::channel(16);
        let (flow_tx, _) = broadcast::channel(16);
        let (process_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            event_tx,
            dpi_tx,
            flow_tx,
            process_tx.clone(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        wait_for_event_receiver(&process_tx).await;
        process_tx.send(process_snapshot()).unwrap();

        let response = read_frame(&mut client).await.unwrap().unwrap();
        assert_eq!(response.sequence, 0);
        let Some(netprobe_frame::Payload::ProcessSnapshot(snapshot)) = response.payload else {
            panic!("expected process snapshot");
        };
        assert_eq!(snapshot.fingerprint, "fp-1");
        assert_eq!(snapshot.entries.len(), 1);

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[cfg(feature = "pcap-capture")]
    #[tokio::test]
    async fn streams_fixture_traffic_events_to_connected_client() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (event_tx, _) = broadcast::channel(16);
        let (dpi_tx, _) = broadcast::channel(16);
        let (flow_tx, _) = broadcast::channel(16);
        let (process_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            event_tx.clone(),
            dpi_tx,
            flow_tx,
            process_tx,
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        wait_for_event_receiver(&event_tx).await;

        let mut engine = crate::fingerprint::FingerprintEngine::phase1().unwrap();
        for event in engine.analyze_packet("eth0", 789, &tls_server_hello_packet()) {
            event_tx.send(event).unwrap();
        }

        let (event, tls) = read_tls_fixture_event(&mut client).await;
        assert_eq!(event.ip, "198.51.100.40");
        assert_eq!(event.interface_name, "eth0");
        assert_eq!(tls.ja4, "");
        assert_eq!(tls.ja4s, "t1302h2_1301_b9a491fefe05");

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn applies_visibility_config() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (event_tx, _) = broadcast::channel(16);
        let (dpi_tx, _) = broadcast::channel(16);
        let (flow_tx, _) = broadcast::channel(16);
        let (process_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            event_tx,
            dpi_tx,
            flow_tx,
            process_tx,
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        write_frame(
            &mut client,
            &NetprobeFrame {
                sequence: 7,
                payload: Some(netprobe_frame::Payload::ApplyConfig(ApplyConfig {
                    config: Some(VisibilityAgentConfig {
                        enabled: true,
                        default_sample_interval_ms: 1_000,
                        ..Default::default()
                    }),
                })),
            },
        )
        .await
        .unwrap();

        let response = read_frame(&mut client).await.unwrap().unwrap();
        assert_eq!(response.sequence, 7);
        assert!(matches!(
            response.payload,
            Some(netprobe_frame::Payload::ConfigAck(_))
        ));

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    async fn wait_for_socket(socket: &std::path::Path) {
        for _ in 0..50 {
            if socket.exists() {
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        panic!("socket did not appear");
    }

    async fn wait_for_event_receiver<T: Clone>(event_tx: &broadcast::Sender<T>) {
        for _ in 0..50 {
            if event_tx.receiver_count() > 0 {
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        panic!("server did not subscribe to fingerprint events");
    }

    #[cfg(feature = "pcap-capture")]
    async fn read_tls_fixture_event(
        client: &mut UnixStream,
    ) -> (FingerprintEvent, crate::proto::netprobe::TlsFingerprint) {
        for _ in 0..5 {
            let response =
                tokio::time::timeout(std::time::Duration::from_secs(1), read_frame(client))
                    .await
                    .expect("timed out waiting for fixture event")
                    .unwrap()
                    .unwrap();
            if let Some(netprobe_frame::Payload::FingerprintEvent(event)) = response.payload {
                if let Some(fingerprint_event::Evidence::Tls(tls)) = event.evidence.clone() {
                    return (event, tls);
                }
            }
        }

        panic!("expected TLS fingerprint event");
    }

    fn fingerprint_event() -> FingerprintEvent {
        FingerprintEvent {
            ip: "192.0.2.10".to_string(),
            profile_id: "profile-1".to_string(),
            interface_name: "eth0".to_string(),
            observed_at_unix_nano: 123,
            evidence: Some(fingerprint_event::Evidence::Tcp(TcpFingerprint {
                signature: "sig".to_string(),
                os_family: "linux".to_string(),
                os_name: "Linux".to_string(),
                confidence: 1.0,
                ..Default::default()
            })),
        }
    }

    fn dpi_event() -> DpiEvent {
        DpiEvent {
            source_ip: "192.0.2.10".to_string(),
            destination_ip: "198.51.100.20".to_string(),
            source_port: 49_152,
            destination_port: 53,
            transport_protocol: "udp".to_string(),
            protocol: "dns".to_string(),
            confidence: 0.95,
            observed_at_unix_nano: 123,
            interface_name: "eth0".to_string(),
            dissector_id: "dns_header".to_string(),
            ..Default::default()
        }
    }

    fn flow_attribution_event() -> FlowAttributionEvent {
        FlowAttributionEvent {
            local_ip: "192.0.2.10".to_string(),
            local_port: 49_152,
            remote_ip: "198.51.100.20".to_string(),
            remote_port: 443,
            transport_protocol: "tcp".to_string(),
            pid: 123,
            tgid: 123,
            uid: 1000,
            gid: 1000,
            comm: "curl".to_string(),
            redacted_cmdline: vec![
                "/usr/bin/curl".to_string(),
                "[redacted 1 arg(s)]".to_string(),
            ],
            observed_at_unix_nano: 123,
            ..Default::default()
        }
    }

    fn process_snapshot() -> ProcessSnapshot {
        ProcessSnapshot {
            fingerprint: "fp-1".to_string(),
            observed_at_unix_nano: 123,
            entries: vec![crate::proto::netprobe::ProcessSnapshotEntry {
                local_ip: "192.0.2.10".to_string(),
                local_port: 443,
                transport_protocol: "tcp".to_string(),
                pid: 123,
                tgid: 123,
                uid: 1000,
                gid: 1000,
                comm: "nginx".to_string(),
                redacted_cmdline: vec!["/usr/sbin/nginx".to_string()],
                ..Default::default()
            }],
        }
    }

    #[cfg(feature = "pcap-capture")]
    fn tls_server_hello_packet() -> Vec<u8> {
        ipv4_tcp_packet(
            [198, 51, 100, 40],
            [192, 0, 2, 22],
            443,
            49_153,
            &tls_server_hello_payload(),
        )
    }

    #[cfg(feature = "pcap-capture")]
    fn tls_server_hello_payload() -> Vec<u8> {
        let mut body = Vec::new();
        body.extend_from_slice(&[0x03, 0x03]);
        body.extend_from_slice(&[0u8; 32]);
        body.push(0x00);
        body.extend_from_slice(&0x1301u16.to_be_bytes());
        body.push(0x00);

        let mut extensions = Vec::new();
        extensions.extend_from_slice(&0x002bu16.to_be_bytes());
        extensions.extend_from_slice(&2u16.to_be_bytes());
        extensions.extend_from_slice(&0x0304u16.to_be_bytes());
        extensions.extend_from_slice(&0x0010u16.to_be_bytes());
        extensions.extend_from_slice(&5u16.to_be_bytes());
        extensions.extend_from_slice(&3u16.to_be_bytes());
        extensions.push(2);
        extensions.extend_from_slice(b"h2");

        body.extend_from_slice(&(extensions.len() as u16).to_be_bytes());
        body.extend_from_slice(&extensions);

        let body_len = body.len() as u32;
        let mut handshake = vec![
            0x02,
            ((body_len >> 16) & 0xff) as u8,
            ((body_len >> 8) & 0xff) as u8,
            (body_len & 0xff) as u8,
        ];
        handshake.extend_from_slice(&body);

        let record_len = handshake.len() as u16;
        let mut record = vec![0x16, 0x03, 0x03];
        record.extend_from_slice(&record_len.to_be_bytes());
        record.extend_from_slice(&handshake);
        record
    }

    #[cfg(feature = "pcap-capture")]
    fn ipv4_tcp_packet(
        source_ip: [u8; 4],
        destination_ip: [u8; 4],
        source_port: u16,
        destination_port: u16,
        payload: &[u8],
    ) -> Vec<u8> {
        let total_len = 20 + 20 + payload.len();
        let mut packet = Vec::with_capacity(total_len);
        packet.extend_from_slice(&[
            0x45,
            0x00,
            ((total_len >> 8) & 0xff) as u8,
            (total_len & 0xff) as u8,
            0x12,
            0x34,
            0x40,
            0x00,
            0x40,
            0x06,
            0x00,
            0x00,
        ]);
        packet.extend_from_slice(&source_ip);
        packet.extend_from_slice(&destination_ip);
        packet.extend_from_slice(&source_port.to_be_bytes());
        packet.extend_from_slice(&destination_port.to_be_bytes());
        packet.extend_from_slice(&[0x01, 0x02, 0x03, 0x04]);
        packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
        packet.extend_from_slice(&[0x50, 0x18]);
        packet.extend_from_slice(&0xfa_f0u16.to_be_bytes());
        packet.extend_from_slice(&0u16.to_be_bytes());
        packet.extend_from_slice(&0u16.to_be_bytes());
        packet.extend_from_slice(payload);
        packet
    }
}
