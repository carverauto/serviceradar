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
	"io"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	fakeCommand         = "whoami\r"
	fakeRemoteSessionID = "remote-session-1"
)

var errFakeReadFailed = errors.New("pty read failed")
var errFakeOpenFailed = errors.New("pty open failed")

type fakeSender struct {
	mu     sync.Mutex
	frames []Frame
	ch     chan Frame
}

func newFakeSender() *fakeSender {
	return &fakeSender{ch: make(chan Frame, 16)}
}

func (f *fakeSender) SendFrame(frame Frame) error {
	f.mu.Lock()
	f.frames = append(f.frames, frame)
	f.mu.Unlock()

	f.ch <- frame

	return nil
}

func (f *fakeSender) nextFrame(t *testing.T, frameType string) Frame {
	t.Helper()

	deadline := time.After(time.Second)
	for {
		select {
		case frame := <-f.ch:
			if frame.FrameType == frameType {
				return frame
			}
		case <-deadline:
			t.Fatalf("timed out waiting for remote access frame type %q", frameType)
		}
	}
}

type fakeRead struct {
	data []byte
	err  error
}

type fakePTY struct {
	reads   chan fakeRead
	writes  chan []byte
	resizes chan [2]uint32
	closed  chan struct{}
	once    sync.Once
}

func newFakePTY() *fakePTY {
	return &fakePTY{
		reads:   make(chan fakeRead, 8),
		writes:  make(chan []byte, 8),
		resizes: make(chan [2]uint32, 8),
		closed:  make(chan struct{}),
	}
}

func (f *fakePTY) Read(ctx context.Context) ([]byte, error) {
	select {
	case read := <-f.reads:
		return read.data, read.err
	case <-f.closed:
		return nil, io.EOF
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (f *fakePTY) Write(data []byte) error {
	copied := append([]byte(nil), data...)
	f.writes <- copied

	return nil
}

func (f *fakePTY) Resize(cols, rows uint32) error {
	f.resizes <- [2]uint32{cols, rows}

	return nil
}

func (f *fakePTY) Close() error {
	f.once.Do(func() { close(f.closed) })

	return nil
}

type fakeEnhancedRecording struct {
	events chan EnhancedEvent
	stop   chan struct{}
	once   sync.Once
}

func newFakeEnhancedRecording() *fakeEnhancedRecording {
	return &fakeEnhancedRecording{
		events: make(chan EnhancedEvent, 8),
		stop:   make(chan struct{}),
	}
}

func (f *fakeEnhancedRecording) Events() <-chan EnhancedEvent {
	return f.events
}

func (f *fakeEnhancedRecording) Stop(context.Context) error {
	f.once.Do(func() { close(f.stop) })

	return nil
}

type fakeEnhancedRecorder struct {
	started chan EnhancedRecordingSession
	err     error
	current *fakeEnhancedRecording
}

func newFakeEnhancedRecorder(recording *fakeEnhancedRecording) *fakeEnhancedRecorder {
	return &fakeEnhancedRecorder{
		started: make(chan EnhancedRecordingSession, 1),
		current: recording,
	}
}

func (f *fakeEnhancedRecorder) Start(_ context.Context, session EnhancedRecordingSession) (EnhancedRecording, error) {
	f.started <- session
	if f.err != nil {
		return nil, f.err
	}
	return f.current, nil
}

func TestManagerRoutesSessionFrames(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	pty := newFakePTY()
	manager := NewManager(func(_ context.Context, frame Frame) (PTY, error) {
		if frame.Protocol != ProtocolSSH {
			t.Fatalf("protocol = %q, want ssh", frame.Protocol)
		}
		if frame.Cols != 120 || frame.Rows != 40 {
			t.Fatalf("open terminal size = %dx%d, want 120x40", frame.Cols, frame.Rows)
		}

		return pty, nil
	})
	sender := newFakeSender()

	manager.HandleFrame(ctx, Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeOpen,
		Cols:      120,
		Rows:      40,
	}, sender)

	ready := sender.nextFrame(t, FrameTypeReady)
	if ready.SessionID != fakeRemoteSessionID {
		t.Fatalf("ready SessionID = %q", ready.SessionID)
	}
	if ready.Protocol != ProtocolSSH {
		t.Fatalf("ready Protocol = %q, want ssh", ready.Protocol)
	}

	manager.HandleFrame(ctx, Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeData,
		Data:      []byte(fakeCommand),
	}, sender)

	select {
	case got := <-pty.writes:
		if string(got) != fakeCommand {
			t.Fatalf("PTY write = %q", string(got))
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for PTY write")
	}

	manager.HandleFrame(ctx, Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeResize,
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

	pty.reads <- fakeRead{data: []byte("root\r\n")}
	output := sender.nextFrame(t, FrameTypeData)
	if string(output.Data) != "root\r\n" {
		t.Fatalf("remote access output = %q", string(output.Data))
	}

	manager.HandleFrame(ctx, Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeClose,
		Reason:    "operator closed session",
	}, sender)

	closeFrame := sender.nextFrame(t, FrameTypeClose)
	if closeFrame.Reason != "operator closed session" {
		t.Fatalf("close reason = %q", closeFrame.Reason)
	}

	select {
	case <-pty.closed:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for PTY close")
	}
}

func TestManagerRejectsDuplicateOpen(t *testing.T) {
	t.Parallel()

	pty := newFakePTY()
	manager := NewManager(func(context.Context, Frame) (PTY, error) {
		return pty, nil
	})
	sender := newFakeSender()

	frame := Frame{SessionID: fakeRemoteSessionID, Protocol: ProtocolSSH, FrameType: FrameTypeOpen}
	manager.HandleFrame(context.Background(), frame, sender)
	_ = sender.nextFrame(t, FrameTypeReady)

	manager.HandleFrame(context.Background(), frame, sender)
	errorFrame := sender.nextFrame(t, FrameTypeError)
	if errorFrame.Reason != ErrSessionExists.Error() {
		t.Fatalf("duplicate open reason = %q", errorFrame.Reason)
	}
}

func TestManagerRejectsInvalidOpenTerminalSize(t *testing.T) {
	t.Parallel()

	openerCalled := false
	manager := NewManager(func(context.Context, Frame) (PTY, error) {
		openerCalled = true
		return newFakePTY(), nil
	})
	sender := newFakeSender()

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeOpen,
		Cols:      MaxTerminalCols + 1,
		Rows:      40,
	}, sender)

	errorFrame := sender.nextFrame(t, FrameTypeError)
	if errorFrame.Reason != ErrInvalidFrameSize.Error() {
		t.Fatalf("invalid open size reason = %q", errorFrame.Reason)
	}
	if openerCalled {
		t.Fatal("opener was called for invalid open terminal size")
	}
}

