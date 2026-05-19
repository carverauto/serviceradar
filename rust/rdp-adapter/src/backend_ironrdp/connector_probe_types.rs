#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct VerifiedTlsPeerPublicKeyForProbe {
    bytes: Vec<u8>,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct ExperimentalConnectorOpenPreflight {
    upstream_host: String,
    upstream_port: u16,
    upstream_endpoint: String,
    tls_server_name: String,
    desktop_width: u16,
    desktop_height: u16,
    domain: Option<String>,
    username: String,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct ConnectorDialTarget {
    host: String,
    port: u16,
    endpoint: String,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct DialedConnectorStream<S: Read + Write> {
    stream: S,
    client_addr: SocketAddr,
    dial_target: ConnectorDialTarget,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<S: Read + Write> DialedConnectorStream<S> {
    fn endpoint(&self) -> &str {
        self.dial_target.endpoint.as_str()
    }

    fn client_addr(&self) -> SocketAddr {
        self.client_addr
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
trait NetworkWriteProbe {
    fn writes_len(&self) -> usize;
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl VerifiedTlsPeerPublicKeyForProbe {
    fn into_bytes(self) -> Vec<u8> {
        self.bytes
    }
}
