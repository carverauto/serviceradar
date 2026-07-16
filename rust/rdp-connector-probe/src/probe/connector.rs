fn validate_service_radar_open_request(
    request: &ServiceRadarOpenRequest,
) -> Result<(), &'static str> {
    if request.schema != OPEN_SCHEMA {
        return Err("open payload schema is unsupported");
    }
    if request.session_id.trim().is_empty() || request.start_unix <= 0 {
        return Err("session policy is invalid");
    }
    if request.local_agent_id.trim().is_empty() {
        return Err("local agent is required");
    }
    if request.target.protocol != "rdp" && request.target.protocol != "desktop" {
        return Err("target protocol is unsupported");
    }
    if request.target.route.selected_agent_id != request.local_agent_id
        || (!request.gateway_id.is_empty()
            && !request.target.route.selected_gateway_id.is_empty()
            && request.target.route.selected_gateway_id != request.gateway_id)
    {
        return Err("selected route is invalid");
    }
    if !request.target.route.allowed_agent_ids.is_empty()
        && !request
            .target
            .route
            .allowed_agent_ids
            .iter()
            .any(|agent_id| agent_id == &request.target.route.selected_agent_id)
    {
        return Err("selected route is not allowed");
    }
    if request.target.upstream.host.trim().is_empty() || request.target.upstream.port == 0 {
        return Err("upstream target is required");
    }
    if !matches!(
        request.target.tls.mode.as_str(),
        "verify" | "pinned_ca" | "system"
    ) || request.tls_nla_mode() != "required"
    {
        return Err("nla is required");
    }
    if request.target.credential.mode != "memory_user"
        || request.credential_grant.mode != "memory_user"
    {
        return Err("memory-user credential grant is required");
    }
    if request.credential_grant.username.trim().is_empty()
        || request.credential_grant.password.is_empty()
    {
        return Err("username and password are required");
    }
    if !request.target.credential.allowed_principals.is_empty()
        && !request
            .target
            .credential
            .allowed_principals
            .iter()
            .any(|principal| principal == &request.credential_grant.username)
    {
        return Err("credential principal is not allowed");
    }
    if !request.credential_grant.session_id.is_empty()
        && request.credential_grant.session_id != request.session_id
    {
        return Err("credential grant session is invalid");
    }
    if !request.credential_grant.target_id.is_empty()
        && request.credential_grant.target_id != request.target.target_id
    {
        return Err("credential grant target is invalid");
    }
    if request.target.screen.max_width == 0
        || request.target.screen.max_height == 0
        || request.target.screen.frame_rate == 0
        || request.target.screen.bitrate_bps == 0
        || request.target.screen.idle_seconds == 0
        || request.target.screen.ttl_seconds == 0
    {
        return Err("screen policy is invalid");
    }
    if request.target.redirection.clipboard_mode != "disabled"
        || request.target.redirection.drive
        || request.target.redirection.printer
        || request.target.redirection.audio
        || request.target.redirection.smart_card
        || request.target.redirection.file_copy
    {
        return Err("redirection policy is unsupported");
    }
    if !request.target.recording.metadata_enabled
        || request.target.recording.screen_enabled
        || request.target.recording.clipboard_enabled
        || request.target.recording.file_enabled
        || request.target.recording.audio_enabled
    {
        return Err("recording policy is unsupported");
    }

    Ok(())
}

fn split_domain_username(username: String) -> (Option<String>, String) {
    if let Some((domain, login)) = username.split_once('\\')
        && !domain.is_empty()
        && !login.is_empty()
    {
        return (Some(domain.to_owned()), login.to_owned());
    }

    (None, username)
}

pub fn build_initial_connector_pdu(
    request: ServiceRadarOpenRequest,
) -> Result<InitialConnectorPdu, &'static str> {
    let password = Zeroizing::new(request.credential_grant.password.clone());
    let config = build_connector_config(request)?;
    let mut connector = ironrdp_connector::ClientConnector::new(config, CLIENT_ADDR);
    let before_state = connector_state_name(&connector);
    let mut buffer = ironrdp_core::WriteBuf::new();
    let written = ironrdp_connector::Sequence::step_no_input(&mut connector, &mut buffer)
        .map_err(|_| "initial connector step failed")?;
    let written_len = written
        .size()
        .ok_or("initial connector step wrote no bytes")?;

    Ok(InitialConnectorPdu {
        before_state,
        after_state: connector_state_name(&connector),
        advertises_credssp: initial_pdu_advertises_credssp(buffer.filled())?,
        advertises_tls_fallback: initial_pdu_advertises_tls_fallback(buffer.filled())?,
        mstshash_cookie: initial_pdu_mstshash_cookie(buffer.filled())?,
        contains_cleartext_password: bytes_contain_secret(buffer.filled(), password.as_bytes()),
        bytes: buffer.filled()[..written_len].to_vec(),
    })
}

