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

	"github.com/carverauto/serviceradar/proto"
)

// AccountingInterval is how often a running session reports its counters
// upstream.
//
// One second because that is what the proposal asks for, and the reason it asks
// is worth keeping in view: it exists so the gateway and core can track
// `bytes_streamed` WITHOUT decoding pcapng. No hop between netprobe and the
// operator's reader should have to parse a capture in order to bill it or to
// draw a progress bar.
const AccountingInterval = time.Second

// CancelPollInterval bounds how quickly a `CaptureCancel` from the gateway
// reaches netprobe.
//
// The budget is one second. This is well inside it, and cheap: the receive runs
// on its own goroutine, so the interval only bounds how long the SEND loop can
// be mid-block when a cancel lands.
const CancelPollInterval = 100 * time.Millisecond

// CaptureTransport is the gRPC stream, narrowed to what the forwarder uses.
//
// An interface rather than the generated client type so the forwarding rules --
// credit, ordering, the terminal message, cancellation latency -- are testable
// without a gateway, a TLS handshake or a network. The generated
// `RemotePacketCaptureService_StreamCaptureClient` satisfies it as-is.
type CaptureTransport interface {
	Send(*proto.RemotePacketCaptureClientMessage) error
	Recv() (*proto.RemotePacketCaptureServerMessage, error)
}

// ErrCaptureCredit reports that the gateway never extended enough credit to
// send a block. Surfaced rather than waited on forever: a session that cannot
// move is more useful reported than hung.
var ErrCaptureCredit = errors.New("gateway did not extend capture credit")

// ForwardOptions are the knobs a test shrinks.
type ForwardOptions struct {
	// Accounting cadence. Zero means AccountingInterval.
	AccountingInterval time.Duration
	// How long to wait for credit before giving up. Zero means no limit
	// beyond the caller's context.
	CreditTimeout time.Duration
	// Injected so a test can drive the cadence without sleeping. Zero means
	// time.Now.
	Now func() time.Time
}

func (o ForwardOptions) accounting() time.Duration {
	if o.AccountingInterval <= 0 {
		return AccountingInterval
	}

	return o.AccountingInterval
}

func (o ForwardOptions) now() time.Time {
	if o.Now == nil {
		return time.Now()
	}

	return o.Now()
}

// captureCredit tracks how many bytes the gateway will accept.
//
// Credit is what keeps the agent honest about backpressure. It cannot slow the
// capture at its source -- the kernel's ring fills at line rate whatever
// userspace does -- so when the gateway stops granting credit the right
// behaviour is to stop reading netprobe, let the ring overflow, and let netprobe
// REPORT the drops. Buffering here instead would turn a reported drop count into
// an unreported one.
type captureCredit struct {
	mu        sync.Mutex
	available int64
	waiters   chan struct{}
	closed    bool
	closeErr  error
}

func newCaptureCredit(initial uint32) *captureCredit {
	return &captureCredit{
		available: int64(initial),
		waiters:   make(chan struct{}, 1),
	}
}

func (c *captureCredit) grant(bytes uint32) {
	c.mu.Lock()
	c.available += int64(bytes)
	c.mu.Unlock()
	c.wake()
}

func (c *captureCredit) fail(err error) {
	c.mu.Lock()
	if !c.closed {
		c.closed = true
		c.closeErr = err
	}
	c.mu.Unlock()
	c.wake()
}

func (c *captureCredit) wake() {
	select {
	case c.waiters <- struct{}{}:
	default:
	}
}

