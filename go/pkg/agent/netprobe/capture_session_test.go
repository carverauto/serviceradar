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
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

const testSessionID = "01JQ0000000000000000000000"

// fakeNetprobe is the sidecar half of the IPC socket: it answers a
// StartRemoteCapture with a header block and then streams whatever the test
// tells it to.
type fakeNetprobe struct {
	conn net.Conn
	t    *testing.T
}

func newCaptureClient(t *testing.T) (*Client, *fakeNetprobe) {
	t.Helper()

	clientConn, serverConn := net.Pipe()
	client := NewClient(clientConn, 4)
	t.Cleanup(func() { _ = client.Close() })

	return client, &fakeNetprobe{conn: serverConn, t: t}
}

// answerStart reads one request frame and replies with a pcapng header on the
// same sequence, mirroring what netprobe's IPC server does.
func (f *fakeNetprobe) answerStart(sessionID string) {
	f.t.Helper()

	go func() {
		frame, err := readFrame(f.conn)
		if err != nil || frame == nil {
			return
		}

		_ = writeFrame(f.conn, &netprobepb.NetprobeFrame{
			Sequence: frame.GetSequence(),
			Payload: &netprobepb.NetprobeFrame_PcapngBlock{
				PcapngBlock: &netprobepb.PcapngBlock{
					SessionId: sessionID,
					Bytes:     []byte("SHB+IDB"),
				},
			},
		})
	}()
}

func (f *fakeNetprobe) sendBlock(block *netprobepb.PcapngBlock) {
	f.t.Helper()
	require.NoError(f.t, writeFrame(f.conn, &netprobepb.NetprobeFrame{
		Sequence: 0,
		Payload:  &netprobepb.NetprobeFrame_PcapngBlock{PcapngBlock: block},
	}))
}

func startRequest(sessionID string) *netprobepb.StartRemoteCapture {
	return &netprobepb.StartRemoteCapture{
		SessionId:  sessionID,
		Actor:      "operator@example.com",
		Interfaces: []string{"eth0"},
	}
}

func TestStartCaptureReturnsTheHeaderAndStreamsBlocksInOrder(t *testing.T) {
	client, probe := newCaptureClient(t)
	probe.answerStart(testSessionID)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	stream, header, err := client.StartCapture(ctx, startRequest(testSessionID))
	require.NoError(t, err)
	require.NotNil(t, stream)
	assert.Equal(t, 1, client.ActiveCaptureCount())
	assert.Equal(t, []byte("SHB+IDB"), header.GetBytes(),
		"the header comes back as the RESPONSE, so a caller can send it before any packet")

	for i := 1; i <= 3; i++ {
		probe.sendBlock(&netprobepb.PcapngBlock{
			SessionId: testSessionID,
			Bytes:     []byte{byte(i)},
		})
	}

	probe.sendBlock(&netprobepb.PcapngBlock{
		SessionId:       testSessionID,
		Final:           true,
		PacketsCaptured: 3,
	})

	for i := 1; i <= 3; i++ {
		block, err := stream.Next(ctx)
		require.NoError(t, err)
		require.NotNil(t, block)
		assert.Equal(t, []byte{byte(i)}, block.GetBytes(),
			"blocks arrive in the order netprobe sent them; nothing reorders")
	}

	terminal, err := stream.Next(ctx)
	require.NoError(t, err)
	require.NotNil(t, terminal)
	assert.True(t, terminal.GetFinal())
	assert.Equal(t, uint64(3), terminal.GetPacketsCaptured())
	assert.Equal(t, 0, client.ActiveCaptureCount())

	// The terminal block is the last thing on the stream, and the end is
	// reported cleanly rather than as an error.
	end, err := stream.Next(ctx)
	assert.Nil(t, end)
	assert.NoError(t, err)
}

// The rule that separates this stream from every other arm in the read loop.
func TestACaptureBlockIsNeverDroppedForBackpressure(t *testing.T) {
	client, probe := newCaptureClient(t)
	probe.answerStart(testSessionID)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	stream, _, err := client.StartCapture(ctx, startRequest(testSessionID))
	require.NoError(t, err)

	// More blocks than the queue holds, with a consumer that is not reading
	// yet. Every other arm in the read loop would drop the excess here.
	const sent = captureQueueDepth + 5

	go func() {
		for i := 1; i <= sent; i++ {
			probe.sendBlock(&netprobepb.PcapngBlock{
				SessionId: testSessionID,
				Bytes:     []byte{byte(i)},
			})
		}
	}()

	// Start reading only after the writer is well ahead, so the queue is
	// genuinely full and the read loop genuinely had to wait.
	time.Sleep(200 * time.Millisecond)

	for i := 1; i <= sent; i++ {
		block, err := stream.Next(ctx)
		require.NoErrorf(t, err, "block %d of %d was lost; a dropped pcapng block is "+
			"undetectable corruption, not a degraded capture", i, sent)
		require.NotNil(t, block)
		assert.Equal(t, []byte{byte(i)}, block.GetBytes(), "block %d arrived out of order", i)
	}

	assert.Zero(t, client.droppedUnknownFrames.Load(),
		"capture blocks must not fall through to the unhandled-arm branch")
}

