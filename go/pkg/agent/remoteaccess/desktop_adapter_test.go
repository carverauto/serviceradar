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
	frames       []DesktopFrame
	closeCount   int
	closeReasons []string
}

func (s *recordingDesktopAdapterSessionStub) SendDesktopFrame(_ context.Context, frame DesktopFrame) error {
	s.frames = append(s.frames, frame)

	return nil
}

func (s *recordingDesktopAdapterSessionStub) Close(_ context.Context, reason string) error {
	s.closeCount++
	s.closeReasons = append(s.closeReasons, reason)

	return nil
}

type desktopMediaSenderStub struct {
	frames []DesktopMediaFrame
}

func (s *desktopMediaSenderStub) SendDesktopMediaFrame(_ context.Context, frame DesktopMediaFrame) error {
	s.frames = append(s.frames, frame)

	return nil
}

type desktopMediaAckSenderStub struct {
	desktopMediaSenderStub
	handler DesktopMediaAckHandler
}

func (s *desktopMediaAckSenderStub) SetDesktopMediaAckHandler(handler DesktopMediaAckHandler) {
	s.handler = handler
}

func TestDesktopAdapterRuntimeOpenRDPValidatesRoutePolicyAndCleansCredentials(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.TLS = DesktopTLSPolicy{
		Mode:        DesktopTLSModePinnedCA,
		CABundleID:  "ca-1",
		CABundlePEM: desktopTestCABundlePEM,
	}
	target.Credential.AllowedPrincipals = []string{"alice@example.com"}

	grant := &DesktopCredentialGrant{
		Mode:      DesktopCredentialModeMemoryUser,
		Username:  "alice@example.com",
		Password:  desktopTestPassword,
		ActorID:   desktopTestActorID,
		SessionID: fakeRemoteSessionID,
		TargetID:  desktopTestTargetID,
		RouteID:   desktopTestAgentID,
	}

	adapter := &desktopAdapterStub{}
	runtime := DesktopAdapterRuntime{
		LocalAgentID:     desktopTestAgentID,
		CurrentGatewayID: remoteAccessTestGatewayID,
		NowUnix:          func() int64 { return 1_778_000_000 },
		Adapter:          adapter,
	}

	session, err := runtime.OpenRDP(context.Background(), desktopOpenFrame(t, target, grant), &desktopMediaSenderStub{})
	if err != nil {
		t.Fatalf("OpenRDP returned error: %v", err)
	}
	if session == nil {
		t.Fatal("OpenRDP returned nil session")
	}
	if adapter.request.SessionID != fakeRemoteSessionID ||
		adapter.request.ActorID != desktopTestActorID ||
		adapter.request.LocalAgentID != desktopTestAgentID ||
		adapter.request.CurrentGatewayID != remoteAccessTestGatewayID ||
		adapter.request.Target.TLS.NLAMode != DesktopDefaultNLAPolicy ||
		adapter.request.Target.TLS.Mode != DesktopTLSModePinnedCA {
		t.Fatalf("adapter request = %#v", adapter.request)
	}
	if adapter.request.CredentialGrant == nil ||
		adapter.request.CredentialGrant.Username != "" ||
		adapter.request.CredentialGrant.Password != "" {
		t.Fatalf("credential grant was retained after open: %#v", adapter.request.CredentialGrant)
	}
	if adapter.observedUsername != "alice@example.com" || adapter.observedPassword != desktopTestPassword {
		t.Fatalf("adapter did not receive memory-only credential during open")
	}
}