pub fn drive_connector_to_credssp_boundary(
    request: ServiceRadarOpenRequest,
) -> Result<ConnectorUpgradeBoundary, &'static str> {
    drive_connector_with_server_protocol(request, ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)
}

pub fn drive_blocking_connect_begin_to_tls_upgrade(
    request: ServiceRadarOpenRequest,
) -> Result<BlockingConnectBeginProbe, &'static str> {
    let password = Zeroizing::new(request.credential_grant.password.clone());
    let config = build_connector_config(request)?;
    let server_confirm = encode_server_confirm(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)?;
    let mut connector = ironrdp_connector::ClientConnector::new(config, CLIENT_ADDR);
    let before_state = connector_state_name(&connector);
    let mut framed = ironrdp_blocking::Framed::new(ScriptedStream::new(vec![server_confirm]));

    ironrdp_blocking::connect_begin(&mut framed, &mut connector)
        .map_err(|_| "blocking connect begin failed")?;

    let after_state = connector_state_name(&connector);
    let requires_security_upgrade = connector.should_perform_security_upgrade();
    let (stream, leftover) = framed.into_inner();
    if !leftover.is_empty() {
        return Err("blocking connect begin left unread bytes");
    }

    Ok(BlockingConnectBeginProbe {
        before_state,
        after_state,
        requires_security_upgrade,
        contains_cleartext_password: bytes_contain_secret(&stream.writes, password.as_bytes()),
        written_bytes: stream.writes,
    })
}

pub fn drive_live_blocking_connect_begin_to_tls_upgrade(
    request: ServiceRadarOpenRequest,
    timeout: Duration,
) -> Result<BlockingConnectBeginProbe, String> {
    let password = Zeroizing::new(request.credential_grant.password.clone());
    let plan = build_connector_plan(request).map_err(str::to_owned)?;
    let target = (plan.upstream_host.as_str(), plan.upstream_port)
        .to_socket_addrs()
        .map_err(|err| format!("rdp target address resolution failed: {err}"))?
        .next()
        .ok_or_else(|| "rdp target address resolution returned no addresses".to_owned())?;
    let stream = TcpStream::connect_timeout(&target, timeout)
        .map_err(|err| format!("rdp target connect failed: {err}"))?;
    stream
        .set_read_timeout(Some(timeout))
        .map_err(|err| format!("rdp target read timeout setup failed: {err}"))?;
    stream
        .set_write_timeout(Some(timeout))
        .map_err(|err| format!("rdp target write timeout setup failed: {err}"))?;

    let mut connector = ironrdp_connector::ClientConnector::new(plan.connector_config, CLIENT_ADDR);
    let before_state = connector_state_name(&connector);
    let mut framed = ironrdp_blocking::Framed::new(RecordingStream::new(stream));

    ironrdp_blocking::connect_begin(&mut framed, &mut connector)
        .map_err(|err| format!("live blocking connect begin failed: {err}"))?;

    let after_state = connector_state_name(&connector);
    let requires_security_upgrade = connector.should_perform_security_upgrade();
    let (stream, leftover) = framed.into_inner();
    if !leftover.is_empty() {
        return Err("live blocking connect begin left unread bytes".to_owned());
    }

    Ok(BlockingConnectBeginProbe {
        before_state,
        after_state,
        requires_security_upgrade,
        contains_cleartext_password: bytes_contain_secret(&stream.writes, password.as_bytes()),
        written_bytes: stream.writes,
    })
}

pub fn drive_live_tls_upgrade_accepting_invalid_certificates_for_lab(
    request: ServiceRadarOpenRequest,
    timeout: Duration,
) -> Result<LiveTlsUpgradeProbe, String> {
    let config = lab_tls_client_config_accepting_invalid_certificates();

    drive_live_tls_upgrade_with_client_config(request, timeout, config)
}

pub fn drive_live_tls_upgrade_with_registered_ca_bundle(
    request: ServiceRadarOpenRequest,
    ca_bundle: &[u8],
    timeout: Duration,
) -> Result<LiveTlsUpgradeProbe, String> {
    let (config, _) = build_tls_client_config_for_registered_ca_bundle(ca_bundle)?;

    drive_live_tls_upgrade_with_client_config(request, timeout, config)
}

