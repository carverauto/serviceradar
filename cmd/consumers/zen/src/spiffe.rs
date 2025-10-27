use anyhow::{anyhow, Context, Result};
use log::warn;
use pem::Pem;
use std::sync::Arc;
use spiffe::cert::Certificate as SpiffeCertificate;
use spiffe::{
    BundleSource, SvidSource, TrustDomain, WorkloadApiClient, X509Source, X509SourceBuilder,
};
use tonic::transport::{Certificate, Identity};

const CERT_TAG: &str = "CERTIFICATE";
const KEY_TAG: &str = "PRIVATE KEY";

pub struct ServerCredentials {
    pub identity: Identity,
    pub client_ca: Certificate,
    guard: SpiffeSourceGuard,
}

impl ServerCredentials {
    pub fn into_parts(self) -> (Identity, Certificate, SpiffeSourceGuard) {
        (self.identity, self.client_ca, self.guard)
    }
}

pub struct SpiffeSourceGuard {
    source: Arc<X509Source>,
}

impl Drop for SpiffeSourceGuard {
    fn drop(&mut self) {
        if let Err(err) = self.source.close() {
            warn!("Failed to close SPIFFE X.509 source: {err}");
        }
    }
}

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

    let svid = source
        .get_svid()
        .map_err(|err| anyhow!("failed to fetch default X.509 SVID from workload API: {err}"))?
        .ok_or_else(|| anyhow!("workload API returned no default X.509 SVID"))?;

    let trust_domain = TrustDomain::try_from(trust_domain)
        .map_err(|e| anyhow!("invalid trust domain {trust_domain}: {e}"))?;

    let bundle = source
        .get_bundle_for_trust_domain(&trust_domain)
        .map_err(|err| anyhow!("failed to fetch X.509 bundle for trust domain: {err}"))?
        .ok_or_else(|| anyhow!("no X.509 bundle available for trust domain {trust_domain}"))?;

    // build PEM encoded chain and key
    let cert_pem = encode_chain(svid.cert_chain());
    let key_pem = encode_block(KEY_TAG, svid.private_key().as_ref());
    let ca_pem = encode_chain(bundle.authorities());

    let identity = Identity::from_pem(cert_pem.into_bytes(), key_pem.into_bytes());
    let client_ca = Certificate::from_pem(ca_pem.into_bytes());

    Ok(ServerCredentials {
        identity,
        client_ca,
        guard: SpiffeSourceGuard { source },
    })
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
