use crate::backend::{BackendError, RdpBackend, RdpBackendSession};
use crate::protocol::{DesktopCredentialGrant, OpenPayload};
#[cfg(serviceradar_rdp_connector_link_probe)]
use std::collections::VecDeque;
#[cfg(serviceradar_rdp_connector_link_probe)]
use std::io::{self, Read, Write};
use zeroize::Zeroizing;

const CONNECTOR_NOT_IMPLEMENTED: &str =
    "IronRDP backend is linked, but the connector loop is not implemented";
const MEMORY_USER_REQUIRED: &str =
    "IronRDP backend currently requires a memory-user credential grant";
const INVALID_CONNECTION_PLAN: &str = "IronRDP connection plan is invalid";
const TLS_MODE_PINNED_CA: &str = "pinned_ca";
const TLS_MODE_VERIFY: &str = "verify";
const TLS_MODE_SYSTEM: &str = "system";

#[derive(Debug, Eq, PartialEq)]
struct NonSecretConnectionPlan {
    upstream_host: String,
    upstream_port: u16,
    tls_server_name: String,
    tls_trust_source: TlsTrustSource,
    desktop_width: u16,
    desktop_height: u16,
}

#[derive(Debug, Eq, PartialEq)]
enum TlsTrustSource {
    SystemRoots,
    RegisteredCaBundle(String),
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

struct MemoryUserCredential {
    domain: Option<Zeroizing<String>>,
    username: Zeroizing<String>,
    password: RedactedSecret,
}

struct RedactedSecret {
    value: Zeroizing<String>,
}

impl MemoryUserCredential {
    fn has_material(&self) -> bool {
        !self.username.is_empty() && !self.password.value.is_empty()
    }

    fn connector_identity(&self) -> (Option<&str>, &str) {
        (
            self.domain.as_ref().map(|domain| domain.as_str()),
            self.username.as_str(),
        )
    }
}

impl std::fmt::Debug for MemoryUserCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MemoryUserCredential")
            .field("domain", &"<redacted>")
            .field("username", &"<redacted>")
            .field("password", &self.password)
            .finish()
    }
}

impl std::fmt::Debug for RedactedSecret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("<redacted>")
    }
}

#[derive(Default)]
pub struct IronRdpBackend;

