use super::*;
use std::net::TcpListener;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::sync_channel;

struct Broker {
    process: Child,
    _storage: tempfile::TempDir,
    url: String,
}

impl Broker {
    fn start() -> Self {
        let address = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap();
        let storage = tempfile::tempdir().unwrap();
        let executable = std::env::var("NATS_SERVER_BIN").unwrap_or_else(|_| "nats-server".into());
        let process = Command::new(executable)
            .args(["--jetstream", "--addr", "127.0.0.1", "--port"])
            .arg(address.port().to_string())
            .arg("--store_dir")
            .arg(storage.path())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("start the declared NATS test broker (Cargo requires nats-server on PATH)");
        Self {
            process,
            _storage: storage,
            url: format!("nats://{address}"),
        }
    }

    async fn connect(&mut self) -> jetstream::Context {
        timeout(Duration::from_secs(5), async {
            loop {
                if let Some(status) = self.process.try_wait().unwrap() {
                    panic!("NATS test broker exited before becoming ready: {status}");
                }
                match async_nats::connect(&self.url).await {
                    Ok(client) => return jetstream::new(client),
                    Err(_) => sleep(Duration::from_millis(10)).await,
                }
            }
        })
        .await
        .expect("NATS test broker did not become ready")
    }
}

impl Broker {
    /// The broker numbers client connections in the order it accepts them, so
    /// the difference between two readings counts every connection in between.
    async fn next_client_id(&self) -> u64 {
        async_nats::connect(&self.url)
            .await
            .unwrap()
            .server_info()
            .client_id
    }
}

impl Drop for Broker {
    fn drop(&mut self) {
        let _ = self.process.kill();
        let _ = self.process.wait();
    }
}

fn worker(
    url: &str,
    count: usize,
    bytes: usize,
) -> (NATSWorker, std::sync::mpsc::SyncSender<Vec<u8>>) {
    worker_with(url, count, bytes, 250, "")
}

fn worker_with(
    url: &str,
    count: usize,
    bytes: usize,
    timeout_ms: u64,
    extra: &str,
) -> (NATSWorker, std::sync::mpsc::SyncSender<Vec<u8>>) {
    let config = Config::from_string(&format!(
        r#"
[output]
nats_url = "{url}"
nats_stream = "SYNTHETIC_LOGS"
nats_subject = "synthetic.logs"
nats_timeout = {timeout_ms}
nats_connect_attempts = 5
nats_connect_initial_backoff_ms = 10
nats_connect_max_backoff_ms = 20
nats_max_inflight = {count}
nats_max_inflight_bytes = {bytes}
{extra}
"#,
    ))
    .unwrap();
    let (tx, rx) = sync_channel(8);
    (
        NATSWorker {
            cfg: NATSOutput::new(&config).cfg,
            arx: Arc::new(Mutex::new(rx)),
            merger: None,
        },
        tx,
    )
}

#[test]
fn pending_acknowledgments_obey_count_and_byte_limits_and_retries_deduplicate() {
    let runtime = RtBuilder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        // Each case makes a different configured bound the limiting factor.
        // Suppress real broker ACKs, observe stored records independently, then
        // restore ACKs so ambiguous retries exercise JetStream deduplication.
        for (count_limit, byte_limit, expected_pending) in [(2, 1024, 2), (8, 256, 2), (1, 1024, 1)]
        {
            let mut broker = Broker::start();
            let js = broker.connect().await;
            let mut stream = js
                .create_stream(jetstream::stream::Config {
                    name: "SYNTHETIC_LOGS".into(),
                    subjects: vec!["synthetic.logs".into()],
                    no_ack: true,
                    duplicate_window: Duration::from_secs(120),
                    ..Default::default()
                })
                .await
                .unwrap();
            let (worker, tx) = worker(&broker.url, count_limit, byte_limit);
            for sequence in 0..6 {
                let mut payload = vec![b'x'; 128];
                payload[0] = b'a' + sequence;
                tx.send(payload).unwrap();
            }
            drop(tx);
            let publishing = tokio::spawn(worker.run());
            timeout(Duration::from_secs(5), async {
                loop {
                    let stored = stream.info().await.unwrap().state.messages;
                    assert!(
                        stored <= expected_pending,
                        "publisher exceeded its pending ACK budget"
                    );
                    if stored == expected_pending {
                        break;
                    }
                    assert!(
                        !publishing.is_finished(),
                        "publisher exited before filling its window"
                    );
                    sleep(Duration::from_millis(10)).await;
                }
            })
            .await
            .expect("publisher did not fill its available ACK window");
            sleep(Duration::from_millis(75)).await;
            assert_eq!(
                stream.info().await.unwrap().state.messages,
                expected_pending
            );
            assert!(
                !publishing.is_finished(),
                "queue closure must drain outstanding ACKs"
            );

            let mut config = stream.info().await.unwrap().config.clone();
            config.no_ack = false;
            js.update_stream(config).await.unwrap();
            timeout(Duration::from_secs(5), publishing)
                .await
                .expect("publisher failed to drain after ACKs were restored")
                .unwrap()
                .unwrap();
            assert_eq!(
                stream.info().await.unwrap().state.messages,
                6,
                "ambiguous retries must not store duplicate records"
            );
            let mut payloads = std::collections::BTreeSet::new();
            let mut message_ids = std::collections::BTreeSet::new();
            for sequence in 1..=6 {
                let record = stream.get_raw_message(sequence).await.unwrap();
                payloads.insert(record.payload.to_vec());
                message_ids.insert(record.headers.get("Nats-Msg-Id").unwrap().to_string());
            }
            let expected: std::collections::BTreeSet<_> = (0..6)
                .map(|sequence| {
                    let mut payload = vec![b'x'; 128];
                    payload[0] = b'a' + sequence;
                    payload
                })
                .collect();
            assert_eq!(payloads, expected);
            assert_eq!(message_ids.len(), 6);
        }
    });
}

