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
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
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
	// retryLast, when set, reports the last received frame REJECTED_RETRYABLE
	// past the resolved watermark, a tail ValidateAck accepts.
	retryLast atomic.Bool
	// decodeEventIDs, when set, takes each disposition's event id from the
	// frame's decoded EdgeRecordV1 instead of its raw bytes.
	decodeEventIDs bool

	mu             sync.Mutex
	receivedFrames []*edgev1.EdgeDeliveryFrameV1
	sessions       atomic.Int32
}

func (f *fakeIngestServer) Stream(stream grpc.BidiStreamingServer[edgev1.EdgeRecordClientMessage, edgev1.EdgeRecordServerMessage]) error {
	f.sessions.Add(1)
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

		eventID := frame.GetRecordBytes()
		if f.decodeEventIDs {
			record, err := edgerecord.DecodeRecord(frame.GetRecordBytes())
			if err != nil {
				return status.Error(codes.InvalidArgument, "undecodable record")
			}
			eventID = record.GetEventId()
		}
		disps = append(disps, &edgev1.EdgeRecordDisposition{
			Sequence: frame.GetSequence(),
			EventId:  eventID,
			Kind:     f.dispositionKind,
		})
		resolvedThrough = frame.GetSequence()
	}
	if f.retryLast.Load() && len(disps) > 0 {
		disps[len(disps)-1].Kind = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE
		disps[len(disps)-1].RejectionCode = "WOULD_BLOCK"
		resolvedThrough--
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
// completionClient records whether a session read the end of its RPC (io.EOF),
// which is how a client stream completes with status OK rather than CANCELLED.
type completionClient struct {
	StreamClient
	completed atomic.Bool
}

func (c *completionClient) Stream(ctx context.Context, opts ...grpc.CallOption) (
	grpc.BidiStreamingClient[edgev1.EdgeRecordClientMessage, edgev1.EdgeRecordServerMessage], error,
) {
	stream, err := c.StreamClient.Stream(ctx, opts...)
	if err != nil {
		return nil, err
	}
	return &completionStream{BidiStreamingClient: stream, completed: &c.completed}, nil
}

type completionStream struct {
	grpc.BidiStreamingClient[edgev1.EdgeRecordClientMessage, edgev1.EdgeRecordServerMessage]
	completed *atomic.Bool
}

func (s *completionStream) Recv() (*edgev1.EdgeRecordServerMessage, error) {
	msg, err := s.BidiStreamingClient.Recv()
	if errors.Is(err, io.EOF) {
		s.completed.Store(true)
	}
	return msg, err
}

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
	client := &completionClient{StreamClient: dialFakeIngest(t, srv)}

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

	// The session ran its RPC to the gateway's end instead of cancelling it.
	if !client.completed.Load() {
		t.Fatal("session ended without reading the end of the RPC; gRPC reports it CANCELLED")
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
	if got := srv.sessions.Load(); got != 0 {
		t.Fatalf("gateway sessions = %d, want 0: an empty spool opens no stream", got)
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

func TestRunOnceKeepsSentPrefixWhenLaterDeliverySendFails(t *testing.T) {
	sp := newTestSpool(t)
	for i := 0; i < 3; i++ {
		id := mustEventID(t)
		if _, err := sp.Append(id, id); err != nil {
			t.Fatalf("append: %v", err)
		}
	}
	if err := sp.Resolve(1); err != nil {
		t.Fatalf("resolve: %v", err)
	}

	srv := &fakeIngestServer{
		grantedByteCredits:  1 << 20,
		grantedFrameCredits: 100,
		dispositionKind:     edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE,
	}
	client := failingStreamClient{
		inner:        dialFakeIngest(t, srv),
		failDelivery: 2,
	}
	s, err := New(sp, client, testConfig(t))
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	result, err := s.RunOnce(ctx)
	if err == nil {
		t.Fatal("RunOnce err = nil, want delivery send failure")
	}
	if want := []uint64{2}; !equalSeqs(result.Sent, want) {
		t.Fatalf("Sent = %v, want %v", result.Sent, want)
	}
	if result.RemoteResolvedThrough != 1 {
		t.Fatalf("RemoteResolvedThrough = %d, want 1", result.RemoteResolvedThrough)
	}
	if got := sp.Resolved(); got != 1 {
		t.Fatalf("spool.Resolved() = %d, want 1", got)
	}
}

func TestRunOnceKeepsSentPrefixWhenCloseSendFails(t *testing.T) {
	sp := newTestSpool(t)
	for i := 0; i < 3; i++ {
		id := mustEventID(t)
		if _, err := sp.Append(id, id); err != nil {
			t.Fatalf("append: %v", err)
		}
	}
	if err := sp.Resolve(1); err != nil {
		t.Fatalf("resolve: %v", err)
	}

	srv := &fakeIngestServer{
		grantedByteCredits:  1 << 20,
		grantedFrameCredits: 100,
		dispositionKind:     edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE,
	}
	client := failingStreamClient{
		inner:         dialFakeIngest(t, srv),
		failCloseSend: true,
	}
	s, err := New(sp, client, testConfig(t))
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	result, err := s.RunOnce(ctx)
	if err == nil {
		t.Fatal("RunOnce err = nil, want close send failure")
	}
	if want := []uint64{2, 3}; !equalSeqs(result.Sent, want) {
		t.Fatalf("Sent = %v, want %v", result.Sent, want)
	}
	if result.RemoteResolvedThrough != 1 {
		t.Fatalf("RemoteResolvedThrough = %d, want 1", result.RemoteResolvedThrough)
	}
	if got := sp.Resolved(); got != 1 {
		t.Fatalf("spool.Resolved() = %d, want 1", got)
	}
}

type failingStreamClient struct {
	inner         StreamClient
	failDelivery  int
	failCloseSend bool
}

func (c failingStreamClient) Stream(
	ctx context.Context,
	opts ...grpc.CallOption,
) (grpc.BidiStreamingClient[edgev1.EdgeRecordClientMessage, edgev1.EdgeRecordServerMessage], error) {
	stream, err := c.inner.Stream(ctx, opts...)
	if err != nil {
		return nil, err
	}
	return &failingSendStream{
		BidiStreamingClient: stream,
		failDelivery:        c.failDelivery,
		failCloseSend:       c.failCloseSend,
	}, nil
}

type failingSendStream struct {
	grpc.BidiStreamingClient[edgev1.EdgeRecordClientMessage, edgev1.EdgeRecordServerMessage]
	failDelivery  int
	failCloseSend bool
	deliveries    int
}

func (s *failingSendStream) Send(msg *edgev1.EdgeRecordClientMessage) error {
	if msg.GetDeliveryFrame() != nil {
		s.deliveries++
		if s.failDelivery > 0 && s.deliveries == s.failDelivery {
			return status.Error(codes.Unavailable, "injected delivery send failure")
		}
	}
	return s.BidiStreamingClient.Send(msg)
}

func (s *failingSendStream) CloseSend() error {
	if s.failCloseSend {
		return status.Error(codes.Unavailable, "injected close send failure")
	}
	return s.BidiStreamingClient.CloseSend()
}

func TestRunOnceCancelsActiveStreamOnInvalidHandshake(t *testing.T) {
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
		t.Fatal("RunOnce err = nil, want local handshake validation error")
	}

	select {
	case <-streamCtxDone:

	case <-time.After(5 * time.Second):
		t.Fatal("server-side stream context was not canceled after RunOnce returned an error")
	}
}

type erroringIngestServer struct {
	fakeIngestServer

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
		SessionNonce:        make([]byte, 16),
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

	<-stream.Context().Done()
	return stream.Context().Err()
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

func TestTerminalAcknowledgementSurvivesReopenBeforeSuppressingReplay(t *testing.T) {
	dir := t.TempDir()
	sp, err := spool.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	id := mustEventID(t)
	if _, err = sp.Append(id, id); err != nil {
		t.Fatal(err)
	}
	srv := &fakeIngestServer{grantedByteCredits: 1 << 20, grantedFrameCredits: 100, dispositionKind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE}
	cfg := testConfig(t)
	cfg.PersistAcknowledgements = true
	sender, err := New(sp, dialFakeIngest(t, srv), cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err = sender.RunOnce(ctx); err != nil {
		t.Fatal(err)
	}
	if err = sp.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := spool.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = reopened.Close() }()
	if reopened.Resolved() != 1 {
		t.Fatalf("resolved after reopen=%d", reopened.Resolved())
	}
	records, err := reopened.Unresolved()
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 0 {
		t.Fatalf("replayed %d terminal records", len(records))
	}
	restarted, err := New(reopened, dialFakeIngest(t, srv), cfg)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := restarted.RunOnce(ctx); !errors.Is(err, ErrNoUnresolvedRecords) {
		t.Fatalf("restarted delivery error=%v, want no unresolved records", err)
	}
	if frames := srv.framesReceived(); len(frames) != 1 || !bytes.Equal(frames[0].GetRecordBytes(), id) {
		t.Fatalf("terminal record replayed after restart: %v", frames)
	}
}

// A gateway may resolve a prefix and report the next record retryable. The lane
// persists only the resolving prefix, so once the retried record is accepted
// the fully accepted segment reclaims. Persisting the retryable tail would keep
// reclaim from proving the prefix accepted, and the lane would never reclaim.
func TestRetryableTailDoesNotBlockReclaimOfTheAcceptedPrefix(t *testing.T) {
	dir := t.TempDir()
	sp, err := spool.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sp.Close() })
	for range 2 {
		id := mustEventID(t)
		if _, err := sp.Append(id, id); err != nil {
			t.Fatal(err)
		}
	}
	srv := &fakeIngestServer{grantedByteCredits: 1 << 20, grantedFrameCredits: 100, dispositionKind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE}
	srv.retryLast.Store(true)
	cfg := testConfig(t)
	cfg.PersistAcknowledgements = true
	sender, err := New(sp, dialFakeIngest(t, srv), cfg)
	if err != nil {
		t.Fatal(err)
	}

	// The retried record is never acknowledged in this session, so the run ends
	// at its deadline after persisting the resolving prefix.
	first, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	_, _ = sender.RunOnce(first)
	cancel()
	if sp.Resolved() != 1 {
		t.Fatalf("resolved after the retryable tail = %d, want 1", sp.Resolved())
	}

	srv.retryLast.Store(false)
	second, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := sender.RunOnce(second); err != nil {
		t.Fatalf("retry run: %v", err)
	}
	if sp.Resolved() != 2 {
		t.Fatalf("resolved after the retry = %d, want 2", sp.Resolved())
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".spool-data-") {
			return
		}
	}
	t.Fatal("the fully accepted lane was not reclaimed")
}

