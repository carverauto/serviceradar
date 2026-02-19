mod config;
mod model;
mod publisher;

use crate::config::Config;
use crate::publisher::Publisher;
use anyhow::{Context, Result};
use arancini_lib::process_bmp_message;
use arancini_lib::state_store::memory::MemoryStore;
use bytes::BytesMut;
use clap::Parser;
use log::{debug, error, info};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::AsyncReadExt;
use tokio::net::{TcpListener, TcpStream};

const BMP_COMMON_HEADER_LEN: usize = 6;
const BMP_MAX_MESSAGE_TYPE: u8 = 6;

#[derive(Parser, Debug)]
#[command(name = "serviceradar-bmp-collector")]
#[command(about = "ServiceRadar BMP collector backed by arancini-lib")]
struct Cli {
    /// Path to BMP collector JSON config.
    #[arg(long, default_value = "rust/bmp-collector/bmp-collector.json")]
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

    let publisher = Publisher::connect(cfg.clone()).await?;
    run_listener(cfg, publisher).await
}

async fn run_listener(cfg: Arc<Config>, publisher: Publisher) -> Result<()> {
    let listener = TcpListener::bind(cfg.listen_addr_parsed()?)
        .await
        .with_context(|| format!("failed to bind BMP listener on {}", cfg.listen_addr))?;

    loop {
        let (stream, socket) = listener.accept().await?;
        debug!("accepted BMP router session from {}", socket);

        let conn_cfg = cfg.clone();
        let conn_publisher = publisher.clone();

        tokio::spawn(async move {
            if let Err(err) = handle_connection(stream, socket, conn_cfg, conn_publisher).await {
                error!("BMP session {} failed: {}", socket, err);
            }
        });
    }
}

async fn handle_connection(
    mut stream: TcpStream,
    socket: std::net::SocketAddr,
    cfg: Arc<Config>,
    publisher: Publisher,
) -> Result<()> {
    let mut slot = vec![0u8; cfg.read_buffer_bytes];
    let mut frame_buffer = BytesMut::with_capacity(cfg.read_buffer_bytes);

    loop {
        let n = stream
            .read(&mut slot)
            .await
            .with_context(|| format!("{}: failed reading BMP socket", socket))?;

        if n == 0 {
            debug!("BMP session {} closed", socket);
            return Ok(());
        }

        frame_buffer.extend_from_slice(&slot[..n]);

        while let Some(packet_length) =
            next_packet_length(&frame_buffer, socket, cfg.max_frame_size_bytes)?
        {
            let mut bytes = frame_buffer.split_to(packet_length).freeze();
            process_bmp_message::<MemoryStore, Publisher>(
                None,
                publisher.clone(),
                socket,
                &mut bytes,
            )
            .await
            .with_context(|| format!("{}: failed processing BMP message", socket))?;
        }

        if frame_buffer.len() > cfg.max_frame_size_bytes {
            anyhow::bail!(
                "{}: buffered BMP data {} exceeds max frame size {}",
                socket,
                frame_buffer.len(),
                cfg.max_frame_size_bytes
            );
        }
    }
}

fn next_packet_length(
    frame_buffer: &BytesMut,
    socket: std::net::SocketAddr,
    max_frame_size: usize,
) -> Result<Option<usize>> {
    if frame_buffer.len() < BMP_COMMON_HEADER_LEN {
        return Ok(None);
    }

    let message_version = frame_buffer[0];
    if message_version != 3 {
        anyhow::bail!("{}: unsupported BMP version {}", socket, message_version);
    }

    let packet_length = u32::from_be_bytes(
        frame_buffer[1..5]
            .try_into()
            .expect("BMP header length slice should be 4 bytes"),
    ) as usize;

    if packet_length < BMP_COMMON_HEADER_LEN {
        anyhow::bail!("{}: invalid BMP packet length {}", socket, packet_length);
    }

    if packet_length > max_frame_size {
        anyhow::bail!(
            "{}: BMP packet length {} exceeds configured max {}",
            socket,
            packet_length,
            max_frame_size
        );
    }

    let message_type = frame_buffer[5];
    if message_type > BMP_MAX_MESSAGE_TYPE {
        anyhow::bail!("{}: unsupported BMP message type {}", socket, message_type);
    }

    if frame_buffer.len() < packet_length {
        return Ok(None);
    }

    Ok(Some(packet_length))
}

fn path_to_string(path: &PathBuf) -> Result<&str> {
    path.to_str()
        .ok_or_else(|| anyhow::anyhow!("config path contains non-UTF-8 characters"))
}
