pub fn extract_credssp_server_public_key(cert_der: &[u8]) -> Result<Vec<u8>, &'static str> {
    use x509_cert::der::Decode as _;

    let cert = x509_cert::Certificate::from_der(cert_der)
        .map_err(|_| "tls peer certificate decode failed")?;
    let public_key = cert
        .tbs_certificate
        .subject_public_key_info
        .subject_public_key
        .as_bytes()
        .ok_or("tls peer certificate public key is unaligned")?;

    if public_key.is_empty() {
        return Err("tls peer certificate public key is empty");
    }

    Ok(public_key.to_vec())
}

pub fn build_verified_tls_client_config_for_registered_ca_bundle(
    ca_bundle: &[u8],
) -> Result<VerifiedTlsClientConfigProbe, String> {
    let (_, trusted_root_count) = build_tls_client_config_for_registered_ca_bundle(ca_bundle)?;

    Ok(VerifiedTlsClientConfigProbe {
        trusted_root_count,
        resumption_disabled_for_credssp: true,
    })
}

pub fn build_verified_tls_client_config_for_system_roots(
) -> Result<VerifiedTlsClientConfigProbe, String> {
    let (_, trusted_root_count) = build_tls_client_config_for_system_roots()?;

    Ok(VerifiedTlsClientConfigProbe {
        trusted_root_count,
        resumption_disabled_for_credssp: true,
    })
}

fn build_tls_client_config_for_registered_ca_bundle(
    ca_bundle: &[u8],
) -> Result<(rustls::ClientConfig, usize), String> {
    let certificates = parse_registered_ca_bundle(ca_bundle)?;

    build_tls_client_config_from_certificates(
        certificates,
        "registered CA bundle contains invalid certificate",
        "registered CA bundle contains no certificates",
    )
}

fn build_tls_client_config_for_system_roots() -> Result<(rustls::ClientConfig, usize), String> {
    let native = rustls_native_certs::load_native_certs();
    if !native.errors.is_empty() {
        return Err(format!(
            "system root store load failed with {} error(s)",
            native.errors.len()
        ));
    }

    build_tls_client_config_from_certificates(
        native.certs,
        "system root store contains invalid certificate",
        "system root store contains no certificates",
    )
}

fn build_tls_client_config_from_certificates(
    certificates: Vec<rustls::pki_types::CertificateDer<'static>>,
    invalid_message: &'static str,
    empty_message: &'static str,
) -> Result<(rustls::ClientConfig, usize), String> {
    let mut roots = rustls::RootCertStore::empty();
    let mut added = 0;

    for certificate in certificates {
        roots
            .add(certificate)
            .map_err(|err| format!("{invalid_message}: {err}"))?;
        added += 1;
    }
    if added == 0 {
        return Err(empty_message.to_owned());
    }

    let mut config = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    config.resumption = rustls::client::Resumption::disabled();

    Ok((config, added))
}

fn parse_registered_ca_bundle(
    ca_bundle: &[u8],
) -> Result<Vec<rustls::pki_types::CertificateDer<'static>>, String> {
    let trimmed = trim_ascii_whitespace(ca_bundle);
    if trimmed.is_empty() {
        return Err("ca_bundle_invalid: registered CA bundle is empty".to_owned());
    }

    // Strict PEM only. Raw / DER / unknown bytes are refused with a structured
    // reason so callers fail closed instead of forwarding garbage to rustls,
    // which would later reject it with an opaque cert-validation error.
    if !trimmed
        .windows(b"-----BEGIN CERTIFICATE-----".len())
        .any(|window| window == b"-----BEGIN CERTIFICATE-----")
    {
        return Err(
            "ca_bundle_invalid: registered CA bundle is not PEM-encoded (missing \
             -----BEGIN CERTIFICATE----- marker)"
                .to_owned(),
        );
    }

    use rustls::pki_types::pem::PemObject as _;

    let mut certificates = Vec::new();
    for certificate in rustls::pki_types::CertificateDer::pem_slice_iter(trimmed) {
        certificates.push(certificate.map_err(|err| {
            format!("ca_bundle_invalid: registered CA bundle PEM is invalid: {err}")
        })?);
    }
    if certificates.is_empty() {
        return Err("ca_bundle_invalid: registered CA bundle contains no certificates".to_owned());
    }

    Ok(certificates)
}

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

