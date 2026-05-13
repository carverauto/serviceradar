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
	"errors"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
	"github.com/carverauto/serviceradar/proto"
)

const fakeProxmoxConsoleCommand = "whoami\r"

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
