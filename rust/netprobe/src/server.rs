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
    fingerprint::FINGERPRINT_ENGINE_VERSION,
    framing::{read_frame, write_frame},
    proto::netprobe::{
        netprobe_frame, ConfigAck, ErrorFrame, FingerprintEvent, NetprobeFrame, PingAck,
    },
    runtime_config::RuntimeConfig,
};

pub struct IpcServer {
    socket_path: PathBuf,
    active_client: Arc<AtomicBool>,
    fingerprint_events: broadcast::Sender<FingerprintEvent>,
    runtime_config: RuntimeConfig,
}

impl IpcServer {
    pub fn new(
        socket_path: impl Into<PathBuf>,
        fingerprint_events: broadcast::Sender<FingerprintEvent>,
        runtime_config: RuntimeConfig,
    ) -> Self {
        Self {
            socket_path: socket_path.into(),
            active_client: Arc::new(AtomicBool::new(false)),
            fingerprint_events,
            runtime_config,
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
                    let event_rx = self.fingerprint_events.subscribe();
                    let runtime_config = self.runtime_config.clone();
                    tokio::spawn(async move {
                        let result = handle_client(stream, event_rx, runtime_config).await;
                        active_client.store(false, Ordering::SeqCst);
                        if let Err(err) = result {
                            log::warn!("netprobe IPC client disconnected with error: {err:#}");
                        }
                    });
                }
            }
        }
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
    runtime_config: RuntimeConfig,
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
                        log::warn!("netprobe IPC client lagged; skipped {skipped} fingerprint event(s)");
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
        framing::{read_frame, write_frame},
        proto::netprobe::{
            fingerprint_event, netprobe_frame, ApplyConfig, FingerprintEvent, NetprobeFrame, Ping,
            TcpFingerprint, VisibilityAgentConfig,
        },
        runtime_config::RuntimeConfig,
    };

    #[tokio::test]
    async fn responds_to_ping() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (event_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(&socket, event_tx, RuntimeConfig::new(&Config::default()));
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
        assert!(matches!(
            response.payload,
            Some(netprobe_frame::Payload::PingAck(_))
        ));

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn rejects_concurrent_client() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (event_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(&socket, event_tx, RuntimeConfig::new(&Config::default()));
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
        let server = IpcServer::new(
            &socket,
            event_tx.clone(),
            RuntimeConfig::new(&Config::default()),
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
    async fn applies_visibility_config() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (event_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(&socket, event_tx, RuntimeConfig::new(&Config::default()));
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

    async fn wait_for_event_receiver(event_tx: &broadcast::Sender<FingerprintEvent>) {
        for _ in 0..50 {
            if event_tx.receiver_count() > 0 {
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        panic!("server did not subscribe to fingerprint events");
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
            })),
        }
    }
}
