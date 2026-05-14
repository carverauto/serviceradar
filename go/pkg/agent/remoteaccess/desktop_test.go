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
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

const (
	desktopTestTargetID    = "rdp-target-1"
	desktopTestAgentID     = "agent-1"
	desktopTestHost        = "windows.internal"
	desktopTestExpiresUnix = 4_102_444_800
)

func TestNormalizeDesktopTargetAppliesSecureDefaults(t *testing.T) {
	t.Parallel()

	target, err := NormalizeDesktopTarget(DesktopTarget{
		TargetID: desktopTestTargetID,
		Route: DesktopRoute{
			SelectedAgentID: desktopTestAgentID,
		},
		Upstream: DesktopUpstream{
			Host: desktopTestHost,
		},
		Credential: DesktopCredentialPolicy{
			Mode: DesktopCredentialModeMemoryUser,
		},
	})
	if err != nil {
		t.Fatalf("NormalizeDesktopTarget returned error: %v", err)
	}

	if target.Protocol != ProtocolRDP {
		t.Fatalf("Protocol = %q, want %q", target.Protocol, ProtocolRDP)
	}
	if target.Upstream.Port != DesktopDefaultRDPPort {
		t.Fatalf("Upstream.Port = %d, want %d", target.Upstream.Port, DesktopDefaultRDPPort)
	}
	if target.TLS.Mode != DesktopDefaultTLSPolicy {
		t.Fatalf("TLS.Mode = %q, want %q", target.TLS.Mode, DesktopDefaultTLSPolicy)
	}
	if target.Redirection.ClipboardMode != DesktopClipboardModeDisabled ||
		target.Redirection.Drive ||
		target.Redirection.Printer ||
		target.Redirection.Audio ||
		target.Redirection.SmartCard ||
		target.Redirection.FileCopy {
		t.Fatalf("redirection defaults = %#v, want disabled", target.Redirection)
	}
	if !target.Recording.MetadataEnabled || target.Recording.ScreenEnabled {
		t.Fatalf("recording defaults = %#v, want metadata-only", target.Recording)
	}
}

func TestNormalizeDesktopTargetRejectsUntrustedOrUnsafePolicy(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*DesktopTarget)
	}{
		{
			name: "missing target id",
			mutate: func(target *DesktopTarget) {
				target.TargetID = ""
			},
		},
		{
			name: "unsupported protocol",
			mutate: func(target *DesktopTarget) {
				target.Protocol = ProtocolSSH
			},
		},
		{
			name: "missing selected agent",
			mutate: func(target *DesktopTarget) {
				target.Route.SelectedAgentID = ""
			},
		},
		{
			name: "selected agent outside allowed route set",
			mutate: func(target *DesktopTarget) {
				target.Route.AllowedAgentIDs = []string{"agent-2"}
			},
		},
		{
			name: "missing upstream",
			mutate: func(target *DesktopTarget) {
				target.Upstream.Host = ""
			},
		},
		{
			name: "invalid credential mode",
			mutate: func(target *DesktopTarget) {
				target.Credential.Mode = "shared_admin"
			},
		},
		{
			name: "brokered secret without approval",
			mutate: func(target *DesktopTarget) {
				target.Credential.Mode = DesktopCredentialModeBrokeredSecret
				target.Credential.CredentialSecretRef = "secretref:rdp/admin"
				target.ApprovalRequired = false
			},
		},
		{
			name: "invalid screen quota",
			mutate: func(target *DesktopTarget) {
				target.Screen.MaxWidth = DesktopMaxWidth + 1
			},
		},
		{
			name: "invalid clipboard mode",
			mutate: func(target *DesktopTarget) {
				target.Redirection.ClipboardMode = "all_content"
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			target := validDesktopTarget()
			tt.mutate(&target)
			_, err := NormalizeDesktopTarget(target)
			if !errors.Is(err, ErrInvalidDesktopTarget) {
				t.Fatalf("error = %v, want %v", err, ErrInvalidDesktopTarget)
			}
		})
	}
}

