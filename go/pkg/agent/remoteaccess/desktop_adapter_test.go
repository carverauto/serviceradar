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
	"context"
	"encoding/json"
	"errors"
	"testing"
)

type desktopAdapterStub struct {
	request          DesktopAdapterOpenRequest
	observedUsername string
	observedPassword string
	err              error
	session          DesktopAdapterSession
}

func (s *desktopAdapterStub) Open(_ context.Context, req DesktopAdapterOpenRequest) (DesktopAdapterSession, error) {
	s.request = req
	if req.CredentialGrant != nil {
		s.observedUsername = req.CredentialGrant.Username
		s.observedPassword = req.CredentialGrant.Password
	}
	if s.err != nil {
		return nil, s.err
	}
	if s.session != nil {
		return s.session, nil
	}

	return desktopAdapterSessionStub{}, nil
}

type desktopAdapterSessionStub struct{}

func (desktopAdapterSessionStub) SendDesktopFrame(context.Context, DesktopFrame) error { return nil }
func (desktopAdapterSessionStub) Close(context.Context, string) error                  { return nil }

type recordingDesktopAdapterSessionStub struct {
	frames []DesktopFrame
}

func (s *recordingDesktopAdapterSessionStub) SendDesktopFrame(_ context.Context, frame DesktopFrame) error {
	s.frames = append(s.frames, frame)

	return nil
}

func (s *recordingDesktopAdapterSessionStub) Close(context.Context, string) error { return nil }

type desktopMediaSenderStub struct{}

func (desktopMediaSenderStub) SendDesktopMediaFrame(context.Context, DesktopMediaFrame) error {
	return nil
}

func TestDesktopAdapterRuntimeOpenRDPValidatesRoutePolicyAndCleansCredentials(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.TLS = DesktopTLSPolicy{Mode: DesktopTLSModePinnedCA, CABundleID: "ca-1"}
	target.Credential.AllowedPrincipals = []string{"alice@example.com"}

	grant := &DesktopCredentialGrant{
		Mode:      DesktopCredentialModeMemoryUser,
		Username:  "alice@example.com",
		Password:  "secret",
		SessionID: fakeRemoteSessionID,
		TargetID:  desktopTestTargetID,
		RouteID:   desktopTestAgentID,
	}

	adapter := &desktopAdapterStub{}
	runtime := DesktopAdapterRuntime{
		LocalAgentID:     desktopTestAgentID,
		CurrentGatewayID: "gateway-1",
		NowUnix:          func() int64 { return 1_778_000_000 },
		Adapter:          adapter,
	}

	session, err := runtime.OpenRDP(context.Background(), desktopOpenFrame(t, target, grant), desktopMediaSenderStub{})
	if err != nil {
		t.Fatalf("OpenRDP returned error: %v", err)
	}
	if session == nil {
		t.Fatal("OpenRDP returned nil session")
	}
	if adapter.request.SessionID != fakeRemoteSessionID ||
		adapter.request.LocalAgentID != desktopTestAgentID ||
		adapter.request.CurrentGatewayID != "gateway-1" ||
		adapter.request.Target.TLS.NLAMode != DesktopDefaultNLAPolicy ||
		adapter.request.Target.TLS.Mode != DesktopTLSModePinnedCA {
		t.Fatalf("adapter request = %#v", adapter.request)
	}
	if adapter.request.CredentialGrant == nil ||
		adapter.request.CredentialGrant.Username != "" ||
		adapter.request.CredentialGrant.Password != "" {
		t.Fatalf("credential grant was retained after open: %#v", adapter.request.CredentialGrant)
	}
	if adapter.observedUsername != "alice@example.com" || adapter.observedPassword != "secret" {
		t.Fatalf("adapter did not receive memory-only credential during open")
	}
}

