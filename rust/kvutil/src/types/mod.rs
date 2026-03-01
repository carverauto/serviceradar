use spiffe::{BundleSource, SvidSource, TrustDomain, X509Source};
use spiffe::cert::Certificate as SpiffeCertificate;
use std::sync::Arc;
use tonic::transport::{Certificate, Identity};

pub(crate) struct SpiffeSourceGuard {
    pub(crate) source: Arc<X509Source>,
    pub(crate) trust_domain: TrustDomain,
}

impl SpiffeSourceGuard {
    pub(crate) fn tls_materials(&self) -> std::result::Result<(Identity, Certificate), anyhow::Error> {
        let svid = self
            .source
            .get_svid()
            .map_err(|err| anyhow::anyhow!("failed to fetch default X.509 SVID: {err}"))?
            .ok_or_else(|| anyhow::anyhow!("workload API returned no default X.509 SVID"))?;

        let bundle = self
            .source
            .get_bundle_for_trust_domain(&self.trust_domain)
            .map_err(|err| anyhow::anyhow!("failed to fetch X.509 bundle: {err}"))?
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "no X.509 bundle available for trust domain {}",
                    self.trust_domain
                )
            })?;

        let cert_pem = encode_chain(svid.cert_chain());
        let key_pem = encode_block("PRIVATE KEY", svid.private_key().as_ref());
        let ca_pem = encode_chain(bundle.authorities());

        Ok((
            Identity::from_pem(cert_pem.into_bytes(), key_pem.into_bytes()),
            Certificate::from_pem(ca_pem.into_bytes()),
        ))
    }
}

fn encode_chain(items: &[SpiffeCertificate]) -> String {
    items
        .iter()
        .map(|cert| encode_block("CERTIFICATE", cert.as_ref()))
        .collect()
}

fn encode_block(tag: &str, der: &[u8]) -> String {
    pem::encode(&pem::Pem::new(tag.to_string(), der.to_vec()))
}