func TestDecodeDesktopOpenPayloadValidatesTargetAndGrantBinding(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Credential.Mode = DesktopCredentialModeBrokeredSecret
	target.Credential.CredentialSecretRef = "secretref:rdp/admin"
	target.ApprovalRequired = true

	payload := DesktopOpenPayload{
		Target: target,
		CredentialGrant: &DesktopCredentialGrant{
			Mode:                DesktopCredentialModeBrokeredSecret,
			CredentialSecretRef: "secretref:rdp/admin",
			ActorID:             "user-1",
			SessionID:           "session-1",
			TargetID:            desktopTestTargetID,
			RouteID:             desktopTestAgentID,
			ExpiresUnix:         desktopTestExpiresUnix,
		},
	}
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	got, err := DecodeDesktopOpenPayload(data)
	if err != nil {
		t.Fatalf("DecodeDesktopOpenPayload returned error: %v", err)
	}
	if got.CredentialGrant == nil || got.CredentialGrant.TargetID != desktopTestTargetID {
		t.Fatalf("CredentialGrant = %#v", got.CredentialGrant)
	}

	payload.CredentialGrant.TargetID = "other-target"
	data, err = json.Marshal(payload)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	_, err = DecodeDesktopOpenPayload(data)
	if !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("mismatched grant error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
}

func TestDecodeDesktopOpenFrameForAgentEnforcesSelectedRoute(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Credential.Mode = DesktopCredentialModeBrokeredSecret
	target.Credential.CredentialSecretRef = "secretref:rdp/admin"
	target.ApprovalRequired = true

	payload := DesktopOpenPayload{
		Target: target,
		CredentialGrant: &DesktopCredentialGrant{
			Mode:                DesktopCredentialModeBrokeredSecret,
			CredentialSecretRef: "secretref:rdp/admin",
			ActorID:             "user-1",
			SessionID:           fakeRemoteSessionID,
			TargetID:            desktopTestTargetID,
			RouteID:             desktopTestAgentID,
			ExpiresUnix:         desktopTestExpiresUnix,
		},
	}
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	frame := Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: FrameTypeOpen,
		Data:      data,
	}

	got, err := DecodeDesktopOpenFrameForAgent(frame, desktopTestAgentID)
	if err != nil {
		t.Fatalf("DecodeDesktopOpenFrameForAgent returned error: %v", err)
	}
	if got.Target.Route.SelectedAgentID != desktopTestAgentID {
		t.Fatalf("SelectedAgentID = %q, want %q", got.Target.Route.SelectedAgentID, desktopTestAgentID)
	}

	if _, err := DecodeDesktopOpenFrameForAgent(frame, "agent-2"); !errors.Is(err, ErrDesktopRouteLost) {
		t.Fatalf("route mismatch error = %v, want %v", err, ErrDesktopRouteLost)
	}

	payload.CredentialGrant.SessionID = "other-session"
	data, err = json.Marshal(payload)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}
	frame.Data = data
	if _, err := DecodeDesktopOpenFrameForAgent(frame, desktopTestAgentID); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("grant session mismatch error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
}

func TestValidateDesktopRouteBindingDetectsRouteLoss(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Route.SelectedGateway = "gateway-1"

	if err := ValidateDesktopRouteBinding(target, desktopTestAgentID, "gateway-1"); err != nil {
		t.Fatalf("ValidateDesktopRouteBinding returned error: %v", err)
	}
	if err := ValidateDesktopRouteBinding(target, desktopTestAgentID, ""); err != nil {
		t.Fatalf("ValidateDesktopRouteBinding without gateway returned error: %v", err)
	}
	if err := ValidateDesktopRouteBinding(target, "agent-2", "gateway-1"); !errors.Is(err, ErrDesktopRouteLost) {
		t.Fatalf("agent route-loss error = %v, want %v", err, ErrDesktopRouteLost)
	}
	if err := ValidateDesktopRouteBinding(target, desktopTestAgentID, "gateway-2"); !errors.Is(err, ErrDesktopRouteLost) {
		t.Fatalf("gateway route-loss error = %v, want %v", err, ErrDesktopRouteLost)
	}
	if err := ValidateDesktopRouteBinding(target, "", "gateway-1"); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("missing local agent error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
}

func TestDesktopSessionGuardComposesRouteLifetimePolicyAndQuota(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Route.SelectedGateway = "gateway-1"
	target.Screen = DesktopScreenPolicy{
		MaxWidth:    1280,
		MaxHeight:   720,
		FrameRate:   1,
		BitrateBPS:  1024,
		IdleSeconds: 10,
		TTLSeconds:  30,
	}
	target.Redirection.ClipboardMode = DesktopClipboardModeTextBoth

	guard, err := NewDesktopSessionGuard(fakeRemoteSessionID, target, 100)
	if err != nil {
		t.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}
	if guard.SessionID() != fakeRemoteSessionID || guard.LastActivityUnix() != 100 {
		t.Fatalf("guard identity/activity = %q/%d", guard.SessionID(), guard.LastActivityUnix())
	}
	if got := guard.Target(); got.Screen.FrameRate != 1 || got.Redirection.ClipboardMode != DesktopClipboardModeTextBoth {
		t.Fatalf("guard target = %#v", got)
	}

	frame := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeUpdate,
		Width:     1280,
		Height:    720,
		Data:      []byte{0x01},
	}
	if err := guard.ValidateFrame(frame, desktopTestAgentID, "gateway-1", 101, 1); err != nil {
		t.Fatalf("ValidateFrame returned error: %v", err)
	}
	if guard.LastActivityUnix() != 101 {
		t.Fatalf("LastActivityUnix = %d, want 101", guard.LastActivityUnix())
	}

	if err := guard.ValidateFrame(frame, desktopTestAgentID, "gateway-1", 102, 2); !errors.Is(err, ErrDesktopQuotaExceeded) {
		t.Fatalf("quota error = %v, want %v", err, ErrDesktopQuotaExceeded)
	}

	clipboard := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeClipboard,
		Direction: DesktopClipboardDirectionToRemote,
		Data:      []byte("text"),
	}
	if err := guard.ValidateFrame(clipboard, desktopTestAgentID, "gateway-1", 103, 3); err != nil {
		t.Fatalf("clipboard frame returned error: %v", err)
	}
}

