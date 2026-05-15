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

package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
)

func TestDesktopRDPHelperAdapterOpenSendsPayloadAndClearsCredential(t *testing.T) {
	t.Parallel()

	transport := newFakeDesktopRDPHelperTransport()
	grant := &remoteaccess.DesktopCredentialGrant{
		Mode:      remoteaccess.DesktopCredentialModeMemoryUser,
		Username:  "alice@example.com",
		Password:  "secret",
		SessionID: "desktop-session-1",
		TargetID:  "target-1",
		RouteID:   "agent-1",
	}

	session, err := (desktopRDPHelperAdapter{
		HelperPath: "helper",
		Start: func(context.Context, string) (desktopRDPHelperTransport, error) {
			return transport, nil
		},
	}).Open(context.Background(), remoteaccess.DesktopAdapterOpenRequest{
		SessionID:        "desktop-session-1",
		LocalAgentID:     "agent-1",
		CurrentGatewayID: "gateway-1",
		StartUnix:        1_778_000_000,
		Target:           testDesktopRDPHelperTarget(),
		CredentialGrant:  grant,
		MediaSender:      &fakeDesktopRDPHelperMediaSender{},
	})
	if err != nil {
		t.Fatalf("Open returned error: %v", err)
	}
	t.Cleanup(func() { _ = session.Close(context.Background(), "test done") })

	if grant.Username != "" || grant.Password != "" {
		t.Fatalf("credential grant was retained after helper open: %#v", grant)
	}

	openFrame := transport.sentFrame(t, 0)
	if openFrame.Type != desktopRDPHelperMessageOpen {
		t.Fatalf("open frame type = %d, want %d", openFrame.Type, desktopRDPHelperMessageOpen)
	}

	var payload desktopRDPHelperOpenPayload
	if err := json.Unmarshal(openFrame.Payload, &payload); err != nil {
		t.Fatalf("Unmarshal open payload returned error: %v", err)
	}
	if payload.Schema != "serviceradar.rdp.helper.open.v1" ||
		payload.SessionID != "desktop-session-1" ||
		payload.LocalAgentID != "agent-1" ||
		payload.GatewayID != "gateway-1" ||
		payload.CredentialGrant == nil ||
		payload.CredentialGrant.Username != "alice@example.com" ||
		payload.CredentialGrant.Password != "secret" {
		t.Fatalf("open payload = %#v", payload)
	}
}

func TestDesktopRDPHelperAdapterRoutesInputAndClose(t *testing.T) {
	t.Parallel()

	transport := newFakeDesktopRDPHelperTransport()
	session, err := openTestDesktopRDPHelperSession(t, transport, &fakeDesktopRDPHelperMediaSender{})
	if err != nil {
		t.Fatalf("openTestDesktopRDPHelperSession returned error: %v", err)
	}

	input := remoteaccess.DesktopFrame{
		SessionID: "desktop-session-1",
		Protocol:  remoteaccess.ProtocolRDP,
		FrameType: remoteaccess.DesktopFrameTypeInput,
		Input:     &remoteaccess.DesktopInputEvent{Kind: remoteaccess.DesktopInputKindKey, Key: "Enter", Down: true},
	}
	if err := session.SendDesktopFrame(context.Background(), input); err != nil {
		t.Fatalf("SendDesktopFrame returned error: %v", err)
	}

	inputFrame := transport.sentFrame(t, 1)
	if inputFrame.Type != desktopRDPHelperMessageInput {
		t.Fatalf("input frame type = %d, want %d", inputFrame.Type, desktopRDPHelperMessageInput)
	}

	if err := session.Close(context.Background(), "operator"); err != nil {
		t.Fatalf("Close returned error: %v", err)
	}
	if err := session.Close(context.Background(), "duplicate"); err != nil {
		t.Fatalf("second Close returned error: %v", err)
	}
	if transport.closeCount != 1 {
		t.Fatalf("transport close count = %d, want 1", transport.closeCount)
	}

	closeFrame := transport.sentFrame(t, 2)
	if closeFrame.Type != desktopRDPHelperMessageClose {
		t.Fatalf("close frame type = %d, want %d", closeFrame.Type, desktopRDPHelperMessageClose)
	}
}

