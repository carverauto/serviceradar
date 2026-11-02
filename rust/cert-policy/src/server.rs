//! Tonic incoming transport with strict peer policy and owned socket shutdown.

use crate::{Store, VerifiedPeer, fingerprint, read_privileged_json};
use futures::{Stream, StreamExt};
use rustls::client::danger::HandshakeSignatureValid;
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, UnixTime};
use rustls::server::WebPkiClientVerifier;
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{
    DigitallySignedStruct, DistinguishedName, RootCertStore, ServerConfig, SignatureScheme,
};
use std::io;
use std::net::{Shutdown, SocketAddr};
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;
use tokio_rustls::{TlsAcceptor, server::TlsStream};
use tokio_stream::wrappers::TcpListenerStream;
use tonic::transport::server::{Connected, TcpConnectInfo, TlsConnectInfo};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[derive(Clone, Debug)]
pub struct Config {
    pub policy_file: PathBuf,
    pub ca_file: PathBuf,
    pub cert_file: PathBuf,
    pub key_file: PathBuf,
}

impl Config {
    /// Managed listeners always require fresh policy and client certificates.
    pub async fn bind(&self, address: SocketAddr) -> Result<Incoming> {
        let store = Arc::new(Store::default());
        store.apply(read_privileged_json(&self.policy_file)?)?;
        let tls = tls_config(self, store.clone())?;
        let listener = TcpListener::bind(address).await?;
        let mut incoming = Incoming::new(listener, tls, store.clone())?;
        let path = self.policy_file.clone();
        incoming.file_watcher = Some(tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_millis(250));
            loop {
                interval.tick().await;
                if let Err(error) = read_privileged_json(&path)
                    .and_then(|snapshot| store.apply(snapshot).map_err(Into::into))
                {
                    tracing::debug!(%error, "managed gRPC policy refresh rejected");
                }
            }
        }));
        Ok(incoming)
    }
}

fn tls_config(config: &Config, store: Arc<Store>) -> Result<ServerConfig> {
    let mut roots = RootCertStore::empty();
    for cert in CertificateDer::pem_file_iter(&config.ca_file)? {
        roots.add(cert?)?;
    }
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let verifier =
        WebPkiClientVerifier::builder_with_provider(Arc::new(roots), provider.clone()).build()?;
    let certificates = CertificateDer::pem_file_iter(&config.cert_file)?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let key = PrivateKeyDer::from_pem_file(&config.key_file)?;
    let mut tls = ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()?
        .with_client_cert_verifier(Arc::new(ClientPolicyVerifier { verifier, store }))
        .with_single_cert(certificates, key)?;
    tls.alpn_protocols = vec![b"h2".to_vec()];
    tls.session_storage = Arc::new(rustls::server::NoServerSessionStorage {});
    tls.send_tls13_tickets = 0;
    Ok(tls)
}

#[derive(Debug)]
struct ClientPolicyVerifier {
    verifier: Arc<dyn ClientCertVerifier>,
    store: Arc<Store>,
}

impl ClientCertVerifier for ClientPolicyVerifier {
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        self.verifier.root_hint_subjects()
    }
    fn verify_client_cert(
        &self,
        cert: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        now: UnixTime,
    ) -> std::result::Result<ClientCertVerified, rustls::Error> {
        let verified = self.verifier.verify_client_cert(cert, intermediates, now)?;
        self.store
            .authorize(&fingerprint(cert))
            .map_err(|error| rustls::Error::General(error.to_string()))?;
        Ok(verified)
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        self.verifier
            .verify_tls12_signature(message, cert, signature)
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        self.verifier
            .verify_tls13_signature(message, cert, signature)
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.verifier.supported_verify_schemes()
    }
}

/// Keeps policy reload alive while Tonic owns the incoming listener.
pub struct Incoming {
    address: SocketAddr,
    streams: Pin<Box<dyn Stream<Item = io::Result<PolicyTlsStream>> + Send>>,
    file_watcher: Option<JoinHandle<()>>,
}

