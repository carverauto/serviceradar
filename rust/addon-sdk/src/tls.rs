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

use std::sync::{Arc, OnceLock};

use base64::Engine as _;
use rcgen::{
    BasicConstraints, Certificate, CertificateParams, DistinguishedName, DnType,
    ExtendedKeyUsagePurpose, IsCa, KeyUsagePurpose, SanType,
};
use rustls::crypto::WebPkiSupportedAlgorithms;
use rustls::pki_types::{
    AlgorithmIdentifier, InvalidSignature, SignatureVerificationAlgorithm, alg_id,
};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, UnixTime};
use rustls::server::WebPkiClientVerifier;
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{DigitallySignedStruct, DistinguishedName as RustlsDn, ServerConfig, SignatureScheme};

/// ECDSA P-521 / SHA-512 signature verification, in pure Rust.
///
/// go-plugin's AutoMTLS hardcodes `ecdsa.GenerateKey(elliptic.P521(), ...)`
/// (`go-plugin/mtls.go`), so P-521 is the ONLY curve a go-plugin host will ever
/// present as its client certificate. The rustls `ring` provider implements
/// P-256 and P-384 but not P-521, so with `ring` alone the handshake fails with
/// `tls: certificate required` -- the client cert is offered and rejected.
///
/// `aws-lc-rs` does implement P-521, but adopting it here would reintroduce
/// ~2.1M lines of vendored BoringSSL to every crate in the workspace, because
/// crates_vendor resolves the workspace as one feature universe. bad32bfc5e
/// removed it deliberately as the most host-sensitive crate in the graph.
///
/// The trust decision does NOT rest on this code. `PinnedClientCertVerifier`
/// accepts a client certificate only when its DER is byte-identical to the
/// `PLUGIN_CLIENT_CERT` the host advertised out of band. This verifies the
/// handshake signature, which proves the peer holds that pinned certificate's
/// private key rather than replaying the certificate itself.
#[derive(Debug)]
struct EcdsaP521Sha512;

impl SignatureVerificationAlgorithm for EcdsaP521Sha512 {
    fn verify_signature(
        &self,
        public_key: &[u8],
        message: &[u8],
        signature: &[u8],
    ) -> Result<(), InvalidSignature> {
        use p521::ecdsa::signature::Verifier as _;

        // `public_key` is the subjectPublicKey BIT STRING contents: an
        // uncompressed SEC1 point (0x04 || X || Y).
        let point = p521::EncodedPoint::from_bytes(public_key).map_err(|_| InvalidSignature)?;
        let key =
            p521::ecdsa::VerifyingKey::from_encoded_point(&point).map_err(|_| InvalidSignature)?;

        // TLS carries ECDSA signatures DER-encoded as SEQUENCE { r, s }.
        let sig = p521::ecdsa::Signature::from_der(signature).map_err(|_| InvalidSignature)?;

        // `message` is unhashed; p521's Verifier applies SHA-512, which is the
        // hash TLS pairs with P-521 (ecdsa_secp521r1_sha512).
        key.verify(message, &sig).map_err(|_| InvalidSignature)
    }

    fn public_key_alg_id(&self) -> AlgorithmIdentifier {
        alg_id::ECDSA_P521
    }

    fn signature_alg_id(&self) -> AlgorithmIdentifier {
        alg_id::ECDSA_SHA512
    }
}