func TestDesktopAdapterRuntimeGuardsInputFrames(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Screen.MaxWidth = 1024
	target.Screen.MaxHeight = 768
	innerSession := &recordingDesktopAdapterSessionStub{}

	session, err := (DesktopAdapterRuntime{
		LocalAgentID:     desktopTestAgentID,
		CurrentGatewayID: "gateway-1",
		NowUnix:          func() int64 { return 1_778_000_000 },
		NowUnixNano:      func() int64 { return 1_778_000_000_000_000_000 },
		Adapter:          &desktopAdapterStub{session: innerSession},
	}).OpenRDP(context.Background(), desktopOpenFrame(t, target, nil), desktopMediaSenderStub{})
	if err != nil {
		t.Fatalf("OpenRDP returned error: %v", err)
	}

	validFrame := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeInput,
		Input:     &DesktopInputEvent{Kind: DesktopInputKindPointer, X: 100, Y: 100},
	}
	if err := session.SendDesktopFrame(context.Background(), validFrame); err != nil {
		t.Fatalf("SendDesktopFrame returned error: %v", err)
	}
	if len(innerSession.frames) != 1 {
		t.Fatalf("forwarded frames = %d, want 1", len(innerSession.frames))
	}

	invalidFrame := validFrame
	invalidFrame.Input = &DesktopInputEvent{Kind: DesktopInputKindPointer, X: 2048, Y: 100}
	if err := session.SendDesktopFrame(context.Background(), invalidFrame); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("invalid frame error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
	if len(innerSession.frames) != 1 {
		t.Fatalf("invalid frame was forwarded: %#v", innerSession.frames)
	}
}

func TestDesktopAdapterRuntimeOpenRDPFailsClosed(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	frame := desktopOpenFrame(t, target, nil)

	if _, err := (DesktopAdapterRuntime{
		LocalAgentID: desktopTestAgentID,
		NowUnix:      func() int64 { return 1_778_000_000 },
	}).OpenRDP(context.Background(), frame, desktopMediaSenderStub{}); !errors.Is(err, ErrDesktopAdapterUnavailable) {
		t.Fatalf("missing adapter error = %v, want %v", err, ErrDesktopAdapterUnavailable)
	}

	if _, err := (DesktopAdapterRuntime{
		LocalAgentID:     desktopTestAgentID,
		CurrentGatewayID: "gateway-2",
		NowUnix:          func() int64 { return 1_778_000_000 },
		Adapter:          &desktopAdapterStub{},
	}).OpenRDP(context.Background(), frame, desktopMediaSenderStub{}); !errors.Is(err, ErrDesktopRouteLost) {
		t.Fatalf("wrong gateway error = %v, want %v", err, ErrDesktopRouteLost)
	}

	if _, err := (DesktopAdapterRuntime{
		LocalAgentID: desktopTestAgentID,
		NowUnix:      func() int64 { return 1_778_000_000 },
		Adapter:      &desktopAdapterStub{},
	}).OpenRDP(context.Background(), frame, nil); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("missing media sender error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
}

func TestDesktopTargetDefaultsRDPToNLARequired(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.TLS.NLAMode = ""

	normalized, err := NormalizeDesktopTarget(target)
	if err != nil {
		t.Fatalf("NormalizeDesktopTarget returned error: %v", err)
	}
	if normalized.TLS.NLAMode != DesktopNLAModeRequired {
		t.Fatalf("NLA mode = %q, want %q", normalized.TLS.NLAMode, DesktopNLAModeRequired)
	}

	target.TLS.NLAMode = "optional"
	if _, err := NormalizeDesktopTarget(target); !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("invalid NLA mode error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
}

func desktopOpenFrame(t *testing.T, target DesktopTarget, grant *DesktopCredentialGrant) Frame {
	t.Helper()

	if target.Route.SelectedGateway == "" {
		target.Route.SelectedGateway = "gateway-1"
	}

	data, err := json.Marshal(DesktopOpenPayload{
		Schema:          "serviceradar.desktop.open.v1",
		Target:          target,
		CredentialGrant: grant,
	})
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	return Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: FrameTypeOpen,
		Data:      data,
	}
}
