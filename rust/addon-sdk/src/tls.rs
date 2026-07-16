/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//! AutoMTLS for the plugin (server) side.
//!
//! go-plugin's AutoMTLS (`server.go`, `mtls.go`, `client.go`) works like this:
//!
//! - The **host** generates a self-signed certificate and passes it to the
//!   plugin in the `PLUGIN_CLIENT_CERT` env var (PEM). It uses that same cert as
//!   its client identity and pins the plugin's returned cert as its only root.
//! - The **plugin** (this code) generates *its own* self-signed certificate,
//!   requires-and-verifies the host's client cert against the host cert, and
//!   emits the base64 (RawStdEncoding) DER of its leaf cert in the handshake
//!   line. The host pins that as its `RootCAs`/`ClientCAs` and dials with
//!   `ServerName = "localhost"`.
//!
//! ## Why a hand-built rustls `ServerConfig` (not tonic's `client_ca_root`)
//!
//! go-plugin's certs are self-signed CAs (ECDSA P-521, `IsCA: true`). The Go
//! TLS stack accepts such a cert as both a pinned trust anchor and the presented
//! leaf. rustls' default `WebPkiClientVerifier`, however, applies strict path
//! validation to the *client* cert and rejects the host's self-signed-CA client
//! cert during a TLS 1.3 gRPC handshake (the host then sees
//! `tls: certificate required`). To interoperate byte-for-byte with the
//! unmodified Go go-plugin client, we build the rustls `ServerConfig` ourselves
//! with a [`PinnedClientCertVerifier`] that requires a client cert and accepts
//! it iff its DER equals the exact `PLUGIN_CLIENT_CERT` the host advertised —
//! which is precisely the trust decision Go makes (`RequireAndVerifyClientCert`
//! with the host cert as the sole `ClientCAs`, self-signed). The server's own
//! cert is still a self-signed CA so the Go host's standard verifier accepts it.

use std::sync::Arc;

use base64::Engine as _;
use rcgen::{
    BasicConstraints, Certificate, CertificateParams, DistinguishedName, DnType,
    ExtendedKeyUsagePurpose, IsCa, KeyUsagePurpose, SanType,
};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, UnixTime};
use rustls::server::WebPkiClientVerifier;
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{DigitallySignedStruct, DistinguishedName as RustlsDn, ServerConfig, SignatureScheme};

/// The AutoMTLS material the server needs to build its rustls `ServerConfig`.
pub struct ServerMtls {
    /// The server's own certificate DER (self-signed CA, single serialization).
    server_cert_der: Vec<u8>,
    /// The server's private key (PKCS#8 DER).
    server_key_der: Vec<u8>,
    /// The host's client certificate DER, parsed from `PLUGIN_CLIENT_CERT`.
    client_cert_der: Vec<u8>,
    /// base64 (RawStdEncoding / no padding) of the server leaf certificate DER,
    /// as the handshake line carries it. This is byte-identical to
    /// `server_cert_der`; the host pins it and then byte-compares the cert the
    /// server presents during the TLS handshake.
    pub server_cert_b64: String,
}

#[derive(Debug, thiserror::Error)]
pub enum MtlsError {
    #[error("failed to generate server certificate: {0}")]
    Generate(#[from] rcgen::Error),
    #[error("PLUGIN_CLIENT_CERT did not contain a PEM certificate")]
    NoClientCert,
    #[error("failed to parse client certificate PEM: {0}")]
    ClientCertParse(std::io::Error),
    #[error("failed to build rustls server config: {0}")]
    Rustls(#[from] rustls::Error),
}

impl ServerMtls {
    /// Builds the rustls `ServerConfig` the gRPC server serves with: the server
    /// identity plus the [`PinnedClientCertVerifier`] that mirrors Go's
    /// `RequireAndVerifyClientCert`-against-the-pinned-host-cert decision.
    pub fn server_config(&self) -> Result<Arc<ServerConfig>, MtlsError> {
        let cert_chain = vec![CertificateDer::from(self.server_cert_der.clone())];
        let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(self.server_key_der.clone()));

        let verifier = Arc::new(PinnedClientCertVerifier {
            pinned: CertificateDer::from(self.client_cert_der.clone()),
        });

        let mut config = ServerConfig::builder()
            .with_client_cert_verifier(verifier)
            .with_single_cert(cert_chain, key)?;
        // gRPC requires HTTP/2 (h2) ALPN.
        config.alpn_protocols = vec![b"h2".to_vec()];
        Ok(Arc::new(config))
    }
}

/// Builds the server-side AutoMTLS material from the host's client cert PEM.
///
/// `client_cert_pem` is the verbatim value of `PLUGIN_CLIENT_CERT`.
pub fn build_server_mtls(client_cert_pem: &str) -> Result<ServerMtls, MtlsError> {
    let (server_cert_der, server_key_der) = generate_localhost_cert()?;

    // RawStdEncoding == standard base64 alphabet, no padding (go-plugin uses
    // base64.RawStdEncoding so the value never contains '=' or newlines).
    let server_cert_b64 = base64::engine::general_purpose::STANDARD_NO_PAD.encode(&server_cert_der);

    let client_cert_der = parse_first_cert_der(client_cert_pem)?;

    Ok(ServerMtls {
        server_cert_der,
        server_key_der,
        client_cert_der,
        server_cert_b64,
    })
}

/// Parses the first PEM `CERTIFICATE` block into DER bytes.
fn parse_first_cert_der(pem: &str) -> Result<Vec<u8>, MtlsError> {
    let mut reader = std::io::BufReader::new(pem.as_bytes());
    let mut certs = rustls_pemfile::certs(&mut reader);
    match certs.next() {
        Some(item) => {
            let der = item.map_err(MtlsError::ClientCertParse)?;
            Ok(der.as_ref().to_vec())
        }
        None => Err(MtlsError::NoClientCert),
    }
}

/// Generates a self-signed `localhost` certificate matching go-plugin's
/// `generateCert` for *validation* purposes. Returns `(cert_der, pkcs8_key_der)`
/// from a SINGLE serialization (see the comment in the body for why that matters).
fn generate_localhost_cert() -> Result<(Vec<u8>, Vec<u8>), rcgen::Error> {
    let mut params = CertificateParams::new(vec!["localhost".to_string()]);

    let mut dn = DistinguishedName::new();
    dn.push(DnType::CommonName, "localhost");
    dn.push(DnType::OrganizationName, "ServiceRadar");
    params.distinguished_name = dn;

    params.subject_alt_names = vec![SanType::DnsName("localhost".to_string())];

    // Self-signed CA, exactly like go-plugin's `generateCert`. This is REQUIRED
    // for the real host: the agent's Go go-plugin client pins this single cert as
    // its sole `RootCAs` and presents it as the leaf, and Go's `crypto/x509`
    // verifier only accepts a pinned self-signed cert as a trust anchor when it
    // carries CA basic constraints (a `NoCa` leaf yields
    // "x509: certificate signed by unknown authority").
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);