/// The `ring` provider's verification algorithms, plus P-521.
///
/// Returned instead of `ring::default_provider().signature_verification_algorithms`
/// so every verification path in this file agrees on the same set; advertising a
/// scheme we cannot verify (or verifying one we never advertised) is how this
/// breaks silently.
///
/// Built exactly once. `WebPkiSupportedAlgorithms` holds `&'static` slices, so
/// assembling one means leaking the backing allocations -- fine for a one-time
/// init, an unbounded leak if done per call. Both callers are per-handshake.
fn supported_algorithms() -> WebPkiSupportedAlgorithms {
    static P521: &dyn SignatureVerificationAlgorithm = &EcdsaP521Sha512;
    static ALGORITHMS: OnceLock<WebPkiSupportedAlgorithms> = OnceLock::new();

    *ALGORITHMS.get_or_init(|| {
        let base = rustls::crypto::ring::default_provider().signature_verification_algorithms;

        let mut all = base.all.to_vec();
        all.push(P521);

        let mut mapping = base.mapping.to_vec();
        // The mapping's value is a &'static slice, not a Vec.
        static P521_ONLY: &[&dyn SignatureVerificationAlgorithm] = &[P521];
        mapping.push((SignatureScheme::ECDSA_NISTP521_SHA512, P521_ONLY));

        WebPkiSupportedAlgorithms {
            all: Box::leak(all.into_boxed_slice()),
            mapping: Box::leak(mapping.into_boxed_slice()),
        }
    })
}

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
        rustls::crypto::verify_tls12_signature(message, cert, dss, &supported_algorithms())
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &supported_algorithms())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        supported_algorithms().supported_schemes()
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

#[cfg(test)]
mod p521_tests {
    use super::*;

    /// Guards the one property that makes go-plugin AutoMTLS work at all.
    ///
    /// go-plugin generates its client certificate with `elliptic.P521()` and
    /// offers no way to choose another curve, so if this scheme is missing the
    /// handshake fails with `tls: certificate required` -- a cross-language
    /// failure that only the slow, path-filtered Rust/Go interop job catches.
    /// Swapping the rustls provider back to a P-521-less one (as bad32bfc5e did)
    /// should fail here, in one line, instead.
    #[test]
    fn advertises_the_curve_go_plugin_mandates() {
        let schemes = supported_algorithms().supported_schemes();

        assert!(
            schemes.contains(&SignatureScheme::ECDSA_NISTP521_SHA512),
            "go-plugin AutoMTLS uses ECDSA P-521 exclusively; without it every \
             Rust add-on fails the agent's mTLS handshake. Got: {schemes:?}"
        );
    }

    /// The ring provider's own schemes must survive being augmented -- a P-521
    /// entry is no use if adding it dropped everything else.
    #[test]
    fn retains_the_base_provider_schemes() {
        let base = rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes();
        let augmented = supported_algorithms().supported_schemes();

        for scheme in base {
            assert!(
                augmented.contains(&scheme),
                "augmenting the provider dropped {scheme:?}"
            );
        }
    }

    /// A signature that is not valid must be rejected. The interop test proves
    /// the positive path against a real go-plugin certificate; this proves
    /// verify_signature is actually verifying rather than returning Ok whenever
    /// its inputs happen to parse.
    #[test]
    fn verifies_a_real_signature_and_rejects_everything_else() {
        use p521::ecdsa::signature::Signer as _;
        use p521::elliptic_curve::rand_core::OsRng;

        let signing = p521::ecdsa::SigningKey::random(&mut OsRng);
        let verifying = p521::ecdsa::VerifyingKey::from(&signing);
        let point = verifying.to_encoded_point(false);
        let sig: p521::ecdsa::Signature = signing.sign(b"the signed message");
        let der = sig.to_der();

        assert!(
            EcdsaP521Sha512
                .verify_signature(point.as_bytes(), b"the signed message", der.as_bytes())
                .is_ok(),
            "a genuine P-521 signature must verify"
        );

        assert!(
            EcdsaP521Sha512
                .verify_signature(point.as_bytes(), b"a different message", der.as_bytes())
                .is_err(),
            "a signature over different data must not verify"
        );

        assert!(
            EcdsaP521Sha512
                .verify_signature(point.as_bytes(), b"the signed message", b"not der")
                .is_err(),
            "a malformed signature must not verify"
        );

        assert!(
            EcdsaP521Sha512
                .verify_signature(b"not a point", b"the signed message", der.as_bytes())
                .is_err(),
            "a malformed public key must not verify"
        );
    }
}