fn resolve_rdp_target(plan: &ConnectorPlan) -> Result<SocketAddr, String> {
    (plan.upstream_host.as_str(), plan.upstream_port)
        .to_socket_addrs()
        .map_err(|err| format!("rdp target address resolution failed: {err}"))?
        .next()
        .ok_or_else(|| "rdp target address resolution returned no addresses".to_owned())
}

fn connect_rdp_target(target: SocketAddr, timeout: Duration) -> Result<TcpStream, String> {
    let stream = TcpStream::connect_timeout(&target, timeout)
        .map_err(|err| format!("rdp target connect failed: {err}"))?;
    stream
        .set_read_timeout(Some(timeout))
        .map_err(|err| format!("rdp target read timeout setup failed: {err}"))?;
    stream
        .set_write_timeout(Some(timeout))
        .map_err(|err| format!("rdp target write timeout setup failed: {err}"))?;

    Ok(stream)
}

type CredSspTlsStream = rustls::StreamOwned<rustls::ClientConnection, RecordingStream<TcpStream>>;

fn lab_tls_client_config_accepting_invalid_certificates() -> rustls::ClientConfig {
    let mut config = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(std::sync::Arc::new(LabNoCertificateVerification))
        .with_no_client_auth();
    config.resumption = rustls::client::Resumption::disabled();

    config
}

fn tls_upgrade_with_client_config(
    stream: RecordingStream<TcpStream>,
    server_name: String,
    config: rustls::ClientConfig,
) -> Result<(CredSspTlsStream, Vec<u8>), String> {
    let server_name = rustls::pki_types::ServerName::try_from(server_name)
        .map_err(|_| "tls server name is invalid".to_owned())?;
    let client = rustls::ClientConnection::new(std::sync::Arc::new(config), server_name)
        .map_err(|err| format!("tls client setup failed: {err}"))?;
    let mut tls_stream = rustls::StreamOwned::new(client, stream);

    for _ in 0..32 {
        if !tls_stream.conn.is_handshaking() {
            break;
        }
        tls_stream
            .conn
            .complete_io(&mut tls_stream.sock)
            .map_err(|err| format!("tls handshake failed: {err}"))?;
    }
    if tls_stream.conn.is_handshaking() {
        return Err("tls handshake did not complete in bounded steps".to_owned());
    }

    let cert = tls_stream
        .conn
        .peer_certificates()
        .and_then(|certificates| certificates.first())
        .ok_or_else(|| "tls peer certificate is missing".to_owned())?;
    let server_public_key =
        extract_credssp_server_public_key(cert.as_ref()).map_err(str::to_owned)?;

    Ok((tls_stream, server_public_key))
}

#[derive(Debug)]
struct LabNoCertificateVerification;

impl rustls::client::danger::ServerCertVerifier for LabNoCertificateVerification {
    fn verify_server_cert(
        &self,
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &[rustls::pki_types::CertificateDer<'_>],
        _: &rustls::pki_types::ServerName<'_>,
        _: &[u8],
        _: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _: &[u8],
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _: &[u8],
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![
            rustls::SignatureScheme::RSA_PKCS1_SHA1,
            rustls::SignatureScheme::ECDSA_SHA1_Legacy,
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::RSA_PKCS1_SHA384,
            rustls::SignatureScheme::ECDSA_NISTP384_SHA384,
            rustls::SignatureScheme::RSA_PKCS1_SHA512,
            rustls::SignatureScheme::ECDSA_NISTP521_SHA512,
            rustls::SignatureScheme::RSA_PSS_SHA256,
            rustls::SignatureScheme::RSA_PSS_SHA384,
            rustls::SignatureScheme::RSA_PSS_SHA512,
            rustls::SignatureScheme::ED25519,
            rustls::SignatureScheme::ED448,
        ]
    }
}
