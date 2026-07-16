#![doc = include_str!("../README.md")]
#![forbid(rust_2018_idioms)]
#![forbid(missing_docs, unsafe_code)]
#![warn(clippy::all, clippy::pedantic)]

use std::sync::Arc;

use rustls::ClientConfig;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_postgres::tls::MakeTlsConnect;

mod private {
    use std::{
        convert::TryFrom,
        future::Future,
        io,
        pin::Pin,
        task::{Context, Poll},
    };

    use rustls::pki_types::ServerName;
    use sha2::{Digest, Sha256, Sha384, Sha512};
    use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
    use tokio_postgres::tls::{ChannelBinding, TlsConnect};
    use tokio_rustls::{TlsConnector, client::TlsStream};
    use x509_cert::der::oid::db::rfc5912::{
        ECDSA_WITH_SHA_256, ECDSA_WITH_SHA_384, ID_SHA_1, ID_SHA_256, ID_SHA_384, ID_SHA_512,
        SHA_1_WITH_RSA_ENCRYPTION, SHA_256_WITH_RSA_ENCRYPTION, SHA_384_WITH_RSA_ENCRYPTION,
        SHA_512_WITH_RSA_ENCRYPTION,
    };
    use x509_cert::{Certificate, der::Decode, der::oid::ObjectIdentifier};

    pub enum TlsConnectFuture<S> {
        Connect(Box<tokio_rustls::Connect<S>>),
        Error(Option<io::Error>),
    }

    impl<S> Future for TlsConnectFuture<S>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        type Output = io::Result<RustlsStream<S>>;

        fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
            match &mut *self {
                Self::Connect(inner) => Pin::new(inner.as_mut()).poll(cx).map_ok(RustlsStream),
                Self::Error(error) => Poll::Ready(Err(error
                    .take()
                    .expect("TlsConnectFuture polled after completion"))),
            }
        }
    }

    pub struct RustlsConnect(pub RustlsConnectData);

    pub struct RustlsConnectData {
        pub hostname: String,
        pub connector: TlsConnector,
    }

    impl<S> TlsConnect<S> for RustlsConnect
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        type Stream = RustlsStream<S>;
        type Error = io::Error;
        type Future = TlsConnectFuture<S>;

        fn connect(self, stream: S) -> Self::Future {
            match ServerName::try_from(self.0.hostname) {
                Ok(hostname) => {
                    TlsConnectFuture::Connect(Box::new(self.0.connector.connect(hostname, stream)))
                }
                Err(error) => TlsConnectFuture::Error(Some(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    error,
                ))),
            }
        }
    }

    pub struct RustlsStream<S>(TlsStream<S>);

    pub(super) enum ChannelBindingDigest {
        Sha256,
        Sha384,
        Sha512,
    }

    impl ChannelBindingDigest {
        pub(super) fn digest(&self, data: &[u8]) -> Vec<u8> {
            match self {
                Self::Sha256 => Sha256::digest(data).to_vec(),
                Self::Sha384 => Sha384::digest(data).to_vec(),
                Self::Sha512 => Sha512::digest(data).to_vec(),
            }
        }

        #[cfg(test)]
        pub(super) fn output_len(&self) -> usize {
            match self {
                Self::Sha256 => 32,
                Self::Sha384 => 48,
                Self::Sha512 => 64,
            }
        }
    }

    pub(super) fn channel_binding_digest(
        signature_algorithm: ObjectIdentifier,
    ) -> Option<ChannelBindingDigest> {
        match signature_algorithm {
            // Note: SHA1 is upgraded to SHA256 as per https://datatracker.ietf.org/doc/html/rfc5929#section-4.1
            ID_SHA_1
            | ID_SHA_256
            | SHA_1_WITH_RSA_ENCRYPTION
            | SHA_256_WITH_RSA_ENCRYPTION
            | ECDSA_WITH_SHA_256 => Some(ChannelBindingDigest::Sha256),
            ID_SHA_384 | SHA_384_WITH_RSA_ENCRYPTION | ECDSA_WITH_SHA_384 => {
                Some(ChannelBindingDigest::Sha384)
            }
            ID_SHA_512 | SHA_512_WITH_RSA_ENCRYPTION => Some(ChannelBindingDigest::Sha512),
            // Unsupported algorithms, including pure signature algorithms like Ed25519, have no
            // digest to use for tls-server-end-point channel binding.
            _ => None,
        }
    }

    impl<S> tokio_postgres::tls::TlsStream for RustlsStream<S>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        fn channel_binding(&self) -> ChannelBinding {
            let (_, session) = self.0.get_ref();
            match session.peer_certificates() {
                Some(certs) if !certs.is_empty() => Certificate::from_der(&certs[0])
                    .ok()
                    .and_then(|cert| channel_binding_digest(cert.signature_algorithm.oid))
                    .map_or_else(ChannelBinding::none, |algorithm| {
                        ChannelBinding::tls_server_end_point(algorithm.digest(certs[0].as_ref()))
                    }),
                _ => ChannelBinding::none(),
            }
        }
    }

    impl<S> AsyncRead for RustlsStream<S>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        fn poll_read(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<tokio::io::Result<()>> {
            Pin::new(&mut self.0).poll_read(cx, buf)
        }
    }

    impl<S> AsyncWrite for RustlsStream<S>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        fn poll_write(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &[u8],
        ) -> Poll<tokio::io::Result<usize>> {
            Pin::new(&mut self.0).poll_write(cx, buf)
        }

        fn poll_flush(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
        ) -> Poll<tokio::io::Result<()>> {
            Pin::new(&mut self.0).poll_flush(cx)
        }

        fn poll_shutdown(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
        ) -> Poll<tokio::io::Result<()>> {
            Pin::new(&mut self.0).poll_shutdown(cx)
        }
    }
}

