use anyhow::{anyhow, Context, Result};
use log::{info, warn};
use pem::Pem;
use spiffe::cert::Certificate as SpiffeCertificate;
use spiffe::{
    BundleSource, SvidSource, TrustDomain, WorkloadApiClient, X509Source, X509SourceBuilder,
};
use std::sync::Arc;
use tokio::sync::watch;
use tonic::transport::{Certificate, Identity};

const CERT_TAG: &str = "CERTIFICATE";
const KEY_TAG: &str = "PRIVATE KEY";

pub async fn load_server_credentials(
    workload_socket: &str,
    trust_domain: &str,
) -> Result<ServerCredentials> {
    let client = WorkloadApiClient::new_from_path(workload_socket)
        .await
        .with_context(|| {
            format!("failed to connect to SPIFFE Workload API at {workload_socket}")
        })?;

    let source = X509SourceBuilder::new()
        .with_client(client)
        .build()
        .await
        .context("failed to initialize SPIFFE X.509 source")?;

    let trust_domain = TrustDomain::try_from(trust_domain)
        .map_err(|e| anyhow!("invalid trust domain {trust_domain}: {e}"))?;

    let guard = SpiffeSourceGuard {
        source,
        trust_domain,
    };

    // Validate that we can build TLS materials up front so we fail fast if the
    // Workload API does not have an SVID yet.
    let _ = guard.tls_materials()?;

    Ok(ServerCredentials { guard })
}

fn encode_chain(items: &[SpiffeCertificate]) -> String {
    items
        .iter()
        .map(|cert| encode_block(CERT_TAG, cert.as_ref()))
        .collect()
}

fn encode_block(tag: &str, der: &[u8]) -> String {
    pem::encode(&Pem::new(tag.to_string(), der.to_vec()))
}

pub struct ServerCredentials {
    guard: SpiffeSourceGuard,
}

impl ServerCredentials {
    pub fn tls_materials(&self) -> Result<(Identity, Certificate)> {
        self.guard.tls_materials()
    }

    pub fn watch_updates(&self) -> watch::Receiver<()> {
        self.guard.updated()
    }
}

pub struct SpiffeSourceGuard {
    source: Arc<X509Source>,
    trust_domain: TrustDomain,
}

impl SpiffeSourceGuard {
    fn tls_materials(&self) -> Result<(Identity, Certificate)> {
        let svid = self
            .source
            .get_svid()
            .map_err(|err| anyhow!("failed to fetch default X.509 SVID from workload API: {err}"))?
            .ok_or_else(|| anyhow!("workload API returned no default X.509 SVID"))?;

        let bundle = self
            .source
            .get_bundle_for_trust_domain(&self.trust_domain)
            .map_err(|err| anyhow!("failed to fetch X.509 bundle for trust domain: {err}"))?
            .ok_or_else(|| {
                anyhow!(
                    "no X.509 bundle available for trust domain {}",
                    self.trust_domain
                )
            })?;

        let cert_pem = encode_chain(svid.cert_chain());
        let key_pem = encode_block(KEY_TAG, svid.private_key().as_ref());
        let ca_pem = encode_chain(bundle.authorities());

        Ok((
            Identity::from_pem(cert_pem.into_bytes(), key_pem.into_bytes()),
            Certificate::from_pem(ca_pem.into_bytes()),
        ))
    }

    fn updated(&self) -> watch::Receiver<()> {
        self.source.updated()
    }
}

impl Drop for SpiffeSourceGuard {
    fn drop(&mut self) {
        if let Err(err) = self.source.close() {
            warn!("Failed to close SPIFFE X.509 source: {err}");
        } else {
            info!(
                "Closed SPIFFE X.509 source for trust domain {}",
                self.trust_domain
            );
        }
    }
}