func TestDesktopRDPHelperAdapterClearsSerializedInputPayload(t *testing.T) {
	t.Parallel()

	transport := newFakeDesktopRDPHelperTransport()
	transport.copySent = false
	session, err := openTestDesktopRDPHelperSession(t, transport, &fakeDesktopRDPHelperMediaSender{})
	if err != nil {
		t.Fatalf("openTestDesktopRDPHelperSession returned error: %v", err)
	}
	t.Cleanup(func() { _ = session.Close(context.Background(), "test done") })

	input := remoteaccess.DesktopFrame{
		SessionID: "desktop-session-1",
		Protocol:  remoteaccess.ProtocolRDP,
		FrameType: remoteaccess.DesktopFrameTypeInput,
		Input: &remoteaccess.DesktopInputEvent{
			Kind: remoteaccess.DesktopInputKindKey,
			Key:  "SuperSecretPassword",
			Down: true,
		},
	}
	if err := session.SendDesktopFrame(context.Background(), input); err != nil {
		t.Fatalf("SendDesktopFrame returned error: %v", err)
	}

	inputFrame := transport.sentFrame(t, 1)
	if bytes.Contains(inputFrame.Payload, []byte("SuperSecretPassword")) {
		t.Fatalf("input payload retained serialized key text: %q", string(inputFrame.Payload))
	}
	if !allZeroBytes(inputFrame.Payload) {
		t.Fatalf("input payload was not cleared: %q", string(inputFrame.Payload))
	}
}

func TestDesktopRDPHelperAdapterClearsSerializedClosePayload(t *testing.T) {
	t.Parallel()

	transport := newFakeDesktopRDPHelperTransport()
	transport.copySent = false
	session, err := openTestDesktopRDPHelperSession(t, transport, &fakeDesktopRDPHelperMediaSender{})
	if err != nil {
		t.Fatalf("openTestDesktopRDPHelperSession returned error: %v", err)
	}

	if err := session.Close(context.Background(), "operator close"); err != nil {
		t.Fatalf("Close returned error: %v", err)
	}

	closeFrame := transport.sentFrame(t, 1)
	if bytes.Contains(closeFrame.Payload, []byte("operator close")) {
		t.Fatalf("close payload retained serialized reason: %q", string(closeFrame.Payload))
	}
	if !allZeroBytes(closeFrame.Payload) {
		t.Fatalf("close payload was not cleared: %q", string(closeFrame.Payload))
	}
}

func TestDesktopRDPHelperAdapterForwardsMediaFrames(t *testing.T) {
	t.Parallel()

	transport := newFakeDesktopRDPHelperTransport()
	mediaSender := &fakeDesktopRDPHelperMediaSender{frames: make(chan remoteaccess.DesktopMediaFrame, 1)}
	session, err := openTestDesktopRDPHelperSession(t, transport, mediaSender)
	if err != nil {
		t.Fatalf("openTestDesktopRDPHelperSession returned error: %v", err)
	}
	t.Cleanup(func() { _ = session.Close(context.Background(), "test done") })

	want := remoteaccess.DesktopMediaFrame{
		SessionBindingID:  "desktop-session-1",
		MediaSessionID:    "media-session-1",
		Sequence:          3,
		TimestampUnixNano: 1_778_000_000_000,
		Width:             640,
		Height:            480,
		PayloadFamily:     remoteaccess.DesktopMediaPayloadDirtyRect,
		Encoding:          "raw_rgba",
		Payload:           []byte{1, 2, 3, 4},
	}
	encoded, err := remoteaccess.EncodeDesktopMediaFrame(want, testDesktopRDPHelperTarget().Screen)
	if err != nil {
		t.Fatalf("EncodeDesktopMediaFrame returned error: %v", err)
	}
	transport.recv <- desktopRDPHelperFrame{Type: desktopRDPHelperMessageMediaFrame, Payload: encoded}

	select {
	case got := <-mediaSender.frames:
		if got.SessionBindingID != want.SessionBindingID ||
			got.MediaSessionID != want.MediaSessionID ||
			got.Sequence != want.Sequence ||
			got.Width != want.Width ||
			got.Height != want.Height ||
			got.PayloadFamily != want.PayloadFamily {
			t.Fatalf("forwarded frame = %#v, want %#v", got, want)
		}
	case err := <-session.(*desktopRDPHelperSession).Err():
		t.Fatalf("helper session returned error: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for forwarded media frame")
	}
}

