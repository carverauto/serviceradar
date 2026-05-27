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
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

const defaultEventBuffer = 1024

var (
	ErrClientClosed      = errors.New("netprobe client is closed")
	ErrUnexpectedFrame   = errors.New("netprobe returned unexpected frame")
	ErrEventBackpressure = errors.New("netprobe fingerprint event buffer is full")
)

type response struct {
	frame *netprobepb.NetprobeFrame
	err   error
}

// Client is a sequence-aware IPC client for the netprobe Unix socket protocol.
type Client struct {
	conn net.Conn

	writeMu sync.Mutex
	nextSeq atomic.Uint64

	pendingMu sync.Mutex
	pending   map[uint64]chan response

	events chan *netprobepb.FingerprintEvent
	done   chan struct{}

	closeOnce sync.Once
	closeErr  atomic.Value

	lastEngineVersion atomic.Value
}

// Dial connects to a netprobe Unix-domain socket and starts the read loop.
func Dial(ctx context.Context, socketPath string) (*Client, error) {
	var dialer net.Dialer
	conn, err := dialer.DialContext(ctx, "unix", socketPath)
	if err != nil {
		return nil, fmt.Errorf("dial netprobe socket: %w", err)
	}

	return NewClient(conn, defaultEventBuffer), nil
}

// NewClient wraps an already-connected net.Conn. It is exported for tests.
func NewClient(conn net.Conn, eventBuffer int) *Client {
	if eventBuffer <= 0 {
		eventBuffer = defaultEventBuffer
	}

	c := &Client{
		conn:    conn,
		pending: make(map[uint64]chan response),
		events:  make(chan *netprobepb.FingerprintEvent, eventBuffer),
		done:    make(chan struct{}),
	}
	go c.readLoop()

	return c
}

// Ping verifies the sidecar is responsive and records the engine version.
func (c *Client) Ping(ctx context.Context) error {
	now := time.Now().UnixNano()
	frame, err := c.request(ctx, &netprobepb.NetprobeFrame{
		Payload: &netprobepb.NetprobeFrame_Ping{
			Ping: &netprobepb.Ping{SentAtUnixNano: now},
		},
	})
	if err != nil {
		return err
	}

	ack := frame.GetPingAck()
	if ack == nil || ack.GetSentAtUnixNano() != now {
		return fmt.Errorf("%w: expected ping_ack", ErrUnexpectedFrame)
	}
	c.lastEngineVersion.Store(ack.GetFingerprintEngineVersion())

	return nil
}

// ApplyConfig sends a VisibilityAgentConfig and returns the acknowledged hash.
func (c *Client) ApplyConfig(ctx context.Context, cfg *netprobepb.VisibilityAgentConfig) (string, error) {
	frame, err := c.request(ctx, &netprobepb.NetprobeFrame{
		Payload: &netprobepb.NetprobeFrame_ApplyConfig{
			ApplyConfig: &netprobepb.ApplyConfig{Config: cfg},
		},
	})
	if err != nil {
		return "", err
	}

	ack := frame.GetConfigAck()
	if ack == nil {
		return "", fmt.Errorf("%w: expected config_ack", ErrUnexpectedFrame)
	}

	return ack.GetConfigHash(), nil
}

// Events returns the bounded stream of fingerprint events from netprobe.
func (c *Client) Events() <-chan *netprobepb.FingerprintEvent {
	return c.events
}

// DrainFingerprintEvents invokes handler for each streamed fingerprint event.
func (c *Client) DrainFingerprintEvents(ctx context.Context, handler func(context.Context, *netprobepb.FingerprintEvent) error) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case event, ok := <-c.events:
			if !ok {
				return c.closeError()
			}
			if err := handler(ctx, event); err != nil {
				return err
			}
		}
	}
}

// FingerprintEngineVersion returns the latest version observed from PingAck.
func (c *Client) FingerprintEngineVersion() string {
	value := c.lastEngineVersion.Load()
	if value == nil {
		return ""
	}
	version, _ := value.(string)

	return version
}

// Close closes the IPC connection and unblocks pending requests.
func (c *Client) Close() error {
	c.closeWithError(ErrClientClosed)
	return nil
}

func (c *Client) request(ctx context.Context, frame *netprobepb.NetprobeFrame) (*netprobepb.NetprobeFrame, error) {
	seq := c.nextSeq.Add(1)
	ch := make(chan response, 1)

	c.pendingMu.Lock()
	select {
	case <-c.done:
		c.pendingMu.Unlock()
		return nil, c.closeError()
	default:
		c.pending[seq] = ch
	}
	c.pendingMu.Unlock()

	frame.Sequence = seq
	if err := c.writeRequest(frame); err != nil {
		c.removePending(seq)
		return nil, err
	}

	select {
	case <-ctx.Done():
		c.removePending(seq)
		return nil, ctx.Err()
	case resp := <-ch:
		if resp.err != nil {
			return nil, resp.err
		}
		if errorFrame := resp.frame.GetError(); errorFrame != nil {
			return nil, ErrorFrame{
				Code:    errorFrame.GetCode(),
				Message: errorFrame.GetMessage(),
			}
		}
		return resp.frame, nil
	case <-c.done:
		c.removePending(seq)
		return nil, c.closeError()
	}
}

func (c *Client) writeRequest(frame *netprobepb.NetprobeFrame) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	select {
	case <-c.done:
		return c.closeError()
	default:
	}

	if err := writeFrame(c.conn, frame); err != nil {
		c.closeWithError(err)
		return err
	}

	return nil
}

func (c *Client) readLoop() {
	for {
		frame, err := readFrame(c.conn)
		if err != nil {
			if errors.Is(err, io.EOF) {
				err = ErrClientClosed
			}
			c.closeWithError(err)
			return
		}

		if frame.GetSequence() == 0 {
			if event := frame.GetFingerprintEvent(); event != nil {
				select {
				case c.events <- event:
				default:
					c.closeWithError(ErrEventBackpressure)
					return
				}
			}
			continue
		}

		c.pendingMu.Lock()
		ch := c.pending[frame.GetSequence()]
		delete(c.pending, frame.GetSequence())
		c.pendingMu.Unlock()

		if ch != nil {
			ch <- response{frame: frame}
		}
	}
}

func (c *Client) removePending(sequence uint64) {
	c.pendingMu.Lock()
	delete(c.pending, sequence)
	c.pendingMu.Unlock()
}

func (c *Client) closeWithError(err error) {
	c.closeOnce.Do(func() {
		if err == nil {
			err = ErrClientClosed
		}
		c.closeErr.Store(err)
		_ = c.conn.Close()

		c.pendingMu.Lock()
		for sequence, ch := range c.pending {
			delete(c.pending, sequence)
			ch <- response{err: err}
		}
		c.pendingMu.Unlock()

		close(c.events)
		close(c.done)
	})
}

func (c *Client) closeError() error {
	value := c.closeErr.Load()
	if value == nil {
		return ErrClientClosed
	}
	err, _ := value.(error)
	if err == nil {
		return ErrClientClosed
	}

	return err
}

// ErrorFrame is returned when netprobe responds with an ErrorFrame payload.
type ErrorFrame struct {
	Code    string
	Message string
}

func (e ErrorFrame) Error() string {
	if e.Code == "" {
		return e.Message
	}
	if e.Message == "" {
		return e.Code
	}

	return e.Code + ": " + e.Message
}
