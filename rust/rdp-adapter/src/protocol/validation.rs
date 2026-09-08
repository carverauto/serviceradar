use super::constants::*;
use super::errors::{DesktopFrameError, DesktopMediaAckError, OpenPayloadError};
use super::types::{
    DesktopCredentialPolicy, DesktopFrame, DesktopMediaAckMessage, DesktopRecordingPolicy,
    DesktopRedirectionPolicy, DesktopRoute, DesktopScreenPolicy, DesktopTlsPolicy, OpenPayload,
};

pub(super) fn validate_open_payload(payload: &OpenPayload) -> Result<(), OpenPayloadError> {
    if payload.schema != OPEN_SCHEMA {
        return Err(OpenPayloadError::InvalidSchema);
    }
    if payload.session_id.trim().is_empty() {
        return Err(OpenPayloadError::MissingSession);
    }
    if payload.actor_id.trim().is_empty() {
        return Err(OpenPayloadError::MissingActor);
    }
    if payload.start_unix <= 0 {
        return Err(OpenPayloadError::InvalidSessionPolicy);
    }
    if payload.local_agent_id.trim().is_empty() {
        return Err(OpenPayloadError::MissingAgent);
    }

    let target = &payload.target;
    if target.target_id.trim().is_empty() {
        return Err(OpenPayloadError::MissingTarget);
    }
    if target.protocol != PROTOCOL_RDP && target.protocol != PROTOCOL_DESKTOP {
        return Err(OpenPayloadError::UnsupportedProtocol);
    }
    if target.route.selected_agent_id.trim().is_empty() {
        return Err(OpenPayloadError::MissingRoute);
    }
    if target.route.selected_agent_id != payload.local_agent_id {
        return Err(OpenPayloadError::MissingRoute);
    }
    if !helper_route_policy_supported(&target.route) {
        return Err(OpenPayloadError::MissingRoute);
    }
    if !payload.gateway_id.is_empty()
        && !target.route.selected_gateway_id.is_empty()
        && target.route.selected_gateway_id != payload.gateway_id
    {
        return Err(OpenPayloadError::MissingRoute);
    }
    if target.upstream.host.trim().is_empty()
        || target.upstream.port == 0
        || target.upstream.port > MAX_TCP_PORT
    {
        return Err(OpenPayloadError::MissingUpstream);
    }
    if !helper_tls_policy_supported(&target.tls) {
        return Err(OpenPayloadError::UnsupportedTlsPolicy);
    }
    if !helper_credential_policy_supported(&target.credential) {
        return Err(OpenPayloadError::UnsupportedCredentialMode);
    }
    if !helper_screen_policy_supported(&target.screen) {
        return Err(OpenPayloadError::InvalidScreenPolicy);
    }
    if !helper_redirection_policy_supported(&target.redirection) {
        return Err(OpenPayloadError::UnsupportedRedirection);
    }
    if !helper_recording_policy_supported(&target.recording) {
        return Err(OpenPayloadError::UnsupportedRecordingPolicy);
    }

    validate_credential_grant(payload)
}

pub(super) fn validate_desktop_frame(
    frame: &DesktopFrame,
    session_id: &str,
    policy: &DesktopScreenPolicy,
) -> Result<(), DesktopFrameError> {
    if frame.session_id.trim().is_empty() {
        return Err(DesktopFrameError::MissingSession);
    }
    if !session_id.is_empty() && frame.session_id != session_id {
        return Err(DesktopFrameError::SessionMismatch);
    }
    if frame.protocol != PROTOCOL_RDP && frame.protocol != PROTOCOL_DESKTOP {
        return Err(DesktopFrameError::UnsupportedProtocol);
    }

    match frame.frame_type.as_str() {
        FRAME_TYPE_INPUT => validate_desktop_input_frame(frame, policy),
        FRAME_TYPE_RESIZE => validate_desktop_dimensions(frame.width, frame.height, policy),
        FRAME_TYPE_QUALITY => validate_desktop_quality_frame(frame, policy),
        FRAME_TYPE_DISCONNECT => {
            if frame.reason.trim().len() > MAX_CLOSE_REASON_BYTES {
                return Err(DesktopFrameError::ReasonTooLarge);
            }

            Ok(())
        }
        _ => Err(DesktopFrameError::UnsupportedFrameType),
    }
}