func TestDesktopRDPHelperAdapterRoutesMediaAcks(t *testing.T) {
	t.Parallel()

	transport := newFakeDesktopRDPHelperTransport()
	mediaSender := &fakeDesktopRDPHelperMediaSender{}
	session, err := openTestDesktopRDPHelperSession(t, transport, mediaSender)
	if err != nil {
		t.Fatalf("openTestDesktopRDPHelperSession returned error: %v", err)
	}
	t.Cleanup(func() { _ = session.Close(context.Background(), "test done") })

	if mediaSender.ackHandler == nil {
		t.Fatal("media ack handler was not registered")
	}

	ack := remoteaccess.DesktopMediaAck{
		SessionBindingID: "desktop-session-1",
		MediaSessionID:   "media-session-1",
		LastAcceptedSeq:  7,
		CreditBytes:      8192,
		QualityLevel:     remoteaccess.DesktopMediaQualityLow,
		Pause:            true,
	}
	if err := mediaSender.ackHandler(context.Background(), ack); err != nil {
		t.Fatalf("ack handler returned error: %v", err)
	}

	ackFrame := transport.sentFrame(t, 1)
	if ackFrame.Type != desktopRDPHelperMessageAck {
		t.Fatalf("ack frame type = %d, want %d", ackFrame.Type, desktopRDPHelperMessageAck)
	}

	got, err := remoteaccess.DecodeDesktopMediaAckMessage(
		ackFrame.Payload,
		"desktop-session-1",
		"media-session-1",
	)
	if err != nil {
		t.Fatalf("DecodeDesktopMediaAckMessage returned error: %v", err)
	}
	if got.LastAcceptedSeq != ack.LastAcceptedSeq ||
		got.CreditBytes != ack.CreditBytes ||
		got.QualityLevel != ack.QualityLevel ||
		!got.Pause {
		t.Fatalf("ack payload = %#v, want %#v", got, ack)
	}
}

func TestDesktopRDPHelperAdapterClearsSerializedAckPayload(t *testing.T) {
	t.Parallel()

	transport := newFakeDesktopRDPHelperTransport()
	transport.copySent = false
	mediaSender := &fakeDesktopRDPHelperMediaSender{}
	session, err := openTestDesktopRDPHelperSession(t, transport, mediaSender)
	if err != nil {
		t.Fatalf("openTestDesktopRDPHelperSession returned error: %v", err)
	}
	t.Cleanup(func() { _ = session.Close(context.Background(), "test done") })

	ack := remoteaccess.DesktopMediaAck{
		SessionBindingID: "desktop-session-1",
		MediaSessionID:   "media-session-1",
		LastAcceptedSeq:  7,
		CreditBytes:      8192,
		CloseReason:      "browser close",
	}
	if err := mediaSender.ackHandler(context.Background(), ack); err != nil {
		t.Fatalf("ack handler returned error: %v", err)
	}

	ackFrame := transport.sentFrame(t, 1)
	if bytes.Contains(ackFrame.Payload, []byte("browser close")) {
		t.Fatalf("ack payload retained serialized close reason: %q", string(ackFrame.Payload))
	}
	if !allZeroBytes(ackFrame.Payload) {
		t.Fatalf("ack payload was not cleared: %q", string(ackFrame.Payload))
	}
}

func TestDesktopRDPHelperAdapterRejectsMediaAcksAfterHelperClose(t *testing.T) {
	t.Parallel()

	transport := newFakeDesktopRDPHelperTransport()
	mediaSender := &fakeDesktopRDPHelperMediaSender{}
	session, err := openTestDesktopRDPHelperSession(t, transport, mediaSender)
	if err != nil {
		t.Fatalf("openTestDesktopRDPHelperSession returned error: %v", err)
	}

	transport.recv <- desktopRDPHelperFrame{Type: desktopRDPHelperMessageClose}

	select {
	case <-session.(*desktopRDPHelperSession).done:
	case err := <-session.(*desktopRDPHelperSession).Err():
		t.Fatalf("helper session returned error: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for helper close")
	}

	err = mediaSender.ackHandler(context.Background(), remoteaccess.DesktopMediaAck{
		SessionBindingID: "desktop-session-1",
		MediaSessionID:   "media-session-1",
		LastAcceptedSeq:  7,
		CreditBytes:      8192,
	})
	if !errors.Is(err, errDesktopRDPHelperClosed) {
		t.Fatalf("post-close ack error = %v, want %v", err, errDesktopRDPHelperClosed)
	}
}

func openTestDesktopRDPHelperSession(
	t *testing.T,
	transport *fakeDesktopRDPHelperTransport,
	mediaSender remoteaccess.DesktopMediaSender,
) (remoteaccess.DesktopAdapterSession, error) {
	t.Helper()

	return (desktopRDPHelperAdapter{
		HelperPath: "helper",
		Start: func(context.Context, string) (desktopRDPHelperTransport, error) {
			return transport, nil
		},
	}).Open(context.Background(), remoteaccess.DesktopAdapterOpenRequest{
		SessionID:        "desktop-session-1",
		LocalAgentID:     "agent-1",
		CurrentGatewayID: "gateway-1",
		StartUnix:        1_778_000_000,
		Target:           testDesktopRDPHelperTarget(),
		MediaSender:      mediaSender,
	})
}