// A consumer that stops reading must not stall the SHARED read loop, because
// fingerprint, DPI, flow-attribution and census delivery all run through it.
func TestAStalledConsumerEndsItsSessionInsteadOfWedgingTheReadLoop(t *testing.T) {
	client, probe := newCaptureClient(t)
	probe.answerStart(testSessionID)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	stream, _, err := client.StartCapture(ctx, startRequest(testSessionID))
	require.NoError(t, err)

	// Never read from `stream`. Fill past the queue so the read loop blocks,
	// then waits out CaptureBlockTimeout.
	go func() {
		for i := range captureQueueDepth + 2 {
			probe.sendBlock(&netprobepb.PcapngBlock{
				SessionId: testSessionID,
				Bytes:     []byte{byte(i)},
			})
		}
	}()

	// Do not read AT ALL until the timeout has elapsed. An earlier version of
	// this test drained in a loop, which meant the consumer was reading and the
	// stall it was supposed to reproduce never happened -- it passed for the
	// wrong reason until the assertion was tightened.
	time.Sleep(CaptureBlockTimeout + 500*time.Millisecond)

	var stallErr error

	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		_, err := stream.Next(ctx)
		if err != nil {
			stallErr = err

			break
		}
	}

	require.Error(t, stallErr, "the session must end with a reason, not hang")
	require.ErrorIs(t, stallErr, ErrCaptureConsumerStalled)

	// And the read loop is still alive: a fresh request still gets answered.
	probe.answerStart("01JQ0000000000000000000001")

	_, _, err = client.StartCapture(ctx, startRequest("01JQ0000000000000000000001"))
	assert.NoError(t, err, "one stalled capture must not wedge the shared read loop")
}

// A block for a session the agent does not know about is an anomaly worth
// counting, not something to discard quietly.
func TestABlockForAnUnknownSessionIsCountedRatherThanDiscarded(t *testing.T) {
	client, probe := newCaptureClient(t)

	probe.sendBlock(&netprobepb.PcapngBlock{
		SessionId: "01JQNOSUCHSESSION000000000",
		Bytes:     []byte("orphan"),
	})

	assert.Eventually(t, func() bool {
		return client.droppedUnknownFrames.Load() > 0
	}, 5*time.Second, 10*time.Millisecond,
		"an unrouted pcapng block must reach the unhandled-arm branch; discarding it silently "+
			"is how 'the capture produced nothing' becomes unexplainable")
}

func TestNetprobesRefusalIsSurfacedWithItsCode(t *testing.T) {
	client, probe := newCaptureClient(t)

	go func() {
		frame, err := readFrame(probe.conn)
		if err != nil || frame == nil {
			return
		}

		_ = writeFrame(probe.conn, &netprobepb.NetprobeFrame{
			Sequence: frame.GetSequence(),
			Payload: &netprobepb.NetprobeFrame_Error{
				Error: &netprobepb.ErrorFrame{
					Code:    "capture_interface_denied",
					Message: "interface eth9 is not in capture_interfaces",
				},
			},
		})
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, _, err := client.StartCapture(ctx, startRequest(testSessionID))
	require.Error(t, err)
	require.ErrorIs(t, err, ErrCaptureRejected)
	// The code and the offending value both survive: "denied" and "your filter
	// does not compile" need different operator actions.
	assert.Contains(t, err.Error(), "capture_interface_denied")
	assert.Contains(t, err.Error(), "eth9")

	// A refused start must leave no session behind, or the next attempt with
	// the same id is rejected for the wrong reason.
	assert.Nil(t, client.lookupCaptureSession(testSessionID))
}

func TestAClosedConnectionEndsEveryLiveCaptureSession(t *testing.T) {
	client, probe := newCaptureClient(t)
	probe.answerStart(testSessionID)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	stream, _, err := client.StartCapture(ctx, startRequest(testSessionID))
	require.NoError(t, err)

	require.NoError(t, client.Close())

	_, err = stream.Next(ctx)
	require.Error(t, err, "a capture whose netprobe went away must not hang its reader: "+
		"upstream would keep showing an active session holding a ring open on the captured host")
	assert.True(t, errors.Is(err, ErrClientClosed) || err != nil)
	assert.Nil(t, client.lookupCaptureSession(testSessionID))
}

func TestTheSameSessionCannotBeStartedTwice(t *testing.T) {
	client, probe := newCaptureClient(t)
	probe.answerStart(testSessionID)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, _, err := client.StartCapture(ctx, startRequest(testSessionID))
	require.NoError(t, err)

	_, _, err = client.StartCapture(ctx, startRequest(testSessionID))
	require.Error(t, err)
	assert.ErrorIs(t, err, ErrCaptureSessionExists)
}

func TestClosingAStreamUnregistersItsSession(t *testing.T) {
	client, probe := newCaptureClient(t)
	probe.answerStart(testSessionID)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	stream, _, err := client.StartCapture(ctx, startRequest(testSessionID))
	require.NoError(t, err)

	stream.Close()
	stream.Close() // idempotent

	assert.Nil(t, client.lookupCaptureSession(testSessionID),
		"a leaked registration would make the next capture on this session id fail as a duplicate")
}
