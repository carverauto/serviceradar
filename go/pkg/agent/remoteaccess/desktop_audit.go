/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package remoteaccess

import (
	"fmt"
	"strconv"
	"strings"
)

// DesktopAuditMetadata returns metadata that is safe to persist for desktop
// session audit/recording records. It intentionally omits usernames, passwords,
// credential secret references, and caller-supplied metadata maps.
func DesktopAuditMetadata(payload DesktopOpenPayload) map[string]string {
	target := payload.Target
	credentialMode := target.Credential.Mode
	if payload.CredentialGrant != nil && payload.CredentialGrant.Mode != "" {
		credentialMode = payload.CredentialGrant.Mode
	}

	return map[string]string{
		"protocol":                       target.Protocol,
		"target_id":                      target.TargetID,
		"device_uid":                     target.DeviceUID,
		"selected_agent_id":              target.Route.SelectedAgentID,
		"selected_gateway_id":            target.Route.SelectedGateway,
		"upstream_host":                  target.Upstream.Host,
		"upstream_port":                  strconv.FormatUint(uint64(target.Upstream.Port), 10),
		"tls_mode":                       target.TLS.Mode,
		"tls_ca_bundle_id":               target.TLS.CABundleID,
		"nla_mode":                       target.TLS.NLAMode,
		"tls_server_name":                target.TLS.ServerName,
		"credential_mode":                credentialMode,
		"screen_max_width":               strconv.FormatUint(uint64(target.Screen.MaxWidth), 10),
		"screen_max_height":              strconv.FormatUint(uint64(target.Screen.MaxHeight), 10),
		"screen_frame_rate":              strconv.FormatUint(uint64(target.Screen.FrameRate), 10),
		"screen_bitrate_bps":             strconv.FormatUint(uint64(target.Screen.BitrateBPS), 10),
		"screen_idle_seconds":            strconv.FormatUint(uint64(target.Screen.IdleSeconds), 10),
		"screen_ttl_seconds":             strconv.FormatUint(uint64(target.Screen.TTLSeconds), 10),
		"redirection_clipboard_mode":     target.Redirection.ClipboardMode,
		"redirection_drive":              strconv.FormatBool(target.Redirection.Drive),
		"redirection_printer":            strconv.FormatBool(target.Redirection.Printer),
		"redirection_audio":              strconv.FormatBool(target.Redirection.Audio),
		"redirection_smart_card":         strconv.FormatBool(target.Redirection.SmartCard),
		"redirection_file_copy":          strconv.FormatBool(target.Redirection.FileCopy),
		"approval_required":              strconv.FormatBool(target.ApprovalRequired),
		"recording_metadata_enabled":     strconv.FormatBool(target.Recording.MetadataEnabled),
		"recording_screen_enabled":       strconv.FormatBool(target.Recording.ScreenEnabled),
		"recording_clipboard_enabled":    strconv.FormatBool(target.Recording.ClipboardEnabled),
		"recording_file_enabled":         strconv.FormatBool(target.Recording.FileEnabled),
		"recording_audio_enabled":        strconv.FormatBool(target.Recording.AudioEnabled),
		"credential_grant_expires_unix":  desktopCredentialGrantExpiresUnix(payload.CredentialGrant),
		"credential_grant_actor_bound":   strconv.FormatBool(payload.CredentialGrant != nil && payload.CredentialGrant.ActorID != ""),
		"credential_grant_session_bound": strconv.FormatBool(payload.CredentialGrant != nil && payload.CredentialGrant.SessionID != ""),
		"credential_grant_target_bound":  strconv.FormatBool(payload.CredentialGrant != nil && payload.CredentialGrant.TargetID != ""),
		"credential_grant_route_bound":   strconv.FormatBool(payload.CredentialGrant != nil && payload.CredentialGrant.RouteID != ""),
	}
}

func desktopCredentialGrantExpiresUnix(grant *DesktopCredentialGrant) string {
	if grant == nil || grant.ExpiresUnix == 0 {
		return ""
	}

	return strconv.FormatInt(grant.ExpiresUnix, 10)
}