func TestDesktopSessionGuardRejectsSessionRouteAndLifetimeViolations(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Route.SelectedGateway = "gateway-1"
	target.Screen = DesktopScreenPolicy{
		MaxWidth:    1280,
		MaxHeight:   720,
		FrameRate:   24,
		BitrateBPS:  4_000_000,
		IdleSeconds: 10,
		TTLSeconds:  30,
	}

	frame := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeInput,
		Input:     &DesktopInputEvent{Kind: DesktopInputKindFocus, Focused: true},
	}

	guard, err := NewDesktopSessionGuard(fakeRemoteSessionID, target, 100)
	if err != nil {
		t.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}
	frame.SessionID = "other-session"
	if err := guard.ValidateFrame(frame, desktopTestAgentID, "gateway-1", 101, 1); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("session mismatch error = %v, want %v", err, ErrInvalidDesktopFrame)
	}

	guard, err = NewDesktopSessionGuard(fakeRemoteSessionID, target, 100)
	if err != nil {
		t.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}
	frame.SessionID = fakeRemoteSessionID
	if err := guard.ValidateFrame(frame, "agent-2", "gateway-1", 101, 1); !errors.Is(err, ErrDesktopRouteLost) {
		t.Fatalf("route-loss error = %v, want %v", err, ErrDesktopRouteLost)
	}

	guard, err = NewDesktopSessionGuard(fakeRemoteSessionID, target, 100)
	if err != nil {
		t.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}
	if err := guard.ValidateFrame(frame, desktopTestAgentID, "gateway-1", 110, 1); !errors.Is(err, ErrDesktopSessionExpired) {
		t.Fatalf("idle-expired error = %v, want %v", err, ErrDesktopSessionExpired)
	}

	if _, err := NewDesktopSessionGuard("", target, 100); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("missing session error = %v, want %v", err, ErrInvalidDesktopFrame)
	}

	var nilGuard *DesktopSessionGuard
	if err := nilGuard.ValidateFrame(frame, desktopTestAgentID, "gateway-1", 101, 1); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("nil guard error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
}

func TestDesktopSessionGuardBindsContentRecordingToTargetPolicy(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	guard, err := NewDesktopSessionGuard(fakeRemoteSessionID, target, 100)
	if err != nil {
		t.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}

	update := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeUpdate,
		Data:      []byte("screen"),
	}
	clipboard := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeClipboard,
		Data:      []byte("clipboard"),
	}
	input := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeInput,
		Input:     &DesktopInputEvent{Kind: DesktopInputKindFocus},
	}

	if err := guard.ValidateContentRecording(update); !errors.Is(err, ErrDesktopContentRecord) {
		t.Fatalf("default screen recording error = %v, want %v", err, ErrDesktopContentRecord)
	}
	if err := guard.ValidateContentRecording(clipboard); !errors.Is(err, ErrDesktopContentRecord) {
		t.Fatalf("default clipboard recording error = %v, want %v", err, ErrDesktopContentRecord)
	}
	if err := guard.ValidateContentRecording(input); err != nil {
		t.Fatalf("metadata-only frame recording returned error: %v", err)
	}

	target.Recording.ScreenEnabled = true
	target.Recording.ClipboardEnabled = true
	guard, err = NewDesktopSessionGuard(fakeRemoteSessionID, target, 100)
	if err != nil {
		t.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}
	if err := guard.ValidateContentRecording(update); err != nil {
		t.Fatalf("screen recording with policy returned error: %v", err)
	}
	if err := guard.ValidateContentRecording(clipboard); err != nil {
		t.Fatalf("clipboard recording with policy returned error: %v", err)
	}

	update.SessionID = "other-session"
	if err := guard.ValidateContentRecording(update); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("session mismatch recording error = %v, want %v", err, ErrInvalidDesktopFrame)
	}

	var nilGuard *DesktopSessionGuard
	if err := nilGuard.ValidateContentRecording(input); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("nil guard recording error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
}

func TestDesktopAuditMetadataOmitsCredentialSecrets(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.DeviceUID = "device-1"
	target.Route.SelectedGateway = "gateway-1"
	target.TLS.Mode = DesktopTLSModePinnedCA
	target.TLS.CABundleID = "ca-bundle-1"
	target.TLS.ServerName = "windows.internal"
	target.Credential.Mode = DesktopCredentialModeBrokeredSecret
	target.Credential.CredentialSecretRef = "secretref:rdp/admin"
	target.ApprovalRequired = true
	target.Redirection.ClipboardMode = DesktopClipboardModeTextToBrowser
	target.Recording = DesktopRecordingPolicy{MetadataEnabled: true}
	target.Metadata = map[string]string{"secret": "target-secret"}

	payload := DesktopOpenPayload{
		Target:   target,
		Metadata: map[string]string{"secret": "payload-secret"},
		CredentialGrant: &DesktopCredentialGrant{
			Mode:                DesktopCredentialModeBrokeredSecret,
			Username:            "administrator",
			Password:            "secret-password",
			CredentialSecretRef: "secretref:rdp/admin",
			ActorID:             "user-1",
			SessionID:           fakeRemoteSessionID,
			TargetID:            desktopTestTargetID,
			RouteID:             desktopTestAgentID,
			ExpiresUnix:         desktopTestExpiresUnix,
		},
	}

	metadata := DesktopAuditMetadata(payload)
	if metadata["protocol"] != ProtocolRDP ||
		metadata["target_id"] != desktopTestTargetID ||
		metadata["selected_agent_id"] != desktopTestAgentID ||
		metadata["selected_gateway_id"] != "gateway-1" ||
		metadata["credential_mode"] != DesktopCredentialModeBrokeredSecret ||
		metadata["tls_mode"] != DesktopTLSModePinnedCA ||
		metadata["redirection_clipboard_mode"] != DesktopClipboardModeTextToBrowser ||
		metadata["recording_metadata_enabled"] != "true" ||
		metadata["credential_grant_expires_unix"] != "4102444800" ||
		metadata["credential_grant_actor_bound"] != "true" {
		t.Fatalf("desktop audit metadata = %#v", metadata)
	}

	encoded, err := json.Marshal(metadata)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}
	for _, forbidden := range []string{
		"secret-password",
		"secretref:rdp/admin",
		"administrator",
		"target-secret",
		"payload-secret",
	} {
		if strings.Contains(string(encoded), forbidden) {
			t.Fatalf("audit metadata leaked %q: %s", forbidden, string(encoded))
		}
	}
}

