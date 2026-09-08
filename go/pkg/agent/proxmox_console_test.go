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
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
	"github.com/carverauto/serviceradar/proto"
)

const (
	fakeProxmoxConsoleCommand = "whoami\r"
	desktopConsoleSessionID   = "desktop-session-1"
	desktopConsoleTargetID    = "rdp-target-1"
	desktopConsoleAgentID     = "agent-1"
	desktopConsoleGatewayID   = "gateway-1"
	desktopConsoleMediaID     = "desktop-media-session-1"
	desktopConsoleLeaseToken  = "lease-token-1"
)

var errFakeProxmoxConsolePTYReadFailed = errors.New("pty read failed")

type fakeProxmoxConsoleSender struct {
	mu     sync.Mutex
	frames []*proto.ConsoleFrame
	ch     chan *proto.ConsoleFrame
}

func newFakeProxmoxConsoleSender() *fakeProxmoxConsoleSender {
	return &fakeProxmoxConsoleSender{ch: make(chan *proto.ConsoleFrame, 16)}
}

func (f *fakeProxmoxConsoleSender) Send(req *proto.ControlStreamRequest) error {
	frame := req.GetConsoleFrame()
	if frame == nil {
		return nil
	}

	f.mu.Lock()
	f.frames = append(f.frames, frame)
	f.mu.Unlock()

	f.ch <- frame

	return nil
}

func (f *fakeProxmoxConsoleSender) nextFrame(t *testing.T, frameType string) *proto.ConsoleFrame {
	t.Helper()

	deadline := time.After(time.Second)
	for {
		select {
		case frame := <-f.ch:
			if frame.GetFrameType() == frameType {
				return frame
			}
		case <-deadline:
			t.Fatalf("timed out waiting for console frame type %q", frameType)
		}
	}
}

type fakeProxmoxConsoleRead struct {
	data []byte
	err  error
}

type fakeProxmoxConsolePTY struct {
	reads   chan fakeProxmoxConsoleRead
	writes  chan []byte
	resizes chan [2]uint32
	closed  chan struct{}
	once    sync.Once
}

type fakeDesktopAdapterSession struct {
	frames chan remoteaccess.DesktopFrame
	closes chan string
}

type fakeDesktopRDPAdapter struct {
	request remoteaccess.DesktopAdapterOpenRequest
	session remoteaccess.DesktopAdapterSession
	err     error
}

func (f *fakeDesktopRDPAdapter) Open(
	_ context.Context,
	req remoteaccess.DesktopAdapterOpenRequest,
) (remoteaccess.DesktopAdapterSession, error) {
	f.request = req
	if f.err != nil {
		return nil, f.err
	}
	if f.session != nil {
		return f.session, nil
	}

	return newFakeDesktopAdapterSession(), nil
}

func newFakeDesktopAdapterSession() *fakeDesktopAdapterSession {
	return &fakeDesktopAdapterSession{
		frames: make(chan remoteaccess.DesktopFrame, 4),
		closes: make(chan string, 4),
	}
}

func (f *fakeDesktopAdapterSession) SendDesktopFrame(
	_ context.Context,
	frame remoteaccess.DesktopFrame,
) error {
	f.frames <- frame

	return nil
}

func (f *fakeDesktopAdapterSession) Close(_ context.Context, reason string) error {
	f.closes <- reason

	return nil
}

func newFakeProxmoxConsolePTY() *fakeProxmoxConsolePTY {
	return &fakeProxmoxConsolePTY{
		reads:   make(chan fakeProxmoxConsoleRead, 8),
		writes:  make(chan []byte, 8),
		resizes: make(chan [2]uint32, 8),
		closed:  make(chan struct{}),
	}
}

