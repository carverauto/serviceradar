use anyhow::{anyhow, Result};
use log::warn;
use pem::Pem;
use spiffe::cert::Certificate as SpiffeCertificate;
use spiffe::error::GrpcClientError;
use spiffe::workload_api::x509_source::X509SourceError;
use spiffe::{
    BundleSource, SvidSource, TrustDomain, WorkloadApiClient, X509Source, X509SourceBuilder,
};
use std::sync::Arc;
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
        .map_err(|err| map_grpc_error("connect to SPIFFE Workload API", workload_socket, err))?;

    let source = X509SourceBuilder::new()
        .with_client(client)
        .build()
        .await
        .map_err(|err| match err {
            X509SourceError::GrpcError(grpc_err) => {
                map_grpc_error("initialize SPIFFE X.509 source", workload_socket, grpc_err)
            }
            other => {
                anyhow!("failed to initialize SPIFFE X.509 source via {workload_socket}: {other}")
            }
        })?;

    let svid = source
        .get_svid()
        .map_err(|err| anyhow!("failed to fetch default X.509 SVID from workload API: {err}"))?
        .ok_or_else(|| anyhow!("workload API returned no default X.509 SVID"))?;

    let trust_domain = TrustDomain::new(trust_domain)
        .map_err(|e| anyhow!("invalid trust domain {trust_domain}: {e}"))?;

    let bundle = source
        .get_bundle_for_trust_domain(&trust_domain)
        .map_err(|err| anyhow!("failed to fetch X.509 bundle for trust domain: {err}"))?
        .ok_or_else(|| anyhow!("no X.509 bundle available for trust domain {trust_domain}"))?;

    let (identity, client_ca) =
        build_tls_identity(&svid, bundle.authorities());

    Ok(ServerCredentials {
        identity,
        client_ca,
        guard: SpiffeSourceGuard { source },
    })
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

#[cfg(test)]
mod tests {
    use super::*;
    use rcgen::{
        BasicConstraints, CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose,
        IsCa, KeyUsagePurpose, SanType,
    };
    use rcgen::generate_simple_self_signed;
    use std::convert::TryFrom;
    use tonic::transport::ServerTlsConfig;

    #[test]
    fn encode_block_wraps_pem_headers() {
        let pem = encode_block("TEST", &[0xAA, 0xBB, 0xCC]);
        assert!(
            pem.starts_with("-----BEGIN TEST-----"),
            "missing PEM begin header"
        );
        assert!(
            pem.contains("qrvM"),
            "expected base64 payload in PEM body, got {:?}",
            pem
        );
        assert!(
            pem.trim_end().ends_with("-----END TEST-----"),
            "missing PEM end footer"
        );
    }

    #[test]
    fn encode_chain_renders_each_certificate() {
        let cert = generate_simple_self_signed(["example.test".into()]).unwrap();
        let der = cert.serialize_der().unwrap();
        let first = SpiffeCertificate::try_from(der.clone()).unwrap();
        let second = SpiffeCertificate::try_from(der).unwrap();
        let chain = encode_chain(&[first, second]);
        let begin_markers = chain.match_indices("-----BEGIN CERTIFICATE-----").count();
        assert_eq!(begin_markers, 2, "expected two certificates in chain");
        assert!(
            chain.contains("-----END CERTIFICATE-----"),
            "expected certificate footer"
        );
    }

    #[test]
    fn map_grpc_error_emits_status_details() {
        let err = map_grpc_error(
            "connect to workload API",
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
        let spiffe_id = "spiffe://carverauto.dev/ns/demo/sa/trapd";
        let (svid, authorities) = build_test_svid(spiffe_id);
        let (identity, client_ca) = build_tls_identity(&svid, &authorities);

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
            .push(DnType::CommonName, "trapd-ca");
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
            .push(DnType::CommonName, "trapd-test");
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
