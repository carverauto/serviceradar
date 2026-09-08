//! Shared rustls helpers for the TLS input/output.
//!
//! Replaces the former OpenSSL usage (`SslAcceptor`/`SslConnector`) with a pure-Rust
//! rustls stack using the `ring` crypto provider, so flowgger no longer links libssl
//! and builds identically across platforms. Cipher lists, DH parameters, and
//! compression toggles from the old OpenSSL config are dropped in favour of rustls'
//! safe defaults (TLS 1.2 + 1.3, AEAD suites, ECDHE) — those OpenSSL-specific knobs
//! have no rustls equivalent and only ever weakened the configuration.

use std::fs::File;
use std::io::BufReader;
use std::path::Path;
use std::sync::Arc;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{CryptoProvider, ring, verify_tls12_signature, verify_tls13_signature};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, RootCertStore, SignatureScheme};

/// A fresh `ring`-backed crypto provider. Cheap to build; call once per config.
pub(crate) fn provider() -> Arc<CryptoProvider> {
    Arc::new(ring::default_provider())
}

/// Load a PEM certificate chain.
pub(crate) fn load_certs(path: &Path) -> Vec<CertificateDer<'static>> {
    let mut reader =
        BufReader::new(File::open(path).unwrap_or_else(|e| {
            panic!("Unable to open the TLS certificate {}: {e}", path.display())
        }));
    rustls_pemfile::certs(&mut reader)
        .collect::<Result<Vec<_>, _>>()
        .unwrap_or_else(|e| panic!("Unable to read the TLS certificate {}: {e}", path.display()))
}

/// Load the first PEM private key (PKCS#8, PKCS#1 or SEC1).
pub(crate) fn load_private_key(path: &Path) -> PrivateKeyDer<'static> {
    let mut reader = BufReader::new(
        File::open(path)
            .unwrap_or_else(|e| panic!("Unable to open the TLS key {}: {e}", path.display())),
    );
    rustls_pemfile::private_key(&mut reader)
        .unwrap_or_else(|e| panic!("Unable to read the TLS key {}: {e}", path.display()))
        .unwrap_or_else(|| panic!("No private key found in {}", path.display()))
}

/// Build a root store from a PEM CA bundle.
pub(crate) fn load_root_store(ca_file: &Path) -> RootCertStore {
    let mut roots = RootCertStore::empty();
    for cert in load_certs(ca_file) {
        roots
            .add(cert)
            .unwrap_or_else(|e| panic!("Invalid CA certificate in {}: {e}", ca_file.display()));
    }
    roots
}

/// Server-certificate verifier that accepts any certificate, preserving the old
/// `tls_verify_peer = false` behaviour (`SslVerifyMode::NONE`). Signature checks are
/// still delegated to the crypto provider so the handshake itself stays well-formed.
#[derive(Debug)]
pub(crate) struct AcceptAnyServerCert {
    provider: Arc<CryptoProvider>,
}

impl AcceptAnyServerCert {
    pub(crate) fn new(provider: Arc<CryptoProvider>) -> Self {
        Self { provider }
    }
}

impl ServerCertVerifier for AcceptAnyServerCert {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}
