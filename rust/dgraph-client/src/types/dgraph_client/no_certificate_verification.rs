/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Certificate verifier for [`TlsMode::RequireNoVerify`](crate::TlsMode::RequireNoVerify).
//!
//! This accepts ANY server certificate. It exists solely because `sslmode=require` is
//! defined that way: encrypted, but with the server unauthenticated, so it does not defend
//! against an active attacker. Isolating it in one small module keeps the blast radius
//! obvious and makes it easy to audit.
//!
//! It is never used unless the caller explicitly selects `sslmode=require`, and selecting
//! that mode logs a warning.

use std::sync::Arc;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{CryptoProvider, verify_tls12_signature, verify_tls13_signature};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, Error as RustlsError, SignatureScheme};

/// Accepts any server certificate without validating it.
#[derive(Debug)]
pub(crate) struct NoCertificateVerification {
    provider: Arc<CryptoProvider>,
}

impl NoCertificateVerification {
    pub(crate) fn new(provider: Arc<CryptoProvider>) -> Self {
        Self { provider }
    }
}

impl ServerCertVerifier for NoCertificateVerification {
    /// Always succeeds. This is the entire point of `sslmode=require`.
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, RustlsError> {
        Ok(ServerCertVerified::assertion())
    }

    /// Handshake signatures are still checked properly. Skipping certificate *identity*
    /// validation does not mean accepting a malformed handshake.
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, RustlsError> {
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
    ) -> Result<HandshakeSignatureValid, RustlsError> {
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