func TestDesktopLifecycleAuditMetadataUsesFixedEventsAndOmitsSecrets(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.DeviceUID = "device-1"
	target.Route.SelectedGateway = "gateway-1"
	target.TLS.Mode = DesktopTLSModePinnedCA
	target.TLS.CABundleID = "ca-bundle-1"
	target.Credential.Mode = DesktopCredentialModeBrokeredSecret
	target.Credential.CredentialSecretRef = "secretref:rdp/admin"
	target.ApprovalRequired = true
	target.Metadata = map[string]string{"secret": "target-secret"}

	payload := DesktopOpenPayload{
		Target:   target,
		Metadata: map[string]string{"secret": "payload-secret"},
		CredentialGrant: &DesktopCredentialGrant{
			Mode:                DesktopCredentialModeBrokeredSecret,
			Username:            "administrator",
			Password:            "secret-password",
			CredentialSecretRef: "secretref:rdp/admin",
			ActorID:             "user-1",
			SessionID:           fakeRemoteSessionID,
			TargetID:            desktopTestTargetID,
			RouteID:             desktopTestAgentID,
			ExpiresUnix:         desktopTestExpiresUnix,
		},
	}

	metadata, err := DesktopLifecycleAuditMetadata(
		payload,
		DesktopLifecycleEventReady,
		1_778_000_000,
		"ready\nwith\t"+strings.Repeat("x", DesktopMaxAuditReason),
	)
	if err != nil {
		t.Fatalf("DesktopLifecycleAuditMetadata returned error: %v", err)
	}
	if metadata["event_type"] != DesktopLifecycleEventReady ||
		metadata["event_timestamp_unix"] != "1778000000" ||
		metadata["event_outcome_truncated"] != "true" ||
		metadata["credential_mode"] != DesktopCredentialModeBrokeredSecret ||
		metadata["tls_mode"] != DesktopTLSModePinnedCA ||
		metadata["selected_agent_id"] != desktopTestAgentID {
		t.Fatalf("lifecycle metadata = %#v", metadata)
	}
	if strings.Contains(metadata["event_outcome"], "\n") ||
		strings.Contains(metadata["event_outcome"], "\t") ||
		len(metadata["event_outcome"]) > DesktopMaxAuditReason {
		t.Fatalf("event outcome was not normalized: %#v", metadata)
	}

	encoded, err := json.Marshal(metadata)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}
	for _, forbidden := range []string{
		"secret-password",
		"secretref:rdp/admin",
		"administrator",
		"target-secret",
		"payload-secret",
	} {
		if strings.Contains(string(encoded), forbidden) {
			t.Fatalf("lifecycle metadata leaked %q: %s", forbidden, string(encoded))
		}
	}

	if _, err := DesktopLifecycleAuditMetadata(payload, "desktop.session.custom", 1, "ok"); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("invalid event type error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
	if _, err := DesktopLifecycleAuditMetadata(payload, DesktopLifecycleEventOpen, 0, "ok"); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("invalid timestamp error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
}

func TestDesktopFrameAuditMetadataOmitsPayloadContents(t *testing.T) {
	t.Parallel()

	frame := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeClipboard,
		Width:     1280,
		Height:    720,
		Encoding:  "utf-8",
		Data:      []byte("sensitive clipboard content"),
		Input: &DesktopInputEvent{
			Kind:   DesktopInputKindKey,
			Key:    "SensitiveKey",
			Button: "SensitiveButton",
		},
		Quality: &DesktopQuality{
			MaxFrameRate: 24,
			MaxBitrate:   4_000_000,
			Width:        1280,
			Height:       720,
		},
		Direction: DesktopClipboardDirectionToBrowser,
		Timestamp: 1_778_000_000,
		Reason:    "sensitive close reason",
		Metadata:  map[string]string{"secret": "frame-secret"},
	}

	metadata := DesktopFrameAuditMetadata(frame)
	if metadata["session_id"] != fakeRemoteSessionID ||
		metadata["frame_type"] != DesktopFrameTypeClipboard ||
		metadata["payload_bytes"] != "27" ||
		metadata["input_kind"] != DesktopInputKindKey ||
		metadata["quality_max_frame_rate"] != "24" ||
		metadata["direction"] != DesktopClipboardDirectionToBrowser {
		t.Fatalf("desktop frame audit metadata = %#v", metadata)
	}

	encoded, err := json.Marshal(metadata)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}
	for _, forbidden := range []string{
		"sensitive clipboard content",
		"SensitiveKey",
		"SensitiveButton",
		"sensitive close reason",
		"frame-secret",
	} {
		if strings.Contains(string(encoded), forbidden) {
			t.Fatalf("frame audit metadata leaked %q: %s", forbidden, string(encoded))
		}
	}
}