// spend blocks until `bytes` of credit are available, then consumes them.
//
// A block larger than any credit the gateway will ever grant would block
// forever, so the caller's context and CreditTimeout both apply. Partial spends
// are deliberately not allowed: a pcapng block is sent whole or not at all,
// because a reader cannot use half of one.
func (c *captureCredit) spend(ctx context.Context, bytes int, timeout time.Duration) error {
	deadline := ctx.Done()

	var timer *time.Timer
	if timeout > 0 {
		timer = time.NewTimer(timeout)
		defer timer.Stop()
	}

	for {
		c.mu.Lock()
		if c.closed {
			err := c.closeErr
			c.mu.Unlock()

			return err
		}

		if c.available >= int64(bytes) {
			c.available -= int64(bytes)
			c.mu.Unlock()

			return nil
		}
		c.mu.Unlock()

		var expired <-chan time.Time
		if timer != nil {
			expired = timer.C
		}

		select {
		case <-c.waiters:
		case <-deadline:
			return ctx.Err()
		case <-expired:
			return fmt.Errorf("%w within %s", ErrCaptureCredit, timeout)
		}
	}
}

// ForwardCapture pumps one capture session onto the gateway stream.
//
// It sends the opening `start`, then blocks and 1 Hz accounting, and finally
// exactly one terminal `SessionStateChanged` -- which is the last client message
// on the stream, so upstream always learns why a capture ended even when it
// ended badly.
func ForwardCapture(
	ctx context.Context,
	stream *CaptureStream,
	transport CaptureTransport,
	start *proto.StartRemoteCaptureSession,
	header *netprobepb.PcapngBlock,
	opts ForwardOptions,
) error {
	if err := transport.Send(&proto.RemotePacketCaptureClientMessage{
		Message: &proto.RemotePacketCaptureClientMessage_Start{Start: start},
	}); err != nil {
		return fmt.Errorf("send capture start: %w", err)
	}

	// Credit comes from the gateway's acks and from nowhere else. Seeding it
	// from `start.initial_credit_bytes` would let the agent grant itself up to
	// 4 GiB on a message it composed, before the gateway had accepted the
	// session at all -- which is the one thing a credit scheme exists to stop.
	// The field is the gateway's echo of what it is willing to receive; the
	// gateway sends 0 on the way in and grants for real in its first ack.
	credit := newCaptureCredit(0)

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	// The gateway's channel is read on its own goroutine so a cancel lands
	// even while the send loop is waiting on credit or on netprobe. Piggybacking
	// it on the send path would make cancellation latency a function of traffic
	// volume -- and a capture matching nothing, which produces no traffic at
	// all, is exactly the session most likely to need stopping.
	cancelReason := make(chan string, 1)

	go func() {
		for {
			message, err := transport.Recv()
			if err != nil {
				credit.fail(fmt.Errorf("capture stream receive: %w", err))
				cancel()

				return
			}

			switch payload := message.GetMessage().(type) {
			case *proto.RemotePacketCaptureServerMessage_Ack:
				credit.grant(payload.Ack.GetCreditBytes())
			case *proto.RemotePacketCaptureServerMessage_Cancel:
				select {
				case cancelReason <- payload.Cancel.GetReason():
				default:
				}

				cancel()

				return
			}
		}
	}()

	state, sendErr := pumpCaptureBlocks(ctx, stream, transport, credit, start, header, opts)

	// The terminal message goes out on the ORIGINAL context, not the cancelled
	// one: the whole point of a terminal frame is that it survives the thing
	// that ended the session.
	if reason, cancelled := readCancelReason(cancelReason); cancelled && state.unmapped == "" {
		state.reason = proto.CaptureSessionState_CAPTURE_SESSION_STATE_CLIENT_CANCEL
		state.unmapped = reason

		// A cancel cancels the pump context, so a send loop parked on credit
		// unwinds with context.Canceled. That is the cancel working, not a
		// transport failure, and reporting it as an error would make every
		// operator stop look like a fault in the logs.
		if errors.Is(sendErr, context.Canceled) {
			sendErr = nil
		}
	}

	if err := transport.Send(&proto.RemotePacketCaptureClientMessage{
		Message: &proto.RemotePacketCaptureClientMessage_State{State: state.toProto(start.GetSessionId())},
	}); err != nil && sendErr == nil {
		return fmt.Errorf("send terminal capture state: %w", err)
	}

	return sendErr
}

