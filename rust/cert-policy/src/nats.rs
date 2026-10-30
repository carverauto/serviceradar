//! Managed NATS TLS configuration and active-connection policy enforcement.

use crate::{Admission, PolicyVerifier, Store, VerifiedPeer, read_privileged_json};
use async_nats::{Client, ConnectOptions, Event, ServerAddr, ToServerAddrs};
use rustls::client::{Resumption, WebPkiServerVerifier};
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use rustls::{ClientConfig, RootCertStore};
use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::watch;
use tokio::task::JoinHandle;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EnforcementStatus {
    Connected,
    /// The enrolled local leaf remains authorized by the last verified snapshot.
    StaleLocal,
    Disconnecting,
    Disconnected,
    /// No disconnect confirmation arrived within the bound. Publishing remains
    /// denied; operators must not interpret this as completed enforcement.
    Unconfirmed,
}

/// Keep this guard beside the client/JetStream context for their whole lifetime.
/// Dropping it stops the policy watcher. Every publish entry point must call
/// ensure_authorized before handing new work to async-nats.
pub struct Guard {
    store: Arc<Store>,
    peer: Arc<Mutex<Option<VerifiedPeer>>>,
    status: watch::Receiver<EnforcementStatus>,
    task: JoinHandle<()>,
}

impl Guard {
    pub fn ensure_authorized(&self) -> Result<()> {
        let peer = self.peer.lock().map_err(|_| crate::Error::Poisoned)?;
        self.store
            .authorize_peer(peer.as_ref().ok_or(crate::Error::Unavailable)?)?;
        if !matches!(
            *self.status.borrow(),
            EnforcementStatus::Connected | EnforcementStatus::StaleLocal
        ) {
            return Err(crate::Error::Unavailable.into());
        }
        Ok(())
    }

    pub fn status(&self) -> EnforcementStatus {
        *self.status.borrow()
    }
}

impl Drop for Guard {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Optional managed adoption. No policy file preserves existing TLS behavior.
/// Managed peers require all TLS inputs and an agent-installed policy. Only an
/// explicit privileged local-leaf binding permits its last verified stale policy;
/// the exact endpoint, leaf SPIFFE identity, full fingerprint, and PKIX still apply.
pub async fn connect<A: ToServerAddrs>(
    options: ConnectOptions,
    addresses: A,
    policy_file: Option<&Path>,
    local_leaf_file: Option<&Path>,
    ca_file: Option<&Path>,
    cert_file: Option<&Path>,
    key_file: Option<&Path>,
) -> Result<(Client, Option<Guard>)> {
    let Some(policy_file) = policy_file else {
        if local_leaf_file.is_some() {
            return Err("local leaf binding requires a managed certificate policy file".into());
        }
        return Ok((options.connect(addresses).await?, None));
    };
    let ca_file = ca_file.ok_or("managed NATS TLS requires a CA file")?;
    let cert_file = cert_file.ok_or("managed NATS TLS requires a client certificate")?;
    let key_file = key_file.ok_or("managed NATS TLS requires a private key")?;
    let local_leaf: Option<LocalLeafBinding> =
        local_leaf_file.map(read_privileged_json).transpose()?;
    let store = Arc::new(Store::default());
    if local_leaf.is_some() {
        store.restore_local(read_privileged_json(policy_file)?)?;
    } else {
        store.apply(read_privileged_json(policy_file)?)?;
    }
    connect_managed(
        options,
        addresses,
        ManagedPolicy {
            store,
            file: Some(policy_file.to_owned()),
            local_leaf,
        },
        ca_file,
        cert_file,
        key_file,
    )
    .await
}

/// Use when snapshots arrive over an already authenticated control stream.
/// No file watcher is installed; the caller owns Store::apply updates.
pub async fn connect_with_store<A: ToServerAddrs>(
    options: ConnectOptions,
    addresses: A,
    store: Arc<Store>,
    ca_file: &Path,
    cert_file: &Path,
    key_file: &Path,
) -> Result<(Client, Option<Guard>)> {
    connect_managed(
        options,
        addresses,
        ManagedPolicy {
            store,
            file: None,
            local_leaf: None,
        },
        ca_file,
        cert_file,
        key_file,
    )
    .await
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct LocalLeafBinding {
    version: u32,
    endpoint: String,
    server_spiffe_id: String,
}

impl LocalLeafBinding {
    fn validate(&self, addresses: &[ServerAddr]) -> Result<()> {
        let expected: ServerAddr = self.endpoint.parse()?;
        let endpoint = expected.clone().into_inner();
        if self.version != 1
            || expected.scheme() != "tls"
            || expected.host().is_empty()
            || expected.has_user_pass()
            || !matches!(endpoint.path(), "" | "/")
            || endpoint.query().is_some()
            || endpoint.fragment().is_some()
            || !self.server_spiffe_id.starts_with("spiffe://")
            || addresses.len() != 1
        {
            return Err("invalid enrolled local leaf binding".into());
        }
        let address = &addresses[0];
        let url = address.clone().into_inner();
        if !matches!(address.scheme(), "tls" | "nats")
            || address.has_user_pass()
            || address.host() != expected.host()
            || address.port() != expected.port()
            || !matches!(url.path(), "" | "/")
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Err("NATS endpoint differs from enrolled local leaf binding".into());
        }
        Ok(())
    }
}

struct ManagedPolicy {
    store: Arc<Store>,
    file: Option<PathBuf>,
    local_leaf: Option<LocalLeafBinding>,
}

async fn connect_managed<A: ToServerAddrs>(
    mut options: ConnectOptions,
    addresses: A,
    policy: ManagedPolicy,
    ca_file: &Path,
    cert_file: &Path,
    key_file: &Path,
) -> Result<(Client, Option<Guard>)> {
    let ManagedPolicy {
        store,
        file: policy_file,
        local_leaf,
    } = policy;
    let addresses: Vec<_> = addresses.to_server_addrs()?.collect();
    if let Some(binding) = &local_leaf {
        binding.validate(&addresses)?;
        options = options.ignore_discovered_servers();
    }
    let mut roots = RootCertStore::empty();
    for cert in CertificateDer::pem_file_iter(ca_file)? {
        roots.add(cert?)?;
    }
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let base =
        WebPkiServerVerifier::builder_with_provider(Arc::new(roots), provider.clone()).build()?;
    let verifier = PolicyVerifier::new(base, store.clone());
    let verifier = match local_leaf {
        Some(binding) => verifier.for_local_leaf(binding.server_spiffe_id),
        None => verifier,
    };
    let peer = verifier.peer();
    let certificates =
        CertificateDer::pem_file_iter(cert_file)?.collect::<std::result::Result<Vec<_>, _>>()?;
    let key = PrivateKeyDer::from_pem_file(key_file)?;
    let mut tls = ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(verifier))
        .with_client_auth_cert(certificates, key)?;
    tls.resumption = Resumption::disabled();
    let (status_tx, status) = watch::channel(EnforcementStatus::Disconnected);
    let event_tx = status_tx.clone();
    let (disconnects_tx, disconnects) = watch::channel(0_u64);
    let options = options
        .require_tls(true)
        .tls_client_config(tls)
        .event_callback(move |event| {
            let event_tx = event_tx.clone();
            let disconnects_tx = disconnects_tx.clone();
            async move {
                match event {
                    Event::Connected => {
                        event_tx.send_replace(EnforcementStatus::Connected);
                    }
                    Event::Disconnected | Event::Closed => {
                        event_tx.send_replace(EnforcementStatus::Disconnected);
                        disconnects_tx.send_modify(|count| *count = count.wrapping_add(1));
                    }
                    _ => {}
                }
            }
        });
    let client = options.connect(addresses).await?;
    // connect returning successfully is a completed NATS authentication, even
    // if the asynchronous Connected event has not yet been dispatched.
    status_tx.send_replace(EnforcementStatus::Connected);
    let task = tokio::spawn(monitor(
        client.clone(),
        store.clone(),
        peer.clone(),
        policy_file,
        status_tx,
        disconnects,
    ));
    Ok((
        client,
        Some(Guard {
            store,
            peer,
            status,
            task,
        }),
    ))
}