func TestManagerRejectsOversizedOpenPayloadBeforeOpener(t *testing.T) {
	t.Parallel()

	openerCalled := false
	manager := NewManager(func(context.Context, Frame) (PTY, error) {
		openerCalled = true
		return newFakePTY(), nil
	})
	sender := newFakeSender()

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeOpen,
		Data:      make([]byte, MaxOpenFrameData+1),
	}, sender)

	errorFrame := sender.nextFrame(t, FrameTypeError)
	if errorFrame.Reason != ErrInvalidFrameSize.Error() {
		t.Fatalf("oversized open payload reason = %q", errorFrame.Reason)
	}
	if openerCalled {
		t.Fatal("opener was called for oversized open payload")
	}
}

func TestManagerRejectsOversizedDataFrameBeforePTYWrite(t *testing.T) {
	t.Parallel()

	pty := newFakePTY()
	manager := NewManager(func(context.Context, Frame) (PTY, error) {
		return pty, nil
	})
	sender := newFakeSender()

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeOpen,
	}, sender)
	_ = sender.nextFrame(t, FrameTypeReady)

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeData,
		Data:      make([]byte, MaxTerminalFrameData+1),
	}, sender)

	errorFrame := sender.nextFrame(t, FrameTypeError)
	if errorFrame.Reason != ErrInvalidFrameSize.Error() {
		t.Fatalf("oversized data reason = %q", errorFrame.Reason)
	}
	closeFrame := sender.nextFrame(t, FrameTypeClose)
	if closeFrame.Reason != "remote access invalid frame size" {
		t.Fatalf("close reason = %q", closeFrame.Reason)
	}

	select {
	case got := <-pty.writes:
		t.Fatalf("oversized data reached PTY write: %d bytes", len(got))
	default:
	}
	select {
	case <-pty.closed:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for PTY close after oversized data")
	}
}

