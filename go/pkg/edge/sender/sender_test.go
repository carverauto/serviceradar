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

package sender

import (
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// fakeIngestServer is a minimal EdgeRecordIngestService.Stream server: it acks
// the handshake, buffers every delivery_frame it receives, and once the
// client closes send it replies with ONE cumulative ack whose dispositions
// resolve every received frame with dispositionKind. A frame's record_bytes
// doubles as its event id in these tests (real production content decodes
// the embedded EdgeRecordV1 instead); it lets the fake server build a
// disposition whose event_id matches what the client tracked as sent,
// without needing a fully signed EdgeRecordV1 fixture.
type fakeIngestServer struct {
	edgev1.UnimplementedEdgeRecordIngestServiceServer

	grantedByteCredits  uint64
	grantedFrameCredits uint32
	dispositionKind     edgev1.EdgeRecordDispositionKind

	mu             sync.Mutex
	receivedFrames []*edgev1.EdgeDeliveryFrameV1
}

func (f *fakeIngestServer) Stream(stream grpc.BidiStreamingServer[edgev1.EdgeRecordClientMessage, edgev1.EdgeRecordServerMessage]) error {
	first, err := stream.Recv()
	if err != nil {
		return err
	}
	open := first.GetLaneOpen()
	if open == nil {
		return status.Error(codes.InvalidArgument, "expected lane_open")
	}

	ack := &edgev1.EdgeRecordLaneOpenAck{
		SpoolId:             open.GetSpoolId(),
		SessionNonce:        open.GetSessionNonce(),
		GrantedByteCredits:  minU64(f.grantedByteCredits, open.GetRequestedByteCredits()),
		GrantedFrameCredits: minU32(f.grantedFrameCredits, open.GetRequestedFrameCredits()),
		RouteProfile:        open.GetRouteProfile(),
		TrafficClass:        open.GetTrafficClass(),
	}
	if err := stream.Send(&edgev1.EdgeRecordServerMessage{
		Payload: &edgev1.EdgeRecordServerMessage_LaneOpenAck{LaneOpenAck: ack},
	}); err != nil {
		return err
	}

	resolvedThrough := open.GetFirstUnresolvedSequence() - 1
	var disps []*edgev1.EdgeRecordDisposition

	for {
		msg, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		frame := msg.GetDeliveryFrame()
		if frame == nil {
			return status.Error(codes.InvalidArgument, "expected delivery_frame")
		}

		f.mu.Lock()
		f.receivedFrames = append(f.receivedFrames, frame)
		f.mu.Unlock()

		disps = append(disps, &edgev1.EdgeRecordDisposition{
			Sequence: frame.GetSequence(),
			EventId:  frame.GetRecordBytes(),
			Kind:     f.dispositionKind,
		})
		resolvedThrough = frame.GetSequence()
	}

	finalAck := &edgev1.EdgeDeliveryAckV1{
		SpoolId:                 open.GetSpoolId(),
		SessionNonce:            open.GetSessionNonce(),
		ResolvedThroughSequence: resolvedThrough,
		Dispositions:            disps,
	}
	return stream.Send(&edgev1.EdgeRecordServerMessage{
		Payload: &edgev1.EdgeRecordServerMessage_Ack{Ack: finalAck},
	})
}

func (f *fakeIngestServer) framesReceived() []*edgev1.EdgeDeliveryFrameV1 {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]*edgev1.EdgeDeliveryFrameV1(nil), f.receivedFrames...)
}

func minU64(a, b uint64) uint64 {
	if a < b {
		return a
	}
	return b
}

func minU32(a, b uint32) uint32 {
	if a < b {
		return a
	}
	return b
}

// dialFakeIngest serves impl over an in-memory bufconn transport and returns
// a client plus a cleanup func.
func dialFakeIngest(t *testing.T, impl edgev1.EdgeRecordIngestServiceServer) edgev1.EdgeRecordIngestServiceClient {
	t.Helper()

	listener := bufconn.Listen(1 << 20)
	server := grpc.NewServer()
	edgev1.RegisterEdgeRecordIngestServiceServer(server, impl)
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(server.Stop)

	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) {
			return listener.Dial()
		}),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatalf("dial bufconn: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })

	return edgev1.NewEdgeRecordIngestServiceClient(conn)
}