fn validate_desktop_input_frame(
    frame: &DesktopFrame,
    policy: &DesktopScreenPolicy,
) -> Result<(), DesktopFrameError> {
    let Some(input) = frame.input.as_ref() else {
        return Err(DesktopFrameError::InvalidInputEvent);
    };
    if !matches!(
        input.kind.as_str(),
        INPUT_KIND_KEY | INPUT_KIND_POINTER | INPUT_KIND_FOCUS
    ) {
        return Err(DesktopFrameError::InvalidInputEvent);
    }
    if input.key.len() > MAX_INPUT_TOKEN_BYTES || input.button.len() > MAX_INPUT_TOKEN_BYTES {
        return Err(DesktopFrameError::InputTokenTooLarge);
    }
    if input.kind == INPUT_KIND_POINTER
        && (input.x >= policy.max_width || input.y >= policy.max_height)
    {
        return Err(DesktopFrameError::PointerOutOfBounds);
    }

    Ok(())
}

fn validate_desktop_dimensions(
    width: u32,
    height: u32,
    policy: &DesktopScreenPolicy,
) -> Result<(), DesktopFrameError> {
    if width == 0 || height == 0 || width > policy.max_width || height > policy.max_height {
        return Err(DesktopFrameError::InvalidDimensions);
    }

    Ok(())
}

fn validate_desktop_quality_frame(
    frame: &DesktopFrame,
    policy: &DesktopScreenPolicy,
) -> Result<(), DesktopFrameError> {
    let Some(quality) = frame.quality.as_ref() else {
        return Err(DesktopFrameError::MissingQualityRequest);
    };
    if quality.max_frame_rate > policy.frame_rate
        || quality.max_bitrate_bps > policy.bitrate_bps
        || quality.width > policy.max_width
        || quality.height > policy.max_height
    {
        return Err(DesktopFrameError::QualityExceedsPolicy);
    }

    Ok(())
}

pub(super) fn validate_desktop_media_ack_message(
    message: &DesktopMediaAckMessage,
    session_id: &str,
) -> Result<(), DesktopMediaAckError> {
    if message.message_type != ACK_TYPE {
        return Err(DesktopMediaAckError::InvalidType);
    }

    let ack = &message.ack;
    if ack.session_binding_id.trim().is_empty() {
        return Err(DesktopMediaAckError::MissingSession);
    }
    if !session_id.is_empty() && ack.session_binding_id != session_id {
        return Err(DesktopMediaAckError::SessionMismatch);
    }
    if ack.media_session_id.trim().is_empty() {
        return Err(DesktopMediaAckError::MissingMediaSession);
    }
    if ack.pause && ack.resume {
        return Err(DesktopMediaAckError::AmbiguousFlowControl);
    }
    if !matches!(
        ack.quality_level.as_str(),
        "" | MEDIA_QUALITY_AUTO | MEDIA_QUALITY_LOW
    ) {
        return Err(DesktopMediaAckError::UnsupportedQuality);
    }
    if ack.credit_bytes > MAX_ACK_CREDIT_BYTES {
        return Err(DesktopMediaAckError::CreditTooLarge);
    }
    if ack.close_reason.trim().len() > MAX_ACK_CLOSE_REASON_BYTES {
        return Err(DesktopMediaAckError::CloseReasonTooLarge);
    }

    Ok(())
}

fn helper_route_policy_supported(route: &DesktopRoute) -> bool {
    route.allowed_agent_ids.is_empty()
        || route
            .allowed_agent_ids
            .iter()
            .any(|agent_id| agent_id == &route.selected_agent_id)
}

fn helper_tls_policy_supported(policy: &DesktopTlsPolicy) -> bool {
    if policy.nla_mode != NLA_MODE_REQUIRED
        || policy.ca_bundle_pem.len() > MAX_TLS_CA_BUNDLE_PEM_BYTES
    {
        return false;
    }

    let has_bundle_id = !policy.ca_bundle_id.is_empty();
    let has_bundle_pem = !policy.ca_bundle_pem.is_empty();
    let bundle_pair_valid = has_bundle_id == has_bundle_pem
        && (!has_bundle_id
            || (!policy.ca_bundle_id.trim().is_empty() && !policy.ca_bundle_pem.trim().is_empty()));

    match policy.mode.as_str() {
        TLS_MODE_VERIFY => bundle_pair_valid,
        TLS_MODE_PINNED_CA => has_bundle_id && has_bundle_pem,
        TLS_MODE_SYSTEM => !has_bundle_id && !has_bundle_pem,
        _ => false,
    }
}

