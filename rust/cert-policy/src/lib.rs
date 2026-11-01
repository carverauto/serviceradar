//! Full-certificate policy supplied by the authenticated core authority.
//! This supplements PKIX and hostname verification; it does not authenticate
//! snapshot bytes. File consumers require a privileged agent-owned policy file.

use chrono::{DateTime, Utc};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};
use tokio::sync::watch;
use x509_cert::der::Decode;
use x509_cert::ext::pkix::{SubjectAltName, name::GeneralName};

pub mod nats;
pub mod server;

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

/// Constructing a policy store never authorizes a peer. Ordinary callers require
/// an authenticated, fresh snapshot. The managed NATS connector alone may restore
/// stale membership for an enrolled local leaf after a process restart. Consumers
/// must terminate active transports when their admission changes.
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
        self.apply_inner(snapshot, false)
    }

    // Only a privileged, authenticated on-disk snapshot may restore this state.
    // Stale membership is usable solely by a verified, endpoint-bound local leaf.
    pub(crate) fn restore_local(&self, snapshot: Snapshot) -> Result<(), Error> {
        self.apply_inner(snapshot, true)
    }

    fn apply_inner(&self, snapshot: Snapshot, restore_local: bool) -> Result<(), Error> {
        let now = Utc::now();
        let lifetime = (snapshot.valid_until - now).to_std().unwrap_or_default();
        let span = (snapshot.valid_until - snapshot.generated_at)
            .to_std()
            .map_err(|_| Error::InvalidSnapshot)?;
        if snapshot.version != 1
            || (!restore_local && lifetime.is_zero())
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
            if restore_local || snapshot.generated_at < generated {
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

    pub(crate) fn authorize_peer(&self, peer: &VerifiedPeer) -> Result<Admission, Error> {
        if Instant::now() >= peer.deadline || SystemTime::now() >= peer.not_after {
            return Err(Error::Denied);
        }
        let state = self.state.lock().map_err(|_| Error::Poisoned)?;
        if !state.allowed.contains(&peer.fingerprint) {
            return Err(Error::Denied);
        }
        if state
            .deadline
            .is_some_and(|deadline| Instant::now() < deadline)
        {
            Ok(Admission::Fresh)
        } else if peer.bound_local_leaf && state.generated_at.is_some() {
            Ok(Admission::StaleLocal)
        } else {
            Err(Error::Unavailable)
        }
    }

    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.changes.subscribe()
    }
}

pub fn fingerprint(certificate: &CertificateDer<'_>) -> String {
    hex::encode(Sha256::digest(certificate.as_ref()))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Admission {
    Fresh,
    StaleLocal,
}

#[derive(Clone, Debug)]
pub(crate) struct VerifiedPeer {
    fingerprint: String,
    not_after: SystemTime,
    deadline: Instant,
    bound_local_leaf: bool,
}

impl VerifiedPeer {
    fn from_certificates(
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        local_leaf_dns_name: Option<&str>,
    ) -> Result<VerifiedPeer, rustls::Error> {
        let invalid =
            || rustls::Error::General("managed peer certificate identity is invalid".into());
        let certificate =
            x509_cert::Certificate::from_der(end_entity.as_ref()).map_err(|_| invalid())?;
        let bound_local_leaf = if let Some(expected) = local_leaf_dns_name {
            let (_, names) = certificate
                .tbs_certificate
                .get::<SubjectAltName>()
                .map_err(|_| invalid())?
                .ok_or_else(invalid)?;
            if !names.0.iter().any(|name| matches!(name, GeneralName::DnsName(dns) if dns.as_str() == expected)) {
                return Err(invalid());
            }
            true
        } else {
            false
        };
        let mut not_after = certificate
            .tbs_certificate
            .validity
            .not_after
            .to_system_time();
        for intermediate in intermediates {
            let certificate =
                x509_cert::Certificate::from_der(intermediate.as_ref()).map_err(|_| invalid())?;
            not_after = not_after.min(
                certificate
                    .tbs_certificate
                    .validity
                    .not_after
                    .to_system_time(),
            );
        }
        let remaining = not_after
            .duration_since(SystemTime::now())
            .map_err(|_| invalid())?;
        Ok(VerifiedPeer {
            fingerprint: fingerprint(end_entity),
            not_after,
            deadline: Instant::now().checked_add(remaining).ok_or_else(invalid)?,
            bound_local_leaf,
        })
    }
}

/// Adds full-DER policy admission after the supplied verifier's chain/name checks.
/// TLS signature verification is delegated unchanged. Disable client resumption
/// when installing this verifier so every connection passes this admission gate.
#[derive(Debug)]
pub struct PolicyVerifier {
    verifier: Arc<dyn ServerCertVerifier>,
    store: Arc<Store>,
    peer: Arc<Mutex<Option<VerifiedPeer>>>,
    local_leaf_dns_name: Option<String>,
}

impl PolicyVerifier {
    pub fn new(verifier: Arc<dyn ServerCertVerifier>, store: Arc<Store>) -> Self {
        Self {
            verifier,
            store,
            peer: Arc::default(),
            local_leaf_dns_name: None,
        }
    }

    pub(crate) fn for_local_leaf(mut self, dns_name: String) -> Self {
        self.local_leaf_dns_name = Some(dns_name);
        self
    }

    pub(crate) fn peer(&self) -> Arc<Mutex<Option<VerifiedPeer>>> {
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
        let peer = VerifiedPeer::from_certificates(
            end_entity,
            intermediates,
            self.local_leaf_dns_name.as_deref(),
        )?;
        self.store
            .authorize_peer(&peer)
            .map_err(|err| rustls::Error::General(err.to_string()))?;
        *self
            .peer
            .lock()
            .map_err(|_| rustls::Error::General(Error::Poisoned.to_string()))? = Some(peer);
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

pub(crate) fn read_privileged_json<T: DeserializeOwned>(
    path: &Path,
) -> Result<T, Box<dyn std::error::Error + Send + Sync>> {
    if !path.is_absolute()
        || path
            .components()
            .any(|part| matches!(part, std::path::Component::ParentDir))
    {
        return Err("certificate policy path must be absolute without parent traversal".into());
    }
    // A root-owned file in a writable directory can be replaced. Require the
    // entire installation path to be controlled by the privileged host agent.
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        for ancestor in path.ancestors() {
            let metadata = std::fs::metadata(ancestor)?;
            if metadata.uid() != 0 || metadata.mode() & 0o022 != 0 {
                return Err("certificate policy file and parents must be root-owned and not group/world writable".into());
            }
        }
    }
    #[cfg(not(unix))]
    return Err("managed certificate policy file ownership is unsupported on this platform".into());
    let file = std::fs::File::open(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let metadata = file.metadata()?;
        if metadata.uid() != 0 || metadata.mode() & 0o022 != 0 || !metadata.is_file() {
            return Err("certificate policy file must be a privileged regular file".into());
        }
    }
    Ok(serde_json::from_reader(file)?)
}
