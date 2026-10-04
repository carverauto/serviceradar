use crate::config::IpfixTlsConfig;
use crate::listener::{FlowHandler, FlowOutput};
use crate::netflow::NetflowHandler;
use anyhow::{Context, Result};
use rustls::server::{NoServerSessionStorage, WebPkiClientVerifier};
use rustls::{RootCertStore, ServerConfig};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::File;
use std::io::{self, BufReader};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::task::JoinSet;
use tokio::time::timeout;
use tokio_rustls::TlsAcceptor;

/// IPFIX templates belong to a single authenticated transport session (RFC 7011).
/// The listener owns every child task; dropping it cancels handshakes and parsers.
pub struct IpfixTlsListener {
    socket: TcpListener,
    config: Arc<IpfixTlsConfig>,
    acceptor: TlsAcceptor,
    exporter_limits: Arc<HashMap<String, Arc<Semaphore>>>,
    output: FlowOutput,
}

impl IpfixTlsListener {
    pub async fn bind(addr: &str, config: IpfixTlsConfig, output: FlowOutput) -> Result<Self> {
        config.validate()?;
        let acceptor = server_acceptor(&config)?;
        let mut exporter_limits = HashMap::new();
        for identity in config.exporters.values() {
            exporter_limits
                .entry(identity.clone())
                .or_insert_with(|| Arc::new(Semaphore::new(config.max_sessions_per_exporter)));
        }
        Ok(Self {
            socket: TcpListener::bind(addr).await?,
            config: Arc::new(config),
            acceptor,
            exporter_limits: Arc::new(exporter_limits),
            output,
        })
    }

    pub async fn run(self) -> Result<()> {
        let limit = Arc::new(Semaphore::new(self.config.max_sessions));
        let mut sessions = JoinSet::new();
        loop {
            // Completed tasks cannot accumulate while a busy listener accepts.
            while sessions.try_join_next().is_some() {}
            let accepted = tokio::select! {
                accepted = self.socket.accept() => accepted,
                _ = sessions.join_next(), if !sessions.is_empty() => continue,
            };
            let (stream, _) = match accepted {
                Ok(accepted) => accepted,
                Err(error) => {
                    log::warn!("IPFIX TLS accept failed: {error}");
                    tokio::time::sleep(Duration::from_millis(10)).await;
                    continue;
                }
            };
            let Ok(permit) = Arc::clone(&limit).try_acquire_owned() else {
                self.output
                    .metrics
                    .tls_session_limit_rejections
                    .fetch_add(1, Ordering::Relaxed);
                continue;
            };
            let config = Arc::clone(&self.config);
            let limits = Arc::clone(&self.exporter_limits);
            let output = self.output.clone();
            let acceptor = self.acceptor.clone();
            sessions.spawn(async move {
                receive_session(stream, acceptor, config, limits, output, permit).await;
            });
        }
    }
}

fn server_acceptor(config: &IpfixTlsConfig) -> Result<TlsAcceptor> {
    let certificates = rustls_pemfile::certs(&mut BufReader::new(File::open(&config.cert_file)?))
        .collect::<io::Result<Vec<_>>>()?;
    let key = rustls_pemfile::private_key(&mut BufReader::new(File::open(&config.key_file)?))?
        .context("IPFIX TLS server private key is missing")?;
    let mut roots = RootCertStore::empty();
    for cert in rustls_pemfile::certs(&mut BufReader::new(File::open(&config.client_ca_file)?)) {
        roots.add(cert?).context("invalid IPFIX client CA")?;
    }
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    // WebPkiClientVerifier requires a valid client chain and proof of private-key
    // possession. A trusted chain alone is insufficient; map the leaf below.
    let verifier =
        WebPkiClientVerifier::builder_with_provider(Arc::new(roots), Arc::clone(&provider))
            .build()?;
    let mut server = ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()?
        .with_client_cert_verifier(verifier)
        .with_single_cert(certificates, key)?;
    server.max_early_data_size = 0;
    server.send_tls13_tickets = 0;
    server.session_storage = Arc::new(NoServerSessionStorage {});
    Ok(TlsAcceptor::from(Arc::new(server)))
}

