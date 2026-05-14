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
