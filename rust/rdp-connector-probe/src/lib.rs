use serde::Deserialize;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};

const CLIENT_BUILD: u32 = 1;
const CLIENT_NAME: &str = "serviceradar";
const CLIENT_DIR: &str = "C:\\Windows\\System32\\mstscax.dll";
const CLIENT_ADDR: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0);

#[derive(Debug, Deserialize)]
pub struct ServiceRadarOpenRequest {
    pub target: ServiceRadarTarget,
    pub credential_grant: ServiceRadarCredentialGrant,
}

#[derive(Debug, Deserialize)]
pub struct ServiceRadarTarget {
    pub screen: ServiceRadarScreenPolicy,
    pub tls: ServiceRadarTlsPolicy,
}

#[derive(Debug, Deserialize)]
pub struct ServiceRadarScreenPolicy {
    pub max_width: u16,
    pub max_height: u16,
    #[serde(default)]
    pub color_depth: u32,
}

#[derive(Debug, Deserialize)]
pub struct ServiceRadarTlsPolicy {
    pub nla_mode: String,
}

#[derive(Debug, Deserialize)]
pub struct ServiceRadarCredentialGrant {
    pub mode: String,
    pub username: String,
    pub password: String,
}

#[derive(Debug, Eq, PartialEq)]
pub struct InitialConnectorPdu {
    pub before_state: &'static str,
    pub after_state: &'static str,
    pub bytes: Vec<u8>,
}

pub fn connector_dependency_is_linked() -> bool {
    let desktop_size = ironrdp_connector::DesktopSize {
        width: 1024,
        height: 768,
    };

    desktop_size.width == 1024 && desktop_size.height == 768
}

pub fn build_connector_config(
    request: ServiceRadarOpenRequest,
) -> Result<ironrdp_connector::Config, &'static str> {
    if request.tls_nla_mode() != "required" {
        return Err("nla is required");
    }
    if request.credential_grant.mode != "memory_user" {
        return Err("memory-user credential grant is required");
    }
    if request.credential_grant.username.trim().is_empty()
        || request.credential_grant.password.is_empty()
    {
        return Err("username and password are required");
    }
    if request.target.screen.max_width == 0 || request.target.screen.max_height == 0 {
        return Err("screen size is required");
    }

    let (domain, username) = split_domain_username(request.credential_grant.username);

    Ok(ironrdp_connector::Config {
        desktop_size: ironrdp_connector::DesktopSize {
            width: request.target.screen.max_width,
            height: request.target.screen.max_height,
        },
        desktop_scale_factor: 0,
        enable_tls: false,
        enable_credssp: true,
        credentials: ironrdp_connector::Credentials::UsernamePassword {
            username,
            password: request.credential_grant.password,
        },
        domain,
        client_build: CLIENT_BUILD,
        client_name: CLIENT_NAME.to_owned(),
        keyboard_type: ironrdp_pdu::gcc::KeyboardType::IbmEnhanced,
        keyboard_subtype: 0,
        keyboard_functional_keys_count: 12,
        keyboard_layout: 0,
        ime_file_name: String::new(),
        bitmap: None,
        dig_product_id: String::new(),
        client_dir: CLIENT_DIR.to_owned(),
        platform: ironrdp_pdu::rdp::capability_sets::MajorPlatformType::UNIX,
        hardware_id: None,
        request_data: None,
        autologon: false,
        enable_audio_playback: false,
        performance_flags: ironrdp_pdu::rdp::client_info::PerformanceFlags::default(),
        license_cache: None,
        timezone_info: ironrdp_pdu::rdp::client_info::TimezoneInfo::default(),
        enable_server_pointer: false,
        pointer_software_rendering: false,
    })
}

fn split_domain_username(username: String) -> (Option<String>, String) {
    if let Some((domain, login)) = username.split_once('\\') {
        if !domain.is_empty() && !login.is_empty() {
            return (Some(domain.to_owned()), login.to_owned());
        }
    }

    (None, username)
}

pub fn build_initial_connector_pdu(
    request: ServiceRadarOpenRequest,
) -> Result<InitialConnectorPdu, &'static str> {
    let config = build_connector_config(request)?;
    let mut connector = ironrdp_connector::ClientConnector::new(config, CLIENT_ADDR);
    let before_state = connector_state_name(&connector);
    let mut buffer = ironrdp_core::WriteBuf::new();
    let written = ironrdp_connector::Sequence::step_no_input(&mut connector, &mut buffer)
        .map_err(|_| "initial connector step failed")?;
    let written_len = written
        .size()
        .ok_or("initial connector step wrote no bytes")?;

    Ok(InitialConnectorPdu {
        before_state,
        after_state: connector_state_name(&connector),
        bytes: buffer.filled()[..written_len].to_vec(),
    })
}

fn connector_state_name(connector: &ironrdp_connector::ClientConnector) -> &'static str {
    ironrdp_connector::Sequence::state(connector).name()
}

impl ServiceRadarOpenRequest {
    fn tls_nla_mode(&self) -> &str {
        self.target.tls.nla_mode.as_str()
    }
}

#[cfg(test)]
mod tests {
    use ironrdp_connector::Credentials;

    #[test]
    fn links_connector_without_root_workspace_lockfile() {
        assert!(crate::connector_dependency_is_linked());
    }

    #[test]
    fn builds_nla_required_username_password_config() {
        let config = crate::build_connector_config(open_request("EXAMPLE\\alice", "required"))
            .expect("config");

        assert!(!config.enable_tls);
        assert!(config.enable_credssp);
        assert_eq!(config.domain.as_deref(), Some("EXAMPLE"));
        assert_eq!(config.desktop_size.width, 1920);
        assert_eq!(config.desktop_size.height, 1080);
        assert_eq!(
            config.keyboard_type,
            ironrdp_pdu::gcc::KeyboardType::IbmEnhanced
        );

        match config.credentials {
            Credentials::UsernamePassword { username, password } => {
                assert_eq!(username, "alice");
                assert_eq!(password, "secret");
            }
            Credentials::SmartCard { .. } => panic!("unexpected smart-card config"),
        }
    }

    #[test]
    fn rejects_non_nla_connector_config() {
        let err = crate::build_connector_config(open_request("alice", "optional")).unwrap_err();

        assert_eq!(err, "nla is required");
    }

    #[test]
    fn builds_initial_x224_negotiation_pdu() {
        let pdu = crate::build_initial_connector_pdu(open_request("EXAMPLE\\alice", "required"))
            .expect("initial pdu");

        assert_eq!(pdu.before_state, "ConnectionInitiationSendRequest");
        assert_eq!(pdu.after_state, "ConnectionInitiationWaitResponse");
        assert!(pdu.bytes.len() > 10);
        assert_eq!(&pdu.bytes[..2], &[0x03, 0x00]);
    }

    fn open_request(username: &str, nla_mode: &str) -> crate::ServiceRadarOpenRequest {
        crate::ServiceRadarOpenRequest {
            target: crate::ServiceRadarTarget {
                screen: crate::ServiceRadarScreenPolicy {
                    max_width: 1920,
                    max_height: 1080,
                    color_depth: 32,
                },
                tls: crate::ServiceRadarTlsPolicy {
                    nla_mode: nla_mode.to_owned(),
                },
            },
            credential_grant: crate::ServiceRadarCredentialGrant {
                mode: "memory_user".to_owned(),
                username: username.to_owned(),
                password: "secret".to_owned(),
            },
        }
    }
}
