#[cfg(serviceradar_rdp_connector_link_probe)]
struct RejectingNetworkClient;

#[cfg(serviceradar_rdp_connector_link_probe)]
impl ironrdp_connector::sspi::network_client::NetworkClient for RejectingNetworkClient {
    fn send(
        &self,
        _request: &ironrdp_connector::sspi::generator::NetworkRequest,
    ) -> ironrdp_connector::sspi::Result<Vec<u8>> {
        Err(ironrdp_connector::sspi::Error::new(
            ironrdp_connector::sspi::ErrorKind::NoAuthenticatingAuthority,
            "network client is disabled in adapter connector probe",
        ))
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct ServiceRadarKdcNetworkClient {
    timeout: Duration,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl Default for ServiceRadarKdcNetworkClient {
    fn default() -> Self {
        Self {
            timeout: DEFAULT_CONNECTOR_TIMEOUT,
        }
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl ironrdp_connector::sspi::network_client::NetworkClient for ServiceRadarKdcNetworkClient {
    fn send(
        &self,
        request: &ironrdp_connector::sspi::generator::NetworkRequest,
    ) -> ironrdp_connector::sspi::Result<Vec<u8>> {
        match request.protocol {
            ironrdp_connector::sspi::network_client::NetworkProtocol::Tcp => self.send_tcp(request),
            _ => Err(ironrdp_connector::sspi::Error::new(
                ironrdp_connector::sspi::ErrorKind::NoAuthenticatingAuthority,
                "only TCP Kerberos network requests are supported",
            )),
        }
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl ServiceRadarKdcNetworkClient {
    fn send_tcp(
        &self,
        request: &ironrdp_connector::sspi::generator::NetworkRequest,
    ) -> ironrdp_connector::sspi::Result<Vec<u8>> {
        use std::io::{Read as _, Write as _};

        let host = request.url.host_str().ok_or_else(|| {
            ironrdp_connector::sspi::Error::new(
                ironrdp_connector::sspi::ErrorKind::NoAuthenticatingAuthority,
                "Kerberos request is missing host",
            )
        })?;
        let port = request.url.port().unwrap_or(DEFAULT_KDC_PORT);
        let endpoint = match host.parse::<IpAddr>() {
            Ok(IpAddr::V6(_)) => format!("[{host}]:{port}"),
            _ => format!("{host}:{port}"),
        };
        let mut addresses = endpoint.to_socket_addrs().map_err(|err| {
            ironrdp_connector::sspi::Error::new(
                ironrdp_connector::sspi::ErrorKind::NoAuthenticatingAuthority,
                format!("Kerberos TCP address resolution failed: {err}"),
            )
        })?;
        let address = addresses.next().ok_or_else(|| {
            ironrdp_connector::sspi::Error::new(
                ironrdp_connector::sspi::ErrorKind::NoAuthenticatingAuthority,
                "Kerberos TCP address resolution returned no endpoints",
            )
        })?;
        let mut stream = TcpStream::connect_timeout(&address, self.timeout).map_err(|err| {
            ironrdp_connector::sspi::Error::new(
                ironrdp_connector::sspi::ErrorKind::NoAuthenticatingAuthority,
                format!("Kerberos TCP connection failed: {err}"),
            )
        })?;
        stream.set_read_timeout(Some(self.timeout)).map_err(|err| {
            ironrdp_connector::sspi::Error::new(
                ironrdp_connector::sspi::ErrorKind::NoAuthenticatingAuthority,
                format!("Kerberos TCP read timeout setup failed: {err}"),
            )
        })?;
        stream
            .set_write_timeout(Some(self.timeout))
            .map_err(|err| {
                ironrdp_connector::sspi::Error::new(
                    ironrdp_connector::sspi::ErrorKind::NoAuthenticatingAuthority,
                    format!("Kerberos TCP write timeout setup failed: {err}"),
                )
            })?;
        stream.write_all(&request.data).map_err(|err| {
            ironrdp_connector::sspi::Error::new(
                ironrdp_connector::sspi::ErrorKind::NoAuthenticatingAuthority,
                format!("Kerberos TCP send failed: {err}"),
            )
        })?;

        let mut length_bytes = [0_u8; 4];
        stream.read_exact(&mut length_bytes).map_err(|err| {
            ironrdp_connector::sspi::Error::new(
                ironrdp_connector::sspi::ErrorKind::NoAuthenticatingAuthority,
                format!("Kerberos TCP response length read failed: {err}"),
            )
        })?;
        let response_len = u32::from_be_bytes(length_bytes);
        if response_len > MAX_KDC_RESPONSE_BYTES {
            return Err(ironrdp_connector::sspi::Error::new(
                ironrdp_connector::sspi::ErrorKind::NoAuthenticatingAuthority,
                "Kerberos TCP response exceeded maximum size",
            ));
        }

        let mut response = vec![0_u8; response_len as usize + length_bytes.len()];
        response[..length_bytes.len()].copy_from_slice(&length_bytes);
        stream
            .read_exact(&mut response[length_bytes.len()..])
            .map_err(|err| {
                ironrdp_connector::sspi::Error::new(
                    ironrdp_connector::sspi::ErrorKind::NoAuthenticatingAuthority,
                    format!("Kerberos TCP response read failed: {err}"),
                )
            })?;

        Ok(response)
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct ScriptedStream {
    reads: VecDeque<Vec<u8>>,
    read_offset: usize,
    writes: Vec<u8>,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl ScriptedStream {
    fn new(reads: Vec<Vec<u8>>) -> Self {
        Self {
            reads: reads.into(),
            read_offset: 0,
            writes: Vec::new(),
        }
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl NetworkWriteProbe for ScriptedStream {
    fn writes_len(&self) -> usize {
        self.writes.len()
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl Read for ScriptedStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let Some(front) = self.reads.front() else {
            return Ok(0);
        };
        let remaining = &front[self.read_offset..];
        let len = remaining.len().min(buf.len());
        buf[..len].copy_from_slice(&remaining[..len]);
        self.read_offset += len;
        if self.read_offset == front.len() {
            self.reads.pop_front();
            self.read_offset = 0;
        }

        Ok(len)
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl Write for ScriptedStream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.writes.extend_from_slice(buf);

        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn bytes_contain_secret(bytes: &[u8], secret: &[u8]) -> bool {
    // Test/probe-only leak sentinel; production logging must not scan or copy secrets.
    !secret.is_empty() && bytes.windows(secret.len()).any(|window| window == secret)
}

