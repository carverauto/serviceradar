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
        alternate_shell: String::new(),
        work_dir: String::new(),
        platform: ironrdp_pdu::rdp::capability_sets::MajorPlatformType::UNIX,
        hardware_id: None,
        request_data: None,
        autologon: false,
        enable_audio_playback: false,
        performance_flags: ironrdp_pdu::rdp::client_info::PerformanceFlags::default(),
        license_cache: None,
        timezone_info: ironrdp_pdu::rdp::client_info::TimezoneInfo::default(),
        compression_type: None,
        enable_server_pointer: false,
        pointer_software_rendering: false,
        multitransport_flags: None,
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
