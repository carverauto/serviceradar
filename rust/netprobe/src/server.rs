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
    sync::watch,
};

use crate::{
    fingerprint::FINGERPRINT_ENGINE_VERSION,
    framing::{read_frame, write_frame},
    proto::netprobe::{netprobe_frame, ConfigAck, ErrorFrame, NetprobeFrame, PingAck},
};

pub struct IpcServer {
    socket_path: PathBuf,
    active_client: Arc<AtomicBool>,
}

impl IpcServer {
    pub fn new(socket_path: impl Into<PathBuf>) -> Self {
        Self {
            socket_path: socket_path.into(),
            active_client: Arc::new(AtomicBool::new(false)),
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
                    tokio::spawn(async move {
                        let result = handle_client(stream).await;
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

async fn handle_client(mut stream: UnixStream) -> Result<()> {
    while let Some(frame) = read_frame(&mut stream).await? {
        match frame.payload {
            Some(netprobe_frame::Payload::Ping(ping)) => {
                let ack = NetprobeFrame {
                    sequence: frame.sequence,
                    payload: Some(netprobe_frame::Payload::PingAck(PingAck {
                        sent_at_unix_nano: ping.sent_at_unix_nano,
                        acked_at_unix_nano: now_unix_nano(),
                        fingerprint_engine_version: FINGERPRINT_ENGINE_VERSION.to_string(),
                    })),
                };
                write_frame(&mut stream, &ack).await?;
            }
            Some(netprobe_frame::Payload::ApplyConfig(_apply)) => {
                let ack = NetprobeFrame {
                    sequence: frame.sequence,
                    payload: Some(netprobe_frame::Payload::ConfigAck(ConfigAck {
                        config_hash: "phase1-skeleton".to_string(),
                    })),
                };
                write_frame(&mut stream, &ack).await?;
            }
            _ => {
                let err = NetprobeFrame {
                    sequence: frame.sequence,
                    payload: Some(netprobe_frame::Payload::Error(ErrorFrame {
                        code: "unsupported_frame".to_string(),
                        message: "frame type is not supported by the Phase 1 skeleton".to_string(),
                    })),
                };
                write_frame(&mut stream, &err).await?;
            }
        }
    }

    Ok(())
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
    use tokio::{net::UnixStream, sync::watch};

    use super::IpcServer;
    use crate::{
        framing::{read_frame, write_frame},
        proto::netprobe::{netprobe_frame, NetprobeFrame, Ping},
    };

    #[tokio::test]
    async fn responds_to_ping() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let server = IpcServer::new(&socket);
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
        let server = IpcServer::new(&socket);
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

    async fn wait_for_socket(socket: &std::path::Path) {
        for _ in 0..50 {
            if socket.exists() {
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        panic!("socket did not appear");
    }
}