fn helper_credential_policy_supported(policy: &DesktopCredentialPolicy) -> bool {
    matches!(
        policy.mode.as_str(),
        CREDENTIAL_MODE_MEMORY_USER | CREDENTIAL_MODE_BROKERED_SECRET
    )
}

fn helper_screen_policy_supported(policy: &DesktopScreenPolicy) -> bool {
    policy.max_width > 0
        && policy.max_width <= MAX_SCREEN_WIDTH
        && policy.max_height > 0
        && policy.max_height <= MAX_SCREEN_HEIGHT
        && policy.frame_rate > 0
        && policy.frame_rate <= MAX_FRAME_RATE
        && policy.bitrate_bps > 0
        && policy.bitrate_bps <= MAX_BITRATE_BPS
        && policy.idle_seconds > 0
        && policy.ttl_seconds > 0
}

fn helper_redirection_policy_supported(policy: &DesktopRedirectionPolicy) -> bool {
    policy.clipboard_mode == CLIPBOARD_MODE_DISABLED
        && !policy.drive
        && !policy.printer
        && !policy.audio
        && !policy.smart_card
        && !policy.file_copy
}

fn helper_recording_policy_supported(policy: &DesktopRecordingPolicy) -> bool {
    policy.metadata_enabled
        && !policy.screen_enabled
        && !policy.clipboard_enabled
        && !policy.file_enabled
        && !policy.audio_enabled
}

fn validate_credential_grant(payload: &OpenPayload) -> Result<(), OpenPayloadError> {
    let Some(grant) = &payload.credential_grant else {
        return Ok(());
    };
    let target = &payload.target;

    if grant.mode != target.credential.mode {
        return Err(OpenPayloadError::InvalidCredentialGrant);
    }
    if !grant.target_id.is_empty() && grant.target_id != target.target_id {
        return Err(OpenPayloadError::InvalidCredentialGrant);
    }
    if !grant.session_id.is_empty() && grant.session_id != payload.session_id {
        return Err(OpenPayloadError::InvalidCredentialGrant);
    }
    if grant.actor_id.trim().is_empty() || grant.actor_id != payload.actor_id {
        return Err(OpenPayloadError::InvalidCredentialGrant);
    }

    match grant.mode.as_str() {
        CREDENTIAL_MODE_MEMORY_USER => {
            if grant.username.trim().is_empty()
                || grant.password.is_empty()
                || grant.password.expose().is_err()
            {
                return Err(OpenPayloadError::InvalidCredentialGrant);
            }
            if grant.session_id.trim().is_empty()
                || grant.target_id.trim().is_empty()
                || grant.session_id != payload.session_id
                || grant.target_id != target.target_id
            {
                return Err(OpenPayloadError::InvalidCredentialGrant);
            }
            if !target.credential.allowed_principals.is_empty()
                && !target
                    .credential
                    .allowed_principals
                    .iter()
                    .any(|principal| principal == &grant.username)
            {
                return Err(OpenPayloadError::InvalidCredentialGrant);
            }
        }
        CREDENTIAL_MODE_BROKERED_SECRET => {
            let Ok(secret_ref) = grant.credential_secret_ref.expose() else {
                return Err(OpenPayloadError::InvalidCredentialGrant);
            };

            if grant.credential_secret_ref.is_empty()
                || secret_ref != target.credential.credential_secret_ref
                || !grant.password.is_empty()
                || grant.session_id.trim().is_empty()
                || grant.route_id.trim().is_empty()
                || grant.session_id != payload.session_id
                || grant.route_id != target.route.selected_agent_id
                || grant.expires_unix <= 0
            {
                return Err(OpenPayloadError::InvalidCredentialGrant);
            }
        }
        _ => {}
    }

    Ok(())
}
