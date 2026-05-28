/*
 * Copyright 2026 Carver Automation Corporation.
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

package netprobe

import (
	"context"
	"errors"
	"net"
	"sync"
	"testing"
	"time"

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

func TestClientPingApplyConfigAndEvents(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer func() { _ = serverConn.Close() }()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		handleTestFrame(t, serverConn, func(frame *netprobepb.NetprobeFrame) *netprobepb.NetprobeFrame {
			ping := frame.GetPing()
			if ping == nil {
				t.Errorf("first frame payload = %T, want ping", frame.GetPayload())
				return errorResponse(frame.GetSequence(), "unexpected_frame", "expected ping")
			}
			return &netprobepb.NetprobeFrame{
				Sequence: frame.GetSequence(),
				Payload: &netprobepb.NetprobeFrame_PingAck{
					PingAck: &netprobepb.PingAck{
						SentAtUnixNano:           ping.GetSentAtUnixNano(),
						AckedAtUnixNano:          ping.GetSentAtUnixNano() + 1,
						FingerprintEngineVersion: "test-engine",
					},
				},
			}
		})
		handleTestFrame(t, serverConn, func(frame *netprobepb.NetprobeFrame) *netprobepb.NetprobeFrame {
			if frame.GetApplyConfig() == nil {
				t.Errorf("second frame payload = %T, want apply_config", frame.GetPayload())
				return errorResponse(frame.GetSequence(), "unexpected_frame", "expected apply_config")
			}
			return &netprobepb.NetprobeFrame{
				Sequence: frame.GetSequence(),
				Payload: &netprobepb.NetprobeFrame_ConfigAck{
					ConfigAck: &netprobepb.ConfigAck{ConfigHash: "hash-1"},
				},
			}
		})
		err := writeFrame(serverConn, &netprobepb.NetprobeFrame{
			Payload: &netprobepb.NetprobeFrame_FingerprintEvent{
				FingerprintEvent: &netprobepb.FingerprintEvent{Ip: "192.0.2.10"},
			},
		})
		if err != nil {
			t.Errorf("write event frame: %v", err)
		}
		err = writeFrame(serverConn, &netprobepb.NetprobeFrame{
			Payload: &netprobepb.NetprobeFrame_DpiEvent{
				DpiEvent: &netprobepb.DpiEvent{Protocol: "dns"},
			},
		})
		if err != nil {
			t.Errorf("write DPI event frame: %v", err)
		}
	}()

	client := NewClient(clientConn, 4)
	defer func() { _ = client.Close() }()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	if err := client.Ping(ctx); err != nil {
		t.Fatalf("Ping() error = %v", err)
	}
	if got := client.FingerprintEngineVersion(); got != "test-engine" {
		t.Fatalf("FingerprintEngineVersion() = %q, want test-engine", got)
	}

	hash, err := client.ApplyConfig(ctx, &netprobepb.VisibilityAgentConfig{
		Enabled:           true,
		CaptureInterfaces: []string{"en0"},
	})
	if err != nil {
		t.Fatalf("ApplyConfig() error = %v", err)
	}
	if hash != "hash-1" {
		t.Fatalf("ApplyConfig() hash = %q, want hash-1", hash)
	}

	select {
	case event := <-client.Events():
		if event.GetIp() != "192.0.2.10" {
			t.Fatalf("event IP = %q, want 192.0.2.10", event.GetIp())
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for fingerprint event")
	}
	select {
	case event := <-client.DpiEvents():
		if event.GetProtocol() != "dns" {
			t.Fatalf("DPI event protocol = %q, want dns", event.GetProtocol())
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for DPI event")
	}

	_ = client.Close()
	<-serverDone
}

func TestClientDropsDPIEventsOnBackpressure(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer func() { _ = serverConn.Close() }()

	recorder := &testEventDropRecorder{}
	client := NewClient(clientConn, 1, WithEventDropRecorder(recorder))
	defer func() { _ = client.Close() }()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		for i := 0; i < 2; i++ {
			err := writeFrame(serverConn, &netprobepb.NetprobeFrame{
				Payload: &netprobepb.NetprobeFrame_DpiEvent{
					DpiEvent: &netprobepb.DpiEvent{Protocol: "dns"},
				},
			})
			if err != nil {
				t.Errorf("write DPI event frame %d: %v", i, err)
				return
			}
		}
		handleTestFrame(t, serverConn, func(frame *netprobepb.NetprobeFrame) *netprobepb.NetprobeFrame {
			ping := frame.GetPing()
			if ping == nil {
				t.Errorf("frame payload = %T, want ping", frame.GetPayload())
				return errorResponse(frame.GetSequence(), "unexpected_frame", "expected ping")
			}
			return &netprobepb.NetprobeFrame{
				Sequence: frame.GetSequence(),
				Payload: &netprobepb.NetprobeFrame_PingAck{
					PingAck: &netprobepb.PingAck{SentAtUnixNano: ping.GetSentAtUnixNano()},
				},
			}
		})
	}()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	waitFor(t, ctx, func() bool {
		return client.DroppedDPIEvents() == 1
	})
	if err := client.Ping(ctx); err != nil {
		t.Fatalf("Ping() after backpressure error = %v", err)
	}

	select {
	case event := <-client.DpiEvents():
		if event.GetProtocol() != "dns" {
			t.Fatalf("queued DPI event protocol = %q, want dns", event.GetProtocol())
		}
	default:
		t.Fatal("expected first DPI event to remain queued")
	}

	if got := client.DroppedDPIEvents(); got != 1 {
		t.Fatalf("DroppedDPIEvents() = %d, want 1", got)
	}
	recorder.assertOne(t, EventStreamDPI, EventDropBackpressure)

	_ = client.Close()
	<-serverDone
}

func errorResponse(sequence uint64, code, message string) *netprobepb.NetprobeFrame {
	return &netprobepb.NetprobeFrame{
		Sequence: sequence,
		Payload: &netprobepb.NetprobeFrame_Error{
			Error: &netprobepb.ErrorFrame{Code: code, Message: message},
		},
	}
}

func TestClientReturnsErrorFrame(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer func() { _ = serverConn.Close() }()

	go handleTestFrame(t, serverConn, func(frame *netprobepb.NetprobeFrame) *netprobepb.NetprobeFrame {
		return &netprobepb.NetprobeFrame{
			Sequence: frame.GetSequence(),
			Payload: &netprobepb.NetprobeFrame_Error{
				Error: &netprobepb.ErrorFrame{Code: "invalid_config", Message: "bad config"},
			},
		}
	})

	client := NewClient(clientConn, 4)
	defer func() { _ = client.Close() }()

	_, err := client.ApplyConfig(context.Background(), &netprobepb.VisibilityAgentConfig{})
	var errorFrame ErrorFrame
	if !errors.As(err, &errorFrame) {
		t.Fatalf("ApplyConfig() error = %T %v, want ErrorFrame", err, err)
	}
	if errorFrame.Code != "invalid_config" {
		t.Fatalf("ErrorFrame.Code = %q, want invalid_config", errorFrame.Code)
	}
}

func TestClientDropsFingerprintEventsOnBackpressure(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer func() { _ = serverConn.Close() }()

	recorder := &testEventDropRecorder{}
	client := NewClient(clientConn, 1, WithEventDropRecorder(recorder))
	defer func() { _ = client.Close() }()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		for i := 0; i < 2; i++ {
			err := writeFrame(serverConn, &netprobepb.NetprobeFrame{
				Payload: &netprobepb.NetprobeFrame_FingerprintEvent{
					FingerprintEvent: &netprobepb.FingerprintEvent{Ip: "192.0.2.10"},
				},
			})
			if err != nil {
				t.Errorf("write event frame %d: %v", i, err)
				return
			}
		}
		handleTestFrame(t, serverConn, func(frame *netprobepb.NetprobeFrame) *netprobepb.NetprobeFrame {
			ping := frame.GetPing()
			if ping == nil {
				t.Errorf("frame payload = %T, want ping", frame.GetPayload())
				return errorResponse(frame.GetSequence(), "unexpected_frame", "expected ping")
			}
			return &netprobepb.NetprobeFrame{
				Sequence: frame.GetSequence(),
				Payload: &netprobepb.NetprobeFrame_PingAck{
					PingAck: &netprobepb.PingAck{SentAtUnixNano: ping.GetSentAtUnixNano()},
				},
			}
		})
	}()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	waitFor(t, ctx, func() bool {
		return client.DroppedFingerprintEvents() == 1
	})
	if err := client.Ping(ctx); err != nil {
		t.Fatalf("Ping() after backpressure error = %v", err)
	}

	select {
	case event := <-client.Events():
		if event.GetIp() != "192.0.2.10" {
			t.Fatalf("queued event IP = %q, want 192.0.2.10", event.GetIp())
		}
	default:
		t.Fatal("expected first fingerprint event to remain queued")
	}

	if got := client.DroppedFingerprintEvents(); got != 1 {
		t.Fatalf("DroppedFingerprintEvents() = %d, want 1", got)
	}
	recorder.assertOne(t, EventStreamFingerprint, EventDropBackpressure)

	_ = client.Close()
	<-serverDone
}

func TestClientCloseClosesEventsFromReadLoop(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer func() { _ = serverConn.Close() }()

	client := NewClient(clientConn, 4)
	_ = client.Close()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	select {
	case _, ok := <-client.Events():
		if ok {
			t.Fatal("Events() remained open after Close()")
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for Events() to close")
	}
}

func handleTestFrame(t *testing.T, conn net.Conn, handler func(*netprobepb.NetprobeFrame) *netprobepb.NetprobeFrame) {
	t.Helper()

	frame, err := readFrame(conn)
	if err != nil {
		t.Errorf("read test frame: %v", err)
		return
	}
	if err := writeFrame(conn, handler(frame)); err != nil {
		t.Errorf("write test response: %v", err)
	}
}

func waitFor(t *testing.T, ctx context.Context, ready func() bool) {
	t.Helper()

	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()

	for {
		if ready() {
			return
		}
		select {
		case <-ctx.Done():
			t.Fatalf("timed out waiting: %v", ctx.Err())
		case <-ticker.C:
		}
	}
}

type testEventDropRecorder struct {
	mu     sync.Mutex
	events []eventDrop
}

type eventDrop struct {
	stream string
	reason string
}

func (r *testEventDropRecorder) IncEventDrop(stream, reason string) {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.events = append(r.events, eventDrop{stream: stream, reason: reason})
}

func (r *testEventDropRecorder) assertOne(t *testing.T, stream, reason string) {
	t.Helper()
	r.mu.Lock()
	defer r.mu.Unlock()

	if len(r.events) != 1 {
		t.Fatalf("recorded event drops = %d, want 1", len(r.events))
	}
	if r.events[0].stream != stream || r.events[0].reason != reason {
		t.Fatalf("recorded event drop = (%q, %q), want (%q, %q)", r.events[0].stream, r.events[0].reason, stream, reason)
	}
}