impl Incoming {
    fn new(listener: TcpListener, tls: ServerConfig, store: Arc<Store>) -> io::Result<Self> {
        let address = listener.local_addr()?;
        let acceptor = TlsAcceptor::from(Arc::new(tls));
        // Concurrent bounded handshakes prevent one stalled TLS peer from
        // blocking other clients before Tonic receives their accepted sockets.
        let streams = TcpListenerStream::new(listener)
            .map(move |accepted| {
                let acceptor = acceptor.clone();
                let store = store.clone();
                async move {
                    let tcp = accepted?.into_std()?;
                    let close = Arc::new(tcp.try_clone()?);
                    let tcp = TcpStream::from_std(tcp)?;
                    let stream = tokio::time::timeout(Duration::from_secs(5), acceptor.accept(tcp))
                        .await
                        .map_err(|_| {
                            io::Error::new(
                                io::ErrorKind::TimedOut,
                                "managed TLS handshake timed out",
                            )
                        })??;
                    let certs = stream
                        .get_ref()
                        .1
                        .peer_certificates()
                        .filter(|certs| !certs.is_empty())
                        .ok_or_else(|| {
                            io::Error::new(
                                io::ErrorKind::PermissionDenied,
                                "client certificate required",
                            )
                        })?;
                    let peer = VerifiedPeer::from_certificates(&certs[0], &certs[1..], None)
                        .map_err(io::Error::other)?;
                    let mut changes = store.subscribe();
                    store.authorize_peer(&peer).map_err(io::Error::other)?;
                    let close_task = close.clone();
                    let guard = tokio::spawn(async move {
                        let mut interval = tokio::time::interval(Duration::from_millis(250));
                        loop {
                            tokio::select! {
                                _ = interval.tick() => {},
                                _ = changes.changed() => {},
                            }
                            if store.authorize_peer(&peer).is_err() {
                                match close_task.shutdown(Shutdown::Both) {
                                    Ok(()) => break,
                                    Err(error) if error.kind() == io::ErrorKind::NotConnected => break,
                                    Err(error) => tracing::error!(%error, "managed gRPC peer shutdown failed; retrying"),
                                }
                            }
                        }
                    });
                    Ok(PolicyTlsStream {
                        stream,
                        close,
                        guard,
                    })
                }
            })
            .buffer_unordered(64);
        Ok(Self {
            address,
            streams: Box::pin(streams),
            file_watcher: None,
        })
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.address
    }
}

impl Stream for Incoming {
    type Item = io::Result<PolicyTlsStream>;
    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        self.streams.as_mut().poll_next(cx)
    }
}

impl Drop for Incoming {
    fn drop(&mut self) {
        if let Some(task) = &self.file_watcher {
            task.abort();
        }
    }
}

/// The duplicate descriptor shares the exact accepted socket; shutdown closes
/// existing HTTP/2 streams even if they are not polling a policy-aware handler.
pub struct PolicyTlsStream {
    stream: TlsStream<TcpStream>,
    close: Arc<std::net::TcpStream>,
    guard: JoinHandle<()>,
}

impl Connected for PolicyTlsStream {
    type ConnectInfo = TlsConnectInfo<TcpConnectInfo>;
    fn connect_info(&self) -> Self::ConnectInfo {
        self.stream.connect_info()
    }
}

impl AsyncRead for PolicyTlsStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stream).poll_read(cx, buffer)
    }
}

impl AsyncWrite for PolicyTlsStream {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.stream).poll_write(cx, bytes)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stream).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stream).poll_shutdown(cx)
    }
}

