#[cfg(serviceradar_rdp_connector_link_probe)]
fn derive_credssp_server_public_key_from_verified_tls_peer_for_probe(
    cert_der: &[u8],
) -> Result<VerifiedTlsPeerPublicKeyForProbe, BackendError> {
    use x509_cert::der::Decode as _;

    let cert = x509_cert::Certificate::from_der(cert_der)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let public_key = cert
        .tbs_certificate
        .subject_public_key_info
        .subject_public_key
        .as_bytes()
        .ok_or(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    if public_key.is_empty() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    Ok(VerifiedTlsPeerPublicKeyForProbe {
        bytes: public_key.to_vec(),
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_verified_tls_client_config_for_registered_ca_bundle(
    ca_bundle: &[u8],
) -> Result<VerifiedTlsClientConfig, BackendError> {
    let certificates = parse_registered_ca_bundle_for_probe(ca_bundle)?;

    build_verified_tls_client_config_from_certificates(certificates, INVALID_TLS_CA_BUNDLE)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_verified_tls_client_config_for_system_roots(
) -> Result<VerifiedTlsClientConfig, BackendError> {
    let native = rustls_native_certs::load_native_certs();
    if !native.errors.is_empty() {
        return Err(BackendError::Unsupported(INVALID_TLS_CA_BUNDLE));
    }

    build_verified_tls_client_config_from_certificates(native.certs, INVALID_TLS_CA_BUNDLE)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_verified_tls_client_config_for_plan(
    plan: &NonSecretConnectionPlan,
) -> Result<VerifiedTlsClientConfig, BackendError> {
    match &plan.tls_trust_source {
        TlsTrustSource::SystemRoots => build_verified_tls_client_config_for_system_roots(),
        TlsTrustSource::RegisteredCaBundle { pem, .. } => {
            build_verified_tls_client_config_for_registered_ca_bundle(pem.as_bytes())
        }
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_connector_kerberos_config_for_plan(
    plan: &NonSecretConnectionPlan,
) -> Result<Option<ironrdp_connector::credssp::KerberosConfig>, BackendError> {
    if plan.kdc_proxy_url.is_none() && plan.kerberos_hostname.is_none() {
        return Ok(None);
    }

    let hostname = plan
        .kerberos_hostname
        .clone()
        .ok_or(BackendError::Unsupported(INVALID_CONNECTION_PLAN))?;

    ironrdp_connector::credssp::KerberosConfig::new(
        plan.kdc_proxy_url.clone(),
        hostname,
    )
    .map(Some)
    .map_err(|_| BackendError::Unsupported(INVALID_CONNECTION_PLAN))
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn connector_kerberos_binding_from_config(
    config: &Option<ironrdp_connector::credssp::KerberosConfig>,
) -> ConnectorKerberosBinding {
    let Some(config) = config else {
        return ConnectorKerberosBinding::default();
    };

    ConnectorKerberosBinding {
        kdc_proxy_url: config
            .kdc_proxy_url
            .as_ref()
            .map(|url| url.as_str().to_owned()),
        hostname: Some(config.hostname.clone()),
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn validate_connector_kerberos_binding(
    binding: &ConnectorKerberosBinding,
    config: &Option<ironrdp_connector::credssp::KerberosConfig>,
) -> Result<(), BackendError> {
    if connector_kerberos_binding_from_config(config) != *binding {
        return Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN));
    }

    Ok(())
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_verified_tls_client_config_from_certificates(
    certificates: Vec<rustls::pki_types::CertificateDer<'static>>,
    error_message: &'static str,
) -> Result<VerifiedTlsClientConfig, BackendError> {
    let mut roots = rustls::RootCertStore::empty();
    let mut added = 0;

    for certificate in certificates {
        roots
            .add(certificate)
            .map_err(|_| BackendError::Unsupported(error_message))?;
        added += 1;
    }
    if added == 0 {
        return Err(BackendError::Unsupported(error_message));
    }

    let mut config = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    config.resumption = rustls::client::Resumption::disabled();

    Ok(VerifiedTlsClientConfig {
        config,
        trusted_root_count: added,
        resumption_disabled_for_credssp: true,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn parse_registered_ca_bundle_for_probe(
    ca_bundle: &[u8],
) -> Result<Vec<rustls::pki_types::CertificateDer<'static>>, BackendError> {
    let trimmed = trim_ascii_whitespace(ca_bundle);
    if trimmed.is_empty() {
        return Err(BackendError::Unsupported(INVALID_TLS_CA_BUNDLE));
    }

    if !trimmed
        .windows(b"-----BEGIN CERTIFICATE-----".len())
        .any(|window| window == b"-----BEGIN CERTIFICATE-----")
    {
        return Err(BackendError::Unsupported(INVALID_TLS_CA_BUNDLE));
    }

    use rustls::pki_types::pem::PemObject as _;

    let mut certificates = Vec::new();
    for certificate in rustls::pki_types::CertificateDer::pem_slice_iter(trimmed) {
        certificates
            .push(certificate.map_err(|_| BackendError::Unsupported(INVALID_TLS_CA_BUNDLE))?);
    }
    if certificates.is_empty() {
        return Err(BackendError::Unsupported(INVALID_TLS_CA_BUNDLE));
    }

    Ok(certificates)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn trim_ascii_whitespace(bytes: &[u8]) -> &[u8] {
    let start = bytes
        .iter()
        .position(|byte| !byte.is_ascii_whitespace())
        .unwrap_or(bytes.len());
    let end = bytes
        .iter()
        .rposition(|byte| !byte.is_ascii_whitespace())
        .map_or(start, |position| position + 1);

    &bytes[start..end]
}