func TestDesktopTerminationAuditMetadataCapsAndNormalizesReason(t *testing.T) {
	t.Parallel()

	frame := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeDisconnect,
		Reason:    "operator\nclosed\t" + strings.Repeat("x", DesktopMaxAuditReason),
		Timestamp: 1_778_000_000,
		Data:      []byte("screen or clipboard payload"),
	}

	metadata := DesktopTerminationAuditMetadata(frame)
	if metadata["session_id"] != fakeRemoteSessionID ||
		metadata["frame_type"] != DesktopFrameTypeDisconnect ||
		metadata["termination_reason_truncated"] != "true" {
		t.Fatalf("termination metadata = %#v", metadata)
	}
	if strings.Contains(metadata["termination_reason"], "\n") ||
		strings.Contains(metadata["termination_reason"], "\t") {
		t.Fatalf("termination reason was not normalized: %#v", metadata)
	}
	if len(metadata["termination_reason"]) > DesktopMaxAuditReason {
		t.Fatalf("termination reason length = %d, want <= %d", len(metadata["termination_reason"]), DesktopMaxAuditReason)
	}

	encoded, err := json.Marshal(metadata)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}
	if strings.Contains(string(encoded), "screen or clipboard payload") {
		t.Fatalf("termination metadata leaked payload: %s", string(encoded))
	}
}

func TestValidateDesktopContentRecordingRequiresExplicitContentPolicy(t *testing.T) {
	t.Parallel()

	update := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeUpdate,
		Data:      []byte("screen"),
	}
	clipboard := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeClipboard,
		Data:      []byte("clipboard"),
	}
	input := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeInput,
		Input:     &DesktopInputEvent{Kind: DesktopInputKindFocus},
	}

	if err := ValidateDesktopContentRecording(update, DesktopRecordingPolicy{}); !errors.Is(err, ErrDesktopContentRecord) {
		t.Fatalf("screen recording error = %v, want %v", err, ErrDesktopContentRecord)
	}
	if err := ValidateDesktopContentRecording(clipboard, DesktopRecordingPolicy{}); !errors.Is(err, ErrDesktopContentRecord) {
		t.Fatalf("clipboard recording error = %v, want %v", err, ErrDesktopContentRecord)
	}
	if err := ValidateDesktopContentRecording(update, DesktopRecordingPolicy{ScreenEnabled: true}); err != nil {
		t.Fatalf("screen recording with policy returned error: %v", err)
	}
	if err := ValidateDesktopContentRecording(clipboard, DesktopRecordingPolicy{ClipboardEnabled: true}); err != nil {
		t.Fatalf("clipboard recording with policy returned error: %v", err)
	}
	if err := ValidateDesktopContentRecording(input, DesktopRecordingPolicy{}); err != nil {
		t.Fatalf("metadata-only input recording returned error: %v", err)
	}
}

func TestDesktopFrameQuotaWindowEnforcesFrameRateAndBitrate(t *testing.T) {
	t.Parallel()

	policy := DesktopScreenPolicy{
		MaxWidth:   1280,
		MaxHeight:  720,
		FrameRate:  2,
		BitrateBPS: 16,
	}
	frame := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeUpdate,
		Width:     1280,
		Height:    720,
		Data:      []byte{0x01},
	}
	quota := NewDesktopFrameQuotaWindow(policy)

	if err := quota.Consume(frame, 1); err != nil {
		t.Fatalf("first frame quota returned error: %v", err)
	}
	if err := quota.Consume(frame, 2); err != nil {
		t.Fatalf("second frame quota returned error: %v", err)
	}
	if err := quota.Consume(frame, 3); !errors.Is(err, ErrDesktopQuotaExceeded) {
		t.Fatalf("frame-rate quota error = %v, want %v", err, ErrDesktopQuotaExceeded)
	}

	quota = NewDesktopFrameQuotaWindow(policy)
	frame.Data = []byte{0x01, 0x02, 0x03}
	if err := quota.Consume(frame, 1); !errors.Is(err, ErrDesktopQuotaExceeded) {
		t.Fatalf("bitrate quota error = %v, want %v", err, ErrDesktopQuotaExceeded)
	}

	quota = NewDesktopFrameQuotaWindow(policy)
	frame.Data = []byte{0x01}
	if err := quota.Consume(frame, 1); err != nil {
		t.Fatalf("frame before reset returned error: %v", err)
	}
	if err := quota.Consume(frame, desktopQuotaWindowNanos+1); err != nil {
		t.Fatalf("frame after reset returned error: %v", err)
	}
	if err := quota.Consume(DesktopFrame{FrameType: DesktopFrameTypeInput}, 0); err != nil {
		t.Fatalf("non-update frame quota returned error: %v", err)
	}
	if err := quota.Consume(frame, 0); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("missing timestamp error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
}

