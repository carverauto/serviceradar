mod bmp;
mod config;
mod metrics;
mod model;
mod publisher;

use crate::config::Config;
use crate::publisher::Publisher;
use anyhow::{Context, Result};
use arancini_lib::state_store::memory::MemoryStore;
use bytes::Bytes;
use clap::Parser;
use log::{debug, error, info};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Semaphore;
use tokio::time::{Duration, Instant, timeout_at};

const BMP_COMMON_HEADER_LEN: usize = 6;
const BMP_MAX_MESSAGE_TYPE: u8 = 6;
// Bound decoded TLV/stat collections as well as raw bytes before invoking the parser.
const BMP_DECODE_FRAME_LIMIT: usize = 256 * 1024;

#[derive(Parser, Debug)]
#[command(name = "serviceradar-bmp-collector")]
#[command(about = "ServiceRadar BMP collector backed by arancini-lib")]
struct Cli {
    /// Path to BMP collector JSON config.
    #[arg(long)]
    config: PathBuf,
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();

    let cli = Cli::parse();
    let cfg = Arc::new(Config::from_file(path_to_string(&cli.config)?)?);

    info!(
        "starting bmp collector listen={} stream={} prefix={}",
        cfg.listen_addr, cfg.stream_name, cfg.subject_prefix
    );

    metrics::start(&cfg.metrics_addr).await?;
    let publisher = Publisher::connect(cfg.clone()).await?;
    run_listener(cfg, publisher).await
}

async fn run_listener(cfg: Arc<Config>, publisher: Publisher) -> Result<()> {
    let listener = TcpListener::bind(cfg.listen_addr_parsed()?)
        .await
        .with_context(|| format!("failed to bind BMP listener on {}", cfg.listen_addr))?;

    let sessions = Arc::new(Semaphore::new(cfg.max_connections));
    loop {
        let (stream, socket, permit) = accept_session(&listener, &sessions).await;
        debug!("accepted BMP router session from {}", socket);
        let conn_cfg = cfg.clone();
        let conn_publisher = publisher.clone();
        tokio::spawn(async move {
            let _permit = permit;
            if let Err(err) = handle_connection(stream, socket, conn_cfg, conn_publisher).await {
                error!("BMP session {} failed: {err:#}", socket);
            }
        });
    }
}

/// Admission occurs before the caller spawns a task or reads a frame.
async fn accept_session(
    listener: &TcpListener,
    sessions: &Arc<Semaphore>,
) -> (
    TcpStream,
    std::net::SocketAddr,
    tokio::sync::OwnedSemaphorePermit,
) {
    let mut backoff = Duration::from_millis(250);
    loop {
        let (stream, socket) = match listener.accept().await {
            Ok(pair) => {
                backoff = Duration::from_millis(250);
                pair
            }
            Err(err) => {
                metrics::ACCEPT_ERRORS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                error!("BMP accept failed; retrying after {backoff:?}: {err}");
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(Duration::from_secs(5));
                continue;
            }
        };
        let Ok(permit) = Arc::clone(sessions).try_acquire_owned() else {
            metrics::REJECTED_SESSIONS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            drop(stream);
            continue;
        };
        return (stream, socket, permit);
    }
}

async fn handle_connection(
    mut stream: TcpStream,
    socket: std::net::SocketAddr,
    cfg: Arc<Config>,
    publisher: Publisher,
) -> Result<()> {
    while let Some(mut bytes) = read_frame(
        &mut stream,
        cfg.max_frame_size_bytes,
        Duration::from_secs(cfg.read_timeout_secs),
    )
    .await?
    {
        bmp::process_bmp_message::<MemoryStore, Publisher>(
            None,
            publisher.clone(),
            socket,
            &mut bytes,
        )
        .await
        .with_context(|| format!("{socket}: failed processing BMP message"))?;
    }
    Ok(())
}

/// One absolute deadline spans the header and body. A trickle cannot renew it.
/// Silent sessions allocate only a stack header; validated frames allocate exactly once.
async fn read_frame<R: AsyncRead + Unpin>(
    reader: &mut R,
    max_frame_size: usize,
    read_timeout: Duration,
) -> Result<Option<Bytes>> {
    let deadline = Instant::now() + read_timeout;
    let result = timeout_at(deadline, async {
        let mut header = [0u8; BMP_COMMON_HEADER_LEN];
        if reader.read(&mut header[..1]).await? == 0 {
            return Ok(None);
        }
        reader.read_exact(&mut header[1..]).await?;
        let length = packet_length(&header, max_frame_size)?;
        let mut frame = vec![0u8; length];
        frame[..BMP_COMMON_HEADER_LEN].copy_from_slice(&header);
        reader
            .read_exact(&mut frame[BMP_COMMON_HEADER_LEN..])
            .await?;
        Ok(Some(Bytes::from(frame)))
    })
    .await;
    match result {
        Ok(result) => result,
        Err(_) => {
            metrics::READ_TIMEOUTS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            anyhow::bail!("BMP frame read deadline exceeded");
        }
    }
}

