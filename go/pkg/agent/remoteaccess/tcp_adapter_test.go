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
	"net"
	"strconv"
	"testing"
	"time"
)

func TestTCPAdapterWritesAndReadsBoundedConnection(t *testing.T) {
	t.Parallel()

	addr, closeServer := startTCPEchoServer(t)
	defer closeServer()

	open := tcpOpenPayloadForAddr(t, addr, map[string]any{
		"max_bytes_in":  64,
		"max_bytes_out": 64,
	})

	adapter, err := NewTCPAdapter(context.Background(), open, TCPAdapterOptions{})
	if err != nil {
		t.Fatalf("NewTCPAdapter returned error: %v", err)
	}
	defer func() { _ = adapter.Close() }()

	progress, err := adapter.Write(TCPDataPayload{
		SessionID:    "session-1",
		ConnectionID: "conn-1",
		Direction:    TCPDataDirectionClient,
		Sequence:     1,
		Data:         []byte("ping"),
	})
	if err != nil {
		t.Fatalf("Write returned error: %v", err)
	}
	if progress.BytesIn != 4 || progress.Status != TCPStatusInProgress {
		t.Fatalf("Write progress = %#v", progress)
	}

	frame, progress, err := adapter.Read(context.Background(), 1024)
	if err != nil {
		t.Fatalf("Read returned error: %v", err)
	}
	if frame.Direction != TCPDataDirectionUpstream || string(frame.Data) != "ping" || frame.Sequence != 1 {
		t.Fatalf("Read frame = %#v", frame)
	}
	if progress.BytesOut != 4 {
		t.Fatalf("Read progress = %#v", progress)
	}
}

func TestTCPAdapterRejectsDirectionAndQuotaViolations(t *testing.T) {
	t.Parallel()

	addr, closeServer := startTCPEchoServer(t)
	defer closeServer()

	adapter, err := NewTCPAdapter(context.Background(), tcpOpenPayloadForAddr(t, addr, map[string]any{
		"max_bytes_in": 3,
	}), TCPAdapterOptions{})
	if err != nil {
		t.Fatalf("NewTCPAdapter returned error: %v", err)
	}
	defer func() { _ = adapter.Close() }()

	_, err = adapter.Write(TCPDataPayload{
		SessionID:    "session-1",
		ConnectionID: "conn-1",
		Direction:    TCPDataDirectionUpstream,
		Sequence:     1,
		Data:         []byte("bad"),
	})
	if !errors.Is(err, ErrTCPDirectionNotAllowed) {
		t.Fatalf("Write upstream direction error = %v, want %v", err, ErrTCPDirectionNotAllowed)
	}

	_, err = adapter.Write(TCPDataPayload{
		SessionID:    "session-1",
		ConnectionID: "conn-1",
		Direction:    TCPDataDirectionClient,
		Sequence:     2,
		Data:         []byte("toolong"),
	})
	if !errors.Is(err, ErrTCPBytesInQuotaExceeded) {
		t.Fatalf("Write quota error = %v, want %v", err, ErrTCPBytesInQuotaExceeded)
	}
}

func TestTCPAdapterRejectsBindingAndSequenceViolations(t *testing.T) {
	t.Parallel()

	addr, closeServer := startTCPEchoServer(t)
	defer closeServer()

	adapter, err := NewTCPAdapter(context.Background(), tcpOpenPayloadForAddr(t, addr, map[string]any{
		"max_bytes_in": 64,
	}), TCPAdapterOptions{})
	if err != nil {
		t.Fatalf("NewTCPAdapter returned error: %v", err)
	}
	defer func() { _ = adapter.Close() }()

	_, err = adapter.Write(TCPDataPayload{
		SessionID:    "other-session",
		ConnectionID: "conn-1",
		Direction:    TCPDataDirectionClient,
		Sequence:     1,
		Data:         []byte("bad"),
	})
	if !errors.Is(err, ErrTCPSessionMismatch) {
		t.Fatalf("Write binding error = %v, want %v", err, ErrTCPSessionMismatch)
	}

	_, err = adapter.Write(TCPDataPayload{
		SessionID:    "session-1",
		ConnectionID: "conn-1",
		Direction:    TCPDataDirectionClient,
		Sequence:     1,
		Data:         []byte("ok"),
	})
	if err != nil {
		t.Fatalf("Write returned error: %v", err)
	}

	_, err = adapter.Write(TCPDataPayload{
		SessionID:    "session-1",
		ConnectionID: "conn-1",
		Direction:    TCPDataDirectionClient,
		Sequence:     1,
		Data:         []byte("replay"),
	})
	if !errors.Is(err, ErrTCPSequenceOutOfOrder) {
		t.Fatalf("Write sequence error = %v, want %v", err, ErrTCPSequenceOutOfOrder)
	}
}