func testDesktopRDPHelperTarget() remoteaccess.DesktopTarget {
	return remoteaccess.DesktopTarget{
		TargetID: "target-1",
		Protocol: remoteaccess.ProtocolRDP,
		Route: remoteaccess.DesktopRoute{
			SelectedAgentID: "agent-1",
			SelectedGateway: "gateway-1",
		},
		Upstream: remoteaccess.DesktopUpstream{Host: "rdp.example", Port: remoteaccess.DesktopDefaultRDPPort},
		TLS: remoteaccess.DesktopTLSPolicy{
			Mode:    remoteaccess.DesktopTLSModeVerify,
			NLAMode: remoteaccess.DesktopNLAModeRequired,
		},
		Credential: remoteaccess.DesktopCredentialPolicy{
			Mode:              remoteaccess.DesktopCredentialModeMemoryUser,
			AllowedPrincipals: []string{"alice@example.com"},
		},
		Screen: remoteaccess.DesktopScreenPolicy{
			MaxWidth:    1024,
			MaxHeight:   768,
			FrameRate:   30,
			BitrateBPS:  8_000_000,
			IdleSeconds: 900,
			TTLSeconds:  3600,
		},
		Redirection: remoteaccess.DesktopRedirectionPolicy{ClipboardMode: remoteaccess.DesktopClipboardModeDisabled},
	}
}

type fakeDesktopRDPHelperTransport struct {
	mu         sync.Mutex
	sent       []desktopRDPHelperFrame
	recv       chan desktopRDPHelperFrame
	copySent   bool
	closeCount int
	closed     bool
}

func newFakeDesktopRDPHelperTransport() *fakeDesktopRDPHelperTransport {
	return &fakeDesktopRDPHelperTransport{
		recv:     make(chan desktopRDPHelperFrame, 1),
		copySent: true,
	}
}

func (t *fakeDesktopRDPHelperTransport) SendFrame(frame desktopRDPHelperFrame) error {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.closed {
		return errDesktopRDPHelperClosed
	}
	if t.copySent {
		frame.Payload = append([]byte(nil), frame.Payload...)
	}
	t.sent = append(t.sent, frame)

	return nil
}

func (t *fakeDesktopRDPHelperTransport) ReadFrame() (desktopRDPHelperFrame, error) {
	frame, ok := <-t.recv
	if !ok {
		return desktopRDPHelperFrame{}, io.EOF
	}

	return frame, nil
}

func (t *fakeDesktopRDPHelperTransport) Close(context.Context) error {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.closed {
		return nil
	}
	t.closed = true
	t.closeCount++
	close(t.recv)

	return nil
}

func (t *fakeDesktopRDPHelperTransport) sentFrame(tb testing.TB, index int) desktopRDPHelperFrame {
	tb.Helper()

	t.mu.Lock()
	defer t.mu.Unlock()

	if len(t.sent) <= index {
		tb.Fatalf("sent frames = %d, want index %d", len(t.sent), index)
	}

	return t.sent[index]
}

func allZeroBytes(data []byte) bool {
	if len(data) == 0 {
		return false
	}
	for _, value := range data {
		if value != 0 {
			return false
		}
	}

	return true
}

type fakeDesktopRDPHelperMediaSender struct {
	frames     chan remoteaccess.DesktopMediaFrame
	ackHandler remoteaccess.DesktopMediaAckHandler
	err        error
}

func (s *fakeDesktopRDPHelperMediaSender) SendDesktopMediaFrame(_ context.Context, frame remoteaccess.DesktopMediaFrame) error {
	if s.err != nil {
		return s.err
	}
	if s.frames != nil {
		s.frames <- frame
	}

	return nil
}

func (s *fakeDesktopRDPHelperMediaSender) SetDesktopMediaAckHandler(handler remoteaccess.DesktopMediaAckHandler) {
	s.ackHandler = handler
}