impl Drop for PolicyTlsStream {
    fn drop(&mut self) {
        self.guard.abort();
        let _ = self.close.shutdown(Shutdown::Both);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Snapshot;
    use chrono::{Duration as ChronoDuration, Utc};
    use rcgen::{BasicConstraints, Certificate, CertificateParams, IsCa};
    use tonic::transport::{Channel, ClientTlsConfig, Endpoint, Identity, Server};
    use tonic_health::pb::{HealthCheckRequest, HealthCheckResponse, health_client::HealthClient};

    fn apply(store: &Store, seconds: i64, allowed: &[String]) {
        let generated_at = Utc::now();
        store
            .apply(Snapshot {
                version: 1,
                generated_at,
                valid_until: generated_at + ChronoDuration::seconds(seconds),
                allowed_fingerprints: allowed.to_vec(),
            })
            .unwrap();
    }

    async fn client(
        address: SocketAddr,
        ca: &Certificate,
        cert: &Certificate,
        signed_pem: &str,
    ) -> HealthClient<Channel> {
        let tls = ClientTlsConfig::new()
            .domain_name("localhost")
            .ca_certificate(tonic::transport::Certificate::from_pem(
                ca.serialize_pem().unwrap(),
            ))
            .identity(Identity::from_pem(
                signed_pem,
                cert.serialize_private_key_pem(),
            ));
        HealthClient::new(
            Endpoint::from_shared(format!("https://{address}"))
                .unwrap()
                .connect_timeout(Duration::from_secs(2))
                .tls_config(tls)
                .unwrap()
                .connect_lazy(),
        )
    }

    async fn watch(client: &mut HealthClient<Channel>) -> tonic::Streaming<HealthCheckResponse> {
        let mut stream = client
            .watch(HealthCheckRequest {
                service: "synthetic".into(),
            })
            .await
            .unwrap()
            .into_inner();
        assert_eq!(stream.message().await.unwrap().unwrap().status, 1);
        stream
    }

    async fn closed(stream: &mut tonic::Streaming<HealthCheckResponse>) {
        let result = tokio::time::timeout(Duration::from_secs(3), stream.message())
            .await
            .expect("revoked TLS socket must stop an already-open gRPC stream");
        assert!(
            matches!(result, Err(_) | Ok(None)),
            "unexpected message after revocation: {result:?}"
        );
    }

    #[tokio::test]
    async fn revokes_live_grpc_streams_without_disrupting_same_serial_control() {
        let mut params = CertificateParams::default();
        params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        let ca = Certificate::from_params(params).unwrap();
        let certificate = || {
            let mut params = CertificateParams::new(vec!["localhost".into()]);
            params.serial_number = Some(7_u64.into());
            Certificate::from_params(params).unwrap()
        };
        let server_cert = certificate();
        let a = certificate();
        let b = certificate();
        let a_pem = a.serialize_pem_with_signer(&ca).unwrap();
        let b_pem = b.serialize_pem_with_signer(&ca).unwrap();
        let fp_a = fingerprint(&CertificateDer::from_pem_slice(a_pem.as_bytes()).unwrap());
        let fp_b = fingerprint(&CertificateDer::from_pem_slice(b_pem.as_bytes()).unwrap());
        assert_ne!(fp_a, fp_b);
        let directory = tempfile::tempdir().unwrap();
        let config = Config {
            policy_file: directory.path().join("policy.json"),
            ca_file: directory.path().join("ca.pem"),
            cert_file: directory.path().join("server.pem"),
            key_file: directory.path().join("server-key.pem"),
        };
        std::fs::write(&config.ca_file, ca.serialize_pem().unwrap()).unwrap();
        std::fs::write(
            &config.cert_file,
            server_cert.serialize_pem_with_signer(&ca).unwrap(),
        )
        .unwrap();
        std::fs::write(&config.key_file, server_cert.serialize_private_key_pem()).unwrap();
        let mut other_params = CertificateParams::default();
        other_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        let other_ca = Certificate::from_params(other_params).unwrap();
        let untrusted = certificate();
        let untrusted_pem = untrusted.serialize_pem_with_signer(&other_ca).unwrap();
        let untrusted_fp =
            fingerprint(&CertificateDer::from_pem_slice(untrusted_pem.as_bytes()).unwrap());
        let store = Arc::new(Store::default());
        apply(&store, 20, &[fp_a.clone(), fp_b.clone(), untrusted_fp]);
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let incoming = Incoming::new(
            listener,
            tls_config(&config, store.clone()).unwrap(),
            store.clone(),
        )
        .unwrap();
        let address = incoming.local_addr();
        let (reporter, health) = tonic_health::server::health_reporter();
        reporter
            .set_service_status("synthetic", tonic_health::ServingStatus::Serving)
            .await;
        let server = tokio::spawn(
            Server::builder()
                .add_service(health)
                .serve_with_incoming(incoming),
        );
        // Allowlisting a fingerprint must not bypass ordinary issuer validation.
        let mut untrusted_client = client(address, &ca, &untrusted, &untrusted_pem).await;
        assert!(
            tokio::time::timeout(
                Duration::from_secs(3),
                untrusted_client.check(HealthCheckRequest {
                    service: "synthetic".into()
                })
            )
            .await
            .expect("untrusted issuer handshake must finish")
            .is_err()
        );
        let mut client_a = client(address, &ca, &a, &a_pem).await;
        let mut client_b = client(address, &ca, &b, &b_pem).await;
        let mut stream_a = watch(&mut client_a).await;
        let mut stream_b = watch(&mut client_b).await;

        apply(&store, 20, std::slice::from_ref(&fp_b));
        closed(&mut stream_a).await;
        reporter
            .set_service_status("synthetic", tonic_health::ServingStatus::NotServing)
            .await;
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(2), stream_b.message())
                .await
                .unwrap()
                .unwrap()
                .unwrap()
                .status,
            2
        );
        let mut denied = client(address, &ca, &a, &a_pem).await;
        assert!(
            tokio::time::timeout(
                Duration::from_secs(3),
                denied.check(HealthCheckRequest {
                    service: "synthetic".into()
                })
            )
            .await
            .expect("rejected handshake must finish")
            .is_err()
        );

        apply(&store, 1, std::slice::from_ref(&fp_b));
        closed(&mut stream_b).await;
        apply(&store, 20, &[fp_a]);
        reporter
            .set_service_status("synthetic", tonic_health::ServingStatus::Serving)
            .await;
        let mut restored = client(address, &ca, &a, &a_pem).await;
        assert_eq!(
            restored
                .check(HealthCheckRequest {
                    service: "synthetic".into()
                })
                .await
                .unwrap()
                .into_inner()
                .status,
            1
        );
        server.abort();
    }
}