func TestTCPAdapterEnforcesBytesOutQuota(t *testing.T) {
	t.Parallel()

	addr, closeServer := startTCPEchoServer(t)
	defer closeServer()

	adapter, err := NewTCPAdapter(context.Background(), tcpOpenPayloadForAddr(t, addr, map[string]any{
		"max_bytes_in":  64,
		"max_bytes_out": 3,
	}), TCPAdapterOptions{})
	if err != nil {
		t.Fatalf("NewTCPAdapter returned error: %v", err)
	}
	defer func() { _ = adapter.Close() }()

	_, err = adapter.Write(TCPDataPayload{
		SessionID:    "session-1",
		ConnectionID: "conn-1",
		Direction:    TCPDataDirectionClient,
		Sequence:     1,
		Data:         []byte("ping"),
	})
	if err != nil {
		t.Fatalf("Write returned error: %v", err)
	}

	_, _, err = adapter.Read(context.Background(), 1024)
	if !errors.Is(err, ErrTCPBytesOutQuotaExceeded) {
		t.Fatalf("Read quota error = %v, want %v", err, ErrTCPBytesOutQuotaExceeded)
	}
}

func TestTCPAdapterCapsIdleDeadlineAtAbsoluteTimeout(t *testing.T) {
	t.Parallel()

	client, server := net.Pipe()
	defer func() { _ = client.Close() }()
	defer func() { _ = server.Close() }()

	adapter := &TCPAdapter{
		open:             tcpOpenPayloadForAddr(t, "127.0.0.1:5432", nil),
		conn:             client,
		absoluteDeadline: time.Now().Add(25 * time.Millisecond),
	}
	adapter.open.IdleTimeoutSeconds = 30
	adapter.refreshDeadline()

	time.Sleep(50 * time.Millisecond)

	_, err := adapter.Write(TCPDataPayload{
		SessionID:    "session-1",
		ConnectionID: "conn-1",
		Direction:    TCPDataDirectionClient,
		Sequence:     1,
		Data:         []byte("expired"),
	})
	if err == nil {
		t.Fatal("expected write to fail after absolute deadline")
	}
}

func startTCPEchoServer(t *testing.T) (string, func()) {
	t.Helper()

	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen tcp: %v", err)
	}

	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer func() { _ = conn.Close() }()
				_, _ = io.Copy(conn, conn)
			}()
		}
	}()

	return listener.Addr().String(), func() {
		_ = listener.Close()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("tcp echo server did not stop")
		}
	}
}

func tcpOpenPayloadForAddr(t *testing.T, addr string, quota map[string]any) TCPOpenPayload {
	t.Helper()

	host, portText, err := net.SplitHostPort(addr)
	if err != nil {
		t.Fatalf("split host port: %v", err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		t.Fatalf("parse port: %v", err)
	}

	return TCPOpenPayload{
		TargetID:           "tcp-target-1",
		SessionID:          "session-1",
		ConnectionID:       "conn-1",
		UpstreamHost:       host,
		UpstreamPort:       port,
		IdleTimeoutSeconds: 30,
		QuotaPolicy:        quota,
	}
}
