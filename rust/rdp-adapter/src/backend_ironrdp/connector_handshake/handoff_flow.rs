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
