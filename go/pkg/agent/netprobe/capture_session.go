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
	"sync"
	"time"

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

// EventStreamCapture names the capture stream in drop metrics. It should never
// appear with EventDropBackpressure: a dropped pcapng block is not a degraded
// capture, it is a corrupt one, so the capture path aborts instead of dropping.
const EventStreamCapture = "capture"

// EventDropStalledConsumer marks a capture aborted because its consumer did not
// take a block within CaptureBlockTimeout.
const EventDropStalledConsumer = "stalled_consumer"

// CaptureBlockTimeout bounds how long the shared read loop will wait for a
// capture consumer before abandoning the session.
//
// The bound exists because this stream cannot use the `default: drop` that
// every other arm in the read loop uses. A dropped fingerprint event is a
// missing observation; a dropped pcapng block is UNDETECTABLE corruption --
// the file still parses, and nothing distinguishes a packet the filter excluded
// from one that vanished in transit.
//
// Blocking forever is not the alternative, because the read loop is shared:
// stalling it would also stop fingerprint, DPI, flow-attribution and census
// delivery, so one wedged capture consumer would silently degrade every other
// netprobe stream. Two seconds is long enough that ordinary gateway
// backpressure rides through it and short enough that a genuinely wedged
// consumer is not mistaken for a quiet interface.
const CaptureBlockTimeout = 2 * time.Second

// captureQueueDepth is how many blocks may sit between the read loop and the
// forwarder before the read loop starts waiting.
//
// Deliberately shallow. A deep queue would let the agent absorb a slow gateway
// for a while and then abort anyway, having hidden the growing lag the whole
// time; a shallow one turns the same condition into visible backpressure that
// reaches netprobe, fills the kernel ring, and is REPORTED as a drop count on
// the terminal block. An honest drop count beats a hidden delay.
const captureQueueDepth = 8

var (
	// ErrCaptureSessionExists guards the session id, not the interface:
	// netprobe already refuses a second capture, and this catches the earlier,
	// more confusing case of the same session being started twice by the agent.
	ErrCaptureSessionExists = errors.New("netprobe capture session already registered")

	// ErrCaptureConsumerStalled ends a session whose consumer stopped reading.
	// Surfaced rather than swallowed: upstream must record the capture as
	// incomplete instead of presenting a truncated file as a whole one.
	ErrCaptureConsumerStalled = errors.New("netprobe capture consumer did not accept a block in time")

	// ErrCaptureRejected reports netprobe's own refusal, carrying its stable
	// code so a caller can distinguish an allowlist denial from a bad filter.
	ErrCaptureRejected = errors.New("netprobe refused the capture request")
)

// captureSink is the read loop's half of one session.
type captureSink struct {
	blocks chan *netprobepb.PcapngBlock
	// Closed once, by whichever side ends the session first.
	done     chan struct{}
	doneOnce sync.Once
	// Set before done is closed, so a reader always sees a reason.
	failure error
	failMu  sync.Mutex
}

func (s *captureSink) fail(err error) {
	s.failMu.Lock()
	if s.failure == nil {
		s.failure = err
	}
	s.failMu.Unlock()
	s.close()
}

func (s *captureSink) err() error {
	s.failMu.Lock()
	defer s.failMu.Unlock()

	return s.failure
}

func (s *captureSink) close() {
	s.doneOnce.Do(func() { close(s.done) })
}

// CaptureStream delivers one session's pcapng blocks in order.
//
// Ordering is the read loop's, which is netprobe's, which is the ring's. No hop
// reorders or re-encodes, so the concatenation of Block bytes is the pcapng
// file.
type CaptureStream struct {
	sessionID string
	sink      *captureSink
	client    *Client
	closeOnce sync.Once
}

// SessionID is the core-issued ULID this stream belongs to.
func (s *CaptureStream) SessionID() string { return s.sessionID }

