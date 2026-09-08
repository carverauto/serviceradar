#[derive(Debug, Eq, PartialEq)]
struct NonSecretConnectionPlan {
    upstream_host: String,
    upstream_port: u16,
    tls_server_name: String,
    tls_trust_source: TlsTrustSource,
    kdc_proxy_url: Option<String>,
    kerberos_hostname: Option<String>,
    desktop_width: u16,
    desktop_height: u16,
}

#[derive(Debug, Eq, PartialEq)]
enum TlsTrustSource {
    SystemRoots,
    RegisteredCaBundle { id: String, pem: String },
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct ConnectorUpgradeBoundaryProbe {
    requires_security_upgrade: bool,
    requires_credssp_after_upgrade: bool,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct BlockingConnectBeginProbe {
    requires_security_upgrade: bool,
    contains_cleartext_password: bool,
    written_bytes: Vec<u8>,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct BlockingConnectFinalizeProbe {
    wrote_credssp_bytes: bool,
    contains_cleartext_password: bool,
    written_bytes: Vec<u8>,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ConnectorRuntimePolicy {
    dial_timeout: Duration,
    kdc_timeout: Duration,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl Default for ConnectorRuntimePolicy {
    fn default() -> Self {
        Self {
            dial_timeout: DEFAULT_CONNECTOR_TIMEOUT,
            kdc_timeout: DEFAULT_CONNECTOR_TIMEOUT,
        }
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn connector_runtime_policy_from_request(
    request: &OpenPayload,
) -> Result<ConnectorRuntimePolicy, BackendError> {
    Ok(ConnectorRuntimePolicy {
        dial_timeout: optional_metadata_timeout_ms(
            &request.target.metadata,
            METADATA_DIAL_TIMEOUT_MS,
        )?
        .unwrap_or(DEFAULT_CONNECTOR_TIMEOUT),
        kdc_timeout: optional_metadata_timeout_ms(
            &request.target.metadata,
            METADATA_KDC_TIMEOUT_MS,
        )?
        .unwrap_or(DEFAULT_CONNECTOR_TIMEOUT),
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn optional_metadata_timeout_ms(
    metadata: &std::collections::BTreeMap<String, String>,
    key: &str,
) -> Result<Option<Duration>, BackendError> {
    let Some(value) = metadata.get(key).map(|value| value.trim()) else {
        return Ok(None);
    };
    if value.is_empty() {
        return Ok(None);
    }
    let millis = value
        .parse::<u64>()
        .map_err(|_| BackendError::Unsupported(INVALID_CONNECTION_PLAN))?;
    if millis == 0 {
        return Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN));
    }

    let timeout = Duration::from_millis(millis);
    if timeout > MAX_CONNECTOR_STAGE_TIMEOUT {
        return Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN));
    }

    Ok(Some(timeout))
}