impl RdpBackend for IronRdpBackend {
    fn open(&mut self, request: OpenPayload) -> Result<Box<dyn RdpBackendSession>, BackendError> {
        let Some(grant) = request.credential_grant.as_ref() else {
            return Err(BackendError::Unsupported(MEMORY_USER_REQUIRED));
        };
        if !is_memory_user_grant(grant) {
            return Err(BackendError::Unsupported(MEMORY_USER_REQUIRED));
        }
        let _plan = build_nonsecret_connection_plan(&request)?;
        let credential = build_memory_user_credential(grant)?;
        if !credential.has_material() {
            return Err(BackendError::Unsupported(MEMORY_USER_REQUIRED));
        }
        let _connector_identity = credential.connector_identity();

        // Keep connector readiness false until the real IronRDP loop consumes
        // only zeroizing credential wrappers and proves cleanup ordering.
        Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_connector_config_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> ironrdp_connector::Config {
    let (domain, username) = credential.connector_identity();

    ironrdp_connector::Config {
        desktop_size: ironrdp_connector::DesktopSize {
            width: plan.desktop_width,
            height: plan.desktop_height,
        },
        desktop_scale_factor: 0,
        enable_tls: false,
        enable_credssp: true,
        credentials: ironrdp_connector::Credentials::UsernamePassword {
            username: username.to_owned(),
            password: credential.password.value.as_str().to_owned(),
        },
        domain: domain.map(str::to_owned),
        client_build: 1,
        client_name: "serviceradar".to_owned(),
        keyboard_type: ironrdp_pdu::gcc::KeyboardType::IbmEnhanced,
        keyboard_subtype: 0,
        keyboard_functional_keys_count: 12,
        keyboard_layout: 0,
        ime_file_name: String::new(),
        bitmap: None,
        dig_product_id: String::new(),
        client_dir: "C:\\Windows\\System32\\mstscax.dll".to_owned(),
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
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_initial_connector_pdu_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> Result<Vec<u8>, BackendError> {
    let config = build_connector_config_for_probe(plan, credential);
    let mut connector =
        ironrdp_connector::ClientConnector::new(config, "127.0.0.1:0".parse().expect("loopback"));
    let mut buffer = ironrdp_core::WriteBuf::new();
    let written = ironrdp_connector::Sequence::step_no_input(&mut connector, &mut buffer)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let written_len = written
        .size()
        .ok_or(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    Ok(buffer.filled()[..written_len].to_vec())
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn decode_initial_connection_request_for_probe(
    bytes: &[u8],
) -> Result<ironrdp_pdu::nego::ConnectionRequest, BackendError> {
    let request = ironrdp_core::decode::<
        ironrdp_pdu::x224::X224<ironrdp_pdu::nego::ConnectionRequest>,
    >(bytes)
    .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?
    .0;

    Ok(request)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn drive_connector_to_upgrade_boundary_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    selected_protocol: ironrdp_pdu::nego::SecurityProtocol,
) -> Result<ConnectorUpgradeBoundaryProbe, BackendError> {
    let config = build_connector_config_for_probe(plan, credential);
    let mut connector =
        ironrdp_connector::ClientConnector::new(config, "127.0.0.1:0".parse().expect("loopback"));
    let mut initial = ironrdp_core::WriteBuf::new();
    ironrdp_connector::Sequence::step_no_input(&mut connector, &mut initial)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    let server_confirm = encode_server_confirm_for_probe(selected_protocol)?;
    let mut output = ironrdp_core::WriteBuf::new();
    ironrdp_connector::Sequence::step(&mut connector, &server_confirm, &mut output)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    let requires_security_upgrade = connector.should_perform_security_upgrade();
    connector.mark_security_upgrade_as_done();

    Ok(ConnectorUpgradeBoundaryProbe {
        requires_security_upgrade,
        requires_credssp_after_upgrade: connector.should_perform_credssp(),
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn encode_server_confirm_for_probe(
    selected_protocol: ironrdp_pdu::nego::SecurityProtocol,
) -> Result<Vec<u8>, BackendError> {
    ironrdp_core::encode_vec(&ironrdp_pdu::x224::X224(
        ironrdp_pdu::nego::ConnectionConfirm::Response {
            flags: ironrdp_pdu::nego::ResponseFlags::empty(),
            protocol: selected_protocol,
        },
    ))
    .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn drive_blocking_connect_begin_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> Result<BlockingConnectBeginProbe, BackendError> {
    let config = build_connector_config_for_probe(plan, credential);
    let server_confirm =
        encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)?;
    let mut connector =
        ironrdp_connector::ClientConnector::new(config, "127.0.0.1:0".parse().expect("loopback"));
    let mut framed = ironrdp_blocking::Framed::new(ScriptedStream::new(vec![server_confirm]));

    let should_upgrade = ironrdp_blocking::connect_begin(&mut framed, &mut connector)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let (stream, leftover) = framed.into_inner();
    if !leftover.is_empty() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    Ok(BlockingConnectBeginProbe {
        requires_security_upgrade: should_upgrade,
        contains_cleartext_password: bytes_contain_secret(
            &stream.writes,
            credential.password.value.as_str().as_bytes(),
        ),
        written_bytes: stream.writes,
    })
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
    !secret.is_empty() && bytes.windows(secret.len()).any(|window| window == secret)
}

fn is_memory_user_grant(grant: &DesktopCredentialGrant) -> bool {
    grant.mode == "memory_user"
        && !grant.username.trim().is_empty()
        && !grant.password.expose().is_empty()
}

fn build_nonsecret_connection_plan(
    request: &OpenPayload,
) -> Result<NonSecretConnectionPlan, BackendError> {
    let upstream_host = request.target.upstream.host.trim();
    let tls_server_name = request.target.tls.server_name.trim();
    let effective_tls_server_name = if tls_server_name.is_empty() {
        upstream_host
    } else {
        tls_server_name
    };
    let tls_trust_source = build_tls_trust_source(request)?;
    let upstream_port = u16::try_from(request.target.upstream.port)
        .map_err(|_| BackendError::Unsupported(INVALID_CONNECTION_PLAN))?;
    let desktop_width = u16::try_from(request.target.screen.max_width)
        .map_err(|_| BackendError::Unsupported(INVALID_CONNECTION_PLAN))?;
    let desktop_height = u16::try_from(request.target.screen.max_height)
        .map_err(|_| BackendError::Unsupported(INVALID_CONNECTION_PLAN))?;

    if upstream_host.is_empty() || effective_tls_server_name.is_empty() {
        return Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN));
    }

    Ok(NonSecretConnectionPlan {
        upstream_host: upstream_host.to_owned(),
        upstream_port,
        tls_server_name: effective_tls_server_name.to_owned(),
        tls_trust_source,
        desktop_width,
        desktop_height,
    })
}

fn build_tls_trust_source(request: &OpenPayload) -> Result<TlsTrustSource, BackendError> {
    let ca_bundle_id = request.target.tls.ca_bundle_id.trim();

    match request.target.tls.mode.as_str() {
        TLS_MODE_SYSTEM => Ok(TlsTrustSource::SystemRoots),
        TLS_MODE_VERIFY if ca_bundle_id.is_empty() => Ok(TlsTrustSource::SystemRoots),
        TLS_MODE_VERIFY => Ok(TlsTrustSource::RegisteredCaBundle(ca_bundle_id.to_owned())),
        TLS_MODE_PINNED_CA if ca_bundle_id.is_empty() => {
            Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN))
        }
        TLS_MODE_PINNED_CA => Ok(TlsTrustSource::RegisteredCaBundle(ca_bundle_id.to_owned())),
        _ => Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN)),
    }
}

fn build_memory_user_credential(
    grant: &DesktopCredentialGrant,
) -> Result<MemoryUserCredential, BackendError> {
    let raw_username = grant.username.trim();
    let password = grant.password.expose();
    if raw_username.is_empty() || password.is_empty() {
        return Err(BackendError::Unsupported(MEMORY_USER_REQUIRED));
    }
    let (domain, username) = split_domain_username(raw_username);
    if username.is_empty() {
        return Err(BackendError::Unsupported(MEMORY_USER_REQUIRED));
    }

    Ok(MemoryUserCredential {
        domain: domain.map(|value| Zeroizing::new(value.to_owned())),
        username: Zeroizing::new(username.to_owned()),
        password: RedactedSecret {
            value: Zeroizing::new(password.to_owned()),
        },
    })
}

fn split_domain_username(username: &str) -> (Option<&str>, &str) {
    if let Some((domain, login)) = username.split_once('\\') {
        if !domain.is_empty() && !login.is_empty() {
            return (Some(domain), login);
        }
    }

    (None, username)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{parse_open_payload, tests::valid_open_payload};
    use ironrdp_pdu::gcc::KeyboardType;
    use ironrdp_pdu::rdp::capability_sets::MajorPlatformType;
    use ironrdp_pdu::rdp::client_info::PerformanceFlags;

    #[test]
    fn ironrdp_core_pdu_types_are_linked() {
        let _buffer = ironrdp_core::WriteBuf::new();

        assert_eq!(KeyboardType::IbmEnhanced.as_u32(), 4);
        assert_eq!(
            format!("{:?}", MajorPlatformType::UNIX),
            "MajorPlatformType(0x04-UNIX)"
        );
        assert!(PerformanceFlags::default().contains(PerformanceFlags::ENABLE_FONT_SMOOTHING));
    }

    #[test]
    fn nonsecret_connection_plan_uses_registered_endpoint_and_server_name() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");

        assert_eq!(
            plan,
            NonSecretConnectionPlan {
                upstream_host: "win.example".to_owned(),
                upstream_port: 3389,
                tls_server_name: "win.example".to_owned(),
                tls_trust_source: TlsTrustSource::SystemRoots,
                desktop_width: 1920,
                desktop_height: 1080,
            }
        );
    }

    #[test]
    fn nonsecret_connection_plan_falls_back_to_upstream_host_for_tls_name() {
        let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"verify","nla_mode":"required"}"#,
        );
        let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");

        assert_eq!(plan.upstream_host, "win.example");
        assert_eq!(plan.tls_server_name, "win.example");
    }

