#[cfg(serviceradar_rdp_connector_link_probe)]
struct ConnectorBeginHandoff<S: Read + Write> {
    framed: ironrdp_blocking::Framed<S>,
    should_upgrade: ironrdp_blocking::ShouldUpgrade,
    connector: ironrdp_connector::ClientConnector,
    dial_target: ConnectorDialTarget,
    tls_config: VerifiedTlsClientConfig,
    server_name: ironrdp_connector::ServerName,
    kerberos_binding: ConnectorKerberosBinding,
    kerberos_config: Option<ironrdp_connector::credssp::KerberosConfig>,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<S: Read + Write> ConnectorBeginHandoff<S> {
    fn requires_security_upgrade(&self) -> bool {
        let _should_upgrade = &self.should_upgrade;

        self.connector.should_perform_security_upgrade()
    }

    fn tls_probe(&self) -> VerifiedTlsClientConfigProbe {
        self.tls_config.probe()
    }

    fn server_name(&self) -> &str {
        self.server_name.as_str()
    }

    fn client_addr(&self) -> SocketAddr {
        self.connector.client_addr
    }

    fn remote_endpoint(&self) -> &str {
        self.dial_target.endpoint.as_str()
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct ConnectorCredsspHandoff<S: Read + Write> {
    framed: ironrdp_blocking::Framed<S>,
    upgraded: ironrdp_blocking::Upgraded,
    connector: ironrdp_connector::ClientConnector,
    server_name: ironrdp_connector::ServerName,
    server_public_key: Vec<u8>,
    kerberos_binding: ConnectorKerberosBinding,
    kerberos_config: Option<ironrdp_connector::credssp::KerberosConfig>,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<S: Read + Write> ConnectorCredsspHandoff<S> {
    fn requires_credssp(&self) -> bool {
        self.connector.should_perform_credssp()
    }

    fn server_name(&self) -> &str {
        self.server_name.as_str()
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct ConnectorFinalizedHandoff<S: Read + Write> {
    framed: ironrdp_blocking::Framed<S>,
    connection_result: ironrdp_connector::ConnectionResult,
    desktop_size: ironrdp_connector::DesktopSize,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct ConnectorKerberosBinding {
    kdc_proxy_url: Option<String>,
    hostname: Option<String>,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<S: Read + Write> ConnectorFinalizedHandoff<S> {
    #[allow(clippy::too_many_arguments)]
    fn into_network_pump_session<W: Write>(
        self,
        upstream: W,
        policy: &DesktopScreenPolicy,
        session_binding_id: String,
        media_session_id: String,
        timestamp_unix_nano: i64,
    ) -> ActiveStageNetworkPumpSessionProbe<S, W> {
        ActiveStageNetworkPumpSessionProbe::from_connection_result(
            self.framed,
            self.connection_result,
            self.desktop_size,
            upstream,
            policy,
            session_binding_id,
            media_session_id,
            timestamp_unix_nano,
        )
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn finalized_connector_handoff_into_network_pump_session_for_probe<S, W>(
    handoff: ConnectorFinalizedHandoff<S>,
    upstream: W,
    request: &OpenPayload,
) -> Result<ActiveStageNetworkPumpSessionProbe<S, W>, BackendError>
where
    S: Read + Write,
    W: Write,
{
    let media_session_id =
        optional_metadata_value(&request.target.metadata, METADATA_MEDIA_SESSION_ID)
            .ok_or(BackendError::Unsupported(INVALID_CONNECTION_PLAN))?;

    Ok(handoff.into_network_pump_session(
        upstream,
        &request.target.screen,
        request.session_id.clone(),
        media_session_id,
        request.start_unix,
    ))
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct ConnectorFinalizeFailure<S: Read + Write> {
    framed: ironrdp_blocking::Framed<S>,
    error: BackendError,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct VerifiedTlsClientConfigProbe {
    trusted_root_count: usize,
    resumption_disabled_for_credssp: bool,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct VerifiedTlsClientConfig {
    config: rustls::ClientConfig,
    trusted_root_count: usize,
    resumption_disabled_for_credssp: bool,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl VerifiedTlsClientConfig {
    fn probe(&self) -> VerifiedTlsClientConfigProbe {
        let _client_config = &self.config;

        VerifiedTlsClientConfigProbe {
            trusted_root_count: self.trusted_root_count,
            resumption_disabled_for_credssp: self.resumption_disabled_for_credssp,
        }
    }
}
