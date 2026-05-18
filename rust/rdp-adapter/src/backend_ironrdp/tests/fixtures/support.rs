#[cfg(serviceradar_rdp_connector_link_probe)]
fn desktop_key_frame(key: &str, down: bool) -> DesktopFrame {
    DesktopFrame {
        session_id: "session-1".to_owned(),
        protocol: "rdp".to_owned(),
        frame_type: "desktop.input".to_owned(),
        width: 0,
        height: 0,
        input: Some(crate::protocol::DesktopInputEvent {
            kind: "key".to_owned(),
            key: key.to_owned(),
            down,
            button: String::new(),
            x: 0,
            y: 0,
            focused: false,
        }),
        quality: None,
        reason: String::new(),
        timestamp: 0,
        metadata: Default::default(),
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn desktop_pointer_frame(button: &str, down: bool, x: u32, y: u32) -> DesktopFrame {
    DesktopFrame {
        session_id: "session-1".to_owned(),
        protocol: "rdp".to_owned(),
        frame_type: "desktop.input".to_owned(),
        width: 0,
        height: 0,
        input: Some(crate::protocol::DesktopInputEvent {
            kind: "pointer".to_owned(),
            key: String::new(),
            down,
            button: button.to_owned(),
            x,
            y,
            focused: false,
        }),
        quality: None,
        reason: String::new(),
        timestamp: 0,
        metadata: Default::default(),
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct FailingWriter;

#[cfg(serviceradar_rdp_connector_link_probe)]
impl Write for FailingWriter {
    fn write(&mut self, _buf: &[u8]) -> io::Result<usize> {
        Err(io::Error::new(io::ErrorKind::BrokenPipe, "closed"))
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn fixture_server_cert_der() -> Vec<u8> {
    use base64::{engine::general_purpose::STANDARD, Engine as _};

    STANDARD
            .decode(
                "MIIDDTCCAfWgAwIBAgIUFaHwQBAFyvmfso6OPbcQ+2/fVSUwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLd2luLmV4YW1wbGUwHhcNMjYwNTE2MTYzNzQ3WhcNMjYwNTE3MTYzNzQ3WjAWMRQwEgYDVQQDDAt3aW4uZXhhbXBsZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALbcS3SPVJlbV5AwbziMjXX0Z5CXcOIMt67zeIzoh6hmiAou1IIVZ14FrWStQj4kJNcAwdYQWtZcjM0ya6Hx3fd/M4H3FIatWkrlZcwDtxPeMHxoLzJ0mP/yLdacyvjfKqQDn8f0JEd4KY5dN1eD/OFBGF+XuQyIBsAom6SFuo7uZA4+HmC01P5ac0zAyJKOVDpgdBWa9FYn+YszqAwjrRau1m4A8K5BgRPDBs1FQwjGhRGePEuRgOKsHdBGq/PJ1Iw4mES4pwStTgGvFHJnIPxxZHX0WHiDZnbNx+K+HJh0eaWEjYUazuQtvsyllNM6KmZIHb/bgcZ0VTRQZ87l9lUCAwEAAaNTMFEwHQYDVR0OBBYEFOEi76jfCExGDeYivuwXNMm6uGnAMB8GA1UdIwQYMBaAFOEi76jfCExGDeYivuwXNMm6uGnAMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAI6IdjMvys+AEAoeZ31Lo0IbMsM4EChsvXwpE9BZ5zuPEtRwxoxLwVKrhfjkQjuX6CWFcMlWPvUqKU4t8G3b6/5ym67vJqYkLXgF5UG5Aj7AuiLIY6j8zBcZ4dFsx7hheXZC4em5e6D16eDgATWEBKf/kfbmnX8EET5gkqolAjYI4D1M3gT5yJrulhNmfXThW5A2Vvn70AhsrhMylogKRejaMOelRi1XA0AAXkZ53JWNTCJLJtRg/6PAeyT6nJwpTZi1iKJs0gRTv2TAnUFKeVfDV1CE63YM8953dq+xwqmrTmyZabWJb6yAXEepIUPMscB2UcHKFAqgWZ+4herSzfY=",
            )
            .expect("fixture certificate")
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn fixture_server_cert_pem() -> String {
    use base64::{engine::general_purpose::STANDARD, Engine as _};

    let body = STANDARD.encode(fixture_server_cert_der());
    let mut pem = String::from("-----BEGIN CERTIFICATE-----\n");
    for chunk in body.as_bytes().chunks(64) {
        pem.push_str(std::str::from_utf8(chunk).expect("base64 is utf8"));
        pem.push('\n');
    }
    pem.push_str("-----END CERTIFICATE-----\n");

    pem
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct HybridExTlsProbeCapture {
    initial_request: Vec<u8>,
    tls_plaintext: Vec<u8>,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn spawn_hybrid_ex_tls_probe_server(
    listener: std::net::TcpListener,
) -> std::thread::JoinHandle<Vec<u8>> {
    use std::io::{Read as _, Write as _};

    let server_confirm =
        encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)
            .expect("server confirm");

    std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accepted connection");
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .expect("read timeout");
        stream
            .set_write_timeout(Some(Duration::from_secs(1)))
            .expect("write timeout");
        let mut initial_request = [0_u8; 4096];
        let read = stream
            .read(&mut initial_request)
            .expect("initial connector request");
        stream
            .write_all(&server_confirm)
            .expect("server confirm write");
        let server_config = fixture_tls_server_config_for_probe();
        let mut server_connection =
            rustls::ServerConnection::new(Arc::new(server_config)).expect("server connection");
        while server_connection.is_handshaking() {
            if server_connection.complete_io(&mut stream).is_err() {
                break;
            }
        }

        initial_request[..read].to_vec()
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn spawn_hybrid_ex_tls_capture_server(
    listener: std::net::TcpListener,
) -> std::thread::JoinHandle<HybridExTlsProbeCapture> {
    use std::io::{Read as _, Write as _};

    let server_confirm =
        encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)
            .expect("server confirm");

    std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accepted connection");
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .expect("read timeout");
        stream
            .set_write_timeout(Some(Duration::from_secs(1)))
            .expect("write timeout");
        let mut initial_request = [0_u8; 4096];
        let read = stream
            .read(&mut initial_request)
            .expect("initial connector request");
        stream
            .write_all(&server_confirm)
            .expect("server confirm write");
        let server_config = fixture_tls_server_config_for_probe();
        let mut server_connection =
            rustls::ServerConnection::new(Arc::new(server_config)).expect("server connection");
        while server_connection.is_handshaking() {
            server_connection
                .complete_io(&mut stream)
                .expect("server TLS handshake");
        }

        let mut tls_plaintext = Vec::new();
        let _ = server_connection.complete_io(&mut stream);
        let mut plaintext = [0_u8; 4096];
        loop {
            match server_connection.reader().read(&mut plaintext) {
                Ok(0) => break,
                Ok(count) => tls_plaintext.extend_from_slice(&plaintext[..count]),
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => break,
                Err(_) => break,
            }
        }

        HybridExTlsProbeCapture {
            initial_request: initial_request[..read].to_vec(),
            tls_plaintext,
        }
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn fixture_tls_server_config_for_probe() -> rustls::ServerConfig {
    let cert = rustls::pki_types::CertificateDer::from(fixture_tls_server_cert_der());
    let key = rustls::pki_types::PrivateKeyDer::Pkcs8(rustls::pki_types::PrivatePkcs8KeyDer::from(
        fixture_tls_server_key_der(),
    ));

    rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .expect("fixture TLS server config")
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn fixture_tls_server_cert_der() -> Vec<u8> {
    use base64::{engine::general_purpose::STANDARD, Engine as _};

    STANDARD
            .decode(
                "MIIDJTCCAg2gAwIBAgIUaVf+hJE9biQOeCj7Hlnyp0pWaqAwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLd2luLmV4YW1wbGUwHhcNMjYwNTE3MDUxMDQxWhcNMjYwNTE4MDUxMDQxWjAWMRQwEgYDVQQDDAt3aW4uZXhhbXBsZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAKGuZfZ1QqXmZtoBDjgHfUW7AqXIsIP9AaWsECA7SFNDwVLAzrlw3s1GauZFzpRkByxC73+Tf9P4eqhBlR23zY9AZ9I//fJVOKLDJIHQjjUZba2y4ipb+/ns4GRFBsu7hw3QQd8l+egLZrDzZEYuaZQxtTtSjFcZadDZPSzkGuJ4Q1YqAryl6yrLKeLlsxonUNfnCu7rEgiRRfl6fUAzHLz9/Ewi69NpmykR3AGwbS9pf1FmYIBxhlpIw4fqQGw+pVRaCz6XnCWCaut4sEhBEDIShfRW8ZxXfrdJ4C5Ndw4rKbny9vrr2X65OW8i9vq4jctJvGq2CV5s09A9udoEpecCAwEAAaNrMGkwHQYDVR0OBBYEFEnORq1zs4ze0Cjw9dYRSpM0U3ZfMB8GA1UdIwQYMBaAFEnORq1zs4ze0Cjw9dYRSpM0U3ZfMA8GA1UdEwEB/wQFMAMBAf8wFgYDVR0RBA8wDYILd2luLmV4YW1wbGUwDQYJKoZIhvcNAQELBQADggEBADq9Cr8CFhXREqA1+UJNjkm4LrsiSSfTEzOkjExutLshFzfA9jJbtDyfVNF+9mYQlGpJJIFy3FVlL4GsVxG9wtHgL6c3jwWaFjT3RJCo37eqUGfwGI9lbxlSvdfqPZmmpGHv+3pqE9zs7s1nPicIwHs9V21TH8EsJrI/p8bGayx2hW7hKiRZ+lHdyc6T0JYGorMOUNzrabd8FLAt+tlQN0PKx8d1AvbQ2liADhBrUqfSZnSge5q/Ei8/BXtpO2QIR+0aR6gCABEgCh9Dn8hF3rYhShl7dSmaaZw7sB/oetco1b+hS1/trjsG6tdnQhvpcy206OmzMsuCsWj+nLhodXw=",
            )
            .expect("fixture TLS certificate")
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn fixture_tls_server_cert_pem() -> String {
    use base64::{engine::general_purpose::STANDARD, Engine as _};

    let body = STANDARD.encode(fixture_tls_server_cert_der());
    let mut pem = String::from("-----BEGIN CERTIFICATE-----\n");
    for chunk in body.as_bytes().chunks(64) {
        pem.push_str(std::str::from_utf8(chunk).expect("base64 is utf8"));
        pem.push('\n');
    }
    pem.push_str("-----END CERTIFICATE-----\n");

    pem
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn fixture_tls_server_key_der() -> Vec<u8> {
    use base64::{engine::general_purpose::STANDARD, Engine as _};

    STANDARD
            .decode(
                "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQChrmX2dUKl5mbaAQ44B31FuwKlyLCD/QGlrBAgO0hTQ8FSwM65cN7NRmrmRc6UZAcsQu9/k3/T+HqoQZUdt82PQGfSP/3yVTiiwySB0I41GW2tsuIqW/v57OBkRQbLu4cN0EHfJfnoC2aw82RGLmmUMbU7UoxXGWnQ2T0s5BrieENWKgK8pesqyyni5bMaJ1DX5wru6xIIkUX5en1AMxy8/fxMIuvTaZspEdwBsG0vaX9RZmCAcYZaSMOH6kBsPqVUWgs+l5wlgmrreLBIQRAyEoX0VvGcV363SeAuTXcOKym58vb669l+uTlvIvb6uI3LSbxqtglebNPQPbnaBKXnAgMBAAECggEAQadUbzahmEWNqWP5VqYv6ANvKUvr5cT1CMXsjHIWRf2DAOwbZfEgAEJigVyCbP6LbR1HLMqEA1roz+9FspojJlMUdauXnvKdO3a7md1LCePoBjtYHLRah1v5qK3g+xUM2/6f6RH+P4x1qFBFfTw2kj93JP45z9qZff3hGhwMkL54rp+ObfwGnu97Egy51Xzx94C5LK86KmwgfytGOpKAHLWijf+md61exTn+4danJcMkx550ynKBFoXEqRFZ2phiKP3/I8Ni9k67vktJ6mrpR1ymGtcBmDwZDqhc1IpWIZLmbf6iSSvmrunImDdYelZgINh+fD3oU28duou9IYhKtQKBgQDYCpOyaACRNc66xlzThE2JknN/8wm6nCvDyNIfAdMXgITRezuOoEPoHRSxGc87GZ/oIlQ72Jicp390U50YC4Q/vCXHi9omTycuH62Cd8+CrI7HjWons5989p8uDn+cRQLNtZqtotFY/tH/nQwH3zG5rp7GoR8couqTMRKFuTUtZQKBgQC/lefKcNExAcitENlQJrG5G2XPLrmqyit3DDxJ7byxfcXu9kObLOLx8rTLQCwaZxHcnEFT8QGByuxVFpYmy8MvyLbH9aYGYitydpVeu3+prODj3FNX3zVAHRZX50weerXDB2EUs/4Meupyxe0e7ecRTLxIHmulUYpeqD6/s0THWwKBgGoHJt2UNVMO+VqpJ72XXQZ7nbvZ55hyNPhtgtI87wDFzmmQ9XXWKf2s6A7S/+WdeeFPl8+XSa74dZD9yEeYv1sYV+JLPNE4X54/ZcR2UJ1tWtWNDeBWQ5vs3cqYywBCzlFvI268TcpDpYSx6smiPKFIlhwdz0samc2Lc++1KegRAoGBALK4VJI0y/C7iUho/1AVyJS1SjQLkogQMJvNfjA45l1sxsg0UrzfEpZBowY3xuyaWb9CxG5Z1N4PPofhmhB25I4e3uOJ9GbgDUep9413u4+9Bc2KKvU9857rg3xc+FU2g3h72cRGZCegQjTvDlRb+cHZo4pjVmfRuRK0QFT0FqUhAoGAFaZzpX5A75HegMY2RfGIivRPgWdDquAHzlsUHYPbfOYVAABAnUOvWD6tZzTxDfrwixfALYIa/4sU0j+H2mun+8ypmU7jMh/B/OzW6gltNgUkgXfiqxfRBoMXIPydwlFKgqOOryEFJjf14YBQv7OLd80BXXOmbIaY0+tOYOwX1ME=",
            )
            .expect("fixture TLS key")
}
