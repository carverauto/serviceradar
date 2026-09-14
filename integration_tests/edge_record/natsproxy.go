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
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"sync"
	"time"
)

// natsproxy.go puts a transparent TCP relay between the gateway release and
// the embedded broker, so Groups E and F can hold a real publish request IN
// FLIGHT.
//
// Both groups make claims about a request that is still outstanding: a
// replacement transport must not reopen the capacity it holds (E), and a
// retry must be refused while it is un-fenced (F). Against a healthy local
// broker a JetStream PubAck returns in milliseconds, so no observation can
// land inside that window. Withholding the broker's bytes does: the publish
// still reaches JetStream, but the PubAck never reaches the gateway, so the
// request stays outstanding until its owner's own receive timeout ends it.
// That is the broker-ambiguous case the accountant's fencing exists for.
//
// Only the broker-to-client direction is gated, and only for connections
// that exist when StallServerToClient is called. A connection opened during
// a stall relays normally, so a replacement transport generation can come
// up while the old generation's requests are still held.
//
// A NATS client pings every ten seconds (Gnat's default ping_interval) and
// closes a connection that has not answered by the next ping, so a stall
// must stay well under that or it becomes a connection failure instead.

var errNATSProxyUpstreamURL = errors.New("verticalslice: nats proxy upstream URL has no host")

// natsProxyDialTimeout bounds how long an accepted client waits for the
// broker. The broker is on loopback, so a refusal is immediate; the bound
// only matters if the dial hangs.
const natsProxyDialTimeout = 2 * time.Second

// NATSProxy relays client connections to one upstream broker address.
type NATSProxy struct {
	// URL is the nats:// URL a client dials instead of the broker's own.
	URL string

	upstream string
	ln       net.Listener

	mu     sync.Mutex
	conns  map[*proxyConn]struct{}
	closed bool

	wg sync.WaitGroup
}

type proxyConn struct {
	client net.Conn
	server net.Conn

	// fromServer gates broker-to-client bytes.
	fromServer *relayGate

	done      chan struct{}
	closeOnce sync.Once
}

func (c *proxyConn) close() {
	c.closeOnce.Do(func() {
		close(c.done)
		_ = c.client.Close()
		_ = c.server.Close()
	})
}

// relayGate is open while its channel is closed. Pausing swaps in a fresh,
// open channel; waiters block on it until resume closes it.
type relayGate struct {
	mu   sync.Mutex
	open chan struct{}
}

func newOpenRelayGate() *relayGate {
	ch := make(chan struct{})
	close(ch)
	return &relayGate{open: ch}
}

func (g *relayGate) pause() {
	g.mu.Lock()
	defer g.mu.Unlock()
	select {
	case <-g.open:
		g.open = make(chan struct{})
	default: // already paused
	}
}

func (g *relayGate) resume() {
	g.mu.Lock()
	defer g.mu.Unlock()
	select {
	case <-g.open: // already open
	default:
		close(g.open)
	}
}

// wait blocks until the gate is open (true) or the connection is gone
// (false).
func (g *relayGate) wait(done <-chan struct{}) bool {
	g.mu.Lock()
	ch := g.open
	g.mu.Unlock()
	select {
	case <-ch:
		return true
	case <-done:
		return false
	}
}

// StartNATSProxy listens on a fresh loopback port and relays every accepted
// connection to upstreamURL's host. A connection accepted while the broker is
// down is closed at once, which a NATS client handles like a refused connect.
func StartNATSProxy(upstreamURL string) (*NATSProxy, error) {
	u, err := url.Parse(upstreamURL)
	if err != nil {
		return nil, fmt.Errorf("verticalslice: parse nats proxy upstream URL: %w", err)
	}
	if u.Host == "" {
		return nil, errNATSProxyUpstreamURL
	}

	ln, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("verticalslice: nats proxy listen: %w", err)
	}

	p := &NATSProxy{
		URL:      "nats://" + ln.Addr().String(),
		upstream: u.Host,
		ln:       ln,
		conns:    make(map[*proxyConn]struct{}),
	}
	p.wg.Add(1)
	go p.acceptLoop()
	return p, nil
}

func (p *NATSProxy) acceptLoop() {
	defer p.wg.Done()
	dialer := &net.Dialer{Timeout: natsProxyDialTimeout}
	for {
		client, err := p.ln.Accept()
		if err != nil {
			return // listener closed
		}

		server, err := dialer.DialContext(context.Background(), "tcp", p.upstream)
		if err != nil {
			_ = client.Close()
			continue
		}

		pc := &proxyConn{
			client:     client,
			server:     server,
			fromServer: newOpenRelayGate(),
			done:       make(chan struct{}),
		}

		p.mu.Lock()
		if p.closed {
			p.mu.Unlock()
			pc.close()
			return
		}
		p.conns[pc] = struct{}{}
		p.wg.Add(2)
		p.mu.Unlock()

		go p.relay(pc, pc.server, pc.client, nil)
		go p.relay(pc, pc.client, pc.server, pc.fromServer)
	}
}

// relay copies src to dst until either side fails, holding each chunk at
// gate (when non-nil) before writing it. Ending either direction closes the
// whole connection, so a broker that goes away closes its clients too.
func (p *NATSProxy) relay(pc *proxyConn, dst io.Writer, src io.Reader, gate *relayGate) {
	defer p.wg.Done()
	defer p.forget(pc)

	buf := make([]byte, 32*1024)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			if gate != nil && !gate.wait(pc.done) {
				return
			}
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

func (p *NATSProxy) forget(pc *proxyConn) {
	pc.close()
	p.mu.Lock()
	delete(p.conns, pc)
	p.mu.Unlock()
}

// StallServerToClient withholds broker-to-client bytes on every connection
// open right now, and returns how many that is. Client-to-broker bytes keep
// flowing, and connections opened afterwards are not stalled.
func (p *NATSProxy) StallServerToClient() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	for pc := range p.conns {
		pc.fromServer.pause()
	}
	return len(p.conns)
}

// Resume releases every stalled connection, delivering what was withheld in
// order. Resuming a proxy that is not stalled does nothing.
func (p *NATSProxy) Resume() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for pc := range p.conns {
		pc.fromServer.resume()
	}
}

// Close stops accepting, closes every relayed connection, and waits for the
// relay goroutines to finish.
func (p *NATSProxy) Close() {
	if p == nil {
		return
	}
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	p.closed = true
	_ = p.ln.Close()
	for pc := range p.conns {
		pc.close()
	}
	p.mu.Unlock()
	p.wg.Wait()
}
