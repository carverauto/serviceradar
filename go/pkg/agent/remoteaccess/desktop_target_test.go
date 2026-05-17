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
			name: "pinned ca without bundle id",
			mutate: func(target *DesktopTarget) {
				target.TLS.Mode = DesktopTLSModePinnedCA
				target.TLS.CABundleID = ""
			},
		},
		{
			name: "ca bundle id without material",
			mutate: func(target *DesktopTarget) {
				target.TLS.CABundleID = "rdp-ca"
				target.TLS.CABundlePEM = ""
			},
		},
		{
			name: "ca bundle material without id",
			mutate: func(target *DesktopTarget) {
				target.TLS.CABundleID = ""
				target.TLS.CABundlePEM = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
			},
		},
		{
			name: "oversized ca bundle material",
			mutate: func(target *DesktopTarget) {
				target.TLS.CABundleID = "rdp-ca"
				target.TLS.CABundlePEM = strings.Repeat("a", DesktopMaxCABundlePEM+1)
			},
		},
		{
			name: "brokered secret without approval",
			mutate: func(target *DesktopTarget) {
				target.Credential.Mode = DesktopCredentialModeBrokeredSecret
				target.Credential.CredentialSecretRef = desktopTestBrokeredSecret
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
	target.Credential.CredentialSecretRef = desktopTestBrokeredSecret
	target.ApprovalRequired = true

	payload := DesktopOpenPayload{
		ActorID: desktopTestActorID,
		Target:  target,
		CredentialGrant: &DesktopCredentialGrant{
			Mode:                DesktopCredentialModeBrokeredSecret,
			CredentialSecretRef: desktopTestBrokeredSecret,
			ActorID:             desktopTestActorID,
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
	target.Credential.CredentialSecretRef = desktopTestBrokeredSecret
	target.ApprovalRequired = true

	payload := DesktopOpenPayload{
		ActorID: desktopTestActorID,
		Target:  target,
		CredentialGrant: &DesktopCredentialGrant{
			Mode:                DesktopCredentialModeBrokeredSecret,
			CredentialSecretRef: desktopTestBrokeredSecret,
			ActorID:             desktopTestActorID,
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

	payload.CredentialGrant.SessionID = remoteAccessTestOtherSessionID
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
	target.Route.SelectedGateway = remoteAccessTestGatewayID

	if err := ValidateDesktopRouteBinding(target, desktopTestAgentID, remoteAccessTestGatewayID); err != nil {
		t.Fatalf("ValidateDesktopRouteBinding returned error: %v", err)
	}
	if err := ValidateDesktopRouteBinding(target, desktopTestAgentID, ""); err != nil {
		t.Fatalf("ValidateDesktopRouteBinding without gateway returned error: %v", err)
	}
	if err := ValidateDesktopRouteBinding(target, "agent-2", remoteAccessTestGatewayID); !errors.Is(err, ErrDesktopRouteLost) {
		t.Fatalf("agent route-loss error = %v, want %v", err, ErrDesktopRouteLost)
	}
	if err := ValidateDesktopRouteBinding(target, desktopTestAgentID, "gateway-2"); !errors.Is(err, ErrDesktopRouteLost) {
		t.Fatalf("gateway route-loss error = %v, want %v", err, ErrDesktopRouteLost)
	}
	if err := ValidateDesktopRouteBinding(target, "", remoteAccessTestGatewayID); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("missing local agent error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
}
