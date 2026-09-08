#[cfg(serviceradar_rdp_connector_link_probe)]
fn live_env(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn parse_live_adapter_target(target: &str) -> Result<(String, u16), &'static str> {
    let target = target.trim();
    if target.is_empty() {
        return Err("empty target");
    }

    if let Some((host, port)) = target.rsplit_once(':') {
        if !host.contains(':')
            && !port.is_empty()
            && port.chars().all(|value| value.is_ascii_digit())
        {
            let port = port.parse::<u16>().map_err(|_| "invalid port")?;

            return Ok((host.to_owned(), port));
        }
    }

    Ok((target.to_owned(), 3389))
}

#[cfg(serviceradar_rdp_connector_link_probe)]
pub fn run_live_helper_open_probe_from_env() -> Result<(), String> {
    let Some(target) = live_env("SERVICERADAR_RDP_ADAPTER_LIVE_TARGET") else {
        eprintln!(
            "skipping live RDP adapter open probe; \
             SERVICERADAR_RDP_ADAPTER_LIVE_TARGET is not set"
        );
        return Ok(());
    };
    let Some(username) = live_env("SERVICERADAR_RDP_ADAPTER_LIVE_USERNAME") else {
        eprintln!(
            "skipping live RDP adapter open probe; \
             SERVICERADAR_RDP_ADAPTER_LIVE_USERNAME is not set"
        );
        return Ok(());
    };
    let Some(password) = live_env("SERVICERADAR_RDP_ADAPTER_LIVE_PASSWORD") else {
        eprintln!(
            "skipping live RDP adapter open probe; \
             SERVICERADAR_RDP_ADAPTER_LIVE_PASSWORD is not set"
        );
        return Ok(());
    };

    let (host, port) = parse_live_adapter_target(&target)?;
    let mut payload = parse_open_payload(live_adapter_open_payload_template().as_bytes())
        .map_err(|err| err.to_string())?;
    payload.target.upstream.host = host.clone();
    payload.target.upstream.port = u32::from(port);
    payload.target.tls.server_name =
        live_env("SERVICERADAR_RDP_ADAPTER_LIVE_SERVER_NAME").unwrap_or(host);
    if let Some(ca_bundle_file) = live_env("SERVICERADAR_RDP_ADAPTER_LIVE_CA_BUNDLE_FILE") {
        payload.target.tls.ca_bundle_id = "live-ca-bundle-file".to_owned();
        payload.target.tls.ca_bundle_pem =
            std::fs::read_to_string(ca_bundle_file).map_err(|err| err.to_string())?;
    }
    payload.target.credential.allowed_principals = vec![username.clone()];
    payload.target.metadata.insert(
        METADATA_MEDIA_SESSION_ID.to_owned(),
        "media-live-1".to_owned(),
    );
    let grant = payload
        .credential_grant
        .as_mut()
        .ok_or("memory user credential grant is required")?;
    grant.username = username;
    grant.password = password.into();
    grant.session_id = payload.session_id.clone();
    grant.target_id = payload.target.target_id.clone();

    let mut session = open_live_helper_probe_session(&payload)?;
    session
        .close(&DesktopClosePayload {
            reason: "live probe cleanup".to_owned(),
        })
        .map_err(|err| err.to_string())
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn open_live_helper_probe_session(
    payload: &OpenPayload,
) -> Result<
    ActiveStageNetworkPumpSessionProbe<
        rustls::StreamOwned<rustls::ClientConnection, TcpStream>,
        io::Sink,
    >,
    String,
> {
    let Some(grant) = payload.credential_grant.as_ref() else {
        return Err("live payload is missing memory-user credential grant".to_owned());
    };
    if !is_memory_user_grant(grant) {
        return Err("live payload credential grant is not memory-user".to_owned());
    }

    let plan = build_nonsecret_connection_plan(payload)
        .map_err(|err| format!("live connection plan failed: {err}"))?;
    let credential = build_memory_user_credential(grant, &payload.actor_id)
        .map_err(|err| format!("live credential assembly failed: {err}"))?;
    if !credential.has_material() {
        return Err("live credential grant has no usable credential material".to_owned());
    }
    prepare_connector_open_for_experimental(&plan, &credential)
        .map_err(|err| format!("live connector preflight failed: {err}"))?;

    let runtime = connector_runtime_policy_from_request(payload)
        .map_err(|err| format!("live connector runtime policy failed: {err}"))?;
    let dialed = dial_connector_tcp_for_probe(&plan, runtime.dial_timeout)
        .map_err(|err| format!("live TCP dial failed: {err}"))?;
    let begin_handoff =
        begin_connector_handoff_with_dialed_stream_for_probe(&plan, &credential, dialed)
            .map_err(|err| format!("live RDP negotiation begin failed: {err}"))?;
    let credssp_handoff = upgrade_connector_handoff_tls_for_live_probe(begin_handoff)?;
    let handoff = match finalize_verified_connector_for_experimental(credssp_handoff, runtime) {
        Ok(handoff) => handoff,
        Err(failure) => {
            return Err(format!(
                "live CredSSP/connector finalize failed: {}",
                failure.error
            ));
        }
    };

    finalized_connector_handoff_into_network_pump_session_for_probe(handoff, io::sink(), payload)
        .map_err(|err| format!("live active-stage media binding failed: {err}"))
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn upgrade_connector_handoff_tls_for_live_probe<S>(
    handoff: ConnectorBeginHandoff<S>,
) -> Result<ConnectorCredsspHandoff<rustls::StreamOwned<rustls::ClientConnection, S>>, String>
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
    validate_connector_kerberos_binding(&kerberos_binding, &kerberos_config)
        .map_err(|err| format!("live TLS upgrade failed: {err}"))?;
    let (stream, leftover) = framed.into_inner();
    if !leftover.is_empty() {
        return Err(
            "live TLS upgrade failed: connector had buffered bytes before handshake".into(),
        );
    }

    let tls_server_name = rustls::pki_types::ServerName::try_from(server_name.as_str().to_owned())
        .map_err(|_| "live TLS upgrade failed: invalid TLS server name".to_owned())?;
    let client_config = Arc::new(tls_config.config);
    let client_connection = rustls::ClientConnection::new(client_config, tls_server_name)
        .map_err(|_| "live TLS upgrade failed: rustls client setup failed".to_owned())?;
    let mut tls_stream = rustls::StreamOwned::new(client_connection, stream);
    while tls_stream.conn.is_handshaking() {
        tls_stream
            .conn
            .complete_io(&mut tls_stream.sock)
            .map_err(|err| live_tls_handshake_error_message(&err))?;
    }

    let peer_certificate = tls_stream
        .conn
        .peer_certificates()
        .and_then(|certificates| certificates.first())
        .ok_or_else(|| "live TLS upgrade failed: peer certificate was unavailable".to_owned())?;
    let server_public_key = derive_credssp_server_public_key_from_verified_tls_peer_for_probe(
        peer_certificate.as_ref(),
    )
    .map_err(|err| format!("live TLS upgrade failed: {err}"))?
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
fn live_tls_handshake_error_message(err: &io::Error) -> String {
    let message = err.to_string();
    if message.contains("UnknownIssuer") {
        return "live TLS upgrade failed: peer certificate is not trusted by the configured CA roots"
            .to_owned();
    }
    if message.contains("NotValidForName") || message.contains("CertNotValidForName") {
        return "live TLS upgrade failed: configured TLS server name does not match the peer certificate"
            .to_owned();
    }
    if message.contains("Expired") {
        return "live TLS upgrade failed: peer certificate is expired".to_owned();
    }
    if message.contains("NotValidYet") {
        return "live TLS upgrade failed: peer certificate is not valid yet".to_owned();
    }
    if message.contains("NoCertificatesPresented") {
        return "live TLS upgrade failed: peer did not present a certificate".to_owned();
    }

    "live TLS upgrade failed: TLS handshake I/O failed".to_owned()
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn live_adapter_open_payload_template() -> &'static str {
    r#"{
        "schema":"serviceradar.rdp.helper.open.v1",
        "session_id":"session-live-1",
        "actor_id":"user-live-1",
        "local_agent_id":"agent-live-1",
        "gateway_id":"gateway-live-1",
        "start_unix":1778636531,
        "target":{
            "target_id":"target-live-1",
            "display_name":"Live RDP Target",
            "device_uid":"device-live-1",
            "protocol":"rdp",
            "route":{"selected_agent_id":"agent-live-1","selected_gateway_id":"gateway-live-1"},
            "upstream":{"host":"127.0.0.1","port":3389},
            "tls":{"mode":"verify","nla_mode":"required","server_name":"win-live.local"},
            "credential":{"mode":"memory_user","allowed_principals":["placeholder"]},
            "screen":{"max_width":1920,"max_height":1080,"frame_rate":30,"bitrate_bps":8000000,"idle_seconds":900,"ttl_seconds":3600},
            "redirection":{"clipboard_mode":"disabled"},
            "recording":{"metadata_enabled":true}
        },
        "credential_grant":{"mode":"memory_user","username":"placeholder","password":"placeholder","actor_id":"user-live-1","session_id":"session-live-1","target_id":"target-live-1"}
    }"#
}