fn certificate_fingerprint(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

struct ActiveSession(Arc<crate::metrics::ListenerMetrics>);
impl Drop for ActiveSession {
    fn drop(&mut self) {
        self.0.tls_active_sessions.fetch_sub(1, Ordering::Relaxed);
    }
}

async fn receive_session(
    stream: TcpStream,
    acceptor: TlsAcceptor,
    config: Arc<IpfixTlsConfig>,
    limits: Arc<HashMap<String, Arc<Semaphore>>>,
    output: FlowOutput,
    _listener_permit: OwnedSemaphorePermit,
) {
    let Ok(peer) = stream.peer_addr() else {
        return;
    };
    let handshake = timeout(
        Duration::from_secs(config.handshake_timeout_secs),
        acceptor.accept(stream),
    )
    .await;
    let mut stream = match handshake {
        Ok(Ok(stream)) => stream,
        _ => {
            output
                .metrics
                .tls_auth_rejections
                .fetch_add(1, Ordering::Relaxed);
            return;
        }
    };
    let identity = stream
        .get_ref()
        .1
        .peer_certificates()
        .and_then(|certs| certs.first())
        .and_then(|leaf| {
            config
                .exporters
                .get(&certificate_fingerprint(leaf.as_ref()))
        });
    let Some(identity) = identity else {
        output
            .metrics
            .tls_auth_rejections
            .fetch_add(1, Ordering::Relaxed);
        return;
    };
    let Ok(_exporter_permit) = Arc::clone(&limits[identity]).try_acquire_owned() else {
        output
            .metrics
            .tls_session_limit_rejections
            .fetch_add(1, Ordering::Relaxed);
        return;
    };
    output
        .metrics
        .tls_authenticated_sessions
        .fetch_add(1, Ordering::Relaxed);
    output
        .metrics
        .tls_active_sessions
        .fetch_add(1, Ordering::Relaxed);
    let _active = ActiveSession(Arc::clone(&output.metrics));
    // Only now construct parser/sampler/pending state. No secondary store, no
    // retained state across reconnects, and no state shared by two identities.
    let handler = NetflowHandler::new(
        config.max_templates,
        config.pending_flows.as_ref(),
        Some(config.default_sampling_rate),
        HashMap::new(),
        Some(config.max_sources),
        Arc::clone(&output.metrics),
    );
    loop {
        let read = timeout(
            Duration::from_secs(config.read_timeout_secs),
            read_frame(&mut stream, config.max_message_size),
        )
        .await;
        match read {
            Ok(Ok(Some(frame))) => {
                output
                    .metrics
                    .packets_received
                    .fetch_add(1, Ordering::Relaxed);
                let messages = handler.parse_datagram(&frame, frame.len(), peer);
                if output.publish("ipfix_tls", messages).is_err() {
                    break;
                }
            }
            Ok(Ok(None)) => break,
            _ => {
                output
                    .metrics
                    .ipfix_frame_rejections
                    .fetch_add(1, Ordering::Relaxed);
                break;
            }
        }
    }
}

/// A single deadline in the caller covers both header and body, including idle
/// and partial-message stalls. Size is checked before allocating the payload.
async fn read_frame(
    stream: &mut (impl AsyncRead + Unpin),
    maximum: usize,
) -> io::Result<Option<Vec<u8>>> {
    let mut header = [0u8; 4];
    if stream.read(&mut header[..1]).await? == 0 {
        return Ok(None);
    }
    stream.read_exact(&mut header[1..]).await?;
    let version = u16::from_be_bytes([header[0], header[1]]);
    let length = usize::from(u16::from_be_bytes([header[2], header[3]]));
    if version != 10 || length < 16 || length > maximum {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid IPFIX TLS message header",
        ));
    }
    let mut frame = vec![0; length];
    frame[..4].copy_from_slice(&header);
    stream.read_exact(&mut frame[4..]).await?;
    Ok(Some(frame))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::flowpb::FlowMessage;
    use crate::host_slice::HostSliceRouter;
    use crate::metrics::{ListenerMetrics, SubjectDropRegistry};
    use crate::publisher::OutboundFlow;
    use prost::Message;
    use rustls::ClientConfig;
    use std::net::SocketAddr;
    use std::path::PathBuf;
    use std::sync::atomic::AtomicU64;
    use tokio::io::AsyncWriteExt;
    use tokio::sync::mpsc;
    use tokio::task::JoinHandle;
    use tokio_rustls::TlsConnector;
    use tokio_rustls::client::TlsStream;

    static FIXTURE_SEQUENCE: AtomicU64 = AtomicU64::new(0);
    struct Fixtures(PathBuf);
    impl Fixtures {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "ipfix-tls-test-{}-{}",
                std::process::id(),
                FIXTURE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir(&path).unwrap();
            // Entire PKI is invented afresh for this test; no committed private keys.
            let ca = generated_certificate("test-ca", None);
            let wrong_ca = generated_certificate("wrong-ca", None);
            std::fs::write(path.join("test-ca.pem"), ca.serialize_pem().unwrap()).unwrap();
            for (name, purpose, issuer) in [
                ("server", rcgen::ExtendedKeyUsagePurpose::ServerAuth, &ca),
                (
                    "exporter-a",
                    rcgen::ExtendedKeyUsagePurpose::ClientAuth,
                    &ca,
                ),
                (
                    "exporter-b",
                    rcgen::ExtendedKeyUsagePurpose::ClientAuth,
                    &ca,
                ),
                ("unlisted", rcgen::ExtendedKeyUsagePurpose::ClientAuth, &ca),
                (
                    "wrong-client",
                    rcgen::ExtendedKeyUsagePurpose::ClientAuth,
                    &wrong_ca,
                ),
            ] {
                let certificate = generated_certificate(name, Some(purpose));
                std::fs::write(
                    path.join(format!("{name}.pem")),
                    certificate.serialize_pem_with_signer(issuer).unwrap(),
                )
                .unwrap();
                std::fs::write(
                    path.join(format!("{name}-key.pem")),
                    certificate.serialize_private_key_pem(),
                )
                .unwrap();
            }
            Self(path)
        }
        fn path(&self, name: &str) -> PathBuf {
            self.0.join(format!("{name}.pem"))
        }
        fn certificates(&self, name: &str) -> Vec<rustls::pki_types::CertificateDer<'static>> {
            rustls_pemfile::certs(&mut BufReader::new(File::open(self.path(name)).unwrap()))
                .collect::<io::Result<Vec<_>>>()
                .unwrap()
        }
    }
    fn generated_certificate(
        name: &str,
        purpose: Option<rcgen::ExtendedKeyUsagePurpose>,
    ) -> rcgen::Certificate {
        let hostname = if name == "server" {
            "host01.example.com".into()
        } else {
            format!("{name}.example.com")
        };
        let mut params = rcgen::CertificateParams::new(vec![hostname]);
        params.distinguished_name = rcgen::DistinguishedName::new();
        params
            .distinguished_name
            .push(rcgen::DnType::CommonName, format!("{name}.example.com"));
        params.not_before = rcgen::date_time_ymd(2020, 1, 1);
        params.not_after = rcgen::date_time_ymd(2040, 1, 1);
        params.key_usages = vec![rcgen::KeyUsagePurpose::DigitalSignature];
        if let Some(purpose) = purpose {
            params.is_ca = rcgen::IsCa::ExplicitNoCa;
            params.extended_key_usages = vec![purpose];
        } else {
            params.is_ca = rcgen::IsCa::Ca(rcgen::BasicConstraints::Constrained(0));
            params.key_usages.push(rcgen::KeyUsagePurpose::KeyCertSign);
            params.key_usages.push(rcgen::KeyUsagePurpose::CrlSign);
        }
        rcgen::Certificate::from_params(params).unwrap()
    }

    impl Drop for Fixtures {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    struct Harness {
        fixtures: Fixtures,
        addr: SocketAddr,
        metrics: Arc<ListenerMetrics>,
        received: mpsc::Receiver<OutboundFlow>,
        task: JoinHandle<Result<()>>,
    }
    impl Harness {
        async fn start(change: impl FnOnce(&mut IpfixTlsConfig)) -> Self {
            let fixtures = Fixtures::new();
            let mut config: IpfixTlsConfig = serde_json::from_value(serde_json::json!({
                "cert_file": fixtures.path("server"), "key_file": fixtures.path("server-key"),
                "client_ca_file": fixtures.path("test-ca"), "read_timeout_secs": 3,
                "exporters": {
                    certificate_fingerprint(fixtures.certificates("exporter-a")[0].as_ref()): "exporter-a",
                    certificate_fingerprint(fixtures.certificates("exporter-b")[0].as_ref()): "exporter-b"
                }
            })).unwrap();
            change(&mut config);
            let metrics = Arc::new(ListenerMetrics::new("ipfix_tls", "127.0.0.1:0".into()));
            let (sender, received) = mpsc::channel(32);
            let output = FlowOutput::new(
                "flows.raw.ipfix".into(),
                Arc::new(HostSliceRouter::default()),
                sender,
                Arc::clone(&metrics),
                Arc::new(SubjectDropRegistry::new()),
            );
            let listener = IpfixTlsListener::bind("127.0.0.1:0", config, output)
                .await
                .unwrap();
            let addr = listener.socket.local_addr().unwrap();
            let task = tokio::spawn(listener.run());
            Self {
                fixtures,
                addr,
                metrics,
                received,
                task,
            }
        }
        async fn connect(&self, identity: Option<&str>) -> Result<TlsStream<TcpStream>> {
            let mut roots = RootCertStore::empty();
            roots.add(self.fixtures.certificates("test-ca")[0].clone())?;
            let builder = ClientConfig::builder_with_provider(Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_safe_default_protocol_versions()?
            .with_root_certificates(roots);
            let client = if let Some(name) = identity {
                let key = rustls_pemfile::private_key(&mut BufReader::new(File::open(
                    self.fixtures.path(&format!("{name}-key")),
                )?))?
                .unwrap();
                builder.with_client_auth_cert(self.fixtures.certificates(name), key)?
            } else {
                builder.with_no_client_auth()
            };
            let connector = TlsConnector::from(Arc::new(client));
            Ok(connector
                .connect(
                    "host01.example.com".try_into().unwrap(),
                    TcpStream::connect(self.addr).await?,
                )
                .await?)
        }
        async fn next(&mut self) -> FlowMessage {
            let (subject, bytes, _) = timeout(Duration::from_secs(3), self.received.recv())
                .await
                .expect("no published flow before deadline")
                .expect("publisher closed");
            assert_eq!(subject, "flows.raw.ipfix");
            FlowMessage::decode(bytes.as_slice()).unwrap()
        }
        async fn stop(&mut self) {
            self.task.abort();
            assert!((&mut self.task).await.as_ref().unwrap_err().is_cancelled());
            wait_for(|| self.metrics.tls_active_sessions.load(Ordering::Relaxed) == 0).await;
            assert_eq!(self.metrics.source_count.load(Ordering::Relaxed), 0);
        }
    }
    impl Drop for Harness {
        fn drop(&mut self) {
            self.task.abort();
        }
    }

    async fn wait_for(condition: impl Fn() -> bool) {
        timeout(Duration::from_secs(4), async {
            while !condition() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("collector state did not reach expected value before deadline");
    }

    use crate::test_packets::ipfix;

    #[tokio::test]
    async fn ingress_requires_valid_and_explicitly_approved_client_identity() {
        for identity in [
            None,
            Some("wrong-client"),
            Some("unlisted"),
            Some("plaintext"),
        ] {
            let mut server = Harness::start(|_| {}).await;
            if identity == Some("plaintext") {
                let mut stream = TcpStream::connect(server.addr).await.unwrap();
                stream
                    .write_all(&ipfix(1, Some(&[(1, 4)]), &111u32.to_be_bytes()))
                    .await
                    .unwrap();
            } else if let Ok(mut stream) = server.connect(identity).await {
                let _ = stream
                    .write_all(&ipfix(1, Some(&[(1, 4)]), &111u32.to_be_bytes()))
                    .await;
            }
            wait_for(|| server.metrics.tls_auth_rejections.load(Ordering::Relaxed) == 1).await;
            assert_eq!(
                server
                    .metrics
                    .tls_authenticated_sessions
                    .load(Ordering::Relaxed),
                0
            );
            assert_eq!(server.metrics.packets_received.load(Ordering::Relaxed), 0);
            assert_eq!(server.metrics.source_count.load(Ordering::Relaxed), 0);
            assert!(server.received.try_recv().is_err());
            // The identical message is accepted through the approved native TLS path.
            let mut approved = server.connect(Some("exporter-a")).await.unwrap();
            approved
                .write_all(&ipfix(1, Some(&[(1, 4)]), &111u32.to_be_bytes()))
                .await
                .unwrap();
            assert_eq!(server.next().await.bytes, 111);
            server.stop().await;
        }
    }

    #[tokio::test]
    async fn templates_domains_withdrawals_and_reconnects_are_session_local() {
        let mut server = Harness::start(|_| {}).await;
        let mut a = server.connect(Some("exporter-a")).await.unwrap();
        let mut b = server.connect(Some("exporter-b")).await.unwrap();
        a.write_all(&ipfix(1, Some(&[(1, 4)]), &111u32.to_be_bytes()))
            .await
            .unwrap();
        assert_eq!(server.next().await.bytes, 111);
        b.write_all(&ipfix(1, Some(&[(2, 4)]), &7u32.to_be_bytes()))
            .await
            .unwrap();
        assert_eq!(server.next().await.packets, 7);
        // Same template ID, same actual source IP, different authenticated session.
        a.write_all(&ipfix(1, None, &222u32.to_be_bytes()))
            .await
            .unwrap();
        assert_eq!(server.next().await.bytes, 222);
        // Unannounced observation domain cannot borrow this session's domain 1.
        a.write_all(&ipfix(2, None, &333u32.to_be_bytes()))
            .await
            .unwrap();
        a.write_all(&ipfix(1, None, &444u32.to_be_bytes()))
            .await
            .unwrap();
        assert_eq!(server.next().await.bytes, 444);
        // Withdrawal by B cannot remove A's template; B must reannounce its own.
        b.write_all(&ipfix(1, Some(&[]), &[])).await.unwrap();
        b.write_all(&ipfix(1, None, &8u32.to_be_bytes()))
            .await
            .unwrap();
        b.write_all(&ipfix(1, Some(&[(2, 4)]), &9u32.to_be_bytes()))
            .await
            .unwrap();
        assert_eq!(server.next().await.packets, 9);
        a.write_all(&ipfix(1, None, &555u32.to_be_bytes()))
            .await
            .unwrap();
        assert_eq!(server.next().await.bytes, 555);
        a.shutdown().await.unwrap();
        drop(a);
        b.shutdown().await.unwrap();
        drop(b);
        wait_for(|| server.metrics.tls_active_sessions.load(Ordering::Relaxed) == 0).await;
        assert_eq!(server.metrics.source_count.load(Ordering::Relaxed), 0);
        let mut reconnected = server.connect(Some("exporter-a")).await.unwrap();
        reconnected
            .write_all(&ipfix(1, None, &666u32.to_be_bytes()))
            .await
            .unwrap();
        reconnected
            .write_all(&ipfix(1, Some(&[(1, 4)]), &777u32.to_be_bytes()))
            .await
            .unwrap();
        assert_eq!(
            server.next().await.bytes,
            777,
            "reconnect restored a previous session template"
        );
        assert!(server.received.try_recv().is_err());
        server.stop().await;
    }

    #[tokio::test]
    async fn sampler_rates_are_not_shared_between_sessions() {
        let mut server = Harness::start(|c| c.max_sources = 2).await;
        let mut a = server.connect(Some("exporter-a")).await.unwrap();
        let mut b = server.connect(Some("exporter-b")).await.unwrap();
        let values: Vec<u8> = [1u32, 17, 111]
            .into_iter()
            .flat_map(u32::to_be_bytes)
            .collect();
        a.write_all(&ipfix(1, Some(&[(48, 4), (34, 4), (1, 4)]), &values))
            .await
            .unwrap();
        assert_eq!(server.next().await.sampling_rate, 17);
        let values: Vec<u8> = [1u32, 222].into_iter().flat_map(u32::to_be_bytes).collect();
        b.write_all(&ipfix(1, Some(&[(48, 4), (1, 4)]), &values))
            .await
            .unwrap();
        assert_eq!(server.next().await.sampling_rate, 1);
        a.write_all(&ipfix(2, Some(&[(48, 4), (1, 4)]), &values))
            .await
            .unwrap();
        assert_eq!(
            server.next().await.sampling_rate,
            1,
            "another observation domain's sampler rate leaked"
        );
        let domain_two: Vec<u8> = [1u32, 23, 333]
            .into_iter()
            .flat_map(u32::to_be_bytes)
            .collect();
        a.write_all(&ipfix(2, Some(&[(48, 4), (34, 4), (1, 4)]), &domain_two))
            .await
            .unwrap();
        assert_eq!(server.next().await.sampling_rate, 23);
        a.write_all(&ipfix(2, Some(&[(48, 4), (1, 4)]), &values))
            .await
            .unwrap();
        assert_eq!(server.next().await.sampling_rate, 23);
        a.write_all(&ipfix(1, Some(&[(48, 4), (1, 4)]), &values))
            .await
            .unwrap();
        assert_eq!(server.next().await.sampling_rate, 17);
        a.write_all(&ipfix(3, Some(&[(1, 4)]), &444u32.to_be_bytes()))
            .await
            .unwrap();
        assert_eq!(server.next().await.bytes, 444);
        a.write_all(&ipfix(2, Some(&[(48, 4), (1, 4)]), &values))
            .await
            .unwrap();
        assert_eq!(
            server.next().await.sampling_rate,
            1,
            "evicted domain retained sampler metadata"
        );
        server.stop().await;
    }

    #[tokio::test]
    async fn pending_records_replay_only_inside_the_owning_session() {
        let mut server = Harness::start(|c| {
            c.pending_flows = Some(serde_json::from_value(serde_json::json!({})).unwrap());
        })
        .await;
        let mut a = server.connect(Some("exporter-a")).await.unwrap();
        let mut b = server.connect(Some("exporter-b")).await.unwrap();
        b.write_all(&ipfix(1, None, &222u32.to_be_bytes()))
            .await
            .unwrap();
        // Fragment a legitimate message across writes; the TCP boundary is not
        // the IPFIX message boundary.
        let message = ipfix(1, Some(&[(1, 4)]), &111u32.to_be_bytes());
        for chunk in message.chunks(3) {
            a.write_all(chunk).await.unwrap();
        }
        assert_eq!(
            server.next().await.bytes,
            111,
            "another session's pending record was replayed"
        );
        b.write_all(&ipfix(1, Some(&[(1, 4)]), &333u32.to_be_bytes()))
            .await
            .unwrap();
        let mut replayed = vec![server.next().await.bytes, server.next().await.bytes];
        replayed.sort_unstable();
        assert_eq!(replayed, vec![222, 333]);
        // A missing template in a different domain must not survive reconnect.
        a.write_all(&ipfix(2, None, &444u32.to_be_bytes()))
            .await
            .unwrap();
        a.shutdown().await.unwrap();
        drop(a);
        b.shutdown().await.unwrap();
        drop(b);
        wait_for(|| server.metrics.tls_active_sessions.load(Ordering::Relaxed) == 0).await;
        let mut reconnect = server.connect(Some("exporter-a")).await.unwrap();
        let coalesced = [
            ipfix(2, Some(&[(1, 4)]), &555u32.to_be_bytes()),
            ipfix(2, None, &666u32.to_be_bytes()),
        ]
        .concat();
        reconnect.write_all(&coalesced).await.unwrap();
        assert_eq!(server.next().await.bytes, 555);
        assert_eq!(server.next().await.bytes, 666);
        assert!(server.received.try_recv().is_err());
        server.stop().await;
    }

    #[tokio::test]
    async fn invalid_partial_and_stalled_frames_close_authenticated_sessions() {
        for (bytes, close) in [
            (vec![0, 9, 0, 20], false),
            (vec![0, 10, 0, 15], false),
            (vec![0, 10, 1, 0], false),
            (vec![0, 10, 0, 20, 0], true),
            (vec![0, 10, 0, 20, 0], false),
        ] {
            let mut server = Harness::start(|c| {
                c.max_message_size = 128;
                c.read_timeout_secs = 1;
            })
            .await;
            let mut stream = server.connect(Some("exporter-a")).await.unwrap();
            stream.write_all(&bytes).await.unwrap();
            if close {
                stream.shutdown().await.unwrap();
            }
            wait_for(|| {
                server
                    .metrics
                    .ipfix_frame_rejections
                    .load(Ordering::Relaxed)
                    == 1
            })
            .await;
            assert_eq!(server.metrics.packets_received.load(Ordering::Relaxed), 0);
            assert_eq!(server.metrics.source_count.load(Ordering::Relaxed), 0);
            assert!(server.received.try_recv().is_err());
            server.stop().await;
        }
    }

    #[tokio::test]
    async fn connection_budgets_and_listener_cancellation_bound_session_lifetime() {
        let mut server = Harness::start(|c| {
            c.max_sessions = 1;
            c.max_sessions_per_exporter = 1;
            c.handshake_timeout_secs = 1;
        })
        .await;
        let held = TcpStream::connect(server.addr).await.unwrap();
        let second = TcpStream::connect(server.addr).await.unwrap();
        wait_for(|| {
            server
                .metrics
                .tls_session_limit_rejections
                .load(Ordering::Relaxed)
                == 1
        })
        .await;
        drop(second);
        wait_for(|| server.metrics.tls_auth_rejections.load(Ordering::Relaxed) == 1).await;
        drop(held);
        let mut approved = server.connect(Some("exporter-a")).await.unwrap();
        approved
            .write_all(&ipfix(1, Some(&[(1, 4)]), &111u32.to_be_bytes()))
            .await
            .unwrap();
        assert_eq!(server.next().await.bytes, 111);
        server.stop().await;
        let mut byte = [0u8; 1];
        let ended = timeout(Duration::from_secs(2), approved.read(&mut byte))
            .await
            .expect("cancelled listener retained a child session");
        assert!(ended.is_err() || ended.unwrap() == 0);

        let mut server = Harness::start(|c| {
            c.max_sessions = 3;
            c.max_sessions_per_exporter = 1;
        })
        .await;
        let mut a = server.connect(Some("exporter-a")).await.unwrap();
        wait_for(|| server.metrics.tls_active_sessions.load(Ordering::Relaxed) == 1).await;
        let mut duplicate = server.connect(Some("exporter-a")).await.unwrap();
        let _ = duplicate
            .write_all(&ipfix(1, Some(&[(1, 4)]), &999u32.to_be_bytes()))
            .await;
        wait_for(|| {
            server
                .metrics
                .tls_session_limit_rejections
                .load(Ordering::Relaxed)
                == 1
        })
        .await;
        let mut b = server.connect(Some("exporter-b")).await.unwrap();
        b.write_all(&ipfix(1, Some(&[(1, 4)]), &222u32.to_be_bytes()))
            .await
            .unwrap();
        assert_eq!(server.next().await.bytes, 222);
        a.write_all(&ipfix(1, Some(&[(1, 4)]), &333u32.to_be_bytes()))
            .await
            .unwrap();
        assert_eq!(server.next().await.bytes, 333);
        server.stop().await;
    }
}
