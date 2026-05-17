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

func TestDesktopAuditMetadataOmitsCredentialSecrets(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.DeviceUID = "device-1"
	target.Route.SelectedGateway = remoteAccessTestGatewayID
	target.TLS.Mode = DesktopTLSModePinnedCA
	target.TLS.CABundleID = "ca-bundle-1"
	target.TLS.CABundlePEM = desktopTestCABundlePEM
	target.TLS.NLAMode = DesktopNLAModeRequired
	target.TLS.ServerName = "windows.internal"
	target.Credential.Mode = DesktopCredentialModeBrokeredSecret
	target.Credential.CredentialSecretRef = desktopTestBrokeredSecret
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
			CredentialSecretRef: desktopTestBrokeredSecret,
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
		metadata["selected_gateway_id"] != remoteAccessTestGatewayID ||
		metadata["credential_mode"] != DesktopCredentialModeBrokeredSecret ||
		metadata["tls_mode"] != DesktopTLSModePinnedCA ||
		metadata["nla_mode"] != DesktopNLAModeRequired ||
		metadata["redirection_clipboard_mode"] != DesktopClipboardModeTextToBrowser ||
		metadata["recording_metadata_enabled"] != enhancedMetadataTrue ||
		metadata["credential_grant_expires_unix"] != "4102444800" ||
		metadata["credential_grant_actor_bound"] != enhancedMetadataTrue {
		t.Fatalf("desktop audit metadata = %#v", metadata)
	}

	encoded, err := json.Marshal(metadata)
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}
	for _, forbidden := range []string{
		"secret-password",
		desktopTestBrokeredSecret,
		desktopTestCABundlePEM,
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
	target.Route.SelectedGateway = remoteAccessTestGatewayID
	target.TLS.Mode = DesktopTLSModePinnedCA
	target.TLS.CABundleID = "ca-bundle-1"
	target.TLS.CABundlePEM = desktopTestCABundlePEM
	target.Credential.Mode = DesktopCredentialModeBrokeredSecret
	target.Credential.CredentialSecretRef = desktopTestBrokeredSecret
	target.ApprovalRequired = true
	target.Metadata = map[string]string{"secret": "target-secret"}

	payload := DesktopOpenPayload{
		Target:   target,
		Metadata: map[string]string{"secret": "payload-secret"},
		CredentialGrant: &DesktopCredentialGrant{
			Mode:                DesktopCredentialModeBrokeredSecret,
			Username:            "administrator",
			Password:            "secret-password",
			CredentialSecretRef: desktopTestBrokeredSecret,
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
		metadata["event_outcome_truncated"] != enhancedMetadataTrue ||
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
		desktopTestBrokeredSecret,
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
		metadata["termination_reason_truncated"] != enhancedMetadataTrue {
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
