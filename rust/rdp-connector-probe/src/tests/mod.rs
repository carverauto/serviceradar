use super::*;
use base64::{engine::general_purpose::STANDARD, Engine as _};
use ironrdp_connector::Credentials;

mod config_and_plan;
mod handoff;
mod smoke;
mod tls;

fn open_request(username: &str, nla_mode: &str) -> crate::ServiceRadarOpenRequest {
    crate::ServiceRadarOpenRequest {
        schema: OPEN_SCHEMA.to_owned(),
        session_id: "session-1".to_owned(),
        local_agent_id: "agent-1".to_owned(),
        gateway_id: "gateway-1".to_owned(),
        start_unix: 1_778_636_531,
        target: crate::ServiceRadarTarget {
            target_id: "target-1".to_owned(),
            display_name: "Windows VM".to_owned(),
            device_uid: "device-1".to_owned(),
            protocol: "rdp".to_owned(),
            route: crate::ServiceRadarRoute {
                selected_agent_id: "agent-1".to_owned(),
                selected_gateway_id: "gateway-1".to_owned(),
                allowed_agent_ids: Vec::new(),
            },
            upstream: crate::ServiceRadarUpstream {
                host: "win.example".to_owned(),
                port: 3389,
            },
            screen: crate::ServiceRadarScreenPolicy {
                max_width: 1920,
                max_height: 1080,
                color_depth: 32,
                frame_rate: 30,
                bitrate_bps: 8_000_000,
                idle_seconds: 900,
                ttl_seconds: 3600,
            },
            tls: crate::ServiceRadarTlsPolicy {
                mode: "verify".to_owned(),
                ca_bundle_id: String::new(),
                nla_mode: nla_mode.to_owned(),
                server_name: "win.example".to_owned(),
            },
            credential: crate::ServiceRadarCredentialPolicy {
                mode: "memory_user".to_owned(),
                allowed_principals: vec![username.to_owned()],
                credential_secret_ref: String::new(),
            },
            redirection: crate::ServiceRadarRedirectionPolicy {
                clipboard_mode: "disabled".to_owned(),
                drive: false,
                printer: false,
                audio: false,
                smart_card: false,
                file_copy: false,
            },
            recording: crate::ServiceRadarRecordingPolicy {
                metadata_enabled: true,
                screen_enabled: false,
                clipboard_enabled: false,
                file_enabled: false,
                audio_enabled: false,
            },
            approval_required: false,
            metadata: BTreeMap::new(),
        },
        credential_grant: crate::ServiceRadarCredentialGrant {
            mode: "memory_user".to_owned(),
            username: username.to_owned(),
            password: "secret".to_owned(),
            credential_secret_ref: String::new(),
            actor_id: "user-1".to_owned(),
            session_id: "session-1".to_owned(),
            target_id: "target-1".to_owned(),
            route_id: "agent-1".to_owned(),
            expires_unix: 1_778_640_000,
        },
    }
}

fn valid_open_payload() -> String {
    r#"{
            "schema":"serviceradar.rdp.helper.open.v1",
            "session_id":"session-1",
            "local_agent_id":"agent-1",
            "gateway_id":"gateway-1",
            "start_unix":1778636531,
            "target":{
                "target_id":"target-1",
                "display_name":"Windows VM",
                "device_uid":"device-1",
                "protocol":"rdp",
                "route":{"selected_agent_id":"agent-1","selected_gateway_id":"gateway-1"},
                "upstream":{"host":"win.example","port":3389},
                "tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"},
                "credential":{"mode":"memory_user","allowed_principals":["alice"]},
                "screen":{"max_width":1920,"max_height":1080,"frame_rate":30,"bitrate_bps":8000000,"idle_seconds":900,"ttl_seconds":3600},
                "redirection":{"clipboard_mode":"disabled"},
                "recording":{"metadata_enabled":true}
            },
            "credential_grant":{"mode":"memory_user","username":"alice","password":"secret","session_id":"session-1","target_id":"target-1","route_id":"agent-1"}
        }"#
        .to_owned()
}

fn parse_live_target(raw: &str) -> Result<(String, u16), &'static str> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("live RDP target is empty");
    }

    if let Some((host, port)) = trimmed.rsplit_once(':') {
        let port = port
            .parse()
            .map_err(|_| "live RDP target port is invalid")?;
        if host.is_empty() || port == 0 {
            return Err("live RDP target is invalid");
        }

        return Ok((host.to_owned(), port));
    }

    Ok((trimmed.to_owned(), 3389))
}

fn fixture_server_cert_der() -> Vec<u8> {
    STANDARD
            .decode(
                "MIIDDTCCAfWgAwIBAgIUFaHwQBAFyvmfso6OPbcQ+2/fVSUwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLd2luLmV4YW1wbGUwHhcNMjYwNTE2MTYzNzQ3WhcNMjYwNTE3MTYzNzQ3WjAWMRQwEgYDVQQDDAt3aW4uZXhhbXBsZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALbcS3SPVJlbV5AwbziMjXX0Z5CXcOIMt67zeIzoh6hmiAou1IIVZ14FrWStQj4kJNcAwdYQWtZcjM0ya6Hx3fd/M4H3FIatWkrlZcwDtxPeMHxoLzJ0mP/yLdacyvjfKqQDn8f0JEd4KY5dN1eD/OFBGF+XuQyIBsAom6SFuo7uZA4+HmC01P5ac0zAyJKOVDpgdBWa9FYn+YszqAwjrRau1m4A8K5BgRPDBs1FQwjGhRGePEuRgOKsHdBGq/PJ1Iw4mES4pwStTgGvFHJnIPxxZHX0WHiDZnbNx+K+HJh0eaWEjYUazuQtvsyllNM6KmZIHb/bgcZ0VTRQZ87l9lUCAwEAAaNTMFEwHQYDVR0OBBYEFOEi76jfCExGDeYivuwXNMm6uGnAMB8GA1UdIwQYMBaAFOEi76jfCExGDeYivuwXNMm6uGnAMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAI6IdjMvys+AEAoeZ31Lo0IbMsM4EChsvXwpE9BZ5zuPEtRwxoxLwVKrhfjkQjuX6CWFcMlWPvUqKU4t8G3b6/5ym67vJqYkLXgF5UG5Aj7AuiLIY6j8zBcZ4dFsx7hheXZC4em5e6D16eDgATWEBKf/kfbmnX8EET5gkqolAjYI4D1M3gT5yJrulhNmfXThW5A2Vvn70AhsrhMylogKRejaMOelRi1XA0AAXkZ53JWNTCJLJtRg/6PAeyT6nJwpTZi1iKJs0gRTv2TAnUFKeVfDV1CE63YM8953dq+xwqmrTmyZabWJb6yAXEepIUPMscB2UcHKFAqgWZ+4herSzfY=",
            )
            .expect("fixture certificate")
}

fn fixture_server_cert_pem() -> String {
    let body = STANDARD.encode(fixture_server_cert_der());
    let mut pem = String::from("-----BEGIN CERTIFICATE-----\n");
    for chunk in body.as_bytes().chunks(64) {
        pem.push_str(std::str::from_utf8(chunk).expect("base64 is utf8"));
        pem.push('\n');
    }
    pem.push_str("-----END CERTIFICATE-----\n");

    pem
}