    // Both EKUs: serverAuth so the host (acting as TLS client) accepts us;
    // clientAuth for symmetry with go-plugin's template.
    params.extended_key_usages = vec![
        ExtendedKeyUsagePurpose::ServerAuth,
        ExtendedKeyUsagePurpose::ClientAuth,
    ];
    params.key_usages = vec![
        KeyUsagePurpose::DigitalSignature,
        KeyUsagePurpose::KeyEncipherment,
        KeyUsagePurpose::KeyAgreement,
        KeyUsagePurpose::KeyCertSign,
    ];

    let cert = Certificate::from_params(params)?;

    // CRITICAL: serialize the certificate exactly ONCE. rcgen re-signs the
    // TBSCertificate on every `serialize_*` call, and ECDSA signatures are
    // randomized, so two separate serializations differ in their signature bytes
    // (identical body, different DER). The host pins the DER we advertise in the
    // handshake line and byte-compares the cert presented during the TLS
    // handshake; serving a *different* serialization yields
    // "x509: certificate signed by unknown authority". We therefore serialize the
    // DER once and serve exactly those bytes.
    let cert_der = cert.serialize_der()?;
    let key_der = cert.serialize_private_key_der();
    Ok((cert_der, key_der))
}

/// A rustls client-certificate verifier that mirrors go-plugin's AutoMTLS trust
/// decision: require a client cert and accept it iff its DER equals the exact
/// certificate the host advertised in `PLUGIN_CLIENT_CERT`.
///
/// This is the byte-pinning equivalent of Go's `RequireAndVerifyClientCert` with
/// the host cert as the sole `ClientCAs` (the host cert is self-signed, so "valid
/// chain to the pinned CA" reduces to "is the pinned cert"). It deliberately
/// sidesteps rustls' default `WebPkiClientVerifier`, whose strict path validation
/// rejects go-plugin's self-signed-CA client cert.
#[derive(Debug)]
struct PinnedClientCertVerifier {
    pinned: CertificateDer<'static>,
}

impl ClientCertVerifier for PinnedClientCertVerifier {
    fn root_hint_subjects(&self) -> &[RustlsDn] {
        // No CA hints; the host always sends its (only) client cert under
        // AutoMTLS regardless of hints.
        &[]
    }

    fn verify_client_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, rustls::Error> {
        if end_entity.as_ref() == self.pinned.as_ref() {
            Ok(ClientCertVerified::assertion())
        } else {
            Err(rustls::Error::General(
                "client certificate does not match the pinned PLUGIN_CLIENT_CERT".to_string(),
            ))
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        // Verify the handshake signature with the platform crypto provider, so
        // the client genuinely controls the pinned cert's private key (rejecting
        // a replayed certificate without the key).
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &rustls::crypto::aws_lc_rs::default_provider().signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::aws_lc_rs::default_provider().signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::aws_lc_rs::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

/// Keeps `WebPkiClientVerifier` referenced so an unused-import lint does not fire
/// if a future refactor reaches for it; it documents the rejected alternative.
#[allow(dead_code)]
fn _webpki_client_verifier_is_the_rejected_alternative() {
    let _ = std::any::type_name::<WebPkiClientVerifier>();
}

/// Decodes a base64 (RawStdEncoding) server-cert field, used by tests that play
/// the host role to confirm the handshake line is parseable.
pub fn decode_server_cert_b64(b64: &str) -> Result<Vec<u8>, base64::DecodeError> {
    base64::engine::general_purpose::STANDARD_NO_PAD.decode(b64)
}