func TestManagerChunksOversizedPTYOutput(t *testing.T) {
	t.Parallel()

	pty := newFakePTY()
	manager := NewManager(func(context.Context, Frame) (PTY, error) {
		return pty, nil
	})
	sender := newFakeSender()

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeOpen,
	}, sender)
	_ = sender.nextFrame(t, FrameTypeReady)

	output := make([]byte, MaxTerminalFrameData+7)
	for i := range output {
		output[i] = byte(i % 251)
	}
	pty.reads <- fakeRead{data: output}

	first := sender.nextFrame(t, FrameTypeData)
	second := sender.nextFrame(t, FrameTypeData)
	if len(first.Data) != MaxTerminalFrameData {
		t.Fatalf("first output chunk size = %d", len(first.Data))
	}
	if len(second.Data) != 7 {
		t.Fatalf("second output chunk size = %d", len(second.Data))
	}
	reassembled := append(append([]byte(nil), first.Data...), second.Data...)
	if string(reassembled) != string(output) {
		t.Fatal("output chunks did not preserve payload")
	}
}

func TestManagerRejectsInvalidResizeBeforePTYResize(t *testing.T) {
	t.Parallel()

	pty := newFakePTY()
	manager := NewManager(func(context.Context, Frame) (PTY, error) {
		return pty, nil
	})
	sender := newFakeSender()

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeOpen,
	}, sender)
	_ = sender.nextFrame(t, FrameTypeReady)

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeResize,
		Cols:      MaxTerminalCols + 1,
		Rows:      30,
	}, sender)

	errorFrame := sender.nextFrame(t, FrameTypeError)
	if errorFrame.Reason != ErrInvalidFrameSize.Error() {
		t.Fatalf("invalid resize reason = %q", errorFrame.Reason)
	}
	_ = sender.nextFrame(t, FrameTypeClose)

	select {
	case got := <-pty.resizes:
		t.Fatalf("invalid resize reached PTY resize: %v", got)
	default:
	}
}

func TestManagerReportsReadFailure(t *testing.T) {
	t.Parallel()

	pty := newFakePTY()
	manager := NewManager(func(context.Context, Frame) (PTY, error) {
		return pty, nil
	})
	sender := newFakeSender()

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeOpen,
	}, sender)
	_ = sender.nextFrame(t, FrameTypeReady)

	pty.reads <- fakeRead{err: errFakeReadFailed}

	errorFrame := sender.nextFrame(t, FrameTypeError)
	if errorFrame.Reason != errFakeReadFailed.Error() {
		t.Fatalf("read failure reason = %q", errorFrame.Reason)
	}

	_ = sender.nextFrame(t, FrameTypeClose)
}

func TestManagerEchoesHeartbeat(t *testing.T) {
	t.Parallel()

	sender := newFakeSender()
	manager := NewManager(nil)

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeHeartbeat,
		Metadata:  map[string]string{"sent_bytes": "12"},
	}, sender)

	heartbeat := sender.nextFrame(t, FrameTypeHeartbeat)
	if heartbeat.Metadata["sent_bytes"] != "12" {
		t.Fatalf("heartbeat metadata = %#v", heartbeat.Metadata)
	}
}

func TestManagerFailsBeforeOpenWhenRequiredEnhancedRecordingUnavailable(t *testing.T) {
	t.Parallel()

	openerCalled := false
	manager := NewManagerWithConfig(ManagerConfig{
		Opener: func(context.Context, Frame) (PTY, error) {
			openerCalled = true
			return newFakePTY(), nil
		},
	})
	sender := newFakeSender()

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeOpen,
		Data: mustJSON(t, map[string]any{
			"protocol":              ProtocolSSH,
			"session_id":            fakeRemoteSessionID,
			"agent_id":              "agent-1",
			"target_execution_mode": EnhancedExecutionManagedTarget,
			"enhanced_recording_policy": map[string]any{
				"enabled":  true,
				"required": true,
				"mode":     "bpf",
			},
		}),
	}, sender)

	errorFrame := sender.nextFrame(t, FrameTypeError)
	if errorFrame.Reason != ErrEnhancedRecordingUnavailable.Error() {
		t.Fatalf("error reason = %q, want %q", errorFrame.Reason, ErrEnhancedRecordingUnavailable.Error())
	}
	if openerCalled {
		t.Fatal("target opener was called before required enhanced recording started")
	}
}