#[test]
fn record_larger_than_publish_byte_budget_fails_without_publishing() {
    let runtime = RtBuilder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let mut broker = Broker::start();
        let js = broker.connect().await;
        let (worker, tx) = worker(&broker.url, 2, 128);
        tx.send(vec![b'x'; 129]).unwrap();
        drop(tx);
        let error = timeout(Duration::from_secs(5), worker.run())
            .await
            .unwrap()
            .unwrap_err();
        assert!(
            error.contains("exceeding output.nats_max_inflight_bytes=128"),
            "{error}"
        );
        let mut stream = js.get_stream("SYNTHETIC_LOGS").await.unwrap();
        assert_eq!(stream.info().await.unwrap().state.messages, 0);
    });
}

#[test]
fn records_failing_together_share_one_replacement_connection() {
    const PENDING: u64 = 8;
    let runtime = RtBuilder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let mut broker = Broker::start();
        let js = broker.connect().await;
        // The broker stores each record but withholds its ACK, so every pending
        // record reaches its ACK timeout on the same connection.
        let mut stream = js
            .create_stream(jetstream::stream::Config {
                name: "SYNTHETIC_LOGS".into(),
                subjects: vec!["synthetic.logs".into()],
                no_ack: true,
                duplicate_window: Duration::from_secs(120),
                ..Default::default()
            })
            .await
            .unwrap();
        let before = broker.next_client_id().await;
        let (worker, tx) = worker_with(&broker.url, PENDING as usize, 1024 * 1024, 1_000, "");
        for sequence in 0..PENDING as u8 {
            tx.send(vec![b'a' + sequence; 64]).unwrap();
        }
        drop(tx);
        let publishing = tokio::spawn(worker.run());
        timeout(Duration::from_secs(5), async {
            while stream.info().await.unwrap().state.messages < PENDING {
                assert!(
                    !publishing.is_finished(),
                    "publisher exited before its records were pending"
                );
                sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("publisher did not send every admitted record");

        // Restore ACKs before the first timeout. The original attempts stay
        // unacknowledged; the retries are acknowledged as duplicates.
        let mut config = stream.info().await.unwrap().config.clone();
        config.no_ack = false;
        js.update_stream(config).await.unwrap();
        timeout(Duration::from_secs(10), publishing)
            .await
            .expect("publisher failed to drain after ACKs were restored")
            .unwrap()
            .unwrap();

        let replacements = broker.next_client_id().await - before - 2;
        assert!(
            replacements >= 1,
            "the ACK timeouts never replaced the publisher connection"
        );
        assert!(
            replacements < PENDING,
            "{replacements} replacement connections for {PENDING} records that failed together"
        );
        assert_eq!(stream.info().await.unwrap().state.messages, PENDING);
    });
}

#[test]
fn certificate_policy_without_managed_tls_inputs_fails_closed() {
    let runtime = RtBuilder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        // The broker accepts plain connections, so only the configured policy
        // can keep this record from being published.
        let mut broker = Broker::start();
        let js = broker.connect().await;
        let (worker, tx) = worker_with(
            &broker.url,
            2,
            1024,
            250,
            r#"nats_cert_policy_file = "/synthetic/absent/nats-policy.json""#,
        );
        tx.send(vec![b'x'; 64]).unwrap();
        drop(tx);
        let error = timeout(Duration::from_secs(5), worker.run())
            .await
            .unwrap()
            .unwrap_err();
        assert!(
            error.contains("NATS initial connection failed")
                && error.contains("managed NATS TLS requires a CA file"),
            "{error}"
        );
        assert!(
            js.get_stream("SYNTHETIC_LOGS").await.is_err(),
            "an unmanaged connection reached the broker"
        );
    });
}