// DesktopLifecycleAuditMetadata returns safe metadata for desktop session
// lifecycle records. It includes target/policy posture plus a fixed event type
// and capped single-line outcome, but it omits credential material and
// caller-supplied metadata.
func DesktopLifecycleAuditMetadata(
	payload DesktopOpenPayload,
	eventType string,
	timestampUnix int64,
	outcome string,
) (map[string]string, error) {
	if !validDesktopLifecycleEventType(eventType) {
		return nil, fmt.Errorf("%w: unsupported lifecycle event type", ErrInvalidDesktopFrame)
	}
	if timestampUnix <= 0 {
		return nil, fmt.Errorf("%w: missing lifecycle timestamp", ErrInvalidDesktopFrame)
	}

	metadata := DesktopAuditMetadata(payload)
	normalizedOutcome, truncated := normalizeDesktopAuditReason(outcome, DesktopMaxAuditReason)
	metadata["event_type"] = eventType
	metadata["event_timestamp_unix"] = strconv.FormatInt(timestampUnix, 10)
	metadata["event_outcome"] = normalizedOutcome
	metadata["event_outcome_truncated"] = strconv.FormatBool(truncated)

	return metadata, nil
}

// DesktopFrameAuditMetadata returns frame metadata suitable for audit and
// recording records without retaining screen pixels, clipboard data, key names,
// button names, or other frame payload contents.
func DesktopFrameAuditMetadata(frame DesktopFrame) map[string]string {
	metadata := map[string]string{
		"session_id":     frame.SessionID,
		"protocol":       frame.Protocol,
		"frame_type":     frame.FrameType,
		"width":          strconv.FormatUint(uint64(frame.Width), 10),
		"height":         strconv.FormatUint(uint64(frame.Height), 10),
		"encoding":       frame.Encoding,
		"payload_bytes":  strconv.Itoa(len(frame.Data)),
		"direction":      frame.Direction,
		"timestamp_unix": strconv.FormatInt(frame.Timestamp, 10),
		"has_input":      strconv.FormatBool(frame.Input != nil),
		"has_quality":    strconv.FormatBool(frame.Quality != nil),
	}
	if frame.Input != nil {
		metadata["input_kind"] = frame.Input.Kind
	}
	if frame.Quality != nil {
		metadata["quality_max_frame_rate"] = strconv.FormatUint(uint64(frame.Quality.MaxFrameRate), 10)
		metadata["quality_max_bitrate_bps"] = strconv.FormatUint(uint64(frame.Quality.MaxBitrate), 10)
		metadata["quality_width"] = strconv.FormatUint(uint64(frame.Quality.Width), 10)
		metadata["quality_height"] = strconv.FormatUint(uint64(frame.Quality.Height), 10)
	}

	return metadata
}

// DesktopTerminationAuditMetadata returns safe metadata for desktop close/error
// outcomes. It includes a capped, single-line reason while keeping generic frame
// audit metadata free of close reasons by default.
func DesktopTerminationAuditMetadata(frame DesktopFrame) map[string]string {
	metadata := DesktopFrameAuditMetadata(frame)
	reason, truncated := normalizeDesktopAuditReason(frame.Reason, DesktopMaxAuditReason)
	metadata["termination_reason"] = reason
	metadata["termination_reason_truncated"] = strconv.FormatBool(truncated)

	return metadata
}

func normalizeDesktopAuditReason(reason string, maxBytes int) (string, bool) {
	reason = strings.TrimSpace(reason)
	if reason == "" || maxBytes <= 0 {
		return "", len(reason) > 0
	}

	var out strings.Builder
	truncated := false

	for _, r := range reason {
		if r < ' ' || r == 0x7f {
			r = ' '
		}

		next := string(r)
		if out.Len()+len(next) > maxBytes {
			truncated = true
			break
		}
		out.WriteString(next)
	}

	return strings.TrimSpace(out.String()), truncated
}

// ValidateDesktopContentRecording returns nil only when policy explicitly
// allows retaining the content represented by the frame.
func ValidateDesktopContentRecording(frame DesktopFrame, policy DesktopRecordingPolicy) error {
	switch frame.FrameType {
	case DesktopFrameTypeUpdate:
		if !policy.ScreenEnabled {
			return ErrDesktopContentRecord
		}
	case DesktopFrameTypeClipboard:
		if !policy.ClipboardEnabled {
			return ErrDesktopContentRecord
		}
	}

	return nil
}