func TestRunOnceReportsCoverageGap(t *testing.T) {
	dir := t.TempDir()
	sp, err := spool.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	id := mustEventID(t)
	if _, err := sp.Append(id, id); err != nil {
		t.Fatal(err)
	}
	if err := sp.Close(); err != nil {
		t.Fatal(err)
	}
	// Simulate durable allocation/evidence with lost record bytes.
	if err := os.Truncate(filepath.Join(dir, "lane.seg"), 0); err != nil {
		t.Fatal(err)
	}
	sp, err = spool.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = sp.Close() }()
	id = mustEventID(t)
	if _, err := sp.Append(id, id); err != nil {
		t.Fatal(err)
	}
	srv := &fakeIngestServer{grantedByteCredits: 1 << 20, grantedFrameCredits: 100,
		dispositionKind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE}
	cfg := testConfig(t)
	cfg.PersistAcknowledgements = true
	s, err := New(sp, dialFakeIngest(t, srv), cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for range 2 {
		result, err := s.RunOnce(ctx)
		if err == nil || !strings.Contains(err.Error(), "coverage gap sequence=1") {
			t.Fatalf("run = %+v, %v; want explicit coverage gap sequence=1", result, err)
		}
		if sp.Resolved() != 0 || len(result.Sent) != 1 || result.Sent[0] != 2 {
			t.Fatalf("gap was skipped or records lost: resolved=%d result=%+v", sp.Resolved(), result)
		}
	}
}