func readCancelReason(ch <-chan string) (string, bool) {
	select {
	case reason := <-ch:
		return reason, true
	default:
		return "", false
	}
}

// captureTotals is the accounting carried on every SessionStateChanged.
type captureTotals struct {
	packets  uint64
	dropped  uint64
	bytes    uint64
	complete bool
	reason   proto.CaptureSessionState
	unmapped string
}

func (t captureTotals) toProto(sessionID string) *proto.SessionStateChanged {
	return &proto.SessionStateChanged{
		SessionId:       sessionID,
		State:           t.reason,
		PacketsCaptured: t.packets,
		PacketsDropped:  t.dropped,
		BytesStreamed:   t.bytes,
		Complete:        t.complete,
		UnmappedReason:  t.unmapped,
	}
}

func pumpCaptureBlocks(
	ctx context.Context,
	stream *CaptureStream,
	transport CaptureTransport,
	credit *captureCredit,
	start *proto.StartRemoteCaptureSession,
	header *netprobepb.PcapngBlock,
	opts ForwardOptions,
) (captureTotals, error) {
	totals := captureTotals{reason: proto.CaptureSessionState_CAPTURE_SESSION_STATE_AGENT_DISCONNECT}
	sequence := uint64(0)
	lastReport := opts.now()

	// The header is block 1. It is part of the file, not metadata about it: a
	// reader that misses the section header cannot parse anything that follows.
	pending := header

	for {
		if pending != nil {
			sequence++

			if err := sendCaptureBlock(ctx, transport, credit, start.GetSessionId(), pending, sequence, opts); err != nil {
				return totals, err
			}

			totals.bytes += uint64(len(pending.GetBytes()))

			if pending.GetFinal() {
				totals.packets = pending.GetPacketsCaptured()
				totals.dropped = pending.GetPacketsDropped()
				totals.bytes = pending.GetBytesStreamed()
				totals.complete = pending.GetPacketsDropped() == 0
				totals.reason = CaptureSessionState(pending.GetTerminationReason())

				if totals.reason == proto.CaptureSessionState_CAPTURE_SESSION_STATE_UNKNOWN_REASON {
					totals.unmapped = pending.GetTerminationReason().String()
				}

				return totals, nil
			}
		}

		if now := opts.now(); now.Sub(lastReport) >= opts.accounting() {
			lastReport = now
			active := totals
			active.reason = proto.CaptureSessionState_CAPTURE_SESSION_STATE_ACTIVE

			if err := transport.Send(&proto.RemotePacketCaptureClientMessage{
				Message: &proto.RemotePacketCaptureClientMessage_State{
					State: active.toProto(start.GetSessionId()),
				},
			}); err != nil {
				return totals, fmt.Errorf("send capture accounting: %w", err)
			}
		}

		block, err := stream.Next(ctx)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				totals.reason = proto.CaptureSessionState_CAPTURE_SESSION_STATE_CLIENT_CANCEL

				return totals, nil
			}

			return totals, err
		}

		if block == nil {
			// The session ended without a terminal block, which means netprobe
			// went away rather than stopping. Reported as a disconnect, not as
			// a clean finish.
			return totals, nil
		}

		pending = block
	}
}

func sendCaptureBlock(
	ctx context.Context,
	transport CaptureTransport,
	credit *captureCredit,
	sessionID string,
	block *netprobepb.PcapngBlock,
	sequence uint64,
	opts ForwardOptions,
) error {
	if err := credit.spend(ctx, len(block.GetBytes()), opts.CreditTimeout); err != nil {
		return err
	}

	return transport.Send(&proto.RemotePacketCaptureClientMessage{
		Message: &proto.RemotePacketCaptureClientMessage_Block{
			Block: &proto.CaptureBlock{
				SessionId: sessionID,
				Bytes:     block.GetBytes(),
				Sequence:  sequence,
			},
		},
	})
}
