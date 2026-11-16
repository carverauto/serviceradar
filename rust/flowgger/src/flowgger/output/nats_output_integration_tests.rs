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
        Self::start_with::<&str>(&[])
    }

    fn start_with<A: AsRef<std::ffi::OsStr>>(extra: &[A]) -> Self {
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
            .args(extra)
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
        self.connect_with(ConnectOptions::new).await
    }

    async fn connect_with(&mut self, options: impl Fn() -> ConnectOptions) -> jetstream::Context {
        timeout(Duration::from_secs(5), async {
            loop {
                if let Some(status) = self.process.try_wait().unwrap() {
                    panic!("NATS test broker exited before becoming ready: {status}");
                }
                match options().connect(&self.url).await {
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

/// A directory the managed policy loader accepts: it and every parent owned by
/// root and writable by nobody else. Only root can create one.
#[cfg(unix)]
fn privileged_directory() -> Option<tempfile::TempDir> {
    use std::os::unix::fs::MetadataExt;
    let directory = tempfile::tempdir_in("/").ok()?;
    (std::fs::metadata(directory.path()).ok()?.uid() == 0).then_some(directory)
}

#[cfg(unix)]
fn write_policy(path: &std::path::Path, allowed_fingerprint: String) {
    let now = chrono::Utc::now();
    let snapshot = serviceradar_cert_policy::Snapshot {
        version: 1,
        generated_at: now,
        valid_until: now + chrono::Duration::seconds(30),
        allowed_fingerprints: vec![allowed_fingerprint],
    };
    // Rename into place so the publisher never reads a partial policy.
    let staged = path.with_extension("staged");
    std::fs::write(&staged, serde_json::to_vec(&snapshot).unwrap()).unwrap();
    std::fs::rename(staged, path).unwrap();
}

#[cfg(unix)]
#[test]
fn revoked_broker_certificate_fails_the_publisher_with_acknowledgments_pending() {
    use rcgen::{BasicConstraints, Certificate, CertificateParams, IsCa, SanType};
    use rustls::pki_types::{CertificateDer, pem::PemObject};

    let Some(privileged) = privileged_directory() else {
        // //rust/flowgger:flowgger_managed_policy_test runs this as root and sets
        // the variable, so the case cannot be skipped everywhere.
        assert!(
            std::env::var_os("FLOWGGER_REQUIRE_MANAGED_POLICY_TEST").is_none(),
            "the managed policy test must run as root"
        );
        eprintln!("skipped: a managed certificate policy file must be root-owned");
        return;
    };

    let mut authority = CertificateParams::default();
    authority.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    let authority = Certificate::from_params(authority).unwrap();
    let leaf = || {
        let mut params = CertificateParams::default();
        params.subject_alt_names = vec![SanType::IpAddress("127.0.0.1".parse().unwrap())];
        Certificate::from_params(params).unwrap()
    };
    let (broker_leaf, client_leaf) = (leaf(), leaf());
    // Signing is randomized: sign each leaf once and fingerprint that PEM.
    let broker_pem = broker_leaf.serialize_pem_with_signer(&authority).unwrap();
    let client_pem = client_leaf.serialize_pem_with_signer(&authority).unwrap();
    let fingerprint = |pem: &str| {
        serviceradar_cert_policy::fingerprint(
            &CertificateDer::from_pem_slice(pem.as_bytes()).unwrap(),
        )
    };
    let (broker_fingerprint, client_fingerprint) =
        (fingerprint(&broker_pem), fingerprint(&client_pem));

    let files = tempfile::tempdir().unwrap();
    let file = |name: &str, contents: String| {
        let path = files.path().join(name);
        std::fs::write(&path, contents).unwrap();
        path
    };
    let authority_file = file("ca.pem", authority.serialize_pem().unwrap());
    let broker_certificate = file("broker.pem", broker_pem);
    let broker_key = file("broker-key.pem", broker_leaf.serialize_private_key_pem());
    let client_certificate = file("client.pem", client_pem);
    let client_key = file("client-key.pem", client_leaf.serialize_private_key_pem());
    let policy = privileged.path().join("nats-policy.json");
    write_policy(&policy, broker_fingerprint);

    let runtime = RtBuilder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let mut broker = Broker::start_with(&[
            "--tls".as_ref(),
            "--tlscert".as_ref(),
            broker_certificate.as_os_str(),
            "--tlskey".as_ref(),
            broker_key.as_os_str(),
        ]);
        broker.url = broker.url.replace("nats://", "tls://");
        let js = broker
            .connect_with(|| {
                ConnectOptions::new()
                    .add_root_certificates(authority_file.clone())
                    .require_tls(true)
            })
            .await;
        // Records are stored but never acknowledged, so both stay pending.
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
        let (worker, tx) = worker_with(
            &broker.url,
            2,
            1024,
            500,
            &format!(
                "nats_tls_ca_file = {:?}\nnats_tls_cert = {:?}\nnats_tls_key = {:?}\nnats_cert_policy_file = {:?}",
                authority_file, client_certificate, client_key, policy
            ),
        );
        tx.send(vec![b'a'; 64]).unwrap();
        tx.send(vec![b'b'; 64]).unwrap();
        drop(tx);
        let publishing = tokio::spawn(worker.run());
        timeout(Duration::from_secs(10), async {
            while stream.info().await.unwrap().state.messages < 2 {
                assert!(
                    !publishing.is_finished(),
                    "publisher exited while its broker certificate was authorized"
                );
                sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("publisher did not send its records over the managed connection");

        // The policy stays fresh and valid; it no longer lists the broker.
        write_policy(&policy, client_fingerprint);
        let error = timeout(Duration::from_secs(20), publishing)
            .await
            .expect("publisher kept running after its broker certificate was revoked")
            .unwrap()
            .unwrap_err();
        assert!(
            error.contains("NATS reconnect failed while retaining pending records"),
            "{error}"
        );
        assert_eq!(stream.info().await.unwrap().state.messages, 2);
    });
}