func TestValidateDesktopSessionLifetimeEnforcesIdleAndTTL(t *testing.T) {
	t.Parallel()

	policy := DesktopScreenPolicy{
		MaxWidth:    1280,
		MaxHeight:   720,
		FrameRate:   24,
		BitrateBPS:  4_000_000,
		IdleSeconds: 10,
		TTLSeconds:  30,
	}

	if err := ValidateDesktopSessionLifetime(policy, 100, 105, 109); err != nil {
		t.Fatalf("active session returned error: %v", err)
	}
	if err := ValidateDesktopSessionLifetime(policy, 100, 105, 115); !errors.Is(err, ErrDesktopSessionExpired) {
		t.Fatalf("idle timeout error = %v, want %v", err, ErrDesktopSessionExpired)
	}
	if err := ValidateDesktopSessionLifetime(policy, 100, 125, 130); !errors.Is(err, ErrDesktopSessionExpired) {
		t.Fatalf("ttl timeout error = %v, want %v", err, ErrDesktopSessionExpired)
	}
	if err := ValidateDesktopSessionLifetime(policy, 100, 0, 109); err != nil {
		t.Fatalf("missing last activity fallback returned error: %v", err)
	}
	if err := ValidateDesktopSessionLifetime(policy, 100, 105, 99); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("clock regression error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
	if err := ValidateDesktopSessionLifetime(policy, 0, 0, 109); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("invalid timestamp error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
}

func TestNormalizeDesktopCredentialGrantEnforcesBrokeredSecretCustody(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Credential.Mode = DesktopCredentialModeBrokeredSecret
	target.Credential.CredentialSecretRef = "secretref:rdp/admin"
	target.ApprovalRequired = true

	validGrant := DesktopCredentialGrant{
		Mode:                DesktopCredentialModeBrokeredSecret,
		CredentialSecretRef: "secretref:rdp/admin",
		ActorID:             "user-1",
		SessionID:           "session-1",
		TargetID:            desktopTestTargetID,
		RouteID:             desktopTestAgentID,
		ExpiresUnix:         desktopTestExpiresUnix,
	}

	if _, err := NormalizeDesktopCredentialGrant(validGrant, target); err != nil {
		t.Fatalf("NormalizeDesktopCredentialGrant returned error: %v", err)
	}

	tests := []struct {
		name   string
		mutate func(*DesktopCredentialGrant)
	}{
		{
			name: "secret mismatch",
			mutate: func(grant *DesktopCredentialGrant) {
				grant.CredentialSecretRef = "secretref:rdp/other"
			},
		},
		{
			name: "password included",
			mutate: func(grant *DesktopCredentialGrant) {
				grant.Password = "not-allowed"
			},
		},
		{
			name: "missing actor binding",
			mutate: func(grant *DesktopCredentialGrant) {
				grant.ActorID = ""
			},
		},
		{
			name: "missing session binding",
			mutate: func(grant *DesktopCredentialGrant) {
				grant.SessionID = ""
			},
		},
		{
			name: "missing target binding",
			mutate: func(grant *DesktopCredentialGrant) {
				grant.TargetID = ""
			},
		},
		{
			name: "missing route binding",
			mutate: func(grant *DesktopCredentialGrant) {
				grant.RouteID = ""
			},
		},
		{
			name: "missing ttl",
			mutate: func(grant *DesktopCredentialGrant) {
				grant.ExpiresUnix = 0
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			grant := validGrant
			tt.mutate(&grant)
			_, err := NormalizeDesktopCredentialGrant(grant, target)
			if !errors.Is(err, ErrInvalidDesktopTarget) {
				t.Fatalf("error = %v, want %v", err, ErrInvalidDesktopTarget)
			}
		})
	}

	if _, err := NormalizeDesktopCredentialGrantAt(
		validGrant,
		target,
		desktopTestExpiresUnix+1,
	); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("expired grant error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
}

func TestNormalizeDesktopCredentialGrantEnforcesMemoryUserCredential(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Credential.AllowedPrincipals = []string{"alice", "DOMAIN\\bob"}
	grant := DesktopCredentialGrant{
		Mode:      DesktopCredentialModeMemoryUser,
		Username:  "alice",
		Password:  "secret",
		SessionID: "session-1",
		TargetID:  desktopTestTargetID,
	}

	got, err := NormalizeDesktopCredentialGrant(grant, target)
	if err != nil {
		t.Fatalf("NormalizeDesktopCredentialGrant returned error: %v", err)
	}
	if got.TargetID != desktopTestTargetID {
		t.Fatalf("TargetID = %q, want %q", got.TargetID, desktopTestTargetID)
	}

	grant.Password = ""
	if _, err := NormalizeDesktopCredentialGrant(grant, target); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("missing password error = %v, want %v", err, ErrInvalidDesktopTarget)
	}

	grant.Username = "mallory"
	grant.Password = "secret"
	if _, err := NormalizeDesktopCredentialGrant(grant, target); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("disallowed principal error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
}

func TestDesktopCredentialGrantDropSensitive(t *testing.T) {
	t.Parallel()

	grant := DesktopCredentialGrant{
		Mode:                DesktopCredentialModeMemoryUser,
		Username:            "alice",
		Password:            "secret",
		CredentialSecretRef: "secretref:rdp/admin",
		ActorID:             "user-1",
		SessionID:           "session-1",
		TargetID:            desktopTestTargetID,
		RouteID:             desktopTestAgentID,
		ExpiresUnix:         desktopTestExpiresUnix,
	}

	grant.DropSensitive()
	if grant.Username != "" || grant.Password != "" || grant.CredentialSecretRef != "" {
		t.Fatalf("sensitive fields not cleared: %#v", grant)
	}
	if grant.ActorID != "user-1" || grant.SessionID != "session-1" ||
		grant.TargetID != desktopTestTargetID || grant.RouteID != desktopTestAgentID ||
		grant.ExpiresUnix != desktopTestExpiresUnix {
		t.Fatalf("binding fields should be retained: %#v", grant)
	}

	var nilGrant *DesktopCredentialGrant
	nilGrant.DropSensitive()
}

func TestValidateDesktopFrameEnforcesGraphicalPolicy(t *testing.T) {
	t.Parallel()

	policy := DesktopScreenPolicy{
		MaxWidth:   1280,
		MaxHeight:  720,
		FrameRate:  24,
		BitrateBPS: 4_000_000,
	}

	if err := ValidateDesktopFrame(DesktopFrame{
		SessionID: "session-1",
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeUpdate,
		Width:     1280,
		Height:    720,
		Data:      []byte("frame"),
	}, policy); err != nil {
		t.Fatalf("valid update returned error: %v", err)
	}

	tests := []DesktopFrame{
		{SessionID: "session-1", Protocol: ProtocolRDP, FrameType: DesktopFrameTypeUpdate, Width: 1281, Height: 720},
		{SessionID: "session-1", Protocol: ProtocolRDP, FrameType: DesktopFrameTypeInput},
		{
			SessionID: "session-1",
			Protocol:  ProtocolRDP,
			FrameType: DesktopFrameTypeQuality,
			Quality:   &DesktopQuality{MaxFrameRate: 25},
		},
		{
			SessionID: "session-1",
			Protocol:  ProtocolRDP,
			FrameType: DesktopFrameTypeQuality,
			Quality:   &DesktopQuality{MaxBitrate: 4_000_001},
		},
		{
			SessionID: "session-1",
			Protocol:  ProtocolRDP,
			FrameType: DesktopFrameTypeQuality,
			Quality:   &DesktopQuality{Width: 1281},
		},
		{
			SessionID: "session-1",
			Protocol:  ProtocolRDP,
			FrameType: DesktopFrameTypeQuality,
			Quality:   &DesktopQuality{Height: 721},
		},
		{
			SessionID: "session-1",
			Protocol:  ProtocolRDP,
			FrameType: DesktopFrameTypeInput,
			Input:     &DesktopInputEvent{Kind: "unknown"},
		},
		{
			SessionID: "session-1",
			Protocol:  ProtocolRDP,
			FrameType: DesktopFrameTypeInput,
			Input: &DesktopInputEvent{
				Kind: DesktopInputKindPointer,
				X:    1281,
				Y:    360,
			},
		},
		{
			SessionID: "session-1",
			Protocol:  ProtocolRDP,
			FrameType: DesktopFrameTypeInput,
			Input: &DesktopInputEvent{
				Kind: DesktopInputKindKey,
				Key:  string(make([]byte, DesktopMaxInputTokenSize+1)),
			},
		},
	}

	for _, frame := range tests {
		_, err := json.Marshal(frame)
		if err != nil {
			t.Fatalf("Marshal returned error: %v", err)
		}
		if err := ValidateDesktopFrame(frame, policy); !errors.Is(err, ErrInvalidDesktopFrame) {
			t.Fatalf("ValidateDesktopFrame(%#v) = %v, want %v", frame, err, ErrInvalidDesktopFrame)
		}
	}
}

func TestValidateDesktopFrameRequiresExplicitClipboardPolicy(t *testing.T) {
	t.Parallel()

	policy := DesktopScreenPolicy{
		MaxWidth:   1280,
		MaxHeight:  720,
		FrameRate:  24,
		BitrateBPS: 4_000_000,
	}
	frame := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeClipboard,
		Direction: DesktopClipboardDirectionToBrowser,
		Data:      []byte("clipboard text"),
	}

	if err := ValidateDesktopFrame(frame, policy); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("default clipboard validation error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
	if err := ValidateDesktopFrameWithPolicy(frame, policy, DesktopRedirectionPolicy{
		ClipboardMode: DesktopClipboardModeDisabled,
	}); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("disabled clipboard validation error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
	if err := ValidateDesktopFrameWithPolicy(frame, policy, DesktopRedirectionPolicy{
		ClipboardMode: DesktopClipboardModeTextBoth,
	}); err != nil {
		t.Fatalf("enabled clipboard validation returned error: %v", err)
	}
	if err := ValidateDesktopFrameWithPolicy(frame, policy, DesktopRedirectionPolicy{
		ClipboardMode: DesktopClipboardModeTextToRemote,
	}); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("wrong-direction clipboard validation error = %v, want %v", err, ErrInvalidDesktopFrame)
	}

	frame.Direction = ""
	if err := ValidateDesktopFrameWithPolicy(frame, policy, DesktopRedirectionPolicy{
		ClipboardMode: DesktopClipboardModeTextBoth,
	}); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("missing-direction clipboard validation error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
}

func TestDesktopFramePayloadPolicyAwareHelpersGateClipboard(t *testing.T) {
	t.Parallel()

	policy := DesktopScreenPolicy{
		MaxWidth:   1280,
		MaxHeight:  720,
		FrameRate:  24,
		BitrateBPS: 4_000_000,
	}
	redirection := DesktopRedirectionPolicy{
		ClipboardMode: DesktopClipboardModeTextBoth,
	}
	frame := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeClipboard,
		Direction: DesktopClipboardDirectionToBrowser,
		Data:      []byte("clipboard text"),
	}

	if _, err := EncodeDesktopFramePayload(frame, policy); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("default encode clipboard error = %v, want %v", err, ErrInvalidDesktopFrame)
	}

	data, err := EncodeDesktopFramePayloadWithPolicy(frame, policy, redirection)
	if err != nil {
		t.Fatalf("EncodeDesktopFramePayloadWithPolicy returned error: %v", err)
	}
	if _, err := DecodeDesktopFramePayload(data, policy); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("default decode clipboard error = %v, want %v", err, ErrInvalidDesktopFrame)
	}

	got, err := DecodeDesktopFramePayloadForSessionWithPolicy(
		data,
		policy,
		redirection,
		fakeRemoteSessionID,
	)
	if err != nil {
		t.Fatalf("DecodeDesktopFramePayloadForSessionWithPolicy returned error: %v", err)
	}
	if got.FrameType != DesktopFrameTypeClipboard || string(got.Data) != "clipboard text" {
		t.Fatalf("decoded clipboard frame = %#v", got)
	}

	_, err = DecodeDesktopFramePayloadForSessionWithPolicy(data, policy, redirection, "other-session")
	if !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("session mismatch error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
}

func TestDesktopFramePayloadRoundTripsThroughConsoleFrameData(t *testing.T) {
	t.Parallel()

	policy := DesktopScreenPolicy{
		MaxWidth:   1280,
		MaxHeight:  720,
		FrameRate:  24,
		BitrateBPS: 4_000_000,
	}
	frame := DesktopFrame{
		SessionID: "session-1",
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeInput,
		Input: &DesktopInputEvent{
			Kind: DesktopInputKindPointer,
			X:    640,
			Y:    360,
		},
	}

	data, err := EncodeDesktopFramePayload(frame, policy)
	if err != nil {
		t.Fatalf("EncodeDesktopFramePayload returned error: %v", err)
	}

	got, err := DecodeDesktopFramePayload(data, policy)
	if err != nil {
		t.Fatalf("DecodeDesktopFramePayload returned error: %v", err)
	}
	if got.SessionID != frame.SessionID || got.FrameType != frame.FrameType || got.Input == nil {
		t.Fatalf("decoded frame = %#v", got)
	}
	if got.Input.Kind != DesktopInputKindPointer || got.Input.X != 640 || got.Input.Y != 360 {
		t.Fatalf("decoded input = %#v", got.Input)
	}

	_, err = DecodeDesktopFramePayload([]byte(`{"session_id":"session-1","protocol":"rdp","frame_type":"desktop.resize","width":9999,"height":720}`), policy)
	if !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("invalid decoded frame error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
}

func TestDecodeDesktopFramePayloadForSessionRejectsMismatchedSession(t *testing.T) {
	t.Parallel()

	policy := DesktopScreenPolicy{
		MaxWidth:   1280,
		MaxHeight:  720,
		FrameRate:  24,
		BitrateBPS: 4_000_000,
	}
	data, err := EncodeDesktopFramePayload(DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeDisconnect,
	}, policy)
	if err != nil {
		t.Fatalf("EncodeDesktopFramePayload returned error: %v", err)
	}

	if _, err := DecodeDesktopFramePayloadForSession(data, policy, fakeRemoteSessionID); err != nil {
		t.Fatalf("DecodeDesktopFramePayloadForSession returned error: %v", err)
	}
	if _, err := DecodeDesktopFramePayloadForSession(data, policy, "other-session"); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("session mismatch error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
}

func validDesktopTarget() DesktopTarget {
	return DesktopTarget{
		TargetID: desktopTestTargetID,
		Protocol: ProtocolRDP,
		Route: DesktopRoute{
			SelectedAgentID: desktopTestAgentID,
		},
		Upstream: DesktopUpstream{
			Host: desktopTestHost,
			Port: DesktopDefaultRDPPort,
		},
		TLS: DesktopTLSPolicy{
			Mode: DesktopTLSModeVerify,
		},
		Credential: DesktopCredentialPolicy{
			Mode: DesktopCredentialModeMemoryUser,
		},
	}
}