    #[test]
    fn nonsecret_connection_plan_uses_registered_ca_bundle_for_verify_mode() {
        let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"verify","ca_bundle_id":"ca-rdp-prod","nla_mode":"required","server_name":"win.example"}"#,
        );
        let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");

        assert_eq!(
            plan.tls_trust_source,
            TlsTrustSource::RegisteredCaBundle("ca-rdp-prod".to_owned())
        );
    }

    #[test]
    fn nonsecret_connection_plan_requires_registered_ca_bundle_for_pinned_ca() {
        let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"pinned_ca","nla_mode":"required","server_name":"win.example"}"#,
        );
        let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
        let err = build_nonsecret_connection_plan(&payload).expect_err("pinned CA rejected");

        assert_eq!(err, BackendError::Unsupported(INVALID_CONNECTION_PLAN));
    }

    #[test]
    fn nonsecret_connection_plan_uses_registered_ca_bundle_for_pinned_ca() {
        let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"pinned_ca","ca_bundle_id":"ca-rdp-prod","nla_mode":"required","server_name":"win.example"}"#,
        );
        let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");

        assert_eq!(
            plan.tls_trust_source,
            TlsTrustSource::RegisteredCaBundle("ca-rdp-prod".to_owned())
        );
    }

    #[test]
    fn memory_user_credential_uses_zeroizing_redacted_storage() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        assert!(credential.domain.is_none());
        assert_eq!(credential.username.as_str(), "alice");
        assert_eq!(credential.password.value.as_str(), "secret");
        assert_eq!(
            format!("{credential:?}"),
            r#"MemoryUserCredential { domain: "<redacted>", username: "<redacted>", password: <redacted> }"#
        );
    }

    #[test]
    fn memory_user_credential_splits_windows_domain_username() {
        let raw = valid_open_payload()
            .replace(r#""username":"alice""#, r#""username":"EXAMPLE\\alice""#)
            .replace(
                r#""allowed_principals":["alice"]"#,
                r#""allowed_principals":["EXAMPLE\\alice"]"#,
            );
        let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        assert_eq!(
            credential.domain.as_ref().map(|domain| domain.as_str()),
            Some("EXAMPLE")
        );
        assert_eq!(credential.username.as_str(), "alice");
        assert_eq!(credential.password.value.as_str(), "secret");
        assert!(!format!("{credential:?}").contains("EXAMPLE"));
        assert!(!format!("{credential:?}").contains("alice"));
        assert!(!format!("{credential:?}").contains("secret"));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_builds_config_from_validated_open_payload() {
        let raw = valid_open_payload()
            .replace(r#""username":"alice""#, r#""username":"EXAMPLE\\alice""#)
            .replace(
                r#""allowed_principals":["alice"]"#,
                r#""allowed_principals":["EXAMPLE\\alice"]"#,
            );
        let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        let config = build_connector_config_for_probe(&plan, &credential);

        assert_eq!(config.desktop_size.width, 1920);
        assert_eq!(config.desktop_size.height, 1080);
        assert!(!config.enable_tls);
        assert!(config.enable_credssp);
        assert_eq!(config.domain.as_deref(), Some("EXAMPLE"));
        let ironrdp_connector::Credentials::UsernamePassword { username, .. } = config.credentials;
        assert_eq!(username, "alice");
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_initial_pdu_advertises_nla_without_tls_fallback() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        let pdu = build_initial_connector_pdu_for_probe(&plan, &credential).expect("initial pdu");
        let request = decode_initial_connection_request_for_probe(&pdu).expect("decoded pdu");

        assert!(request.protocol.intersects(
            ironrdp_pdu::nego::SecurityProtocol::HYBRID
                | ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX
        ));
        assert!(!request
            .protocol
            .intersects(ironrdp_pdu::nego::SecurityProtocol::SSL));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_hybrid_confirm_reaches_tls_then_credssp_boundary() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        for protocol in [
            ironrdp_pdu::nego::SecurityProtocol::HYBRID,
            ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX,
        ] {
            let boundary =
                drive_connector_to_upgrade_boundary_for_probe(&plan, &credential, protocol)
                    .expect("upgrade boundary");

            assert!(boundary.requires_security_upgrade);
            assert!(boundary.requires_credssp_after_upgrade);
        }
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_rejects_tls_only_server_confirm() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        let err = drive_connector_to_upgrade_boundary_for_probe(
            &plan,
            &credential,
            ironrdp_pdu::nego::SecurityProtocol::SSL,
        )
        .expect_err("tls-only confirm rejected");

        assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_blocking_connect_begin_reuses_upstream_loop_without_password() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        let probe = drive_blocking_connect_begin_for_probe(&plan, &credential)
            .expect("blocking connect begin");

        assert!(probe.requires_security_upgrade);
        assert!(!probe.contains_cleartext_password);
        assert!(!probe.written_bytes.is_empty());
    }
}
