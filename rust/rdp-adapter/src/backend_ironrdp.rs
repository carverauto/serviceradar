use crate::backend::{BackendError, RdpBackend, RdpBackendSession};
use crate::protocol::{DesktopCredentialGrant, OpenPayload};

const CONNECTOR_NOT_IMPLEMENTED: &str =
    "IronRDP backend is linked, but the connector loop is not implemented";
const MEMORY_USER_REQUIRED: &str =
    "IronRDP backend currently requires a memory-user credential grant";
const INVALID_CONNECTION_PLAN: &str = "IronRDP connection plan is invalid";

#[derive(Debug, Eq, PartialEq)]
struct NonSecretConnectionPlan {
    upstream_host: String,
    upstream_port: u16,
    tls_server_name: String,
    desktop_width: u16,
    desktop_height: u16,
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

        // Do not copy live credentials into IronRDP-owned strings until the
        // connection loop can guarantee drop ordering and zeroization.
        Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))
    }
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
        desktop_width,
        desktop_height,
    })
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
}