func TestDesktopAdapterRuntimeRejectsMismatchedCredentialSession(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Credential.AllowedPrincipals = []string{"alice@example.com"}
	grant := &DesktopCredentialGrant{
		Mode:      DesktopCredentialModeMemoryUser,
		Username:  "alice@example.com",
		Password:  desktopTestPassword,
		ActorID:   desktopTestActorID,
		SessionID: remoteAccessTestOtherSessionID,
		TargetID:  desktopTestTargetID,
		RouteID:   desktopTestAgentID,
	}
	adapter := &desktopAdapterStub{}

	_, err := (DesktopAdapterRuntime{
		LocalAgentID:     desktopTestAgentID,
		CurrentGatewayID: remoteAccessTestGatewayID,
		NowUnix:          func() int64 { return 1_778_000_000 },
		Adapter:          adapter,
	}).OpenRDP(context.Background(), desktopOpenFrame(t, target, grant), &desktopMediaSenderStub{})
	if !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("mismatched session error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
	if adapter.request.SessionID != "" {
		t.Fatalf("adapter should not have been called: %#v", adapter.request)
	}
}

func TestDesktopAdapterRuntimeRejectsMissingCredentialGrant(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	adapter := &desktopAdapterStub{}

	_, err := (DesktopAdapterRuntime{
		LocalAgentID:     desktopTestAgentID,
		CurrentGatewayID: remoteAccessTestGatewayID,
		NowUnix:          func() int64 { return 1_778_000_000 },
		Adapter:          adapter,
	}).OpenRDP(context.Background(), desktopOpenFrame(t, target, nil), &desktopMediaSenderStub{})
	if !errors.Is(err, ErrInvalidDesktopTarget) {
		t.Fatalf("missing grant error = %v, want %v", err, ErrInvalidDesktopTarget)
	}
	if adapter.request.SessionID != "" {
		t.Fatalf("adapter should not have been called: %#v", adapter.request)
	}
}

func TestDesktopAdapterRuntimeGuardsInputFrames(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Screen.MaxWidth = 1024
	target.Screen.MaxHeight = 768
	innerSession := &recordingDesktopAdapterSessionStub{}
	grant := validDesktopMemoryGrant(fakeRemoteSessionID)

	session, err := (DesktopAdapterRuntime{
		LocalAgentID:     desktopTestAgentID,
		CurrentGatewayID: remoteAccessTestGatewayID,
		NowUnix:          func() int64 { return 1_778_000_000 },
		NowUnixNano:      func() int64 { return 1_778_000_000_000_000_000 },
		Adapter:          &desktopAdapterStub{session: innerSession},
	}).OpenRDP(context.Background(), desktopOpenFrame(t, target, grant), &desktopMediaSenderStub{})
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

func TestDesktopAdapterRuntimeGuardsMediaFrames(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Screen.MaxWidth = 1024
	target.Screen.MaxHeight = 768
	adapter := &desktopAdapterStub{}
	mediaSender := &desktopMediaSenderStub{}
	grant := validDesktopMemoryGrant(fakeRemoteSessionID)

	_, err := (DesktopAdapterRuntime{
		LocalAgentID:     desktopTestAgentID,
		CurrentGatewayID: remoteAccessTestGatewayID,
		NowUnix:          func() int64 { return 1_778_000_000 },
		Adapter:          adapter,
	}).OpenRDP(context.Background(), desktopOpenFrame(t, target, grant), mediaSender)
	if err != nil {
		t.Fatalf("OpenRDP returned error: %v", err)
	}

	validFrame := DesktopMediaFrame{
		SessionBindingID:  fakeRemoteSessionID,
		MediaSessionID:    "media-1",
		Sequence:          1,
		TimestampUnixNano: 1_778_000_000_000_000_000,
		Width:             800,
		Height:            600,
		PayloadFamily:     DesktopMediaPayloadDirtyRect,
		Encoding:          "raw_rgba",
		Payload:           []byte{1, 2, 3, 4},
	}
	if err := adapter.request.MediaSender.SendDesktopMediaFrame(context.Background(), validFrame); err != nil {
		t.Fatalf("SendDesktopMediaFrame returned error: %v", err)
	}
	if len(mediaSender.frames) != 1 {
		t.Fatalf("forwarded media frames = %d, want 1", len(mediaSender.frames))
	}

	invalidFrame := validFrame
	invalidFrame.Width = 2048
	if err := adapter.request.MediaSender.SendDesktopMediaFrame(context.Background(), invalidFrame); !errors.Is(err, ErrInvalidDesktopMediaFrame) {
		t.Fatalf("invalid media frame error = %v, want %v", err, ErrInvalidDesktopMediaFrame)
	}
	if len(mediaSender.frames) != 1 {
		t.Fatalf("invalid media frame was forwarded: %#v", mediaSender.frames)
	}
}

func TestDesktopAdapterRuntimeGuardsMediaAcks(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	adapter := &desktopAdapterStub{}
	mediaSender := &desktopMediaAckSenderStub{}
	grant := validDesktopMemoryGrant(fakeRemoteSessionID)
	session, err := (DesktopAdapterRuntime{
		LocalAgentID:     desktopTestAgentID,
		CurrentGatewayID: remoteAccessTestGatewayID,
		NowUnix:          func() int64 { return 1_778_000_000 },
		Adapter:          adapter,
	}).OpenRDP(context.Background(), desktopOpenFrame(t, target, grant), mediaSender)
	if err != nil {
		t.Fatalf("OpenRDP returned error: %v", err)
	}

	registrar, ok := adapter.request.MediaSender.(DesktopMediaAckHandlerRegistrar)
	if !ok {
		t.Fatal("adapter media sender does not expose ack handler registration")
	}

	var received []DesktopMediaAck
	registrar.SetDesktopMediaAckHandler(func(_ context.Context, ack DesktopMediaAck) error {
		received = append(received, ack)

		return nil
	})
	if mediaSender.handler == nil {
		t.Fatal("inner media sender did not receive ack handler")
	}

	validAck := DesktopMediaAck{
		SessionBindingID: fakeRemoteSessionID,
		MediaSessionID:   "media-1",
		LastAcceptedSeq:  1,
		CreditBytes:      4096,
	}
	if err := mediaSender.handler(context.Background(), validAck); err != nil {
		t.Fatalf("valid ack handler returned error: %v", err)
	}
	if len(received) != 1 || received[0].LastAcceptedSeq != validAck.LastAcceptedSeq {
		t.Fatalf("received acks = %#v", received)
	}

	invalidAck := validAck
	invalidAck.SessionBindingID = remoteAccessTestOtherSessionID
	if err := mediaSender.handler(context.Background(), invalidAck); !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("invalid ack error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}
	if len(received) != 1 {
		t.Fatalf("invalid ack was forwarded: %#v", received)
	}

	if err := session.Close(context.Background(), "operator"); err != nil {
		t.Fatalf("Close returned error: %v", err)
	}
	if err := mediaSender.handler(context.Background(), validAck); !errors.Is(err, ErrDesktopAdapterClosed) {
		t.Fatalf("post-close ack error = %v, want %v", err, ErrDesktopAdapterClosed)
	}
}

func TestDesktopAdapterRuntimeStopsFramesAfterClose(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Screen.MaxWidth = 1024
	target.Screen.MaxHeight = 768
	innerSession := &recordingDesktopAdapterSessionStub{}
	adapter := &desktopAdapterStub{session: innerSession}
	mediaSender := &desktopMediaSenderStub{}
	grant := validDesktopMemoryGrant(fakeRemoteSessionID)

	session, err := (DesktopAdapterRuntime{
		LocalAgentID:     desktopTestAgentID,
		CurrentGatewayID: remoteAccessTestGatewayID,
		NowUnix:          func() int64 { return 1_778_000_000 },
		NowUnixNano:      func() int64 { return 1_778_000_000_000_000_000 },
		Adapter:          adapter,
	}).OpenRDP(context.Background(), desktopOpenFrame(t, target, grant), mediaSender)
	if err != nil {
		t.Fatalf("OpenRDP returned error: %v", err)
	}

	if err := session.Close(context.Background(), "operator"); err != nil {
		t.Fatalf("Close returned error: %v", err)
	}
	if err := session.Close(context.Background(), "duplicate"); err != nil {
		t.Fatalf("second Close returned error: %v", err)
	}
	if innerSession.closeCount != 1 || len(innerSession.closeReasons) != 1 || innerSession.closeReasons[0] != "operator" {
		t.Fatalf("inner close state = count:%d reasons:%v", innerSession.closeCount, innerSession.closeReasons)
	}

	inputFrame := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeInput,
		Input:     &DesktopInputEvent{Kind: DesktopInputKindPointer, X: 100, Y: 100},
	}
	if err := session.SendDesktopFrame(context.Background(), inputFrame); !errors.Is(err, ErrDesktopAdapterClosed) {
		t.Fatalf("post-close input error = %v, want %v", err, ErrDesktopAdapterClosed)
	}
	if len(innerSession.frames) != 0 {
		t.Fatalf("post-close input frame was forwarded: %#v", innerSession.frames)
	}

	mediaFrame := DesktopMediaFrame{
		SessionBindingID:  fakeRemoteSessionID,
		MediaSessionID:    "media-1",
		Sequence:          1,
		TimestampUnixNano: 1_778_000_000_000_000_000,
		Width:             800,
		Height:            600,
		PayloadFamily:     DesktopMediaPayloadDirtyRect,
		Encoding:          "raw_rgba",
		Payload:           []byte{1, 2, 3, 4},
	}
	if err := adapter.request.MediaSender.SendDesktopMediaFrame(context.Background(), mediaFrame); !errors.Is(err, ErrDesktopAdapterClosed) {
		t.Fatalf("post-close media error = %v, want %v", err, ErrDesktopAdapterClosed)
	}
	if len(mediaSender.frames) != 0 {
		t.Fatalf("post-close media frame was forwarded: %#v", mediaSender.frames)
	}
}

func TestDesktopAdapterRuntimeOpenRDPFailsClosed(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	frame := desktopOpenFrame(t, target, validDesktopMemoryGrant(fakeRemoteSessionID))

	if _, err := (DesktopAdapterRuntime{
		LocalAgentID: desktopTestAgentID,
		NowUnix:      func() int64 { return 1_778_000_000 },
	}).OpenRDP(context.Background(), frame, &desktopMediaSenderStub{}); !errors.Is(err, ErrDesktopAdapterUnavailable) {
		t.Fatalf("missing adapter error = %v, want %v", err, ErrDesktopAdapterUnavailable)
	}

	if _, err := (DesktopAdapterRuntime{
		LocalAgentID:     desktopTestAgentID,
		CurrentGatewayID: "gateway-2",
		NowUnix:          func() int64 { return 1_778_000_000 },
		Adapter:          &desktopAdapterStub{},
	}).OpenRDP(context.Background(), frame, &desktopMediaSenderStub{}); !errors.Is(err, ErrDesktopRouteLost) {
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
		target.Route.SelectedGateway = remoteAccessTestGatewayID
	}

	data, err := json.Marshal(DesktopOpenPayload{
		Schema:          "serviceradar.desktop.open.v1",
		ActorID:         desktopTestActorID,
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