/// A `MakeTlsConnect` implementation using `rustls`.
///
/// That way you can connect to PostgreSQL using `rustls` as the TLS stack.
#[derive(Clone)]
pub struct MakeRustlsConnect {
    config: Arc<ClientConfig>,
}

impl MakeRustlsConnect {
    /// Creates a new `MakeRustlsConnect` from the provided `ClientConfig`.
    #[must_use]
    pub fn new(config: ClientConfig) -> Self {
        Self {
            config: Arc::new(config),
        }
    }

    #[cfg(any(feature = "native-certs", feature = "webpki-roots"))]
    fn from_root_certificates(roots: rustls::RootCertStore) -> Self {
        Self::new(
            ClientConfig::builder()
                .with_root_certificates(roots)
                .with_no_client_auth(),
        )
    }

    /// Creates a new `MakeRustlsConnect` using the Mozilla roots from `webpki-roots`.
    ///
    /// This uses rustls' process-level default crypto provider, so the application
    /// must install or otherwise configure a process-default provider before use.
    #[cfg(feature = "webpki-roots")]
    #[must_use]
    pub fn with_webpki_roots() -> Self {
        Self::from_root_certificates(rustls::RootCertStore {
            roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
        })
    }

    /// Creates a new `MakeRustlsConnect` using certificates from the platform's native store.
    ///
    /// This uses rustls' process-level default crypto provider, so the application
    /// must install or otherwise configure a process-default provider before use.
    ///
    /// Returns the connector and any errors reported while loading the native
    /// certificate store. If no certificates could be loaded, returns the
    /// reported errors instead.
    #[cfg(feature = "native-certs")]
    pub fn with_native_certs()
    -> Result<(Self, Vec<rustls_native_certs::Error>), Vec<rustls_native_certs::Error>> {
        let result = rustls_native_certs::load_native_certs();
        if !result.certs.is_empty() {
            let mut roots = rustls::RootCertStore::empty();
            roots.add_parsable_certificates(result.certs);
            Ok((Self::from_root_certificates(roots), result.errors))
        } else {
            Err(result.errors)
        }
    }
}

