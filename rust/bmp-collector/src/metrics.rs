use anyhow::Result;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::Semaphore;
use tokio::time::{Duration, timeout};

pub static REJECTED_SESSIONS: AtomicU64 = AtomicU64::new(0);
pub static ACCEPT_ERRORS: AtomicU64 = AtomicU64::new(0);
pub static READ_TIMEOUTS: AtomicU64 = AtomicU64::new(0);
pub static REJECTED_FRAMES: AtomicU64 = AtomicU64::new(0);
pub static REJECTED_PREFIXES: AtomicU64 = AtomicU64::new(0);
pub static THROTTLED_PUBLISHES: AtomicU64 = AtomicU64::new(0);
pub static REJECTED_PUBLISHES: AtomicU64 = AtomicU64::new(0);

pub async fn start(addr: &str) -> Result<()> {
    let listener = TcpListener::bind(addr).await?;
    let permits = Arc::new(Semaphore::new(4));
    tokio::spawn(async move {
        loop {
            let (mut stream, _) = match listener.accept().await {
                Ok(pair) => pair,
                Err(err) => {
                    log::warn!("BMP metrics accept error: {err}");
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    continue;
                }
            };
            let Ok(permit) = permits.clone().try_acquire_owned() else {
                continue;
            };
            tokio::spawn(async move {
                let _permit = permit;
                let _ = timeout(Duration::from_secs(2), async {
                    let mut request = [0; 1024];
                    let mut n = 0;
                    while n < request.len() && !request[..n].windows(2).any(|pair| pair == b"\r\n") {
                        let read = stream.read(&mut request[n..]).await?;
                        if read == 0 { break; }
                        n += read;
                    }
                    let (status, body) = if request[..n].starts_with(b"GET /metrics HTTP/") {
                        ("200 OK", render())
                    } else {
                        ("404 Not Found", String::new())
                    };
                    let response = format!("HTTP/1.1 {status}\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                    stream.write_all(response.as_bytes()).await
                }).await;
            });
        }
    });
    Ok(())
}

fn render() -> String {
    let mut out = String::new();
    for (name, counter) in [
        ("rejected_sessions", &REJECTED_SESSIONS),
        ("accept_errors", &ACCEPT_ERRORS),
        ("read_timeouts", &READ_TIMEOUTS),
        ("rejected_frames", &REJECTED_FRAMES),
        ("rejected_prefixes", &REJECTED_PREFIXES),
        ("rejected_publishes", &REJECTED_PUBLISHES),
        ("throttled_publishes", &THROTTLED_PUBLISHES),
    ] {
        use std::fmt::Write;
        let _ = writeln!(
            out,
            "# TYPE bmp_collector_{name}_total counter\nbmp_collector_{name}_total {}",
            counter.load(Ordering::Relaxed)
        );
    }
    out
}
