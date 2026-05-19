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
                "MIIDVjCCAj6gAwIBAgIUEZFhbPT/i2wvYsWIFMLxRPBWO1EwDQYJKoZIhvcNAQELBQAwIzEhMB8GA1UEAwwYU2VydmljZVJhZGFyIFRlc3QgUkRQIENBMB4XDTI2MDUxOTAzMTk0NloXDTM2MDUxNjAzMTk0NlowFjEUMBIGA1UEAwwLd2luLmV4YW1wbGUwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCKKSDmLwnLaTEUO9TzY9rVxYgWbMzcasPHsVEJaZDxszquXMVXGkp9gLIucnM4jmA2G2b37h3l559Uv2wF3tZmekwCxhjUnboGb/K5YPsaYcH/pTdqZ+bUCD47wWZaZPhUen/bwvSoS8z6eeZSQ2jP6t4BewqaMAMSsTQCKtaGpkNcbmkN16Fk+XRSrHvSp2VMjRiPoc0zvcKD0eSKM6z3ja9lRk+u3wohnFhY8Z3tddgJR/8dZtL3cn5DV2LpdCcvfyZ6501hCKBRloctMXyYJQqVI+kOv276ogpyIAEMxf9K3i7wldNr89ckgtDjgbZYdg5EB+0lBXNQHwIiYLp/AgMBAAGjgY4wgYswFgYDVR0RBA8wDYILd2luLmV4YW1wbGUwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwHQYDVR0OBBYEFIkynzC+bKW/BOJNCSeZh833RHznMB8GA1UdIwQYMBaAFGHCW8JDiI+c853AxO8RGlHNBRrfMA0GCSqGSIb3DQEBCwUAA4IBAQBVSuGOBwJlGTtzkws/3w8Rp037my876SEeSSGi6lEfNaUkUQXLQFDyX1XnezCuswwxy/VxamySNG+QgMLBVK78Mxa+PCT9mGGmTMy//aT5cNfqJO0i49mZFvRjvprMq88NqQxz6EPu5PQG1oTP41qQ6C4KzI0CzKI7+z7esk5xbv0RMxES/Ko1/HTtuGtPGqXW9jzgDI9JDWz8vYR7in4poRTBBlQbdfhT8GVG96/Jx3+of4yEnWiOUVExNayeZrAPl9IBFMYWqCYnFj01vW3dSv4KmIyjei7vTjzPWAZPoij2o4RLWeONvFv/dRNrHUW2wU3286Y+zzY6HC2tqat5",
            )
            .expect("fixture TLS certificate")
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn fixture_tls_ca_cert_der() -> Vec<u8> {
    use base64::{engine::general_purpose::STANDARD, Engine as _};

    STANDARD
            .decode(
                "MIIDNzCCAh+gAwIBAgIUOv9noEuLrd8Hf+7tetJI/S9A3jowDQYJKoZIhvcNAQELBQAwIzEhMB8GA1UEAwwYU2VydmljZVJhZGFyIFRlc3QgUkRQIENBMB4XDTI2MDUxOTAzMTk0NloXDTM2MDUxNjAzMTk0NlowIzEhMB8GA1UEAwwYU2VydmljZVJhZGFyIFRlc3QgUkRQIENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA55XA0yBQL69MaWno715Z9QBMtIq0Eg+p+odo07ACsv/DT22txjjEyQmdtKJqimTC0LNkzzM2hOWvzea3gQEZ2GAsFmM0FeR8r/Pps+tR32G43C+seK3xsqc6PSAzNsNe0ytyqNUtUMcofb4ph8ee9fyaEaJXL20gXCnOJlFjdcIND6CCL66Z+CoUzt3KpW9yiAiDSrdl/15R99UjbjFOfHrsfaz5tPlWumVxmSZPlacwD3Rgsn4fADHHtD3C55jYBflyfvE1tenMIy1LW1YK20vFuupawq1SmeOhU00L8iODFaxYDlgJgu0xUIKHgB4VahSN/tlL5rBSks1qdTDZmwIDAQABo2MwYTAdBgNVHQ4EFgQUYcJbwkOIj5zzncDE7xEaUc0FGt8wHwYDVR0jBBgwFoAUYcJbwkOIj5zzncDE7xEaUc0FGt8wDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwDQYJKoZIhvcNAQELBQADggEBAMBpn2WAHIJyVPfB4gtqhvX498lkvzSrBwKSWrNlkU2nudsDGxuPl7CA33WG6Gpm8KxqOiL9SlriDX4cdBpBnD/BmMLfxT9T76kxtCisCkI3vPZ++R97HkqWt7SVlWH8RocFTKieq177QyEuVZueVRbkDhIZcrfP63Zwk+9S6b+EEiNGQtewx2Nj1WO96asRvyv0Lb7uL33xzHWMhc81WFOTMTtXYKMf+ZpIrjMBKBOgkRQAm/Kia/TSkizBdVNb6ZglitMNUymOmyT6M2Q3qTs+vATON7w2zxtAa9wd2sQrQlNSYxngREe6HoUGBrH2bqkOkF92Rr+Raw22AU/bPuI=",
            )
            .expect("fixture TLS CA certificate")
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn fixture_tls_server_cert_pem() -> String {
    use base64::{engine::general_purpose::STANDARD, Engine as _};

    let body = STANDARD.encode(fixture_tls_ca_cert_der());
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
                "MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCKKSDmLwnLaTEUO9TzY9rVxYgWbMzcasPHsVEJaZDxszquXMVXGkp9gLIucnM4jmA2G2b37h3l559Uv2wF3tZmekwCxhjUnboGb/K5YPsaYcH/pTdqZ+bUCD47wWZaZPhUen/bwvSoS8z6eeZSQ2jP6t4BewqaMAMSsTQCKtaGpkNcbmkN16Fk+XRSrHvSp2VMjRiPoc0zvcKD0eSKM6z3ja9lRk+u3wohnFhY8Z3tddgJR/8dZtL3cn5DV2LpdCcvfyZ6501hCKBRloctMXyYJQqVI+kOv276ogpyIAEMxf9K3i7wldNr89ckgtDjgbZYdg5EB+0lBXNQHwIiYLp/AgMBAAECggEAQH58hhdVKig7qedYPBnT8NCZ+2Xkp8wLAnAKlSs7Zyi0buqNkGCMf1ORWc9BbBhCX1+hTIFSYZ0jKouFIKRqT0Its2nH85CBYznlA5Z7AVC7H9x/JuPDxBzo+DoKzo2twrnAb9TtIpbn49D9rE8dYVmRMv298EYTWSlxTsWyiP3qfCQtdd2bDKCW0svGJeFX0E28iww7e7B4GPMYboHJ4ZHNHNc9kRfduR/RT/r6fAzFC3+bUREuAp2Aqq+rEQ9NbBV6WEUVR4b1bXL/AV2uq4qCmMBNKyvIbPZ8ZVRll7Bt8aXa5R414K5efxotdLy8Vmkf53n6F5qT6lxtc5Ks6QKBgQC/va21TsGMv0IoudAKcmKAlmPZBBAv+KqXsXZbh43Hg5Jv+NbMH1GypN/bmd84SkyabwByGpF0FDQMsZrOjaIcREvo0bFzVH57OjWDr4crMbWGsIIsGW7BYZIzVT3OSBHn4qMNALkJYKLbHpA9ufjsGhr/SB/flJmXBqzkPto3tQKBgQC4do5Y52K5JGA/k9oiQHeFnO+CxD0Aap0MIg1VbwtYhppMsrcBjchpmHRm/c/o8lYXiOKvdMikc7QaSkv9utoY0IyU5hM4fh+2rnVV5Su6SCiwG2aV/kTsr5KE6o1fj6i0rF9pTqdI5P9e3p77ovOMIrZqu7m3CxTHjTtCGMch4wKBgGnoNBWMPb4nOjzSfYX3rk7GQrpw0xwcJuYI4I4n7nkARJdShBpVRkP9a6SZdkFaULuQild8M1FBg4prY02pz5v7YU5k3LYOOpqICV0GTAvgthqCTjRbi+CGq0FtWOkix7kkZtlcx9fVJ78OP6/IlCSdOsI8rVZKdxeDWWXtDY1tAoGAAXsCHXiN9Ep0c04ufAPkcbAWxAfrLWutowFK9hqUDrvV1TPCAEMxDpfop0L2PjpjsoCowRvA2IENOwDJp1muknBqEG/gS53Hh2HTE0NpnG8j1HYD1sRZrUSjemmfhNrUUc7oXSICebVMz2geAosGRWOp7yVekjeGjSt3BErKnl0CgYBsGM2SkzGMqXp9jqVmJglBnq2AO1RGreq/Gl178tEdOW7zrLzNWMLtMCp9/xFAHF5iFYi6MvrqKbBymP82YDx7p7GjSCgpmDp0x54iFxlwSQIRRmdYS8V5rTE/xNaISdNwPVmrLrzAN3oqE/g3A0PXv+UtOr7EVoLFV+nkiqITWA==",
            )
            .expect("fixture TLS key")
}
