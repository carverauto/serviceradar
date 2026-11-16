//! Synthetic open-loop measurement of the JetStream publish window.
//!
//! Runs one complete Flowgger pipeline (TCP syslog listener, GELF encoder, NATS
//! output) against a private `nats-server` with file storage, sends invented
//! RFC 5424 records over one TCP connection and reports how long the broker
//! takes to store all of them. Every window uses the same stream settings, so
//! runs differ only in `output.nats_max_inflight`; a window of 1 is the serial
//! comparator.
//!
//! ```text
//! cargo run --release --features nats-output --example publish_window_bench -- \
//!     --window 1 --records 200000 --bytes 256
//! ```
//!
//! One process measures one window: a Flowgger pipeline cannot be stopped, and
//! its output exits the process when its broker goes away.

use async_nats::jetstream;
use std::io::Write;
use std::net::{TcpListener, TcpStream};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const STREAM: &str = "SYNTHETIC_BENCH";
const SUBJECT: &str = "synthetic.bench";

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

fn argument(name: &str, default: u64) -> u64 {
    let mut arguments = std::env::args().skip(1);
    while let Some(argument) = arguments.next() {
        if argument == name {
            let value = arguments.next().unwrap_or_default();
            return value
                .parse()
                .ok()
                .filter(|parsed| *parsed > 0)
                .unwrap_or_else(|| panic!("{name} needs a positive integer, got {value:?}"));
        }
    }
    default
}

fn main() {
    let window = argument("--window", 32);
    let records = argument("--records", 100_000);
    let bytes = argument("--bytes", 256) as usize;
    let limit = Duration::from_secs(argument("--timeout-secs", 300));

    let files = tempfile::tempdir().unwrap();
    let nats_port = free_port();
    let syslog_port = free_port();
    let executable = std::env::var("NATS_SERVER_BIN").unwrap_or_else(|_| "nats-server".into());
    let mut broker = Command::new(executable)
        .args(["--jetstream", "--addr", "127.0.0.1", "--port"])
        .arg(nats_port.to_string())
        .arg("--store_dir")
        .arg(files.path().join("jetstream"))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("start nats-server (set NATS_SERVER_BIN or put it on PATH)");

    let config = files.path().join("flowgger.toml");
    std::fs::write(
        &config,
        format!(
            r#"
[input]
type = "tcp"
listen = "127.0.0.1:{syslog_port}"
format = "rfc5424"
framing = "line"

[output]
type = "nats"
format = "gelf"
framing = "noop"
nats_url = "nats://127.0.0.1:{nats_port}"
nats_stream = "{STREAM}"
nats_subject = "{SUBJECT}"
nats_max_inflight = {window}
"#
        ),
    )
    .unwrap();
    let pipeline_config = config.to_str().unwrap().to_owned();
    std::thread::spawn(move || flowgger::start_pipeline(&pipeline_config));

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let outcome = runtime.block_on(async {
        let ready = Instant::now();
        // The output creates the stream after connecting; the listener is
        // accepting once the pipeline has started.
        let mut stream = loop {
            if let Ok(client) = async_nats::connect(format!("nats://127.0.0.1:{nats_port}")).await
                && let Ok(stream) = jetstream::new(client).get_stream(STREAM).await
            {
                break stream;
            }
            if ready.elapsed() > Duration::from_secs(30) {
                return Err("Flowgger never created its stream".to_owned());
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        };
        let mut sender = loop {
            match TcpStream::connect(("127.0.0.1", syslog_port)) {
                Ok(sender) => break sender,
                Err(error) if ready.elapsed() > Duration::from_secs(30) => {
                    return Err(format!("syslog listener never accepted: {error}"));
                }
                Err(_) => tokio::time::sleep(Duration::from_millis(20)).await,
            }
        };

        let started = Instant::now();
        let sending = std::thread::spawn(move || {
            let prefix = "<13>1 2026-01-01T00:00:00Z host01.example.com bench - - - ";
            let filler = "x".repeat(bytes.saturating_sub(prefix.len() + 21));
            for sequence in 0..records {
                // The sequence keeps every record distinct on the wire.
                writeln!(sender, "{prefix}{sequence:020} {filler}").unwrap();
            }
            sender.flush().unwrap();
            started.elapsed()
        });

        loop {
            let stored = stream
                .info()
                .await
                .map_err(|error| format!("stream info failed: {error}"))?
                .state
                .messages;
            if stored == records {
                let elapsed = started.elapsed();
                return Ok((elapsed, sending.join().unwrap()));
            }
            if stored > records {
                return Err(format!("broker stored {stored} of {records} records"));
            }
            if started.elapsed() > limit {
                return Err(format!(
                    "broker stored only {stored} of {records} records in {limit:?}"
                ));
            }
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    });

    let _ = broker.kill();
    let _ = broker.wait();
    match outcome {
        Ok((stored, sent)) => {
            println!(
                "window={window} records={records} line_bytes={bytes} sent_in={:.3}s stored_in={:.3}s stored_per_sec={:.0}",
                sent.as_secs_f64(),
                stored.as_secs_f64(),
                records as f64 / stored.as_secs_f64()
            );
            // Skip destructors: the pipeline threads cannot be joined.
            std::process::exit(0);
        }
        Err(error) => {
            eprintln!("publish window benchmark failed: {error}");
            std::process::exit(1);
        }
    }
}