func TestDesktopRDPHelperAdapterReportsHelperErrors(t *testing.T) {
	t.Parallel()

	transport := newFakeDesktopRDPHelperTransport()
	session, err := openTestDesktopRDPHelperSession(t, transport, &fakeDesktopRDPHelperMediaSender{})
	if err != nil {
		t.Fatalf("openTestDesktopRDPHelperSession returned error: %v", err)
	}
	t.Cleanup(func() { _ = session.Close(context.Background(), "test done") })

	transport.recv <- desktopRDPHelperFrame{Type: desktopRDPHelperMessageError, Payload: []byte("rdp failed")}

	select {
	case err := <-session.(*desktopRDPHelperSession).Err():
		if !errors.Is(err, remoteaccess.ErrDesktopAdapterUnavailable) {
			t.Fatalf("helper error = %v, want %v", err, remoteaccess.ErrDesktopAdapterUnavailable)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for helper error")
	}
}

func TestDesktopRDPHelperAdapterClosesSessionAfterHelperError(t *testing.T) {
	t.Parallel()

	transport := newFakeDesktopRDPHelperTransport()
	session, err := openTestDesktopRDPHelperSession(t, transport, &fakeDesktopRDPHelperMediaSender{})
	if err != nil {
		t.Fatalf("openTestDesktopRDPHelperSession returned error: %v", err)
	}

	transport.recv <- desktopRDPHelperFrame{Type: desktopRDPHelperMessageError, Payload: []byte("rdp failed")}

	select {
	case err := <-session.(*desktopRDPHelperSession).Err():
		if !errors.Is(err, remoteaccess.ErrDesktopAdapterUnavailable) {
			t.Fatalf("helper error = %v, want %v", err, remoteaccess.ErrDesktopAdapterUnavailable)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for helper error")
	}

	input := remoteaccess.DesktopFrame{
		SessionID: "desktop-session-1",
		Protocol:  remoteaccess.ProtocolRDP,
		FrameType: remoteaccess.DesktopFrameTypeInput,
		Input:     &remoteaccess.DesktopInputEvent{Kind: remoteaccess.DesktopInputKindKey, Key: "Enter", Down: true},
	}
	if err := session.SendDesktopFrame(context.Background(), input); !errors.Is(err, errDesktopRDPHelperClosed) {
		t.Fatalf("post-error SendDesktopFrame error = %v, want %v", err, errDesktopRDPHelperClosed)
	}
	if transport.closeCount != 1 {
		t.Fatalf("transport close count = %d, want 1", transport.closeCount)
	}
}

func TestDesktopRDPHelperAdapterClosesSessionAfterHelperClose(t *testing.T) {
	t.Parallel()

	transport := newFakeDesktopRDPHelperTransport()
	session, err := openTestDesktopRDPHelperSession(t, transport, &fakeDesktopRDPHelperMediaSender{})
	if err != nil {
		t.Fatalf("openTestDesktopRDPHelperSession returned error: %v", err)
	}

	transport.recv <- desktopRDPHelperFrame{Type: desktopRDPHelperMessageClose}

	select {
	case <-session.(*desktopRDPHelperSession).done:
	case err := <-session.(*desktopRDPHelperSession).Err():
		t.Fatalf("helper session returned error: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for helper close")
	}

	input := remoteaccess.DesktopFrame{
		SessionID: "desktop-session-1",
		Protocol:  remoteaccess.ProtocolRDP,
		FrameType: remoteaccess.DesktopFrameTypeInput,
		Input:     &remoteaccess.DesktopInputEvent{Kind: remoteaccess.DesktopInputKindKey, Key: "Enter", Down: true},
	}
	if err := session.SendDesktopFrame(context.Background(), input); !errors.Is(err, errDesktopRDPHelperClosed) {
		t.Fatalf("post-close SendDesktopFrame error = %v, want %v", err, errDesktopRDPHelperClosed)
	}
	if transport.closeCount != 1 {
		t.Fatalf("transport close count = %d, want 1", transport.closeCount)
	}
	if err := session.Close(context.Background(), "manager cleanup"); err != nil {
		t.Fatalf("Close after helper close returned error: %v", err)
	}
	if transport.closeCount != 1 {
		t.Fatalf("transport close count after manager cleanup = %d, want 1", transport.closeCount)
	}
}

func TestDesktopRDPHelperProcessCloseKillsStuckHelper(t *testing.T) {
	t.Parallel()

	if runtime.GOOS == "windows" {
		t.Skip("shell helper test requires POSIX sh")
	}

	helperPath := filepath.Join(t.TempDir(), "stuck-rdp-helper.sh")
	if err := os.WriteFile(helperPath, []byte("#!/bin/sh\nsleep 30\n"), 0o755); err != nil {
		t.Fatalf("WriteFile returned error: %v", err)
	}

	transport, err := startDesktopRDPHelperProcess(context.Background(), helperPath)
	if err != nil {
		t.Fatalf("startDesktopRDPHelperProcess returned error: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()

	err = transport.Close(ctx)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Close error = %v, want %v", err, context.DeadlineExceeded)
	}
}
