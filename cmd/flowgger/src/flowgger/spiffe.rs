use anyhow::{anyhow, Result};
use log::warn;
use pem::Pem;
use spiffe::cert::Certificate as SpiffeCertificate;
use spiffe::error::GrpcClientError;
use spiffe::workload_api::x509_source::X509SourceError;
use spiffe::X509SourceBuilder;
use spiffe::{BundleSource, SvidSource, TrustDomain, WorkloadApiClient, X509Source};
use std::sync::Arc;
use tokio::sync::watch;
use tokio::time::{sleep, Duration};
use tonic::transport::{Certificate, Identity};

const CERT_TAG: &str = "CERTIFICATE";
const KEY_TAG: &str = "PRIVATE KEY";

pub struct ServerCredentials {
    guard: SpiffeSourceGuard,
}

pub struct SpiffeSourceGuard {
    source: Arc<X509Source>,
    trust_domain: TrustDomain,
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
    let trust_domain = TrustDomain::new(trust_domain)
        .map_err(|e| anyhow!("invalid trust domain {trust_domain}: {e}"))?;

    let retry_delay = Duration::from_secs(2);

    loop {
        let client = WorkloadApiClient::new_from_path(workload_socket)
            .await
            .map_err(|err| {
                map_grpc_error("connect to SPIFFE Workload API", workload_socket, err)
            })?;

        let source = match X509SourceBuilder::new().with_client(client).build().await {
            Ok(source) => source,
            Err(X509SourceError::GrpcError(grpc_err)) => {
                if should_retry_grpc(&grpc_err) {
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
                if is_retryable_source_error(&other) {
                    sleep(retry_delay).await;
                    continue;
                }
                return Err(anyhow!(
                    "failed to initialize SPIFFE X.509 source via {workload_socket}: {other}"
                ));
            }
        };

        let guard = SpiffeSourceGuard {
            source,
            trust_domain: trust_domain.clone(),
        };

        match guard.tls_materials() {
            Ok(_) => return Ok(ServerCredentials { guard }),
            Err(err) if is_retryable_tls_error(&err) => {
                sleep(retry_delay).await;
                continue;
            }
            Err(err) => return Err(err),
        }
    }
}

fn build_tls_identity(
    svid: &spiffe::X509Svid,
    authorities: &[SpiffeCertificate],
) -> (Identity, Certificate) {
    let cert_pem = encode_chain(svid.cert_chain());
    let key_pem = encode_block(KEY_TAG, svid.private_key().as_ref());
    let ca_pem = encode_chain(authorities);

    (
        Identity::from_pem(cert_pem.into_bytes(), key_pem.into_bytes()),
        Certificate::from_pem(ca_pem.into_bytes()),
    )
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

impl ServerCredentials {
    pub fn tls_materials(&self) -> Result<(Identity, Certificate)> {
        self.guard.tls_materials()
    }

    pub fn watch_updates(&self) -> watch::Receiver<()> {
        self.guard.updated()
    }
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

        Ok(build_tls_identity(&svid, bundle.authorities()))
    }

    fn updated(&self) -> watch::Receiver<()> {
        self.source.updated()
    }
}

fn is_retryable_tls_error(err: &anyhow::Error) -> bool {
    let message = err.to_string();
    message.contains("no default X.509 SVID")
        || message.contains("failed to fetch default X.509 SVID")
        || message.contains("no X.509 bundle available")
        || message.contains("failed to fetch X.509 bundle")
}

#[cfg(test)]
mod tests {
    use super::*;
    use rcgen::generate_simple_self_signed;
    use rcgen::{
        BasicConstraints, CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose,
        IsCa, KeyUsagePurpose, SanType,
    };
    use std::convert::TryFrom;
    use tonic::transport::ServerTlsConfig;

    #[test]
    fn encode_block_wraps_pem_headers() {
        let pem = encode_block("TEST", &[0x00, 0x01, 0x02]);
        assert!(
            pem.starts_with("-----BEGIN TEST-----"),
            "missing PEM begin header"
        );
        assert!(
            pem.contains("AAEC"),
            "expected base64 body to contain AAEC, got {:?}",
            pem
        );
        assert!(
            pem.trim_end().ends_with("-----END TEST-----"),
            "missing PEM end footer"
        );
    }