func TestManagerRejectsAgentlessSSHRequiredBPF(t *testing.T) {
	t.Parallel()

	openerCalled := false
	recording := newFakeEnhancedRecording()
	recorder := newFakeEnhancedRecorder(recording)
	manager := NewManagerWithConfig(ManagerConfig{
		Opener: func(context.Context, Frame) (PTY, error) {
			openerCalled = true
			return newFakePTY(), nil
		},
		EnhancedRecorder: recorder,
	})
	sender := newFakeSender()

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeOpen,
		Data: mustJSON(t, map[string]any{
			"protocol":   ProtocolSSH,
			"session_id": fakeRemoteSessionID,
			"enhanced_recording_policy": map[string]any{
				"enabled":  true,
				"required": true,
				"mode":     "bpf",
			},
		}),
	}, sender)

	errorFrame := sender.nextFrame(t, FrameTypeError)
	if errorFrame.Reason != ErrEnhancedRecordingTargetBoundaryRequired.Error() {
		t.Fatalf("error reason = %q, want %q", errorFrame.Reason, ErrEnhancedRecordingTargetBoundaryRequired.Error())
	}
	if openerCalled {
		t.Fatal("target opener was called for agentless SSH required BPF")
	}
	select {
	case started := <-recorder.started:
		t.Fatalf("enhanced recorder started for invalid boundary: %#v", started)
	default:
	}
}

func TestManagerAllowsOpenWhenEnhancedRecordingFallbackIsAllowed(t *testing.T) {
	t.Parallel()

	pty := newFakePTY()
	manager := NewManagerWithConfig(ManagerConfig{
		Opener: func(context.Context, Frame) (PTY, error) {
			return pty, nil
		},
	})
	sender := newFakeSender()

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeOpen,
		Data: mustJSON(t, map[string]any{
			"protocol":   ProtocolSSH,
			"session_id": fakeRemoteSessionID,
			"enhanced_recording_policy": map[string]any{
				"enabled":        true,
				"required":       true,
				"allow_fallback": true,
			},
		}),
	}, sender)

	ready := sender.nextFrame(t, FrameTypeReady)
	if ready.SessionID != fakeRemoteSessionID {
		t.Fatalf("ready session = %q", ready.SessionID)
	}

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		FrameType: FrameTypeClose,
	}, sender)
	_ = sender.nextFrame(t, FrameTypeClose)
}

func TestManagerAllowsOpenWhenEnhancedRecordingStartFailsAndFallbackIsAllowed(t *testing.T) {
	t.Parallel()

	recording := newFakeEnhancedRecording()
	recorder := newFakeEnhancedRecorder(recording)
	recorder.err = ErrEnhancedRecordingUnavailable
	pty := newFakePTY()
	manager := NewManagerWithConfig(ManagerConfig{
		Opener: func(context.Context, Frame) (PTY, error) {
			return pty, nil
		},
		EnhancedRecorder: recorder,
	})
	sender := newFakeSender()

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeOpen,
		Data: mustJSON(t, map[string]any{
			"enhanced_recording_policy": map[string]any{
				"enabled":        true,
				"required":       true,
				"mode":           "bpf",
				"allow_fallback": true,
			},
		}),
	}, sender)

	<-recorder.started
	ready := sender.nextFrame(t, FrameTypeReady)
	if ready.SessionID != fakeRemoteSessionID {
		t.Fatalf("ready session = %q", ready.SessionID)
	}

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		FrameType: FrameTypeClose,
	}, sender)
	_ = sender.nextFrame(t, FrameTypeClose)
}