impl<S> MakeTlsConnect<S> for MakeRustlsConnect
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    type Stream = private::RustlsStream<S>;
    type TlsConnect = private::RustlsConnect;
    type Error = std::convert::Infallible;

    fn make_tls_connect(&mut self, hostname: &str) -> Result<Self::TlsConnect, Self::Error> {
        Ok(private::RustlsConnect(private::RustlsConnectData {
            hostname: hostname.to_owned(),
            connector: Arc::clone(&self.config).into(),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(any(feature = "aws-lc-rs", feature = "ring"))]
    use rustls::pki_types::{CertificateDer, UnixTime};
    #[cfg(any(feature = "aws-lc-rs", feature = "ring"))]
    use rustls::{
        Error, SignatureScheme,
        client::danger::ServerCertVerifier,
        client::danger::{HandshakeSignatureValid, ServerCertVerified},
        pki_types::ServerName,
    };
    #[cfg(any(feature = "aws-lc-rs", feature = "ring"))]
    use tokio::io::DuplexStream;
    use x509_cert::der::oid::db::{rfc5912::SHA_512_WITH_RSA_ENCRYPTION, rfc8410::ID_ED_25519};

    #[cfg(any(feature = "aws-lc-rs", feature = "ring"))]
    fn client_config_with_provider(
        provider: rustls::crypto::CryptoProvider,
    ) -> rustls::ClientConfig {
        rustls::ClientConfig::builder_with_provider(provider.into())
            .with_safe_default_protocol_versions()
            .expect("default protocol versions")
            .with_root_certificates(rustls::RootCertStore::empty())
            .with_no_client_auth()
    }

    #[cfg(feature = "aws-lc-rs")]
    fn aws_lc_rs_client_config() -> rustls::ClientConfig {
        client_config_with_provider(rustls::crypto::aws_lc_rs::default_provider())
    }

    #[cfg(feature = "ring")]
    fn ring_client_config() -> rustls::ClientConfig {
        client_config_with_provider(rustls::crypto::ring::default_provider())
    }

    #[cfg(any(feature = "aws-lc-rs", feature = "ring"))]
    #[derive(Debug)]
    struct AcceptAllVerifier {}

    #[cfg(any(feature = "aws-lc-rs", feature = "ring"))]
    impl ServerCertVerifier for AcceptAllVerifier {
        fn verify_server_cert(
            &self,
            _end_entity: &CertificateDer<'_>,
            _intermediates: &[CertificateDer<'_>],
            _server_name: &ServerName<'_>,
            _ocsp_response: &[u8],
            _now: UnixTime,
        ) -> Result<ServerCertVerified, Error> {
            Ok(ServerCertVerified::assertion())
        }

        fn verify_tls12_signature(
            &self,
            _message: &[u8],
            _cert: &CertificateDer<'_>,
            _dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn verify_tls13_signature(
            &self,
            _message: &[u8],
            _cert: &CertificateDer<'_>,
            _dss: &rustls::DigitallySignedStruct,
        ) -> Result<rustls::client::danger::HandshakeSignatureValid, Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            vec![
                SignatureScheme::ECDSA_NISTP384_SHA384,
                SignatureScheme::ECDSA_NISTP256_SHA256,
                SignatureScheme::RSA_PSS_SHA512,
                SignatureScheme::RSA_PSS_SHA384,
                SignatureScheme::RSA_PSS_SHA256,
                SignatureScheme::ED25519,
            ]
        }
    }

    #[cfg(any(feature = "aws-lc-rs", feature = "ring"))]
    async fn connect_works(mut config: rustls::ClientConfig) {
        env_logger::builder().is_test(true).try_init().unwrap();

        config
            .dangerous()
            .set_certificate_verifier(Arc::new(AcceptAllVerifier {}));
        let tls = super::MakeRustlsConnect::new(config);
        let (client, conn) = tokio_postgres::connect(
            "sslmode=require host=localhost port=5432 user=postgres",
            tls,
        )
        .await
        .expect("connect");
        tokio::spawn(async move { conn.await.map_err(|e| panic!("{e:?}")) });
        let stmt = client.prepare("SELECT 1").await.expect("prepare");
        let _ = client.query(&stmt, &[]).await.expect("query");
    }

    #[cfg(feature = "aws-lc-rs")]
    #[tokio::test]
    async fn it_works_with_aws_lc_rs() {
        connect_works(aws_lc_rs_client_config()).await;
    }

    #[cfg(feature = "ring")]
    #[tokio::test]
    async fn it_works_with_ring() {
        connect_works(ring_client_config()).await;
    }

    #[cfg(any(feature = "aws-lc-rs", feature = "ring"))]
    fn accepts_unix_socket_hostname_before_tls_is_used(config: rustls::ClientConfig) {
        let mut tls = super::MakeRustlsConnect::new(config);

        let tls_connect =
            <super::MakeRustlsConnect as MakeTlsConnect<DuplexStream>>::make_tls_connect(
                &mut tls,
                "/var/run/postgresql",
            );

        assert!(tls_connect.is_ok());
    }

    #[cfg(feature = "aws-lc-rs")]
    #[test]
    fn accepts_unix_socket_hostname_before_tls_is_used_with_aws_lc_rs() {
        accepts_unix_socket_hostname_before_tls_is_used(aws_lc_rs_client_config());
    }

    #[cfg(feature = "ring")]
    #[test]
    fn accepts_unix_socket_hostname_before_tls_is_used_with_ring() {
        accepts_unix_socket_hostname_before_tls_is_used(ring_client_config());
    }

    #[test]
    fn ed25519_has_no_channel_binding_digest() {
        assert!(private::channel_binding_digest(ID_ED_25519).is_none());
    }

    #[test]
    fn sha512_with_rsa_has_channel_binding_digest() {
        let algorithm = private::channel_binding_digest(SHA_512_WITH_RSA_ENCRYPTION)
            .expect("SHA-512 signature algorithm should map to a digest");

        assert_eq!(algorithm.output_len(), 64);
    }
}
