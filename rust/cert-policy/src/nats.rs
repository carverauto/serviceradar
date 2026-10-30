//! Managed NATS TLS configuration and active-connection policy enforcement.

use crate::{PolicyVerifier, Snapshot, Store};
use async_nats::{Client, ConnectOptions, Event, ToServerAddrs};
use rustls::client::{Resumption, WebPkiServerVerifier};
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use rustls::{ClientConfig, RootCertStore};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::watch;
use tokio::task::JoinHandle;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EnforcementStatus {
    Connected,
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
    peer: Arc<Mutex<Option<String>>>,
    status: watch::Receiver<EnforcementStatus>,
    task: JoinHandle<()>,
}

impl Guard {
    pub fn ensure_authorized(&self) -> Result<()> {
        let peer = self.peer.lock().map_err(|_| crate::Error::Poisoned)?;
        self.store
            .authorize(peer.as_deref().ok_or(crate::Error::Unavailable)?)?;
        if *self.status.borrow() != EnforcementStatus::Connected {
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

/// Optional managed adoption. None preserves the caller's existing TLS options;
/// Some requires all TLS inputs and a fresh agent-installed policy file.
pub async fn connect<A: ToServerAddrs>(
    options: ConnectOptions,
    addresses: A,
    policy_file: Option<&Path>,
    ca_file: Option<&Path>,
    cert_file: Option<&Path>,
    key_file: Option<&Path>,
) -> Result<(Client, Option<Guard>)> {
    let Some(policy_file) = policy_file else {
        return Ok((options.connect(addresses).await?, None));
    };
    let ca_file = ca_file.ok_or("managed NATS TLS requires a CA file")?;
    let cert_file = cert_file.ok_or("managed NATS TLS requires a client certificate")?;
    let key_file = key_file.ok_or("managed NATS TLS requires a private key")?;
    let store = Arc::new(Store::default());
    store.apply(read_snapshot(policy_file)?)?;
    connect_managed(
        options,
        addresses,
        store,
        Some(policy_file.to_owned()),
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
        options, addresses, store, None, ca_file, cert_file, key_file,
    )
    .await
}

async fn connect_managed<A: ToServerAddrs>(
    options: ConnectOptions,
    addresses: A,
    store: Arc<Store>,
    policy_file: Option<PathBuf>,
    ca_file: &Path,
    cert_file: &Path,
    key_file: &Path,
) -> Result<(Client, Option<Guard>)> {
    let mut roots = RootCertStore::empty();
    for cert in CertificateDer::pem_file_iter(ca_file)? {
        roots.add(cert?)?;
    }
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let base =
        WebPkiServerVerifier::builder_with_provider(Arc::new(roots), provider.clone()).build()?;
    let verifier = PolicyVerifier::new(base, store.clone());
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
    peer: Arc<Mutex<Option<String>>>,
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
            && let Err(error) =
                read_snapshot(path).and_then(|snapshot| store.apply(snapshot).map_err(Into::into))
        {
            tracing::debug!(%error, "managed certificate policy update rejected");
        }
        let authorized = peer
            .lock()
            .ok()
            .and_then(|peer| peer.clone())
            .is_some_and(|fp| store.authorize(&fp).is_ok());
        if authorized {
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

fn read_snapshot(path: &Path) -> Result<Snapshot> {
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
