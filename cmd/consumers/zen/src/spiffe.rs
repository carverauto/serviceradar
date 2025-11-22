use anyhow::{anyhow, Result};
use log::{info, warn};
use pem::Pem;
use spiffe::cert::Certificate as SpiffeCertificate;
use spiffe::error::GrpcClientError;
use spiffe::workload_api::x509_source::X509SourceError;
use spiffe::{
    BundleSource, SvidSource, TrustDomain, WorkloadApiClient, X509Source, X509SourceBuilder,
};
use std::sync::Arc;
use tokio::sync::watch;
use tokio::time::{sleep, Duration};
use tonic::transport::{Certificate, Identity};

const CERT_TAG: &str = "CERTIFICATE";
const KEY_TAG: &str = "PRIVATE KEY";

pub async fn load_server_credentials(
    workload_socket: &str,
    trust_domain: &str,
) -> Result<ServerCredentials> {
    let trust_domain = TrustDomain::try_from(trust_domain)
        .map_err(|e| anyhow!("invalid trust domain {trust_domain}: {e}"))?;
    let retry_delay = Duration::from_secs(2);
    let max_retries = std::env::var("SPIFFE_MAX_RETRIES")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(60);
    let mut attempts: u32 = 0;

    loop {
        attempts += 1;
        let client = match WorkloadApiClient::new_from_path(workload_socket).await {
            Ok(client) => client,
            Err(err) => {
                let mapped = map_grpc_error("connect to SPIFFE Workload API", workload_socket, err);
                if attempts >= max_retries {
                    return Err(anyhow!(
                        "{mapped}; exceeded {max_retries} attempts connecting to SPIFFE Workload API"
                    ));
                }
                warn!("{mapped}; retrying in {}s", retry_delay.as_secs());
                sleep(retry_delay).await;
                continue;
            }
        };

        let source = match X509SourceBuilder::new().with_client(client).build().await {
            Ok(source) => source,
            Err(X509SourceError::GrpcError(grpc_err)) => {
                if should_retry_grpc(&grpc_err) && attempts < max_retries {
                    warn!(
                        "SPIFFE Workload API unavailable ({grpc_err:?}); retrying in {}s",
                        retry_delay.as_secs()
                    );
                    sleep(retry_delay).await;
                    continue;
                }
                return Err(map_grpc_error(
                    "initialize SPIFFE X.509 source",
                    workload_socket,
                    grpc_err,
                ));
            }
            Err(other) => {
                if is_retryable_source_error(&other) && attempts < max_retries {
                    warn!(
                        "SPIFFE source not ready ({other}); retrying in {}s",
                        retry_delay.as_secs()
                    );
                    sleep(retry_delay).await;
                    continue;
                }
                return Err(anyhow!(
                    "failed to initialize SPIFFE X.509 source via {workload_socket} after {attempts} attempts: {other}"
                ));
            }
        };

        let guard = SpiffeSourceGuard {
            source,
            trust_domain: trust_domain.clone(),
        };

        // Validate TLS materials up front; if the Workload API is not yet returning an
        // SVID/bundle we wait and retry instead of failing the gRPC server permanently.
        match guard.tls_materials() {
            Ok(_) => return Ok(ServerCredentials { guard }),
            Err(err) if is_retryable_tls_error(&err) => {
                if attempts >= max_retries {
                    return Err(anyhow!(
                        "failed to fetch SPIFFE TLS materials after {attempts} attempts: {err}"
                    ));
                }
                warn!(
                    "SPIFFE materials unavailable ({err}); retrying in {}s",
                    retry_delay.as_secs()
                );
                sleep(retry_delay).await;
                continue;
            }
            Err(err) => return Err(err),
        }
    }
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

fn map_grpc_error(action: &str, socket: &str, err: GrpcClientError) -> anyhow::Error {
    match &err {
        GrpcClientError::Grpc(status) => anyhow!(
            "failed to {action} at {socket}: gRPC status {:?} ({})",
            status.code(),
            status.message()
        ),
        GrpcClientError::Transport(transport) => {
            anyhow!("failed to {action} at {socket}: transport error {transport}")
        }
        _ => anyhow!(err),
    }
}

fn should_retry_grpc(err: &GrpcClientError) -> bool {
    matches!(err, GrpcClientError::Grpc(_)) || matches!(err, GrpcClientError::Transport(_))
}

fn is_retryable_source_error(err: &X509SourceError) -> bool {
    matches!(err, X509SourceError::NoSuitableSvid)
}

fn is_retryable_tls_error(err: &anyhow::Error) -> bool {
    let message = err.to_string();
    message.contains("no default X.509 SVID")
        || message.contains("failed to fetch default X.509 SVID")
        || message.contains("no X.509 bundle available")
        || message.contains("failed to fetch X.509 bundle")
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