fn packet_length(header: &[u8; BMP_COMMON_HEADER_LEN], max_frame_size: usize) -> Result<usize> {
    if header[0] != 3 {
        anyhow::bail!("unsupported BMP version {}", header[0]);
    }
    let length = u32::from_be_bytes(header[1..5].try_into().expect("four length bytes")) as usize;
    let max_frame_size = max_frame_size.min(BMP_DECODE_FRAME_LIMIT);
    if length < BMP_COMMON_HEADER_LEN || length > max_frame_size {
        metrics::REJECTED_FRAMES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        anyhow::bail!("BMP frame length {length} outside 6..={max_frame_size}");
    }
    if header[5] > BMP_MAX_MESSAGE_TYPE {
        anyhow::bail!("unsupported BMP message type {}", header[5]);
    }
    Ok(length)
}

fn path_to_string(path: &Path) -> Result<&str> {
    path.to_str()
        .ok_or_else(|| anyhow::anyhow!("config path contains non-UTF-8 characters"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;

    #[tokio::test]
    async fn listener_drops_excess_sessions_and_recovers_capacity() {
        let listener = Arc::new(TcpListener::bind("127.0.0.1:0").await.unwrap());
        let address = listener.local_addr().unwrap();
        let sessions = Arc::new(Semaphore::new(2));
        let _client1 = TcpStream::connect(address).await.unwrap();
        let first = accept_session(&listener, &sessions).await;
        let _client2 = TcpStream::connect(address).await.unwrap();
        let second = accept_session(&listener, &sessions).await;
        let accept = {
            let listener = listener.clone();
            let sessions = sessions.clone();
            tokio::spawn(async move { accept_session(&listener, &sessions).await })
        };
        let mut excess = TcpStream::connect(address).await.unwrap();
        let mut byte = [0];
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), excess.read(&mut byte))
                .await
                .unwrap()
                .unwrap(),
            0
        );
        drop(first);
        let _client3 = TcpStream::connect(address).await.unwrap();
        let recovered = tokio::time::timeout(Duration::from_secs(1), accept)
            .await
            .unwrap()
            .unwrap();
        drop(second);
        drop(recovered);
        assert_eq!(sessions.available_permits(), 2);
    }

    #[tokio::test]
    async fn reads_exact_frames_and_rejects_lengths_before_waiting_for_body() {
        let (mut tx, mut rx) = tokio::io::duplex(64);
        tx.write_all(&[3, 0, 0, 0, 6, 4, 3, 0, 0, 0, 6, 5])
            .await
            .unwrap();
        for kind in [4, 5] {
            let frame = read_frame(&mut rx, 64, Duration::from_secs(1))
                .await
                .unwrap()
                .unwrap();
            assert_eq!(&frame[..], &[3, 0, 0, 0, 6, kind]);
        }
        tx.write_all(&[3, 0, 0, 0, 65, 0]).await.unwrap();
        assert!(
            read_frame(&mut rx, 64, Duration::from_secs(1))
                .await
                .is_err()
        );
        let mut oversized = vec![3];
        oversized.extend_from_slice(&((BMP_DECODE_FRAME_LIMIT + 1) as u32).to_be_bytes());
        oversized.push(4); // Initiation TLVs are bounded before parser allocation.
        tx.write_all(&oversized).await.unwrap();
        assert!(
            read_frame(&mut rx, 16 * 1024 * 1024, Duration::from_secs(1))
                .await
                .is_err()
        );
        drop(tx);
        assert!(
            read_frame(&mut rx, 64, Duration::from_secs(1))
                .await
                .unwrap()
                .is_none()
        );
    }

    #[tokio::test]
    async fn silent_partial_and_trickling_frames_expire() {
        for partial in [&[][..], &[3, 0, 0][..], &[3, 0, 0, 1, 0, 0, 1][..]] {
            let (mut tx, mut rx) = tokio::io::duplex(64);
            tx.write_all(partial).await.unwrap();
            assert!(
                read_frame(&mut rx, 256, Duration::from_millis(20))
                    .await
                    .is_err()
            );
        }
        let (mut tx, mut rx) = tokio::io::duplex(64);
        let result = tokio::join!(read_frame(&mut rx, 256, Duration::from_millis(20)), async {
            for byte in [3, 0, 0, 1, 0, 0] {
                tx.write_all(&[byte]).await.unwrap();
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        });
        assert!(
            result.0.is_err(),
            "trickling reset the whole-frame deadline"
        );
    }
}