func TestManagerEmitsNormalizedEnhancedRecordingEvents(t *testing.T) {
	t.Parallel()

	recording := newFakeEnhancedRecording()
	recorder := newFakeEnhancedRecorder(recording)
	pty := newFakePTY()
	manager := NewManagerWithConfig(ManagerConfig{
		Opener: func(context.Context, Frame) (PTY, error) {
			return pty, nil
		},
		EnhancedRecorder: recorder,
	})
	sender := newFakeSender()

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeOpen,
		Data: mustJSON(t, map[string]any{
			"protocol":        ProtocolSSH,
			"session_id":      fakeRemoteSessionID,
			"agent_id":        "agent-1",
			"gateway_id":      remoteAccessTestGatewayID,
			"credential_mode": "ssh_certificate",
			"target": map[string]any{
				"host": "router.example",
				"port": 22,
			},
			"enhanced_recording_policy": map[string]any{
				"enabled":                   true,
				"mode":                      "bpf",
				"include_command_arguments": false,
			},
		}),
	}, sender)

	started := <-recorder.started
	if started.SessionID != fakeRemoteSessionID || started.AgentID != "agent-1" {
		t.Fatalf("enhanced session = %#v", started)
	}
	if started.Target["host"] != enhancedTestRouterHost || started.Target["port"] != "22" {
		t.Fatalf("enhanced target = %#v", started.Target)
	}

	_ = sender.nextFrame(t, FrameTypeReady)

	recording.events <- EnhancedEvent{
		EventType:   EnhancedEventCommand,
		CommandPath: "/usr/bin/sudo",
		Argv:        []string{"sudo", "--password", "secret-value"},
		PID:         123,
		UID:         1000,
	}

	eventFrame := sender.nextFrame(t, FrameTypeEnhancedEvent)
	var event EnhancedEvent
	if err := json.Unmarshal(eventFrame.Data, &event); err != nil {
		t.Fatalf("decode enhanced event: %v", err)
	}

	if event.SessionID != fakeRemoteSessionID || event.AgentID != "agent-1" {
		t.Fatalf("event identity = %#v", event)
	}
	if event.CredentialCustodyMode != "ssh_certificate" {
		t.Fatalf("credential custody = %q", event.CredentialCustodyMode)
	}
	if len(event.Argv) != 0 {
		t.Fatalf("argv should be omitted by policy, got %#v", event.Argv)
	}
	if strings.Contains(string(eventFrame.Data), "secret-value") {
		t.Fatalf("enhanced event leaked argument secret: %s", string(eventFrame.Data))
	}

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		FrameType: FrameTypeClose,
	}, sender)
	_ = sender.nextFrame(t, FrameTypeClose)

	select {
	case <-recording.stop:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for enhanced recording stop")
	}
}

func TestManagerStopsEnhancedRecordingWhenOpenFails(t *testing.T) {
	t.Parallel()

	recording := newFakeEnhancedRecording()
	recorder := newFakeEnhancedRecorder(recording)
	manager := NewManagerWithConfig(ManagerConfig{
		Opener: func(context.Context, Frame) (PTY, error) {
			return nil, errFakeOpenFailed
		},
		EnhancedRecorder: recorder,
	})
	sender := newFakeSender()

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeOpen,
		Data: mustJSON(t, map[string]any{
			"enhanced_recording_policy": map[string]any{
				"enabled": true,
				"mode":    "bpf",
			},
		}),
	}, sender)

	<-recorder.started
	errorFrame := sender.nextFrame(t, FrameTypeError)
	if errorFrame.Reason != errFakeOpenFailed.Error() {
		t.Fatalf("open failure reason = %q", errorFrame.Reason)
	}

	select {
	case <-recording.stop:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for enhanced recording stop after open failure")
	}
}

func TestManagerStopsSessionWhenContextIsCanceled(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	recording := newFakeEnhancedRecording()
	recorder := newFakeEnhancedRecorder(recording)
	pty := newFakePTY()
	manager := NewManagerWithConfig(ManagerConfig{
		Opener: func(context.Context, Frame) (PTY, error) {
			return pty, nil
		},
		EnhancedRecorder: recorder,
	})
	sender := newFakeSender()

	manager.HandleFrame(ctx, Frame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeOpen,
		Data: mustJSON(t, map[string]any{
			"enhanced_recording_policy": map[string]any{
				"enabled": true,
				"mode":    "bpf",
			},
		}),
	}, sender)

	<-recorder.started
	_ = sender.nextFrame(t, FrameTypeReady)
	cancel()

	closeFrame := sender.nextFrame(t, FrameTypeClose)
	if closeFrame.Reason != context.Canceled.Error() {
		t.Fatalf("context close reason = %q", closeFrame.Reason)
	}

	select {
	case <-recording.stop:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for enhanced recording stop after context cancel")
	}
	select {
	case <-pty.closed:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for PTY close after context cancel")
	}

	manager.HandleFrame(context.Background(), Frame{
		SessionID: fakeRemoteSessionID,
		FrameType: FrameTypeData,
		Data:      []byte(fakeCommand),
	}, sender)
	errorFrame := sender.nextFrame(t, FrameTypeError)
	if errorFrame.Reason != ErrSessionNotActive.Error() {
		t.Fatalf("post-cancel write reason = %q", errorFrame.Reason)
	}
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()

	data, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal json: %v", err)
	}

	return data
}