func newTestSpool(t *testing.T) *spool.Spool {
	t.Helper()
	sp, err := spool.Open(t.TempDir())
	if err != nil {
		t.Fatalf("open spool: %v", err)
	}
	t.Cleanup(func() { _ = sp.Close() })
	return sp
}

func mustEventID(t *testing.T) []byte {
	t.Helper()
	id, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("new uuidv7: %v", err)
	}
	return id
}

func testConfig(t *testing.T) Config {
	t.Helper()
	spoolID, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("new spool id: %v", err)
	}
	return Config{
		SpoolID:               spoolID,
		RouteProfile:          edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass:          edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		RequestedByteCredits:  1 << 20,
		RequestedFrameCredits: 10,
	}
}

// TestRunOnceSendsUnresolvedRecordsWithoutReclaimingTheSpool is the core
// group-D negative-reclaim proof at unit scope: after a gateway ack resolves
// everything sent, the spool's own local reclaim watermark MUST be
// untouched. Only local durability (owned by a later milestone) may advance
// it; the remote ack alone must not.
func TestRunOnceSendsUnresolvedRecordsWithoutReclaimingTheSpool(t *testing.T) {
	sp := newTestSpool(t)
	e1, e2, e3 := mustEventID(t), mustEventID(t), mustEventID(t)
	for _, id := range [][]byte{e1, e2, e3} {
		if _, err := sp.Append(id, id); err != nil {
			t.Fatalf("append: %v", err)
		}
	}

	srv := &fakeIngestServer{
		grantedByteCredits:  1 << 20,
		grantedFrameCredits: 100,
		dispositionKind:     edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE,
	}
	client := dialFakeIngest(t, srv)

	s, err := New(sp, client, testConfig(t))
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	result, err := s.RunOnce(ctx)
	if err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if want := []uint64{1, 2, 3}; !equalSeqs(result.Sent, want) {
		t.Fatalf("Sent = %v, want %v", result.Sent, want)
	}
	if result.RemoteResolvedThrough != 3 {
		t.Fatalf("RemoteResolvedThrough = %d, want 3", result.RemoteResolvedThrough)
	}
	if len(result.Dispositions) != 3 {
		t.Fatalf("Dispositions = %d, want 3", len(result.Dispositions))
	}

	// The negative rule: a remote ack/resolved-prefix advance alone must NOT
	// physically reclaim the spool record.
	if got := sp.Resolved(); got != 0 {
		t.Fatalf("spool.Resolved() = %d after remote ack alone, want 0 (ack must not reclaim)", got)
	}
	unresolved, err := sp.Unresolved()
	if err != nil {
		t.Fatalf("Unresolved: %v", err)
	}
	if len(unresolved) != 3 {
		t.Fatalf("spool still reports %d unresolved records, want 3 (nothing physically reclaimed)", len(unresolved))
	}

	frames := srv.framesReceived()
	if len(frames) != 3 {
		t.Fatalf("server received %d frames, want 3", len(frames))
	}
	for i, frame := range frames {
		if frame.GetSequence() != uint64(i+1) {
			t.Fatalf("frame[%d].Sequence = %d, want %d", i, frame.GetSequence(), i+1)
		}
	}
}

// TestRunOnceRespectsGrantedFrameCredits proves the sender stops sending once
// the gateway-granted frame credit window is exhausted, rather than draining
// the whole backlog regardless of what was granted.
func TestRunOnceRespectsGrantedFrameCredits(t *testing.T) {
	sp := newTestSpool(t)
	for i := 0; i < 3; i++ {
		id := mustEventID(t)
		if _, err := sp.Append(id, id); err != nil {
			t.Fatalf("append: %v", err)
		}
	}

	srv := &fakeIngestServer{
		grantedByteCredits:  1 << 20,
		grantedFrameCredits: 2,
		dispositionKind:     edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE,
	}
	client := dialFakeIngest(t, srv)

	s, err := New(sp, client, testConfig(t))
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	result, err := s.RunOnce(ctx)
	if err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if want := []uint64{1, 2}; !equalSeqs(result.Sent, want) {
		t.Fatalf("Sent = %v, want %v (bounded by granted frame credits)", result.Sent, want)
	}
	if got := sp.Resolved(); got != 0 {
		t.Fatalf("spool.Resolved() = %d, want 0 (ack must not reclaim)", got)
	}
}

