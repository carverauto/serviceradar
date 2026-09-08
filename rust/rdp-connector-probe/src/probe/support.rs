struct RejectingNetworkClient;

impl ironrdp_connector::sspi::network_client::NetworkClient for RejectingNetworkClient {
    fn send(
        &self,
        _request: &ironrdp_connector::sspi::generator::NetworkRequest,
    ) -> ironrdp_connector::sspi::Result<Vec<u8>> {
        Err(ironrdp_connector::sspi::Error::new(
            ironrdp_connector::sspi::ErrorKind::NoAuthenticatingAuthority,
            "network client is disabled in connector probe",
        ))
    }
}

struct ScriptedStream {
    reads: VecDeque<Vec<u8>>,
    read_offset: usize,
    writes: Vec<u8>,
}

impl ScriptedStream {
    fn new(reads: Vec<Vec<u8>>) -> Self {
        Self {
            reads: reads.into(),
            read_offset: 0,
            writes: Vec::new(),
        }
    }
}

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

impl Write for ScriptedStream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.writes.extend_from_slice(buf);

        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

struct RecordingStream<T> {
    inner: T,
    writes: Vec<u8>,
}

impl<T> RecordingStream<T> {
    fn new(inner: T) -> Self {
        Self {
            inner,
            writes: Vec::new(),
        }
    }
}

impl<T: Read> Read for RecordingStream<T> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.inner.read(buf)
    }
}

impl<T: Write> Write for RecordingStream<T> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let written = self.inner.write(buf)?;
        self.writes.extend_from_slice(&buf[..written]);

        Ok(written)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

fn drive_connector_with_server_protocol(
    request: ServiceRadarOpenRequest,
    selected_protocol: ironrdp_pdu::nego::SecurityProtocol,
) -> Result<ConnectorUpgradeBoundary, &'static str> {
    let config = build_connector_config(request)?;
    let mut connector = ironrdp_connector::ClientConnector::new(config, CLIENT_ADDR);
    let mut buffer = ironrdp_core::WriteBuf::new();

    ironrdp_connector::Sequence::step_no_input(&mut connector, &mut buffer)
        .map_err(|_| "initial connector step failed")?;

    let before_confirm_state = connector_state_name(&connector);
    let server_confirm = encode_server_confirm(selected_protocol)?;
    let mut output = ironrdp_core::WriteBuf::new();

    ironrdp_connector::Sequence::step(&mut connector, &server_confirm, &mut output)
        .map_err(|_| "server confirm step failed")?;

    let after_confirm_state = connector_state_name(&connector);
    let requires_security_upgrade = connector.should_perform_security_upgrade();
    connector.mark_security_upgrade_as_done();

    Ok(ConnectorUpgradeBoundary {
        before_confirm_state,
        after_confirm_state,
        requires_security_upgrade,
        after_upgrade_state: connector_state_name(&connector),
        requires_credssp: connector.should_perform_credssp(),
    })
}

fn encode_server_confirm(
    selected_protocol: ironrdp_pdu::nego::SecurityProtocol,
) -> Result<Vec<u8>, &'static str> {
    ironrdp_core::encode_vec(&ironrdp_pdu::x224::X224(
        ironrdp_pdu::nego::ConnectionConfirm::Response {
            flags: ironrdp_pdu::nego::ResponseFlags::empty(),
            protocol: selected_protocol,
        },
    ))
    .map_err(|_| "server confirm encode failed")
}

fn connector_state_name(connector: &ironrdp_connector::ClientConnector) -> &'static str {
    ironrdp_connector::Sequence::state(connector).name()
}

fn initial_pdu_advertises_credssp(bytes: &[u8]) -> Result<bool, &'static str> {
    let protocol = decode_initial_connection_request(bytes)?.protocol;

    Ok(protocol.intersects(
        ironrdp_pdu::nego::SecurityProtocol::HYBRID
            | ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX,
    ))
}

fn initial_pdu_advertises_tls_fallback(bytes: &[u8]) -> Result<bool, &'static str> {
    let protocol = decode_initial_connection_request(bytes)?.protocol;

    Ok(protocol.intersects(ironrdp_pdu::nego::SecurityProtocol::SSL))
}

fn initial_pdu_mstshash_cookie(bytes: &[u8]) -> Result<Option<String>, &'static str> {
    let request = decode_initial_connection_request(bytes)?;

    match request.nego_data {
        Some(ironrdp_pdu::nego::NegoRequestData::Cookie(cookie)) => Ok(Some(cookie.0)),
        _ => Ok(None),
    }
}

fn decode_initial_connection_request(
    bytes: &[u8],
) -> Result<ironrdp_pdu::nego::ConnectionRequest, &'static str> {
    let request = ironrdp_core::decode::<
        ironrdp_pdu::x224::X224<ironrdp_pdu::nego::ConnectionRequest>,
    >(bytes)
    .map_err(|_| "initial connector pdu decode failed")?
    .0;

    Ok(request)
}

fn bytes_contain_secret(bytes: &[u8], secret: &[u8]) -> bool {
    // Test/probe-only leak sentinel; production logging must not scan or copy secrets.
    !secret.is_empty() && bytes.windows(secret.len()).any(|window| window == secret)
}

impl ServiceRadarOpenRequest {
    fn tls_nla_mode(&self) -> &str {
        self.target.tls.nla_mode.as_str()
    }
}
