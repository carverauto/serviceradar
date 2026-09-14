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

package verticalslice

import (
	"bufio"
	"context"
	"errors"
	"net"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// lineEchoBroker is a stand-in upstream: it greets each connection with
// "HELLO", answers every line with "ACK <line>", and reports each line it
// received on lines, so a test can tell "withheld from the client" apart from
// "never reached the broker".
type lineEchoBroker struct {
	ln    net.Listener
	lines chan string

	mu    sync.Mutex
	conns []net.Conn
}

// goAway stops accepting and drops every connection, as a broker shutdown
// does.
func (b *lineEchoBroker) goAway() {
	_ = b.ln.Close()
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, c := range b.conns {
		_ = c.Close()
	}
}

func startLineEchoBroker(t *testing.T) *lineEchoBroker {
	t.Helper()
	ln, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	b := &lineEchoBroker{ln: ln, lines: make(chan string, 16)}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			b.mu.Lock()
			b.conns = append(b.conns, conn)
			b.mu.Unlock()
			go func(conn net.Conn) {
				defer func() { _ = conn.Close() }()
				if _, err := conn.Write([]byte("HELLO\n")); err != nil {
					return
				}
				r := bufio.NewReader(conn)
				for {
					line, err := r.ReadString('\n')
					if err != nil {
						return
					}
					line = strings.TrimSpace(line)
					b.lines <- line
					if _, err := conn.Write([]byte("ACK " + line + "\n")); err != nil {
						return
					}
				}
			}(conn)
		}
	}()
	t.Cleanup(b.goAway)
	return b
}

func (b *lineEchoBroker) url() string { return "nats://" + b.ln.Addr().String() }

type proxyClient struct {
	conn net.Conn
	r    *bufio.Reader
}

func dialProxy(t *testing.T, p *NATSProxy) *proxyClient {
	t.Helper()
	conn, err := (&net.Dialer{}).DialContext(context.Background(), "tcp", strings.TrimPrefix(p.URL, "nats://"))
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return &proxyClient{conn: conn, r: bufio.NewReader(conn)}
}

func (c *proxyClient) readLine(timeout time.Duration) (string, error) {
	_ = c.conn.SetReadDeadline(time.Now().Add(timeout))
	line, err := c.r.ReadString('\n')
	return strings.TrimSpace(line), err
}

func (c *proxyClient) send(t *testing.T, line string) {
	t.Helper()
	if _, err := c.conn.Write([]byte(line + "\n")); err != nil {
		t.Fatalf("write %q: %v", line, err)
	}
}