    #[test]
    fn encode_chain_renders_all_certificates() {
        let cert = generate_simple_self_signed(["example.test".into()]).unwrap();
        let der = cert.serialize_der().unwrap();
        let spiffe_cert = SpiffeCertificate::try_from(der.clone()).unwrap();
        let chain = encode_chain(&[spiffe_cert.clone(), spiffe_cert]);
        let begin_markers = chain.match_indices("-----BEGIN CERTIFICATE-----").count();
        assert_eq!(
            begin_markers, 2,
            "expected two PEM certificates, got {chain}"
        );
        assert!(
            chain.contains("-----END CERTIFICATE-----"),
            "expected PEM footer"
        );
        assert!(
            !chain.contains("PRIVATE KEY"),
            "unexpected key block in chain"
        );
    }

    #[test]
    fn encode_chain_empty_is_empty_string() {
        let chain = encode_chain(&[]);
        assert!(chain.is_empty(), "expected empty string for empty chain");
    }

    #[test]
    fn map_grpc_error_formats_status() {
        let err = map_grpc_error(
            "connect to SPIFFE Workload API",
            "unix:/run/spire/sockets/agent.sock",
            GrpcClientError::MissingEndpointSocketPath,
        );
        let message = err.to_string();
        assert!(
            message.contains("missing endpoint socket address"),
            "expected original error preserved: {}",
            message
        );
    }

    #[test]
    fn build_tls_identity_produces_pem_materials() {
        let spiffe_id = "spiffe://carverauto.dev/ns/demo/sa/test";
        let (svid, authorities) = build_test_svid(spiffe_id);
        let (identity, client_ca) = build_tls_identity(&svid, &authorities);

        // Ensure resulting materials can configure tonic TLS without panicking.
        let _ = ServerTlsConfig::new()
            .identity(identity.clone())
            .client_ca_root(client_ca.clone());

        let pem = String::from_utf8(client_ca.clone().into_inner()).expect("utf8 pem");
        assert!(
            pem.contains("BEGIN CERTIFICATE"),
            "expected PEM formatted CA certificate"
        );
    }

    fn build_test_svid(spiffe_id: &str) -> (spiffe::X509Svid, Vec<SpiffeCertificate>) {
        let mut ca_params = CertificateParams::new(vec![]);
        ca_params.distinguished_name = DistinguishedName::new();
        ca_params
            .distinguished_name
            .push(DnType::CommonName, "flowgger-ca");
        ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        ca_params.key_usages = vec![
            KeyUsagePurpose::KeyCertSign,
            KeyUsagePurpose::CrlSign,
            KeyUsagePurpose::DigitalSignature,
        ];

        let ca_cert = rcgen::Certificate::from_params(ca_params).expect("generate ca certificate");

        let mut leaf_params = CertificateParams::new(vec![]);
        leaf_params
            .subject_alt_names
            .push(SanType::URI(spiffe_id.to_string()));
        leaf_params.distinguished_name = DistinguishedName::new();
        leaf_params
            .distinguished_name
            .push(DnType::CommonName, "flowgger-test");
        leaf_params.is_ca = IsCa::ExplicitNoCa;
        leaf_params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
        leaf_params.extended_key_usages = vec![
            ExtendedKeyUsagePurpose::ServerAuth,
            ExtendedKeyUsagePurpose::ClientAuth,
        ];

        let leaf_cert =
            rcgen::Certificate::from_params(leaf_params).expect("generate leaf certificate");
        let cert_der = leaf_cert
            .serialize_der_with_signer(&ca_cert)
            .expect("sign certificate");
        let key_der = leaf_cert.serialize_private_key_der();

        let svid = spiffe::X509Svid::parse_from_der(&cert_der, &key_der).expect("valid svid");
        let ca_der = ca_cert.serialize_der().expect("serialize ca certificate");
        let authority = SpiffeCertificate::try_from(ca_der).expect("valid authority");

        (svid, vec![authority])
    }
}
