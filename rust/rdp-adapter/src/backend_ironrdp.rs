use crate::backend::{BackendError, RdpBackend, RdpBackendSession};
use crate::protocol::{DesktopCredentialGrant, OpenPayload};

const CONNECTOR_NOT_IMPLEMENTED: &str =
    "IronRDP backend is linked, but the connector loop is not implemented";
const MEMORY_USER_REQUIRED: &str =
    "IronRDP backend currently requires a memory-user credential grant";

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

#[cfg(test)]
mod tests {
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
}
