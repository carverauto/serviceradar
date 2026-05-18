#[cfg(serviceradar_rdp_connector_link_probe)]
fn open_connector_for_experimental_with_runtime(
    request: &OpenPayload,
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    runtime: ConnectorRuntimePolicy,
) -> Result<Box<dyn RdpBackendSession>, BackendError> {
    prepare_connector_open_for_experimental(plan, credential)?;

    let handoff = connect_verified_credssp_handoff_for_experimental(plan, credential, runtime)?;
    let handoff = match finalize_verified_connector_for_experimental(handoff, runtime) {
        Ok(handoff) => handoff,
        Err(failure) => return Err(failure.error),
    };
    let session = finalized_connector_handoff_into_network_pump_session_for_probe(
        handoff,
        io::sink(),
        request,
    )?;

    Ok(Box::new(session))
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_connector_config_preflight_for_experimental(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> Result<ExperimentalConnectorOpenPreflight, BackendError> {
    let (domain, username) = credential.connector_identity();
    let dial_target = build_connector_dial_target_for_plan(plan)?;
    if username.trim().is_empty()
        || credential.password.value.is_empty()
        || plan.tls_server_name.trim().is_empty()
        || plan.desktop_width == 0
        || plan.desktop_height == 0
    {
        return Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN));
    }

    Ok(ExperimentalConnectorOpenPreflight {
        upstream_host: dial_target.host,
        upstream_port: dial_target.port,
        upstream_endpoint: dial_target.endpoint,
        tls_server_name: plan.tls_server_name.clone(),
        desktop_width: plan.desktop_width,
        desktop_height: plan.desktop_height,
        domain: domain.map(str::to_owned),
        username: username.to_owned(),
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_connector_dial_target_for_plan(
    plan: &NonSecretConnectionPlan,
) -> Result<ConnectorDialTarget, BackendError> {
    let host = plan.upstream_host.trim();
    if host.is_empty()
        || host.len() > MAX_DIAL_HOST_LEN
        || host
            .chars()
            .any(|ch| ch.is_ascii_control() || ch.is_whitespace())
    {
        return Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN));
    }

    let endpoint = match host.parse::<IpAddr>() {
        Ok(IpAddr::V6(_)) => format!("[{host}]:{}", plan.upstream_port),
        _ => format!("{host}:{}", plan.upstream_port),
    };

    Ok(ConnectorDialTarget {
        host: host.to_owned(),
        port: plan.upstream_port,
        endpoint,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn dial_connector_tcp_for_probe(
    plan: &NonSecretConnectionPlan,
    timeout: Duration,
) -> Result<DialedConnectorStream<TcpStream>, BackendError> {
    let dial_target = build_connector_dial_target_for_plan(plan)?;
    let mut addresses = dial_target
        .endpoint
        .to_socket_addrs()
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let remote_addr = addresses
        .next()
        .ok_or(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let stream = TcpStream::connect_timeout(&remote_addr, timeout)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    stream
        .set_read_timeout(Some(timeout))
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    stream
        .set_write_timeout(Some(timeout))
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let client_addr = stream
        .local_addr()
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    Ok(DialedConnectorStream {
        stream,
        client_addr,
        dial_target,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_connector_config_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> ironrdp_connector::Config {
    let (domain, username) = credential.connector_identity();

    ironrdp_connector::Config {
        desktop_size: ironrdp_connector::DesktopSize {
            width: plan.desktop_width,
            height: plan.desktop_height,
        },
        desktop_scale_factor: 0,
        enable_tls: false,
        enable_credssp: true,
        credentials: ironrdp_connector::Credentials::UsernamePassword {
            username: username.to_owned(),
            password: credential.password.value.as_str().to_owned(),
        },
        domain: domain.map(str::to_owned),
        client_build: 1,
        client_name: "serviceradar".to_owned(),
        keyboard_type: ironrdp_pdu::gcc::KeyboardType::IbmEnhanced,
        keyboard_subtype: 0,
        keyboard_functional_keys_count: 12,
        keyboard_layout: 0,
        ime_file_name: String::new(),
        bitmap: None,
        dig_product_id: String::new(),
        client_dir: "C:\\Windows\\System32\\mstscax.dll".to_owned(),
        platform: ironrdp_pdu::rdp::capability_sets::MajorPlatformType::UNIX,
        hardware_id: None,
        request_data: None,
        autologon: false,
        enable_audio_playback: false,
        performance_flags: ironrdp_pdu::rdp::client_info::PerformanceFlags::default(),
        license_cache: None,
        timezone_info: ironrdp_pdu::rdp::client_info::TimezoneInfo::default(),
        enable_server_pointer: false,
        pointer_software_rendering: false,
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_initial_connector_pdu_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> Result<Vec<u8>, BackendError> {
    let config = build_connector_config_for_probe(plan, credential);
    let mut connector =
        ironrdp_connector::ClientConnector::new(config, default_connector_client_addr_for_probe());
    let mut buffer = ironrdp_core::WriteBuf::new();
    let written = ironrdp_connector::Sequence::step_no_input(&mut connector, &mut buffer)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let written_len = written
        .size()
        .ok_or(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    Ok(buffer.filled()[..written_len].to_vec())
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn decode_initial_connection_request_for_probe(
    bytes: &[u8],
) -> Result<ironrdp_pdu::nego::ConnectionRequest, BackendError> {
    let request = ironrdp_core::decode::<
        ironrdp_pdu::x224::X224<ironrdp_pdu::nego::ConnectionRequest>,
    >(bytes)
    .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?
    .0;

    Ok(request)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn drive_connector_to_upgrade_boundary_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    selected_protocol: ironrdp_pdu::nego::SecurityProtocol,
) -> Result<ConnectorUpgradeBoundaryProbe, BackendError> {
    let config = build_connector_config_for_probe(plan, credential);
    let mut connector =
        ironrdp_connector::ClientConnector::new(config, default_connector_client_addr_for_probe());
    let mut initial = ironrdp_core::WriteBuf::new();
    ironrdp_connector::Sequence::step_no_input(&mut connector, &mut initial)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    let server_confirm = encode_server_confirm_for_probe(selected_protocol)?;
    let mut output = ironrdp_core::WriteBuf::new();
    ironrdp_connector::Sequence::step(&mut connector, &server_confirm, &mut output)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    let requires_security_upgrade = connector.should_perform_security_upgrade();
    connector.mark_security_upgrade_as_done();

    Ok(ConnectorUpgradeBoundaryProbe {
        requires_security_upgrade,
        requires_credssp_after_upgrade: connector.should_perform_credssp(),
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn encode_server_confirm_for_probe(
    selected_protocol: ironrdp_pdu::nego::SecurityProtocol,
) -> Result<Vec<u8>, BackendError> {
    ironrdp_core::encode_vec(&ironrdp_pdu::x224::X224(
        ironrdp_pdu::nego::ConnectionConfirm::Response {
            flags: ironrdp_pdu::nego::ResponseFlags::empty(),
            protocol: selected_protocol,
        },
    ))
    .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn drive_blocking_connect_begin_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> Result<BlockingConnectBeginProbe, BackendError> {
    let server_confirm =
        encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)?;
    let handoff = begin_connector_handoff_for_probe(
        plan,
        credential,
        ScriptedStream::new(vec![server_confirm]),
    )?;
    let requires_security_upgrade = handoff.requires_security_upgrade();
    let (stream, leftover) = handoff.framed.into_inner();
    if !leftover.is_empty() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    Ok(BlockingConnectBeginProbe {
        requires_security_upgrade,
        contains_cleartext_password: bytes_contain_secret(
            &stream.writes,
            credential.password.value.as_str().as_bytes(),
        ),
        written_bytes: stream.writes,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn begin_connector_handoff_for_probe<S>(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    stream: S,
) -> Result<ConnectorBeginHandoff<S>, BackendError>
where
    S: Sync + Read + Write,
{
    begin_connector_handoff_with_client_addr_for_probe(
        plan,
        credential,
        stream,
        default_connector_client_addr_for_probe(),
    )
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn begin_connector_handoff_with_tcp_dial_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    timeout: Duration,
) -> Result<ConnectorBeginHandoff<TcpStream>, BackendError> {
    let dialed = dial_connector_tcp_for_probe(plan, timeout)?;

    begin_connector_handoff_with_dialed_stream_for_probe(plan, credential, dialed)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn connect_verified_credssp_handoff_for_experimental(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    runtime: ConnectorRuntimePolicy,
) -> Result<
    ConnectorCredsspHandoff<rustls::StreamOwned<rustls::ClientConnection, TcpStream>>,
    BackendError,
> {
    let begin_handoff =
        begin_connector_handoff_with_tcp_dial_for_probe(plan, credential, runtime.dial_timeout)?;

    upgrade_connector_handoff_tls_for_probe(begin_handoff)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn finalize_verified_connector_for_experimental(
    handoff: ConnectorCredsspHandoff<rustls::StreamOwned<rustls::ClientConnection, TcpStream>>,
    runtime: ConnectorRuntimePolicy,
) -> Result<
    ConnectorFinalizedHandoff<rustls::StreamOwned<rustls::ClientConnection, TcpStream>>,
    ConnectorFinalizeFailure<rustls::StreamOwned<rustls::ClientConnection, TcpStream>>,
> {
    let mut network_client = ServiceRadarKdcNetworkClient {
        timeout: runtime.kdc_timeout,
    };

    finalize_connector_handoff_for_probe(handoff, &mut network_client)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn begin_connector_handoff_with_client_addr_for_probe<S>(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    stream: S,
    client_addr: SocketAddr,
) -> Result<ConnectorBeginHandoff<S>, BackendError>
where
    S: Sync + Read + Write,
{
    let dialed = prepare_dialed_connector_stream_for_probe(plan, stream, client_addr)?;

    begin_connector_handoff_with_dialed_stream_for_probe(plan, credential, dialed)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn prepare_dialed_connector_stream_for_probe<S>(
    plan: &NonSecretConnectionPlan,
    stream: S,
    client_addr: SocketAddr,
) -> Result<DialedConnectorStream<S>, BackendError>
where
    S: Read + Write,
{
    Ok(DialedConnectorStream {
        stream,
        client_addr,
        dial_target: build_connector_dial_target_for_plan(plan)?,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn begin_connector_handoff_with_dialed_stream_for_probe<S>(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    dialed: DialedConnectorStream<S>,
) -> Result<ConnectorBeginHandoff<S>, BackendError>
where
    S: Sync + Read + Write,
{
    let config = build_connector_config_for_probe(plan, credential);
    let tls_config = build_verified_tls_client_config_for_plan(plan)?;
    let kerberos_config = build_connector_kerberos_config_for_plan(plan)?;
    let kerberos_binding = connector_kerberos_binding_from_config(&kerberos_config);
    let server_name = ironrdp_connector::ServerName::from(&plan.tls_server_name);
    let DialedConnectorStream {
        stream,
        client_addr,
        dial_target,
    } = dialed;
    let mut connector = ironrdp_connector::ClientConnector::new(config, client_addr);
    let mut framed = ironrdp_blocking::Framed::new(stream);

    let should_upgrade = ironrdp_blocking::connect_begin(&mut framed, &mut connector)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    Ok(ConnectorBeginHandoff {
        framed,
        should_upgrade,
        connector,
        dial_target,
        tls_config,
        server_name,
        kerberos_binding,
        kerberos_config,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn default_connector_client_addr_for_probe() -> SocketAddr {
    "127.0.0.1:0".parse().expect("loopback")
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn drive_blocking_connect_finalize_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    server_public_key: VerifiedTlsPeerPublicKeyForProbe,
) -> Result<BlockingConnectFinalizeProbe, BackendError> {
    let server_confirm =
        encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)?;
    let handoff = begin_connector_handoff_for_probe(
        plan,
        credential,
        ScriptedStream::new(vec![server_confirm]),
    )?;
    let (stream, leftover) = handoff.framed.get_inner();
    if !leftover.is_empty() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    let initial_write_len = stream.writes.len();
    let credssp_handoff =
        mark_connector_handoff_tls_upgraded_for_probe(handoff, server_public_key)?;
    let mut network_client = RejectingNetworkClient;
    let failure = match finalize_connector_handoff_for_probe(credssp_handoff, &mut network_client) {
        Ok(_) => return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED)),
        Err(failure) => failure,
    };
    let (stream, leftover) = failure.framed.into_inner();
    if !leftover.is_empty() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }
    if failure.error != BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED) {
        return Err(failure.error);
    }

    Ok(BlockingConnectFinalizeProbe {
        wrote_credssp_bytes: stream.writes.len() > initial_write_len,
        contains_cleartext_password: bytes_contain_secret(
            &stream.writes,
            credential.password.value.as_str().as_bytes(),
        ),
        written_bytes: stream.writes,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn finalize_connector_handoff_for_probe<S, N>(
    handoff: ConnectorCredsspHandoff<S>,
    network_client: &mut N,
) -> Result<ConnectorFinalizedHandoff<S>, ConnectorFinalizeFailure<S>>
where
    S: Read + Write,
    N: ironrdp_connector::sspi::network_client::NetworkClient,
{
    let ConnectorCredsspHandoff {
        mut framed,
        upgraded,
        connector,
        server_name,
        server_public_key,
        kerberos_binding,
        kerberos_config,
    } = handoff;
    if let Err(err) = validate_connector_kerberos_binding(&kerberos_binding, &kerberos_config) {
        return Err(ConnectorFinalizeFailure { framed, error: err });
    }

    match ironrdp_blocking::connect_finalize(
        upgraded,
        connector,
        &mut framed,
        network_client,
        server_name,
        server_public_key,
        kerberos_config,
    ) {
        Ok(connection_result) => {
            let desktop_size = connection_result.desktop_size;

            Ok(ConnectorFinalizedHandoff {
                framed,
                connection_result,
                desktop_size,
            })
        }
        Err(_) => Err(ConnectorFinalizeFailure {
            framed,
            error: BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED),
        }),
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn mark_connector_handoff_tls_upgraded_for_probe<S>(
    handoff: ConnectorBeginHandoff<S>,
    server_public_key: VerifiedTlsPeerPublicKeyForProbe,
) -> Result<ConnectorCredsspHandoff<S>, BackendError>
where
    S: Read + Write,
{
    let server_public_key = server_public_key.into_bytes();
    if server_public_key.is_empty() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    let ConnectorBeginHandoff {
        framed,
        should_upgrade,
        mut connector,
        dial_target: _dial_target,
        tls_config: _tls_config,
        server_name,
        kerberos_binding,
        kerberos_config,
    } = handoff;
    validate_connector_kerberos_binding(&kerberos_binding, &kerberos_config)?;
    let upgraded = ironrdp_blocking::mark_as_upgraded(should_upgrade, &mut connector);

    Ok(ConnectorCredsspHandoff {
        framed,
        upgraded,
        connector,
        server_name,
        server_public_key,
        kerberos_binding,
        kerberos_config,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn upgrade_connector_handoff_tls_for_probe<S>(
    handoff: ConnectorBeginHandoff<S>,
) -> Result<ConnectorCredsspHandoff<rustls::StreamOwned<rustls::ClientConnection, S>>, BackendError>
where
    S: Read + Write,
{
    let ConnectorBeginHandoff {
        framed,
        should_upgrade,
        mut connector,
        dial_target: _dial_target,
        tls_config,
        server_name,
        kerberos_binding,
        kerberos_config,
    } = handoff;
    validate_connector_kerberos_binding(&kerberos_binding, &kerberos_config)?;
    let (stream, leftover) = framed.into_inner();
    if !leftover.is_empty() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    let tls_server_name = rustls::pki_types::ServerName::try_from(server_name.as_str().to_owned())
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let client_config = Arc::new(tls_config.config);
    let client_connection = rustls::ClientConnection::new(client_config, tls_server_name)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let mut tls_stream = rustls::StreamOwned::new(client_connection, stream);
    while tls_stream.conn.is_handshaking() {
        tls_stream
            .conn
            .complete_io(&mut tls_stream.sock)
            .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    }
    if tls_stream.conn.is_handshaking() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    let peer_certificate = tls_stream
        .conn
        .peer_certificates()
        .and_then(|certificates| certificates.first())
        .ok_or(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let server_public_key = derive_credssp_server_public_key_from_verified_tls_peer_for_probe(
        peer_certificate.as_ref(),
    )?
    .into_bytes();
    let upgraded = ironrdp_blocking::mark_as_upgraded(should_upgrade, &mut connector);

    Ok(ConnectorCredsspHandoff {
        framed: ironrdp_blocking::Framed::new(tls_stream),
        upgraded,
        connector,
        server_name,
        server_public_key,
        kerberos_binding,
        kerberos_config,
    })
}

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

    ironrdp_connector::credssp::KerberosConfig::new(
        plan.kdc_proxy_url.clone(),
        plan.kerberos_hostname.clone(),
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
        hostname: config.hostname.clone(),
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

