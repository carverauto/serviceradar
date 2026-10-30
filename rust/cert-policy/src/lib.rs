//! Full-certificate policy supplied by the authenticated core authority.
//! This supplements PKIX and hostname verification; it does not authenticate
//! snapshot bytes. File consumers require a privileged agent-owned policy file.

use chrono::{DateTime, Utc};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::watch;

pub mod nats;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Snapshot {
    pub version: u32,
    pub generated_at: DateTime<Utc>,
    pub valid_until: DateTime<Utc>,
    pub allowed_fingerprints: Vec<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("certificate policy unavailable or expired")]
    Unavailable,
    #[error("peer certificate is not authorized")]
    Denied,
    #[error("invalid or older certificate policy snapshot")]
    InvalidSnapshot,
    #[error("certificate policy state is poisoned")]
    Poisoned,
}

#[derive(Debug, Default)]
struct State {
    generated_at: Option<DateTime<Utc>>,
    valid_until: Option<DateTime<Utc>>,
    deadline: Option<Instant>,
    allowed: HashSet<String>,
}

/// Constructing a policy store never authorizes a peer. Only an authenticated,
/// fresh authority snapshot can do that. Consumers must also terminate active
/// transports when admission changes, including the local monotonic deadline.
#[derive(Debug)]
pub struct Store {
    state: Mutex<State>,
    changes: watch::Sender<u64>,
}

impl Default for Store {
    fn default() -> Self {
        Self {
            state: Mutex::default(),
            changes: watch::channel(0).0,
        }
    }
}

impl Store {
    pub fn apply(&self, snapshot: Snapshot) -> Result<(), Error> {
        let now = Utc::now();
        let lifetime = (snapshot.valid_until - now)
            .to_std()
            .map_err(|_| Error::InvalidSnapshot)?;
        let span = (snapshot.valid_until - snapshot.generated_at)
            .to_std()
            .map_err(|_| Error::InvalidSnapshot)?;
        if snapshot.version != 1
            || lifetime.is_zero()
            || span.is_zero()
            || span > Duration::from_secs(30)
            || snapshot.generated_at > now + chrono::Duration::seconds(5)
            || snapshot.allowed_fingerprints.iter().any(|fp| {
                fp.len() != 64
                    || !fp
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            })
        {
            return Err(Error::InvalidSnapshot);
        }
        let allowed: HashSet<_> = snapshot.allowed_fingerprints.into_iter().collect();
        let mut state = self.state.lock().map_err(|_| Error::Poisoned)?;
        if let Some(generated) = state.generated_at {
            if snapshot.generated_at < generated {
                return Err(Error::InvalidSnapshot);
            }
            if snapshot.generated_at == generated {
                return if state.valid_until == Some(snapshot.valid_until)
                    && state.allowed == allowed
                {
                    Ok(())
                } else {
                    Err(Error::InvalidSnapshot)
                };
            }
        }
        *state = State {
            generated_at: Some(snapshot.generated_at),
            valid_until: Some(snapshot.valid_until),
            deadline: Some(Instant::now() + lifetime.min(Duration::from_secs(30))),
            allowed,
        };
        drop(state);
        self.changes
            .send_modify(|revision| *revision = revision.wrapping_add(1));
        Ok(())
    }

    pub fn authorize(&self, fingerprint: &str) -> Result<(), Error> {
        let state = self.state.lock().map_err(|_| Error::Poisoned)?;
        if state
            .deadline
            .is_none_or(|deadline| Instant::now() >= deadline)
        {
            return Err(Error::Unavailable);
        }
        if !state.allowed.contains(fingerprint) {
            return Err(Error::Denied);
        }
        Ok(())
    }

    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.changes.subscribe()
    }
}

pub fn fingerprint(certificate: &CertificateDer<'_>) -> String {
    hex::encode(Sha256::digest(certificate.as_ref()))
}

/// Adds full-DER policy admission after the supplied verifier's chain/name checks.
/// TLS signature verification is delegated unchanged. Disable client resumption
/// when installing this verifier so every connection passes this admission gate.
#[derive(Debug)]
pub struct PolicyVerifier {
    verifier: Arc<dyn ServerCertVerifier>,
    store: Arc<Store>,
    peer: Arc<Mutex<Option<String>>>,
}

impl PolicyVerifier {
    pub fn new(verifier: Arc<dyn ServerCertVerifier>, store: Arc<Store>) -> Self {
        Self {
            verifier,
            store,
            peer: Arc::default(),
        }
    }

    pub fn peer(&self) -> Arc<Mutex<Option<String>>> {
        self.peer.clone()
    }
}

impl ServerCertVerifier for PolicyVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &ServerName<'_>,
        ocsp: &[u8],
        now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let verified =
            self.verifier
                .verify_server_cert(end_entity, intermediates, server_name, ocsp, now)?;
        let fp = fingerprint(end_entity);
        self.store
            .authorize(&fp)
            .map_err(|err| rustls::Error::General(err.to_string()))?;
        *self
            .peer
            .lock()
            .map_err(|_| rustls::Error::General(Error::Poisoned.to_string()))? = Some(fp);
        Ok(verified)
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        self.verifier.verify_tls12_signature(message, cert, dss)
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        self.verifier.verify_tls13_signature(message, cert, dss)
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.verifier.supported_verify_schemes()
    }
}

#[cfg(test)]
mod tests;