// TestRunOnceReturnsErrNoUnresolvedRecordsOnEmptySpool proves the sender is a
// no-op, not an error path with side effects, when there is nothing to send.
func TestRunOnceReturnsErrNoUnresolvedRecordsOnEmptySpool(t *testing.T) {
	sp := newTestSpool(t)

	srv := &fakeIngestServer{grantedByteCredits: 1 << 20, grantedFrameCredits: 100}
	client := dialFakeIngest(t, srv)

	s, err := New(sp, client, testConfig(t))
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	result, err := s.RunOnce(ctx)
	if !errors.Is(err, ErrNoUnresolvedRecords) {
		t.Fatalf("RunOnce err = %v, want ErrNoUnresolvedRecords", err)
	}
	if len(result.Sent) != 0 {
		t.Fatalf("Sent = %v, want empty", result.Sent)
	}
	if got := sp.Resolved(); got != 0 {
		t.Fatalf("spool.Resolved() = %d, want 0", got)
	}
}

// TestRunOnceReturnsErrInsufficientCreditsWhenFirstRecordExceedsGrant proves
// that a granted byte-credit window smaller than the first unresolved
// record's body is reported as a distinct stall (ErrInsufficientCredits),
// not silently conflated with an empty spool (ErrNoUnresolvedRecords).
func TestRunOnceReturnsErrInsufficientCreditsWhenFirstRecordExceedsGrant(t *testing.T) {
	sp := newTestSpool(t)
	// Body is 16 bytes (UUIDv7 event id reused as body); grant a window
	// smaller than that so even the first record cannot fit.
	id := mustEventID(t)
	if _, err := sp.Append(id, id); err != nil {
		t.Fatalf("append: %v", err)
	}

	srv := &fakeIngestServer{
		grantedByteCredits:  4, // smaller than the 16-byte record body
		grantedFrameCredits: 100,
	}
	client := dialFakeIngest(t, srv)

	s, err := New(sp, client, testConfig(t))
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	result, err := s.RunOnce(ctx)
	if !errors.Is(err, ErrInsufficientCredits) {
		t.Fatalf("RunOnce err = %v, want ErrInsufficientCredits", err)
	}
	if errors.Is(err, ErrNoUnresolvedRecords) {
		t.Fatalf("RunOnce err must not also satisfy ErrNoUnresolvedRecords: %v", err)
	}
	if len(result.Sent) != 0 {
		t.Fatalf("Sent = %v, want empty", result.Sent)
	}
	if got := sp.Resolved(); got != 0 {
		t.Fatalf("spool.Resolved() = %d, want 0", got)
	}
}

// TestRunOnceCancelsStreamContextOnSendError proves that when sendUnresolved
// fails partway through (a local validation or Send error), RunOnce's
// streamCtx is canceled rather than left open indefinitely, so the
// server-side stream goroutine is torn down instead of leaking.
func TestRunOnceCancelsStreamContextOnSendError(t *testing.T) {
	sp := newTestSpool(t)
	for i := 0; i < 2; i++ {
		id := mustEventID(t)
		if _, err := sp.Append(id, id); err != nil {
			t.Fatalf("append: %v", err)
		}
	}

	streamCtxDone := make(chan struct{})
	srv := &erroringIngestServer{
		fakeIngestServer: fakeIngestServer{
			grantedByteCredits:  1 << 20,
			grantedFrameCredits: 100,
		},
		failAfterFrames: 1,
		onServerCtxDone: streamCtxDone,
	}
	client := dialFakeIngest(t, srv)

	s, err := New(sp, client, testConfig(t))
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if _, err := s.RunOnce(ctx); err == nil {
		t.Fatal("RunOnce err = nil, want error from mid-stream server failure")
	}

	select {
	case <-streamCtxDone:
		// Expected: RunOnce's defer cancel() tore down the stream, so the
		// server observed its stream context end.
	case <-time.After(5 * time.Second):
		t.Fatal("server-side stream context was not canceled after RunOnce returned an error")
	}
}

