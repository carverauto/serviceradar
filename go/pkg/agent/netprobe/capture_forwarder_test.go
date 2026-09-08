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
	"io"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"

	"github.com/carverauto/serviceradar/proto"
)

// fakeTransport stands in for the gateway end of the bidi stream.
type fakeTransport struct {
	mu   sync.Mutex
	sent []*proto.RemotePacketCaptureClientMessage

	incoming chan *proto.RemotePacketCaptureServerMessage
	// Blocks Send until closed, so a test can hold the send loop still.
	gate chan struct{}
}

func newFakeTransport() *fakeTransport {
	return &fakeTransport{incoming: make(chan *proto.RemotePacketCaptureServerMessage, 16)}
}

func (f *fakeTransport) Send(message *proto.RemotePacketCaptureClientMessage) error {
	if f.gate != nil {
		<-f.gate
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, message)

	return nil
}

func (f *fakeTransport) Recv() (*proto.RemotePacketCaptureServerMessage, error) {
	message, ok := <-f.incoming
	if !ok {
		return nil, io.EOF
	}

	return message, nil
}

func (f *fakeTransport) grant(bytes uint32) {
	f.incoming <- &proto.RemotePacketCaptureServerMessage{
		Message: &proto.RemotePacketCaptureServerMessage_Ack{
			Ack: &proto.CaptureAck{CreditBytes: bytes},
		},
	}
}

func (f *fakeTransport) cancel(reason string) {
	f.incoming <- &proto.RemotePacketCaptureServerMessage{
		Message: &proto.RemotePacketCaptureServerMessage_Cancel{
			Cancel: &proto.CaptureCancel{Reason: reason},
		},
	}
}

func (f *fakeTransport) messages() []*proto.RemotePacketCaptureClientMessage {
	f.mu.Lock()
	defer f.mu.Unlock()

	return append([]*proto.RemotePacketCaptureClientMessage(nil), f.sent...)
}

func (f *fakeTransport) blocks() []*proto.CaptureBlock {
	var out []*proto.CaptureBlock

	for _, message := range f.messages() {
		if block := message.GetBlock(); block != nil {
			out = append(out, block)
		}
	}

	return out
}

func (f *fakeTransport) states() []*proto.SessionStateChanged {
	var out []*proto.SessionStateChanged

	for _, message := range f.messages() {
		if state := message.GetState(); state != nil {
			out = append(out, state)
		}
	}

	return out
}

func startSession(credit uint32) *proto.StartRemoteCaptureSession {
	return &proto.StartRemoteCaptureSession{
		SessionId:          testSessionID,
		AgentId:            "agent-01",
		GatewayId:          "gateway-01",
		Actor:              "operator@example.com",
		Interface:          "eth0",
		InitialCreditBytes: credit,
	}
}

func headerBlock() *netprobepb.PcapngBlock {
	return &netprobepb.PcapngBlock{SessionId: testSessionID, Bytes: []byte("SHB+IDB")}
}

// forwardHarness wires a real CaptureStream (fed by a fake netprobe) to a fake
// gateway transport.
func forwardHarness(t *testing.T) (*fakeNetprobe, *CaptureStream, *fakeTransport) {
	t.Helper()

	client, probe := newCaptureClient(t)
	probe.answerStart(testSessionID)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	stream, _, err := client.StartCapture(ctx, startRequest(testSessionID))
	require.NoError(t, err)

	return probe, stream, newFakeTransport()
}

