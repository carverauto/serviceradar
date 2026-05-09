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
	"errors"
	"io"
	"sync"
	"testing"
	"time"
)

const fakeCommand = "whoami\r"

var errFakeReadFailed = errors.New("pty read failed")

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

func TestManagerRoutesSessionFrames(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	pty := newFakePTY()
	manager := NewManager(func(_ context.Context, frame Frame) (PTY, error) {
		if frame.Protocol != "ssh" {
			t.Fatalf("protocol = %q, want ssh", frame.Protocol)
		}
		if frame.Cols != 120 || frame.Rows != 40 {
			t.Fatalf("open terminal size = %dx%d, want 120x40", frame.Cols, frame.Rows)
		}

		return pty, nil
	})
	sender := newFakeSender()

	manager.HandleFrame(ctx, Frame{
		SessionID: "remote-session-1",
		Protocol:  "ssh",
		FrameType: FrameTypeOpen,
		Cols:      120,
		Rows:      40,
	}, sender)

	ready := sender.nextFrame(t, FrameTypeReady)
	if ready.SessionID != "remote-session-1" {
		t.Fatalf("ready SessionID = %q", ready.SessionID)
	}
	if ready.Protocol != "ssh" {
		t.Fatalf("ready Protocol = %q, want ssh", ready.Protocol)
	}

	manager.HandleFrame(ctx, Frame{
		SessionID: "remote-session-1",
		Protocol:  "ssh",
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
		SessionID: "remote-session-1",
		Protocol:  "ssh",
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
		SessionID: "remote-session-1",
		Protocol:  "ssh",
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

	frame := Frame{SessionID: "remote-session-1", Protocol: "ssh", FrameType: FrameTypeOpen}
	manager.HandleFrame(context.Background(), frame, sender)
	_ = sender.nextFrame(t, FrameTypeReady)

	manager.HandleFrame(context.Background(), frame, sender)
	errorFrame := sender.nextFrame(t, FrameTypeError)
	if errorFrame.Reason != ErrSessionExists.Error() {
		t.Fatalf("duplicate open reason = %q", errorFrame.Reason)
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
		SessionID: "remote-session-1",
		Protocol:  "ssh",
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
		SessionID: "remote-session-1",
		Protocol:  "ssh",
		FrameType: FrameTypeHeartbeat,
		Metadata:  map[string]string{"sent_bytes": "12"},
	}, sender)

	heartbeat := sender.nextFrame(t, FrameTypeHeartbeat)
	if heartbeat.Metadata["sent_bytes"] != "12" {
		t.Fatalf("heartbeat metadata = %#v", heartbeat.Metadata)
	}
}