// erroringIngestServer acks the handshake normally, then fails the stream
// after receiving failAfterFrames delivery_frame messages, and signals
// onServerCtxDone once its stream context is Done (proving the client tore
// the stream down rather than leaving it open).
type erroringIngestServer struct {
	fakeIngestServer

	failAfterFrames int
	onServerCtxDone chan struct{}
}

func (f *erroringIngestServer) Stream(
	stream grpc.BidiStreamingServer[edgev1.EdgeRecordClientMessage, edgev1.EdgeRecordServerMessage],
) error {
	go func() {
		<-stream.Context().Done()
		close(f.onServerCtxDone)
	}()

	first, err := stream.Recv()
	if err != nil {
		return err
	}
	open := first.GetLaneOpen()
	if open == nil {
		return status.Error(codes.InvalidArgument, "expected lane_open")
	}

	ack := &edgev1.EdgeRecordLaneOpenAck{
		SpoolId:             open.GetSpoolId(),
		SessionNonce:        open.GetSessionNonce(),
		GrantedByteCredits:  minU64(f.grantedByteCredits, open.GetRequestedByteCredits()),
		GrantedFrameCredits: minU32(f.grantedFrameCredits, open.GetRequestedFrameCredits()),
		RouteProfile:        open.GetRouteProfile(),
		TrafficClass:        open.GetTrafficClass(),
	}
	if err := stream.Send(&edgev1.EdgeRecordServerMessage{
		Payload: &edgev1.EdgeRecordServerMessage_LaneOpenAck{LaneOpenAck: ack},
	}); err != nil {
		return err
	}

	frames := 0
	for {
		msg, err := stream.Recv()
		if err != nil {
			return err
		}
		if msg.GetDeliveryFrame() == nil {
			return status.Error(codes.InvalidArgument, "expected delivery_frame")
		}
		frames++
		if frames >= f.failAfterFrames {
			return status.Error(codes.Internal, "injected mid-stream failure")
		}
	}
}

func TestNewRejectsInvalidConfig(t *testing.T) {
	sp := newTestSpool(t)
	srv := &fakeIngestServer{}
	client := dialFakeIngest(t, srv)

	cfg := testConfig(t)
	cfg.SpoolID = []byte("not-a-uuidv7")
	if _, err := New(sp, client, cfg); err == nil {
		t.Fatal("New with invalid spool id = nil error, want error")
	}

	cfg = testConfig(t)
	cfg.RequestedFrameCredits = 0
	if _, err := New(sp, client, cfg); err == nil {
		t.Fatal("New with zero frame credits = nil error, want error")
	}
}

func TestPersistentSpoolIDIsStableAcrossCalls(t *testing.T) {
	dir := t.TempDir()

	first, err := PersistentSpoolID(dir)
	if err != nil {
		t.Fatalf("PersistentSpoolID: %v", err)
	}
	if err := edgerecord.ValidateUUIDv7(first); err != nil {
		t.Fatalf("generated spool id is not a valid UUIDv7: %v", err)
	}

	second, err := PersistentSpoolID(dir)
	if err != nil {
		t.Fatalf("PersistentSpoolID (second call): %v", err)
	}
	if !equalSeqs(toU64(first), toU64(second)) {
		t.Fatalf("PersistentSpoolID not stable: %x != %x", first, second)
	}
}

func equalSeqs(a, b []uint64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func toU64(b []byte) []uint64 {
	out := make([]uint64, len(b))
	for i, v := range b {
		out[i] = uint64(v)
	}
	return out
}