pub fn drive_live_tls_upgrade_with_system_roots(
    request: ServiceRadarOpenRequest,
    timeout: Duration,
) -> Result<LiveTlsUpgradeProbe, String> {
    let (config, _) = build_tls_client_config_for_system_roots()?;

    drive_live_tls_upgrade_with_client_config(request, timeout, config)
}

fn drive_live_tls_upgrade_with_client_config(
    request: ServiceRadarOpenRequest,
    timeout: Duration,
    config: rustls::ClientConfig,
) -> Result<LiveTlsUpgradeProbe, String> {
    let password = Zeroizing::new(request.credential_grant.password.clone());
    let plan = build_connector_plan(request).map_err(str::to_owned)?;
    let target = resolve_rdp_target(&plan)?;
    let stream = connect_rdp_target(target, timeout)?;
    let client_addr = stream
        .local_addr()
        .map_err(|err| format!("rdp client local address lookup failed: {err}"))?;

    let mut connector = ironrdp_connector::ClientConnector::new(plan.connector_config, client_addr);
    let before_state = connector_state_name(&connector);
    let mut framed = ironrdp_blocking::Framed::new(RecordingStream::new(stream));
    let should_upgrade = ironrdp_blocking::connect_begin(&mut framed, &mut connector)
        .map_err(|err| format!("live blocking connect begin failed: {err}"))?;
    let after_begin_state = connector_state_name(&connector);
    let (recording_stream, leftover) = framed.into_inner();
    if !leftover.is_empty() {
        return Err("live blocking connect begin left unread bytes".to_owned());
    }

    let initial_written_len = recording_stream.writes.len();
    let (tls_stream, server_public_key) =
        tls_upgrade_with_client_config(recording_stream, plan.tls_server_name, config)?;
    let peer_certificate_count = tls_stream
        .conn
        .peer_certificates()
        .map_or(0, <[rustls::pki_types::CertificateDer<'_>]>::len);
    let _upgraded = ironrdp_blocking::mark_as_upgraded(should_upgrade, &mut connector);
    let after_upgrade_state = connector_state_name(&connector);
    let tls_writes = tls_stream
        .sock
        .writes
        .len()
        .saturating_sub(initial_written_len);
    let contains_cleartext_password =
        bytes_contain_secret(&tls_stream.sock.writes, password.as_bytes());

    Ok(LiveTlsUpgradeProbe {
        before_state,
        after_begin_state,
        after_upgrade_state,
        peer_certificate_count,
        server_public_key_len: server_public_key.len(),
        contains_cleartext_password,
        wrote_tls_bytes: tls_writes > 0,
    })
}

pub fn drive_blocking_connect_finalize_until_server_input(
    request: ServiceRadarOpenRequest,
    server_public_key: Vec<u8>,
) -> Result<BlockingConnectFinalizeProbe, &'static str> {
    if server_public_key.is_empty() {
        return Err("server public key is required");
    }

    let password = Zeroizing::new(request.credential_grant.password.clone());
    let plan = build_connector_plan(request)?;
    let server_confirm = encode_server_confirm(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)?;
    let mut connector = ironrdp_connector::ClientConnector::new(plan.connector_config, CLIENT_ADDR);
    let mut framed = ironrdp_blocking::Framed::new(ScriptedStream::new(vec![server_confirm]));
    let should_upgrade = ironrdp_blocking::connect_begin(&mut framed, &mut connector)
        .map_err(|_| "blocking connect begin failed")?;
    let (_initial_stream, leftover) = framed.into_inner();
    if !leftover.is_empty() {
        return Err("blocking connect begin left unread bytes");
    }

    let upgraded = ironrdp_blocking::mark_as_upgraded(should_upgrade, &mut connector);
    let after_upgrade_state = connector_state_name(&connector);
    let mut upgraded_framed = ironrdp_blocking::Framed::new(ScriptedStream::new(Vec::new()));
    let mut network_client = RejectingNetworkClient;
    let finalize = ironrdp_blocking::connect_finalize(
        upgraded,
        connector,
        &mut upgraded_framed,
        &mut network_client,
        plan.tls_server_name.into(),
        server_public_key,
        None,
    );
    if finalize.is_ok() {
        return Err("blocking connect finalize unexpectedly completed");
    }

    let (stream, leftover) = upgraded_framed.into_inner();
    if !leftover.is_empty() {
        return Err("blocking connect finalize left unread bytes");
    }

    Ok(BlockingConnectFinalizeProbe {
        after_upgrade_state,
        wrote_credssp_bytes: !stream.writes.is_empty(),
        contains_cleartext_password: bytes_contain_secret(&stream.writes, password.as_bytes()),
        written_bytes: stream.writes,
    })
}

