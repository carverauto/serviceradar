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