var errSyntheticRecoveryJournal = errors.New("synthetic recovery journal EIO")

// Recovery receipts must survive before the sender can suppress their replay.
func TestRecoveryReceiptBarrierPrecedesTerminalPersistence(t *testing.T) {
	journalErr := errSyntheticRecoveryJournal
	for _, tc := range []struct {
		name         string
		kind         edgev1.EdgeRecordDispositionKind
		hookErr      error
		wantErr      error
		wantCalls    int
		wantResolved uint64
	}{
		{"durable receipt", edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE, nil, nil, 1, 1},
		{"journal refusal", edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE, journalErr, journalErr, 1, 0},
		{"invalid acknowledgement", edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_UNSPECIFIED, nil, edgerecord.ErrDisposition, 0, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			sp, err := spool.Open(dir)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = sp.Close() })
			id := mustEventID(t)
			if _, err := sp.Append(id, id); err != nil {
				t.Fatal(err)
			}
			cfg := testConfig(t)
			cfg.PersistAcknowledgements = true
			calls := 0
			cfg.BeforeResolve = func(receipt *edgerecord.ValidatedAck) error {
				calls++
				ack, session, err := receipt.Snapshot()
				if err != nil {
					t.Fatal(err)
				}
				if sp.Resolved() != 0 || session.ResolvedThrough != 0 || ack.ResolvedThroughSequence != 1 || !bytes.Equal(session.SpoolID, cfg.SpoolID) || !bytes.Equal(session.SentEvents[1], id) {
					t.Fatalf("receipt lost its sent-window binding or followed persistence: local=%d session=%+v ack=%v", sp.Resolved(), session, ack)
				}
				return tc.hookErr
			}
			srv := &fakeIngestServer{grantedByteCredits: 1 << 20, grantedFrameCredits: 100, dispositionKind: tc.kind}
			sender, err := New(sp, dialFakeIngest(t, srv), cfg)
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			result, err := sender.RunOnce(ctx)
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("RunOnce error=%v, want %v", err, tc.wantErr)
			}
			if calls != tc.wantCalls || result.RemoteResolvedThrough != tc.wantResolved {
				t.Fatalf("receipt calls=%d remote watermark=%d, want %d/%d", calls, result.RemoteResolvedThrough, tc.wantCalls, tc.wantResolved)
			}
			if err := sp.Close(); err != nil {
				t.Fatal(err)
			}
			reopened, err := spool.Open(dir)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = reopened.Close() }()
			if reopened.Resolved() != tc.wantResolved {
				t.Fatalf("durable watermark=%d, want %d", reopened.Resolved(), tc.wantResolved)
			}
			records, err := reopened.Unresolved()
			if err != nil {
				t.Fatal(err)
			}
			if tc.wantResolved == 0 {
				if len(records) != 1 || records[0].Sequence != 1 || !bytes.Equal(records[0].Body, id) || !bytes.Equal(records[0].EventID, id) {
					t.Fatalf("unresolved receipt lost replay bytes: %v", records)
				}
			} else if len(records) != 0 {
				t.Fatalf("persisted receipt replayed: %v", records)
			}
		})
	}
}