func expectBrokerLine(t *testing.T, b *lineEchoBroker, want string) {
	t.Helper()
	select {
	case got := <-b.lines:
		if got != want {
			t.Fatalf("broker received %q, want %q", got, want)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("broker never received %q", want)
	}
}

// TestNATSProxyStallWithholdsOnlyBrokerBytes proves the property Groups E and
// F depend on, and that the check can fail: while stalled, a client's bytes
// still reach the broker but the broker's answer does not come back, and it
// arrives intact once resumed.
func TestNATSProxyStallWithholdsOnlyBrokerBytes(t *testing.T) {
	broker := startLineEchoBroker(t)
	p, err := StartNATSProxy(broker.url())
	if err != nil {
		t.Fatalf("StartNATSProxy: %v", err)
	}
	t.Cleanup(p.Close)

	c := dialProxy(t, p)
	if got, err := c.readLine(2 * time.Second); err != nil || got != "HELLO" {
		t.Fatalf("greeting = %q, %v", got, err)
	}
	c.send(t, "one")
	expectBrokerLine(t, broker, "one")
	if got, err := c.readLine(2 * time.Second); err != nil || got != "ACK one" {
		t.Fatalf("unstalled answer = %q, %v", got, err)
	}

	if n := p.StallServerToClient(); n != 1 {
		t.Fatalf("StallServerToClient stalled %d connections, want 1", n)
	}
	c.send(t, "two")
	expectBrokerLine(t, broker, "two")

	got, err := c.readLine(300 * time.Millisecond)
	var netErr net.Error
	if !errors.As(err, &netErr) || !netErr.Timeout() {
		t.Fatalf("stalled read returned %q, %v; want a timeout with nothing delivered", got, err)
	}

	p.Resume()
	if got, err := c.readLine(2 * time.Second); err != nil || got != "ACK two" {
		t.Fatalf("answer withheld by the stall = %q, %v after Resume; want \"ACK two\"", got, err)
	}
}

// TestNATSProxyStallSparesNewConnections: a connection opened during a stall
// relays normally, which is what lets a replacement transport connect while
// the previous generation's requests are held.
func TestNATSProxyStallSparesNewConnections(t *testing.T) {
	broker := startLineEchoBroker(t)
	p, err := StartNATSProxy(broker.url())
	if err != nil {
		t.Fatalf("StartNATSProxy: %v", err)
	}
	t.Cleanup(p.Close)

	old := dialProxy(t, p)
	if _, err := old.readLine(2 * time.Second); err != nil {
		t.Fatalf("old greeting: %v", err)
	}
	p.StallServerToClient()

	fresh := dialProxy(t, p)
	if got, err := fresh.readLine(2 * time.Second); err != nil || got != "HELLO" {
		t.Fatalf("connection opened during the stall got %q, %v; want its greeting", got, err)
	}
	fresh.send(t, "fresh")
	expectBrokerLine(t, broker, "fresh")
	if got, err := fresh.readLine(2 * time.Second); err != nil || got != "ACK fresh" {
		t.Fatalf("connection opened during the stall answered %q, %v", got, err)
	}
}

// TestNATSProxyFollowsTheBroker: a broker that goes away closes its relayed
// clients -- even a stalled one -- a client accepted while it is away is
// closed at once, and Close returns with a stalled connection open.
func TestNATSProxyFollowsTheBroker(t *testing.T) {
	broker := startLineEchoBroker(t)
	p, err := StartNATSProxy(broker.url())
	if err != nil {
		t.Fatalf("StartNATSProxy: %v", err)
	}

	gone := dialProxy(t, p)
	if _, err := gone.readLine(2 * time.Second); err != nil {
		t.Fatalf("greeting: %v", err)
	}
	p.StallServerToClient()

	broker.goAway()
	if got, err := gone.readLine(2 * time.Second); err == nil {
		t.Fatalf("stalled client read %q after the broker went away; want the connection closed", got)
	} else if errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatal("stalled client was left open after the broker went away")
	}

	late := dialProxy(t, p)
	if got, err := late.readLine(2 * time.Second); err == nil {
		t.Fatalf("client accepted with the broker down read %q; want the connection closed", got)
	} else if errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("client accepted with the broker down was left open")
	}

	closed := make(chan struct{})
	go func() {
		p.Close()
		close(closed)
	}()
	select {
	case <-closed:
	case <-time.After(5 * time.Second):
		t.Fatal("Close did not return")
	}
}

// TestNATSProxyCloseReleasesStalledConnections: Close returns, and closes the
// client, while a connection is stalled against a live broker.
func TestNATSProxyCloseReleasesStalledConnections(t *testing.T) {
	broker := startLineEchoBroker(t)
	p, err := StartNATSProxy(broker.url())
	if err != nil {
		t.Fatalf("StartNATSProxy: %v", err)
	}

	c := dialProxy(t, p)
	if _, err := c.readLine(2 * time.Second); err != nil {
		t.Fatalf("greeting: %v", err)
	}
	p.StallServerToClient()
	c.send(t, "held")
	expectBrokerLine(t, broker, "held")

	closed := make(chan struct{})
	go func() {
		p.Close()
		close(closed)
	}()
	select {
	case <-closed:
	case <-time.After(5 * time.Second):
		t.Fatal("Close did not return with a stalled connection open")
	}
	if got, err := c.readLine(2 * time.Second); err == nil {
		t.Fatalf("stalled client read %q after Close; want the connection closed", got)
	} else if errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatal("stalled client was left open after Close")
	}
}