// Next returns the next pcapng block.
//
// It returns a nil block and a nil error exactly once, when the session ended
// normally after its terminal block. Any other nil block carries the reason.
func (s *CaptureStream) Next(ctx context.Context) (*netprobepb.PcapngBlock, error) {
	select {
	case block, ok := <-s.sink.blocks:
		if !ok {
			return nil, s.sink.err()
		}

		return block, nil
	case <-s.sink.done:
		// Drain anything already queued before reporting the end, so a session
		// that ends promptly does not lose its last blocks -- including the
		// terminal one, which carries the counters.
		select {
		case block, ok := <-s.sink.blocks:
			if ok {
				return block, nil
			}
		default:
		}

		return nil, s.sink.err()
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// Close unregisters the session. Safe to call more than once.
//
// It does NOT stop the capture inside netprobe; that happens when the IPC
// connection drops or when a cap fires. A caller that wants the capture stopped
// asks netprobe, and the terminal block is what confirms it.
func (s *CaptureStream) Close() {
	s.closeOnce.Do(func() {
		s.sink.close()
		s.client.removeCaptureSession(s.sessionID)
	})
}

// StartCapture asks netprobe to begin a capture and returns its stream.
//
// The sink is registered BEFORE the request goes out, because netprobe may
// begin streaming blocks the moment it accepts: registering afterwards would
// race, and the blocks that lost the race would land in the unhandled-arm
// branch and be counted as a version skew rather than as the bug they are.
func (c *Client) StartCapture(
	ctx context.Context, request *netprobepb.StartRemoteCapture,
) (*CaptureStream, *netprobepb.PcapngBlock, error) {
	if request == nil || request.GetSessionId() == "" {
		return nil, nil, fmt.Errorf("%w: no session id", ErrCaptureRejected)
	}

	sink := &captureSink{
		blocks: make(chan *netprobepb.PcapngBlock, captureQueueDepth),
		done:   make(chan struct{}),
	}

	if err := c.addCaptureSession(request.GetSessionId(), sink); err != nil {
		return nil, nil, err
	}

	frame, err := c.request(ctx, &netprobepb.NetprobeFrame{
		Payload: &netprobepb.NetprobeFrame_StartRemoteCapture{StartRemoteCapture: request},
	})
	if err != nil {
		c.removeCaptureSession(request.GetSessionId())

		var errorFrame ErrorFrame
		if errors.As(err, &errorFrame) {
			// netprobe's refusal codes are stable and its messages name the
			// offending value; both are worth keeping, because "denied" and
			// "your filter does not compile" need different operator actions.
			return nil, nil, fmt.Errorf("%w (%s): %s",
				ErrCaptureRejected, errorFrame.Code, errorFrame.Message)
		}

		return nil, nil, err
	}

	header := frame.GetPcapngBlock()
	if header == nil {
		c.removeCaptureSession(request.GetSessionId())

		return nil, nil, fmt.Errorf("%w: expected a pcapng header, got %T",
			ErrUnexpectedFrame, frame.GetPayload())
	}

	return &CaptureStream{sessionID: request.GetSessionId(), sink: sink, client: c}, header, nil
}

func (c *Client) addCaptureSession(sessionID string, sink *captureSink) error {
	c.captureMu.Lock()
	defer c.captureMu.Unlock()

	if c.captureSessions == nil {
		c.captureSessions = make(map[string]*captureSink)
	}

	if _, exists := c.captureSessions[sessionID]; exists {
		return fmt.Errorf("%w: %s", ErrCaptureSessionExists, sessionID)
	}

	c.captureSessions[sessionID] = sink

	return nil
}

// ActiveCaptureCount returns the number of capture sessions currently registered
// with this IPC client. It deliberately exposes only a count: session identifiers,
// filters, and actors belong in the authorized audit surface, not the broadly
// reported agent status payload.
func (c *Client) ActiveCaptureCount() int {
	c.captureMu.Lock()
	defer c.captureMu.Unlock()

	return len(c.captureSessions)
}

func (c *Client) removeCaptureSession(sessionID string) {
	c.captureMu.Lock()
	sink := c.captureSessions[sessionID]
	delete(c.captureSessions, sessionID)
	c.captureMu.Unlock()

	if sink != nil {
		sink.close()
	}
}

func (c *Client) lookupCaptureSession(sessionID string) *captureSink {
	c.captureMu.Lock()
	defer c.captureMu.Unlock()

	return c.captureSessions[sessionID]
}

// routeCaptureBlock delivers one block to its session, or ends that session.
//
// Called from the read loop, so it must not block indefinitely -- see
// CaptureBlockTimeout. It returns whether the frame belonged to a live session,
// so an unrouted block still reaches the unhandled-arm branch: a pcapng block
// for a session this agent does not know about is a real anomaly, and silently
// discarding it is how "the capture produced nothing" becomes unexplainable.
func (c *Client) routeCaptureBlock(block *netprobepb.PcapngBlock) bool {
	sink := c.lookupCaptureSession(block.GetSessionId())
	if sink == nil {
		return false
	}

	timer := time.NewTimer(CaptureBlockTimeout)
	defer timer.Stop()

	select {
	case sink.blocks <- block:
		if block.GetFinal() {
			// The terminal block is queued; close so the reader drains it and
			// then sees the end rather than waiting for a block that will
			// never come.
			sink.close()
			c.removeCaptureSession(block.GetSessionId())
		}

		return true
	case <-sink.done:
		// The consumer went away between the lookup and the send.
		return true
	case <-timer.C:
		c.recordEventDrop(EventStreamCapture, EventDropStalledConsumer)
		c.logger.Error().
			Str("session_id", block.GetSessionId()).
			Dur("waited", CaptureBlockTimeout).
			Msg("netprobe: capture consumer stalled; ending the session rather than dropping a " +
				"pcapng block, which would corrupt the capture undetectably")
		sink.fail(fmt.Errorf("%w after %s", ErrCaptureConsumerStalled, CaptureBlockTimeout))
		c.removeCaptureSession(block.GetSessionId())

		return true
	case <-c.done:
		sink.fail(c.closeError())

		return true
	}
}

// failAllCaptureSessions ends every live session when the IPC connection dies.
//
// Without this a capture whose netprobe went away hangs its reader until some
// outer context expires, and the session upstream stays "active" -- which for a
// surveillance capability is the wrong direction to fail: a session nobody can
// see is still holding a ring open on the captured host.
func (c *Client) failAllCaptureSessions(err error) {
	c.captureMu.Lock()
	sinks := make([]*captureSink, 0, len(c.captureSessions))

	for id, sink := range c.captureSessions {
		sinks = append(sinks, sink)
		delete(c.captureSessions, id)
	}

	c.captureMu.Unlock()

	for _, sink := range sinks {
		sink.fail(err)
	}
}