func (f *fakeProxmoxConsolePTY) Read(ctx context.Context) ([]byte, error) {
	select {
	case read := <-f.reads:
		return read.data, read.err
	case <-f.closed:
		return nil, io.EOF
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (f *fakeProxmoxConsolePTY) Write(data []byte) error {
	copied := append([]byte(nil), data...)
	f.writes <- copied

	return nil
}

func (f *fakeProxmoxConsolePTY) Resize(cols, rows uint32) error {
	f.resizes <- [2]uint32{cols, rows}

	return nil
}

func (f *fakeProxmoxConsolePTY) Close() error {
	f.once.Do(func() { close(f.closed) })

	return nil
}

func TestProxmoxConsoleManagerRoutesSessionFrames(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	pty := newFakeProxmoxConsolePTY()
	manager := newProxmoxConsoleManager(createTestLogger())
	manager.opener = func(_ context.Context, frame *proto.ConsoleFrame) (proxmoxConsolePTY, error) {
		if frame.GetCols() != 120 || frame.GetRows() != 40 {
			t.Fatalf("open terminal size = %dx%d, want 120x40", frame.GetCols(), frame.GetRows())
		}

		return pty, nil
	}
	sender := newFakeProxmoxConsoleSender()

	manager.HandleFrame(ctx, &proto.ConsoleFrame{
		SessionId: "console-session-1",
		FrameType: consoleFrameTypeOpen,
		Cols:      120,
		Rows:      40,
	}, sender)

	ready := sender.nextFrame(t, consoleFrameTypeReady)
	if ready.GetSessionId() != "console-session-1" {
		t.Fatalf("ready SessionId = %q", ready.GetSessionId())
	}

	manager.HandleFrame(ctx, &proto.ConsoleFrame{
		SessionId: "console-session-1",
		FrameType: consoleFrameTypeData,
		Data:      []byte(fakeProxmoxConsoleCommand),
	}, sender)

	select {
	case got := <-pty.writes:
		if string(got) != fakeProxmoxConsoleCommand {
			t.Fatalf("PTY write = %q", string(got))
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for PTY write")
	}

	manager.HandleFrame(ctx, &proto.ConsoleFrame{
		SessionId: "console-session-1",
		FrameType: consoleFrameTypeResize,
		Cols:      100,
		Rows:      30,
	}, sender)

	select {
	case got := <-pty.resizes:
		if got != [2]uint32{100, 30} {
			t.Fatalf("PTY resize = %v", got)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for PTY resize")
	}

	pty.reads <- fakeProxmoxConsoleRead{data: []byte("root\r\n")}
	output := sender.nextFrame(t, consoleFrameTypeData)
	if string(output.GetData()) != "root\r\n" {
		t.Fatalf("console output = %q", string(output.GetData()))
	}

	manager.HandleFrame(ctx, &proto.ConsoleFrame{
		SessionId: "console-session-1",
		FrameType: consoleFrameTypeClose,
		Reason:    "operator closed console",
	}, sender)

	closeFrame := sender.nextFrame(t, consoleFrameTypeClose)
	if closeFrame.GetReason() != "operator closed console" {
		t.Fatalf("close reason = %q", closeFrame.GetReason())
	}

	select {
	case <-pty.closed:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for PTY close")
	}
}

func TestProxmoxConsoleManagerRejectsDuplicateOpen(t *testing.T) {
	t.Parallel()

	pty := newFakeProxmoxConsolePTY()
	manager := newProxmoxConsoleManager(createTestLogger())
	manager.opener = func(context.Context, *proto.ConsoleFrame) (proxmoxConsolePTY, error) {
		return pty, nil
	}
	sender := newFakeProxmoxConsoleSender()

	frame := &proto.ConsoleFrame{SessionId: "console-session-1", FrameType: consoleFrameTypeOpen}
	manager.HandleFrame(context.Background(), frame, sender)
	_ = sender.nextFrame(t, consoleFrameTypeReady)

	manager.HandleFrame(context.Background(), frame, sender)
	errorFrame := sender.nextFrame(t, consoleFrameTypeError)
	if errorFrame.GetReason() != errProxmoxConsoleSessionExists.Error() {
		t.Fatalf("duplicate open reason = %q", errorFrame.GetReason())
	}
}

func TestProxmoxConsoleManagerReportsReadFailure(t *testing.T) {
	t.Parallel()

	pty := newFakeProxmoxConsolePTY()
	manager := newProxmoxConsoleManager(createTestLogger())
	manager.opener = func(context.Context, *proto.ConsoleFrame) (proxmoxConsolePTY, error) {
		return pty, nil
	}
	sender := newFakeProxmoxConsoleSender()

	manager.HandleFrame(context.Background(), &proto.ConsoleFrame{
		SessionId: "console-session-1",
		FrameType: consoleFrameTypeOpen,
	}, sender)
	_ = sender.nextFrame(t, consoleFrameTypeReady)

	pty.reads <- fakeProxmoxConsoleRead{err: errFakeProxmoxConsolePTYReadFailed}

	errorFrame := sender.nextFrame(t, consoleFrameTypeError)
	if errorFrame.GetReason() != errFakeProxmoxConsolePTYReadFailed.Error() {
		t.Fatalf("read failure reason = %q", errorFrame.GetReason())
	}

	_ = sender.nextFrame(t, consoleFrameTypeClose)
}

func TestProxmoxConsoleManagerRoutesSSHOpenPayload(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	session := &fakeProxmoxConsoleSSHSession{
		waitCh: make(chan struct{}),
		stdout: strings.NewReader("login: "),
		stderr: strings.NewReader(""),
	}
	manager := newProxmoxConsoleManager(createTestLogger())
	manager.sshOptions = remoteaccess.SSHOpenOptions{
		Dial: func(_ context.Context, cfg remoteaccess.SSHConfig) (remoteaccess.SSHSession, error) {
			if cfg.Target.Host != "router.example" {
				t.Fatalf("ssh target host = %q", cfg.Target.Host)
			}
			if cfg.Auth.Username != "admin" || cfg.Auth.Password != "secret" {
				t.Fatalf("ssh auth = %#v", cfg.Auth)
			}

			return session, nil
		},
	}
	sender := newFakeProxmoxConsoleSender()

	manager.HandleFrame(ctx, &proto.ConsoleFrame{
		SessionId: "ssh-session-1",
		FrameType: consoleFrameTypeOpen,
		Cols:      100,
		Rows:      30,
		Data: []byte(`{
			"protocol": "ssh",
			"target": {"host": "router.example"},
			"ssh": {"username": "admin", "password": "secret"}
		}`),
	}, sender)

	ready := sender.nextFrame(t, consoleFrameTypeReady)
	if ready.GetSessionId() != "ssh-session-1" {
		t.Fatalf("ready SessionId = %q", ready.GetSessionId())
	}

	output := sender.nextFrame(t, consoleFrameTypeData)
	if string(output.GetData()) != "login: " {
		t.Fatalf("ssh output = %q", string(output.GetData()))
	}

	manager.HandleFrame(ctx, &proto.ConsoleFrame{
		SessionId: "ssh-session-1",
		FrameType: consoleFrameTypeData,
		Data:      []byte("whoami\r"),
	}, sender)
	manager.HandleFrame(ctx, &proto.ConsoleFrame{
		SessionId: "ssh-session-1",
		FrameType: consoleFrameTypeResize,
		Cols:      132,
		Rows:      43,
	}, sender)

	waitFor(t, time.Second, func() bool {
		stdin, windowChanges := session.ioState()
		return stdin == "whoami\r" &&
			len(windowChanges) == 1 &&
			windowChanges[0] == [2]int{43, 132}
	})

	ptyRows, ptyCols, shellStarted := session.ptyState()
	if ptyRows != 30 || ptyCols != 100 || !shellStarted {
		t.Fatalf("unexpected ssh pty rows=%d cols=%d shell=%t", ptyRows, ptyCols, shellStarted)
	}

	manager.HandleFrame(ctx, &proto.ConsoleFrame{
		SessionId: "ssh-session-1",
		FrameType: consoleFrameTypeClose,
	}, sender)
	_ = sender.nextFrame(t, consoleFrameTypeClose)

	if !session.isClosed() {
		t.Fatal("expected SSH session to close")
	}
}

func TestProxmoxConsoleManagerRejectsSSHOpenForDifferentAgent(t *testing.T) {
	t.Parallel()

	manager := newProxmoxConsoleManagerWithAgentID("agent-1", createTestLogger())
	manager.sshOptions = remoteaccess.SSHOpenOptions{
		Dial: func(context.Context, remoteaccess.SSHConfig) (remoteaccess.SSHSession, error) {
			t.Fatal("dialer should not be called for mismatched agent_id")
			return nil, nil
		},
	}
	sender := newFakeProxmoxConsoleSender()

	manager.HandleFrame(context.Background(), &proto.ConsoleFrame{
		SessionId: "ssh-session-1",
		FrameType: consoleFrameTypeOpen,
		Data: []byte(`{
			"protocol": "ssh",
			"session_id": "ssh-session-1",
			"agent_id": "agent-2",
			"target": {"host": "router.example"},
			"ssh": {"username": "admin", "password": "secret"}
		}`),
	}, sender)

	errorFrame := sender.nextFrame(t, consoleFrameTypeError)
	if !strings.Contains(errorFrame.GetReason(), remoteaccess.ErrSSHOpenAgentMismatch.Error()) {
		t.Fatalf("error reason = %q, want %q", errorFrame.GetReason(), remoteaccess.ErrSSHOpenAgentMismatch)
	}
}

func TestProxmoxConsoleManagerRejectsSSHOpenForDifferentGateway(t *testing.T) {
	t.Parallel()

	manager := newProxmoxConsoleManagerWithRoute("agent-1", "gateway-1", createTestLogger())
	manager.sshOptions = remoteaccess.SSHOpenOptions{
		Dial: func(context.Context, remoteaccess.SSHConfig) (remoteaccess.SSHSession, error) {
			t.Fatal("dialer should not be called for mismatched gateway_id")
			return nil, nil
		},
	}
	sender := newFakeProxmoxConsoleSender()

	manager.HandleFrame(context.Background(), &proto.ConsoleFrame{
		SessionId: "ssh-session-1",
		FrameType: consoleFrameTypeOpen,
		Data: []byte(`{
			"protocol": "ssh",
			"session_id": "ssh-session-1",
			"agent_id": "agent-1",
			"gateway_id": "gateway-2",
			"target": {"host": "router.example"},
			"ssh": {"username": "admin", "password": "secret"}
		}`),
	}, sender)

	errorFrame := sender.nextFrame(t, consoleFrameTypeError)
	if !strings.Contains(errorFrame.GetReason(), remoteaccess.ErrSSHOpenGatewayMismatch.Error()) {
		t.Fatalf("error reason = %q, want %q", errorFrame.GetReason(), remoteaccess.ErrSSHOpenGatewayMismatch)
	}
}

func TestProxmoxConsoleManagerFailsClosedWhenRequiredEnhancedRecordingUnavailable(t *testing.T) {
	t.Parallel()

	manager := newProxmoxConsoleManagerWithAgentID("agent-1", createTestLogger())
	manager.sshOptions = remoteaccess.SSHOpenOptions{
		Dial: func(context.Context, remoteaccess.SSHConfig) (remoteaccess.SSHSession, error) {
			t.Fatal("dialer should not be called when required enhanced recording is unavailable")
			return nil, nil
		},
	}
	sender := newFakeProxmoxConsoleSender()

	manager.HandleFrame(context.Background(), &proto.ConsoleFrame{
		SessionId: "ssh-session-1",
		FrameType: consoleFrameTypeOpen,
		Data: []byte(`{
			"protocol": "ssh",
			"session_id": "ssh-session-1",
			"agent_id": "agent-1",
			"target_execution_mode": "managed_target",
			"target": {"host": "router.example"},
			"ssh": {"username": "admin", "password": "secret"},
			"enhanced_recording_policy": {"enabled": true, "required": true, "mode": "bpf"}
		}`),
	}, sender)

	errorFrame := sender.nextFrame(t, consoleFrameTypeError)
	if !strings.Contains(errorFrame.GetReason(), remoteaccess.ErrEnhancedRecordingUnavailable.Error()) {
		t.Fatalf("error reason = %q, want %q", errorFrame.GetReason(), remoteaccess.ErrEnhancedRecordingUnavailable)
	}
}

func TestProxmoxConsoleManagerRoutesDesktopControlFrame(t *testing.T) {
	t.Parallel()

	target := testDesktopConsoleTarget(t)
	adapterSession := newFakeDesktopAdapterSession()
	manager := newProxmoxConsoleManagerWithAgentID(desktopConsoleAgentID, createTestLogger())
	manager.registerDesktopSession(desktopConsoleSessionID, target, adapterSession)
	sender := newFakeProxmoxConsoleSender()
	payload := encodeDesktopConsoleFrame(t, target, remoteaccess.DesktopFrame{
		SessionID: desktopConsoleSessionID,
		Protocol:  remoteaccess.ProtocolRDP,
		FrameType: remoteaccess.DesktopFrameTypeInput,
		Input: &remoteaccess.DesktopInputEvent{
			Kind: remoteaccess.DesktopInputKindPointer,
			X:    640,
			Y:    360,
		},
	})

	manager.HandleFrame(context.Background(), &proto.ConsoleFrame{
		SessionId: desktopConsoleSessionID,
		FrameType: remoteaccess.DesktopFrameTypeInput,
		Data:      payload,
	}, sender)

	select {
	case got := <-adapterSession.frames:
		if got.FrameType != remoteaccess.DesktopFrameTypeInput ||
			got.Input == nil ||
			got.Input.Kind != remoteaccess.DesktopInputKindPointer ||
			got.Input.X != 640 ||
			got.Input.Y != 360 {
			t.Fatalf("desktop frame = %#v", got)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for desktop adapter frame")
	}
}

func TestProxmoxConsoleManagerOpensRDPDesktopSessionWithMediaGateway(t *testing.T) {
	t.Parallel()

	target := testDesktopConsoleTarget(t)
	target.Route.SelectedGateway = desktopConsoleGatewayID
	stream := newFakeDesktopMediaStream()
	gateway := &fakeDesktopMediaGateway{
		openResp: &proto.OpenDesktopMediaSessionResponse{
			Accepted:           true,
			MediaIngestId:      testDesktopMediaIngestID,
			MediaSessionId:     desktopConsoleMediaID,
			MaxChunkBytes:      4096,
			InitialCreditBytes: 8192,
		},
		stream: stream,
	}
	adapter := &fakeDesktopRDPAdapter{}
	manager := newProxmoxConsoleManagerWithRoute(
		desktopConsoleAgentID,
		desktopConsoleGatewayID,
		createTestLogger(),
	)
	manager.desktopGateway = gateway
	manager.desktopAdapter = adapter
	sender := newFakeProxmoxConsoleSender()

	manager.HandleFrame(context.Background(), &proto.ConsoleFrame{
		SessionId: desktopConsoleSessionID,
		FrameType: consoleFrameTypeOpen,
		Data:      encodeDesktopOpenPayloadWithGrant(t, target, testDesktopConsoleCredentialGrant()),
	}, sender)

	ready := sender.nextFrame(t, consoleFrameTypeReady)
	var readyPayload map[string]any
	if err := json.Unmarshal(ready.GetData(), &readyPayload); err != nil {
		t.Fatalf("ready payload decode returned error: %v", err)
	}
	if readyPayload["media_session_id"] != desktopConsoleMediaID ||
		readyPayload["max_chunk_bytes"].(float64) != 4096 {
		t.Fatalf("ready payload = %#v", readyPayload)
	}

	if gateway.openReq.GetDesktopSessionId() != desktopConsoleSessionID ||
		gateway.openReq.GetMediaSessionId() != desktopConsoleMediaID ||
		gateway.openReq.GetAgentId() != desktopConsoleAgentID ||
		gateway.openReq.GetGatewayId() != desktopConsoleGatewayID ||
		gateway.openReq.GetTargetId() != desktopConsoleTargetID ||
		gateway.openReq.GetRouteId() != desktopConsoleAgentID ||
		gateway.openReq.GetLeaseToken() != desktopConsoleLeaseToken {
		t.Fatalf("desktop media open request = %#v", gateway.openReq)
	}
	if adapter.request.SessionID != desktopConsoleSessionID ||
		adapter.request.LocalAgentID != desktopConsoleAgentID ||
		adapter.request.CurrentGatewayID != desktopConsoleGatewayID ||
		adapter.request.Target.TargetID != desktopConsoleTargetID ||
		adapter.request.MediaSender == nil {
		t.Fatalf("adapter request = %#v", adapter.request)
	}
	if !manager.hasDesktopSession(desktopConsoleSessionID) {
		t.Fatal("desktop session was not registered after open")
	}
}

func TestProxmoxConsoleManagerRejectsRDPDesktopOpenWithoutMediaBinding(t *testing.T) {
	t.Parallel()

	target := testDesktopConsoleTarget(t)
	target.Route.SelectedGateway = desktopConsoleGatewayID
	adapter := &fakeDesktopRDPAdapter{}
	manager := newProxmoxConsoleManagerWithRoute(
		desktopConsoleAgentID,
		desktopConsoleGatewayID,
		createTestLogger(),
	)
	manager.desktopAdapter = adapter
	sender := newFakeProxmoxConsoleSender()

	manager.HandleFrame(context.Background(), &proto.ConsoleFrame{
		SessionId: desktopConsoleSessionID,
		FrameType: consoleFrameTypeOpen,
		Data:      encodeDesktopOpenPayloadWithGrant(t, target, testDesktopConsoleCredentialGrant()),
	}, sender)

	errorFrame := sender.nextFrame(t, consoleFrameTypeError)
	if !strings.Contains(errorFrame.GetReason(), errDesktopMediaGatewayRequired.Error()) {
		t.Fatalf("desktop open reason = %q", errorFrame.GetReason())
	}
	if adapter.request.SessionID != "" {
		t.Fatalf("adapter should not have been called: %#v", adapter.request)
	}
}

func TestProxmoxConsoleManagerRejectsRDPDesktopOpenWithoutCredentialGrant(t *testing.T) {
	t.Parallel()

	target := testDesktopConsoleTarget(t)
	target.Route.SelectedGateway = desktopConsoleGatewayID
	gateway := &fakeDesktopMediaGateway{}
	adapter := &fakeDesktopRDPAdapter{}
	manager := newProxmoxConsoleManagerWithRoute(
		desktopConsoleAgentID,
		desktopConsoleGatewayID,
		createTestLogger(),
	)
	manager.desktopGateway = gateway
	manager.desktopAdapter = adapter
	sender := newFakeProxmoxConsoleSender()

	manager.HandleFrame(context.Background(), &proto.ConsoleFrame{
		SessionId: desktopConsoleSessionID,
		FrameType: consoleFrameTypeOpen,
		Data:      encodeDesktopOpenPayload(t, target),
	}, sender)

	errorFrame := sender.nextFrame(t, consoleFrameTypeError)
	if !strings.Contains(errorFrame.GetReason(), "desktop credential grant required") {
		t.Fatalf("desktop open reason = %q", errorFrame.GetReason())
	}
	if gateway.openReq != nil {
		t.Fatalf("media gateway should not have been opened: %#v", gateway.openReq)
	}
	if adapter.request.SessionID != "" {
		t.Fatalf("adapter should not have been called: %#v", adapter.request)
	}
}

func TestProxmoxConsoleManagerRejectsDesktopControlWithoutActiveSession(t *testing.T) {
	t.Parallel()

	target := testDesktopConsoleTarget(t)
	manager := newProxmoxConsoleManagerWithAgentID(desktopConsoleAgentID, createTestLogger())
	sender := newFakeProxmoxConsoleSender()
	payload := encodeDesktopConsoleFrame(t, target, remoteaccess.DesktopFrame{
		SessionID: desktopConsoleSessionID,
		Protocol:  remoteaccess.ProtocolRDP,
		FrameType: remoteaccess.DesktopFrameTypeResize,
		Width:     800,
		Height:    600,
	})

	manager.HandleFrame(context.Background(), &proto.ConsoleFrame{
		SessionId: desktopConsoleSessionID,
		FrameType: remoteaccess.DesktopFrameTypeResize,
		Data:      payload,
	}, sender)

	errorFrame := sender.nextFrame(t, consoleFrameTypeError)
	if errorFrame.GetReason() != errProxmoxConsoleSessionNotActive.Error() {
		t.Fatalf("inactive desktop reason = %q", errorFrame.GetReason())
	}
}

func TestProxmoxConsoleManagerRejectsDesktopControlFrameTypeMismatch(t *testing.T) {
	t.Parallel()

	target := testDesktopConsoleTarget(t)
	adapterSession := newFakeDesktopAdapterSession()
	manager := newProxmoxConsoleManagerWithAgentID(desktopConsoleAgentID, createTestLogger())
	manager.registerDesktopSession(desktopConsoleSessionID, target, adapterSession)
	sender := newFakeProxmoxConsoleSender()
	payload := encodeDesktopConsoleFrame(t, target, remoteaccess.DesktopFrame{
		SessionID: desktopConsoleSessionID,
		Protocol:  remoteaccess.ProtocolRDP,
		FrameType: remoteaccess.DesktopFrameTypeResize,
		Width:     800,
		Height:    600,
	})

	manager.HandleFrame(context.Background(), &proto.ConsoleFrame{
		SessionId: desktopConsoleSessionID,
		FrameType: remoteaccess.DesktopFrameTypeInput,
		Data:      payload,
	}, sender)

	errorFrame := sender.nextFrame(t, consoleFrameTypeError)
	if errorFrame.GetReason() != errProxmoxConsoleFrameMismatch.Error() {
		t.Fatalf("mismatched desktop reason = %q", errorFrame.GetReason())
	}

	select {
	case got := <-adapterSession.frames:
		t.Fatalf("unexpected desktop frame = %#v", got)
	default:
	}
}

func TestProxmoxConsoleManagerClosesDesktopSession(t *testing.T) {
	t.Parallel()

	target := testDesktopConsoleTarget(t)
	adapterSession := newFakeDesktopAdapterSession()
	manager := newProxmoxConsoleManagerWithAgentID(desktopConsoleAgentID, createTestLogger())
	manager.registerDesktopSession(desktopConsoleSessionID, target, adapterSession)
	sender := newFakeProxmoxConsoleSender()

	manager.HandleFrame(context.Background(), &proto.ConsoleFrame{
		SessionId: desktopConsoleSessionID,
		FrameType: consoleFrameTypeClose,
		Reason:    "operator closed desktop",
	}, sender)

	select {
	case got := <-adapterSession.closes:
		if got != "operator closed desktop" {
			t.Fatalf("desktop close reason = %q", got)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for desktop adapter close")
	}

	closeFrame := sender.nextFrame(t, consoleFrameTypeClose)
	if closeFrame.GetReason() != "operator closed desktop" {
		t.Fatalf("close frame reason = %q", closeFrame.GetReason())
	}

	payload := encodeDesktopConsoleFrame(t, target, remoteaccess.DesktopFrame{
		SessionID: desktopConsoleSessionID,
		Protocol:  remoteaccess.ProtocolRDP,
		FrameType: remoteaccess.DesktopFrameTypeQuality,
		Quality: &remoteaccess.DesktopQuality{
			MaxFrameRate: 24,
			MaxBitrate:   4_000_000,
			Width:        800,
			Height:       600,
		},
	})
	manager.HandleFrame(context.Background(), &proto.ConsoleFrame{
		SessionId: desktopConsoleSessionID,
		FrameType: remoteaccess.DesktopFrameTypeQuality,
		Data:      payload,
	}, sender)

	errorFrame := sender.nextFrame(t, consoleFrameTypeError)
	if errorFrame.GetReason() != errProxmoxConsoleSessionNotActive.Error() {
		t.Fatalf("post-close desktop reason = %q", errorFrame.GetReason())
	}
}

func testDesktopConsoleTarget(t *testing.T) remoteaccess.DesktopTarget {
	t.Helper()

	target, err := remoteaccess.NormalizeDesktopTarget(remoteaccess.DesktopTarget{
		TargetID: desktopConsoleTargetID,
		Route: remoteaccess.DesktopRoute{
			SelectedAgentID: desktopConsoleAgentID,
		},
		Upstream: remoteaccess.DesktopUpstream{
			Host: "rdp.example",
		},
		Credential: remoteaccess.DesktopCredentialPolicy{
			Mode:              remoteaccess.DesktopCredentialModeMemoryUser,
			AllowedPrincipals: []string{"alice"},
		},
		Screen: remoteaccess.DesktopScreenPolicy{
			MaxWidth:   1280,
			MaxHeight:  720,
			FrameRate:  30,
			BitrateBPS: 8_000_000,
		},
	})
	if err != nil {
		t.Fatalf("NormalizeDesktopTarget returned error: %v", err)
	}

	return target
}

func encodeDesktopConsoleFrame(
	t *testing.T,
	target remoteaccess.DesktopTarget,
	frame remoteaccess.DesktopFrame,
) []byte {
	t.Helper()

	payload, err := remoteaccess.EncodeDesktopFramePayloadWithPolicy(frame, target.Screen, target.Redirection)
	if err != nil {
		t.Fatalf("EncodeDesktopFramePayloadWithPolicy returned error: %v", err)
	}

	return payload
}

func encodeDesktopOpenPayload(t *testing.T, target remoteaccess.DesktopTarget) []byte {
	t.Helper()

	return encodeDesktopOpenPayloadWithGrant(t, target, nil)
}

func encodeDesktopOpenPayloadWithGrant(
	t *testing.T,
	target remoteaccess.DesktopTarget,
	grant *remoteaccess.DesktopCredentialGrant,
) []byte {
	t.Helper()

	payload, err := json.Marshal(remoteaccess.DesktopOpenPayload{
		Schema:  "serviceradar.desktop.open.v1",
		ActorID: "user-1",
		Metadata: map[string]string{
			"media_session_id": desktopConsoleMediaID,
			"route_id":         desktopConsoleAgentID,
			"lease_token":      desktopConsoleLeaseToken,
			"encoding_hint":    "srdp",
		},
		Target:          target,
		CredentialGrant: grant,
	})
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	return payload
}

func testDesktopConsoleCredentialGrant() *remoteaccess.DesktopCredentialGrant {
	return &remoteaccess.DesktopCredentialGrant{
		Mode:      remoteaccess.DesktopCredentialModeMemoryUser,
		Username:  "alice",
		Password:  "secret",
		ActorID:   "user-1",
		SessionID: desktopConsoleSessionID,
		TargetID:  desktopConsoleTargetID,
		RouteID:   desktopConsoleAgentID,
	}
}