async fn monitor(
    client: Client,
    store: Arc<Store>,
    peer: Arc<Mutex<Option<VerifiedPeer>>>,
    policy_file: Option<PathBuf>,
    status: watch::Sender<EnforcementStatus>,
    mut disconnects: watch::Receiver<u64>,
) {
    let mut interval = tokio::time::interval(Duration::from_millis(250));
    let mut disconnected_for_policy = false;
    loop {
        interval.tick().await;
        // Invalid/missing updates never extend the last accepted snapshot.
        if let Some(path) = &policy_file
            && let Err(error) = read_privileged_json(path)
                .and_then(|snapshot| store.apply(snapshot).map_err(Into::into))
        {
            tracing::debug!(%error, "managed certificate policy update rejected");
        }
        let admission = peer
            .lock()
            .ok()
            .and_then(|peer| peer.clone())
            .ok_or(crate::Error::Unavailable)
            .and_then(|peer| store.authorize_peer(&peer));
        if let Ok(admission) = admission {
            let next = match admission {
                Admission::Fresh => EnforcementStatus::Connected,
                Admission::StaleLocal => EnforcementStatus::StaleLocal,
            };
            if matches!(
                *status.borrow(),
                EnforcementStatus::Connected | EnforcementStatus::StaleLocal
            ) && *status.borrow() != next
            {
                status.send_replace(next);
                tracing::warn!(?next, "local leaf certificate policy freshness changed");
            }
            disconnected_for_policy = false;
            continue;
        }
        if disconnected_for_policy {
            continue;
        }
        disconnected_for_policy = true;
        status.send_replace(EnforcementStatus::Disconnecting);
        let before = *disconnects.borrow_and_update();
        let disconnected = tokio::time::timeout(Duration::from_secs(2), async {
            client.force_reconnect().await?;
            loop {
                if *disconnects.borrow_and_update() != before {
                    return Ok::<(), Box<dyn std::error::Error + Send + Sync>>(());
                }
                disconnects.changed().await?;
            }
        })
        .await;
        if !matches!(disconnected, Ok(Ok(()))) {
            status.send_replace(EnforcementStatus::Unconfirmed);
            tracing::error!(
                "managed certificate peer disconnect was not confirmed; publishing remains blocked"
            );
        }
    }
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