func TestForwardSendsStartThenBlocksThenExactlyOneTerminalState(t *testing.T) {
	probe, stream, transport := forwardHarness(t)

	probe.sendBlock(&netprobepb.PcapngBlock{SessionId: testSessionID, Bytes: []byte("aaaa")})
	probe.sendBlock(&netprobepb.PcapngBlock{
		SessionId:         testSessionID,
		Final:             true,
		TerminationReason: netprobepb.CaptureTerminationReason_CAPTURE_TERMINATION_REASON_DURATION_CAP,
		PacketsCaptured:   7,
		BytesStreamed:     11,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	transport.grant(1 << 20)

	err := ForwardCapture(ctx, stream, transport, startSession(1<<20), headerBlock(),
		ForwardOptions{AccountingInterval: time.Hour})
	require.NoError(t, err)

	messages := transport.messages()
	require.NotEmpty(t, messages)
	require.NotNil(t, messages[0].GetStart(), "the first message on the stream must be `start`")

	states := transport.states()
	require.Len(t, states, 1, "exactly one terminal state per session")
	assert.Equal(t, proto.CaptureSessionState_CAPTURE_SESSION_STATE_DURATION_CAP, states[0].GetState())
	assert.Equal(t, uint64(7), states[0].GetPacketsCaptured())
	assert.True(t, states[0].GetComplete())

	// And it is LAST: upstream must always learn why a capture ended, even when
	// it ended badly.
	assert.NotNil(t, messages[len(messages)-1].GetState(),
		"the terminal state must be the final client message")
}

func TestTheHeaderIsBlockOneAndSequencesAreMonotonic(t *testing.T) {
	// The section header is part of the FILE, not metadata about it: a reader
	// that misses it cannot parse anything after. And without a sequence a lost
	// block leaves a pcapng that still parses and reports nothing wrong, so the
	// numbering is what makes a gap detectable at all.
	probe, stream, transport := forwardHarness(t)

	for i := range 4 {
		probe.sendBlock(&netprobepb.PcapngBlock{SessionId: testSessionID, Bytes: []byte{byte(i)}})
	}

	probe.sendBlock(&netprobepb.PcapngBlock{SessionId: testSessionID, Final: true})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	transport.grant(1 << 20)

	require.NoError(t, ForwardCapture(ctx, stream, transport, startSession(1<<20), headerBlock(),
		ForwardOptions{AccountingInterval: time.Hour}))

	blocks := transport.blocks()
	require.GreaterOrEqual(t, len(blocks), 5)
	assert.Equal(t, []byte("SHB+IDB"), blocks[0].GetBytes(), "the header is block 1")

	for i, block := range blocks {
		assert.Equalf(t, uint64(i+1), block.GetSequence(),
			"sequences must run 1..n with no gaps; block %d claims %d", i, block.GetSequence())
	}
}

func TestTheAgentNeverSendsMoreBytesThanItsCredit(t *testing.T) {
	// Credit is what keeps backpressure honest. The agent cannot slow the
	// capture at its source, so when the gateway stops granting, the right
	// behaviour is to stop sending and let netprobe report the ring's drops --
	// not to buffer, which converts a reported drop count into an unreported one.
	probe, stream, transport := forwardHarness(t)

	// Header is 7 bytes. The agent's own start message claims the largest credit
	// the field can hold; the gateway grants the header and nothing more. A
	// self-asserted number must buy nothing.
	const headerBytes = 7

	transport.grant(headerBytes)

	probe.sendBlock(&netprobepb.PcapngBlock{SessionId: testSessionID, Bytes: []byte("0123456789")})

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	err := ForwardCapture(ctx, stream, transport, startSession(^uint32(0)), headerBlock(),
		ForwardOptions{AccountingInterval: time.Hour, CreditTimeout: 400 * time.Millisecond})
	require.Error(t, err, "with no further credit the session must end rather than send anyway")
	require.ErrorIs(t, err, ErrCaptureCredit)

	blocks := transport.blocks()
	require.Len(t, blocks, 1, "only the header fit inside the granted credit")

	var sentBytes int
	for _, block := range blocks {
		sentBytes += len(block.GetBytes())
	}

	assert.LessOrEqual(t, sentBytes, headerBytes,
		"the agent sent %d bytes against %d of credit", sentBytes, headerBytes)
}

func TestGrantingCreditReleasesABlockedSend(t *testing.T) {
	// The other half of the credit rule: backpressure must be a pause, not a
	// deadlock.
	probe, stream, transport := forwardHarness(t)

	probe.sendBlock(&netprobepb.PcapngBlock{SessionId: testSessionID, Bytes: []byte("0123456789")})
	probe.sendBlock(&netprobepb.PcapngBlock{SessionId: testSessionID, Final: true})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	done := make(chan error, 1)

	transport.grant(7)

	go func() {
		done <- ForwardCapture(ctx, stream, transport, startSession(7), headerBlock(),
			ForwardOptions{AccountingInterval: time.Hour})
	}()

	// Nothing beyond the header can go until credit arrives.
	time.Sleep(200 * time.Millisecond)
	assert.Len(t, transport.blocks(), 1, "the send is paused, waiting on credit")

	transport.grant(1 << 20)

	select {
	case err := <-done:
		require.NoError(t, err)
	case <-ctx.Done():
		t.Fatal("granting credit did not release the blocked send")
	}

	assert.GreaterOrEqual(t, len(transport.blocks()), 2, "the queued block went out once credit arrived")
}

func TestAGatewayCancelStopsASilentCaptureAndStillReportsTerminalState(t *testing.T) {
	// The case cancellation exists for, and the one a piggybacked design cannot
	// serve: the capture is matching NOTHING, so there is no traffic to carry a
	// cancel on and no acknowledgement to attach it to.
	_, stream, transport := forwardHarness(t)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	done := make(chan error, 1)

	go func() {
		done <- ForwardCapture(ctx, stream, transport, startSession(1<<20), headerBlock(),
			ForwardOptions{AccountingInterval: time.Hour})
	}()

	// No blocks at all -- a filter matching nothing.
	time.Sleep(150 * time.Millisecond)

	sent := time.Now()
	transport.cancel("operator stopped")

	select {
	case err := <-done:
		require.NoError(t, err)
	case <-time.After(5 * time.Second):
		t.Fatal("the cancel never reached the forwarder")
	}

	elapsed := time.Since(sent)
	t.Logf("cancel observed in %s", elapsed)
	assert.Less(t, elapsed, time.Second,
		"the proposal budgets one second for a gateway cancel to take effect")

	states := transport.states()
	require.Len(t, states, 1)
	assert.Equal(t, proto.CaptureSessionState_CAPTURE_SESSION_STATE_CLIENT_CANCEL, states[0].GetState())
	assert.Equal(t, "operator stopped", states[0].GetUnmappedReason(),
		"the operator's stated reason belongs in the audit record")
}

func TestAccountingIsEmittedWhileTheSessionRuns(t *testing.T) {
	// It exists so no hop has to decode pcapng to know how much has moved.
	probe, stream, transport := forwardHarness(t)

	// A clock the test advances, so the cadence is exact and nothing sleeps for
	// a real second.
	var (
		mu  sync.Mutex
		now = time.Unix(1_700_000_000, 0)
	)

	tick := func() time.Time {
		mu.Lock()
		defer mu.Unlock()
		now = now.Add(600 * time.Millisecond)

		return now
	}

	for i := range 6 {
		probe.sendBlock(&netprobepb.PcapngBlock{SessionId: testSessionID, Bytes: []byte{byte(i)}})
	}

	probe.sendBlock(&netprobepb.PcapngBlock{SessionId: testSessionID, Final: true})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	transport.grant(1 << 20)

	require.NoError(t, ForwardCapture(ctx, stream, transport, startSession(1<<20), headerBlock(),
		ForwardOptions{AccountingInterval: time.Second, Now: tick}))

	states := transport.states()
	require.GreaterOrEqual(t, len(states), 2, "accounting must be emitted before the terminal state")

	active := states[:len(states)-1]
	require.NotEmpty(t, active)

	for _, state := range active {
		assert.Equal(t, proto.CaptureSessionState_CAPTURE_SESSION_STATE_ACTIVE, state.GetState())
	}

	// Byte totals climb, so a progress bar drawn from them moves.
	assert.Positive(t, active[len(active)-1].GetBytesStreamed(),
		"accounting must carry the bytes moved so far, without anyone decoding pcapng")
}

func TestADroppedPacketCountNeverReportsComplete(t *testing.T) {
	// The flag an operator relies on. A capture missing packets that presents
	// as a capture is the failure this whole path exists to avoid.
	probe, stream, transport := forwardHarness(t)

	probe.sendBlock(&netprobepb.PcapngBlock{
		SessionId:         testSessionID,
		Final:             true,
		TerminationReason: netprobepb.CaptureTerminationReason_CAPTURE_TERMINATION_REASON_BYTE_CAP,
		PacketsCaptured:   100,
		PacketsDropped:    17,
		BytesStreamed:     4096,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	transport.grant(1 << 20)

	require.NoError(t, ForwardCapture(ctx, stream, transport, startSession(1<<20), headerBlock(),
		ForwardOptions{AccountingInterval: time.Hour}))

	states := transport.states()
	require.Len(t, states, 1)
	assert.Equal(t, uint64(17), states[0].GetPacketsDropped())
	assert.False(t, states[0].GetComplete(),
		"a session that dropped packets must never be presented as a complete capture")
	assert.Equal(t, proto.CaptureSessionState_CAPTURE_SESSION_STATE_BYTE_CAP, states[0].GetState())
}

func TestATransportFailureStillEndsTheSession(t *testing.T) {
	// The receive goroutine failing must not leave the send loop waiting on
	// credit that can never arrive.
	_, stream, transport := forwardHarness(t)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	done := make(chan error, 1)

	go func() {
		done <- ForwardCapture(ctx, stream, transport, startSession(0), headerBlock(),
			ForwardOptions{AccountingInterval: time.Hour})
	}()

	// With no grant from the gateway the header itself is waiting. Kill the stream.
	time.Sleep(100 * time.Millisecond)
	close(transport.incoming)

	select {
	case err := <-done:
		require.Error(t, err, "a dead transport must end the session rather than hang it")
		// Named, not `err != nil`: an assertion that cannot fail is
		// indistinguishable from one that is still waiting. The transport's own
		// EOF must reach the caller, so a hang and a dead peer are told apart.
		require.ErrorIs(t, err, io.EOF)
	case <-time.After(5 * time.Second):
		t.Fatal("a dead transport left the forwarder hanging on credit")
	}
}
