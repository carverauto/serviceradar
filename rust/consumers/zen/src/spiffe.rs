use anyhow::{anyhow, Result};
use log::warn;
use pem::Pem;
use spiffe::bundle::BundleSource;
use spiffe::cert::Certificate as SpiffeCertificate;
use spiffe::workload_api::WorkloadApiError;
use spiffe::X509SourceError;
use spiffe::{TrustDomain, X509Source, X509SourceBuilder};
use std::sync::Arc;
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
        let source = match X509SourceBuilder::new()
            .endpoint(workload_socket)
            .build()
            .await
        {
            Ok(source) => source,
            Err(X509SourceError::Source(grpc_err)) => {
                if is_no_identity_issued(&grpc_err) {
                    let message = format_no_identity_message(&trust_domain);
                    if attempts >= max_retries {
                        return Err(anyhow!(
                            "{message}; exceeded {max_retries} attempts requesting a SPIFFE identity"
                        ));
                    }
                    warn!("{message}; retrying in {}s", retry_delay.as_secs());
                    sleep(retry_delay).await;
                    continue;
                }
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
            source: Arc::new(source),
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

    pub fn watch_updates(&self) -> spiffe::X509SourceUpdates {
        self.guard.updated()
    }
}

pub struct SpiffeSourceGuard {
    source: Arc<X509Source>,
    trust_domain: TrustDomain,
}

impl SpiffeSourceGuard {
    fn tls_materials(&self) -> Result<(Identity, Certificate)> {
        let svid = self.source.svid().map_err(|err| {
            anyhow!("failed to fetch default X.509 SVID from workload API: {err}")
        })?;

        let bundle = self
            .source
            .bundle_for_trust_domain(&self.trust_domain)
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

    fn updated(&self) -> spiffe::X509SourceUpdates {
        self.source.updated()
    }
}

fn map_grpc_error(action: &str, socket: &str, err: WorkloadApiError) -> anyhow::Error {
    anyhow!("failed to {action} at {socket}: {err}")
}

fn should_retry_grpc(err: &WorkloadApiError) -> bool {
    matches!(err, WorkloadApiError::Transport(_))
}

fn is_no_identity_issued(err: &WorkloadApiError) -> bool {
    matches!(err, WorkloadApiError::NoIdentityIssued)
}

fn format_no_identity_message(trust_domain: &TrustDomain) -> String {
    format!(
        "SPIFFE Workload API denied identity for trust domain {trust_domain} (no identity issued). \
Ensure the zen workload is registered in SPIRE (ClusterSPIFFEID/registration entry) and the trust domain matches"
    )
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
    fn drop(&mut self) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_no_identity_permission_denied() {
        assert!(is_no_identity_issued(&WorkloadApiError::NoIdentityIssued));
    }

    #[test]
    fn ignores_other_workload_errors() {
        assert!(!is_no_identity_issued(&WorkloadApiError::EmptyResponse));
    }

    #[test]
    fn formats_no_identity_message_with_trust_domain() {
        let trust_domain = TrustDomain::try_from("example.org").unwrap();
        let message = format_no_identity_message(&trust_domain);
        assert!(message.contains("example.org"));
        assert!(message.contains("no identity issued"));
    }
}
