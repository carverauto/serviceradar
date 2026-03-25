package agent

import (
	"context"
	"errors"
	"io"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/proto"
	gproto "google.golang.org/protobuf/proto"
)

const relayDrainAcknowledgedReason = "camera relay drain acknowledged"

var (
	errCameraRelayStreamFailed      = errors.New("camera relay stream failed")
	errRTSPDialFailed               = errors.New("rtsp dial failed")
	errPluginTerminatedUnexpectedly = errors.New("plugin terminated unexpectedly")
)

type fakeCameraRelayGateway struct {
	mu               sync.Mutex
	gatewayID        string
	uploadMessage    string
	heartbeatMessage string
	openRequests     []*proto.OpenRelaySessionRequest
	uploadBatches    [][]*proto.MediaChunk
	heartbeatReqs    []*proto.RelayHeartbeat
	closeRequests    []*proto.CloseRelaySessionRequest
	closeNotifyOnce  sync.Once
	closeNotifyCh    chan struct{}
}

func newFakeCameraRelayGateway() *fakeCameraRelayGateway {
	return &fakeCameraRelayGateway{
		gatewayID:        "gateway-test-1",
		uploadMessage:    "ok",
		heartbeatMessage: "ok",
		closeNotifyCh:    make(chan struct{}),
	}
}

func (f *fakeCameraRelayGateway) GetGatewayID() string {
	return f.gatewayID
}

func (f *fakeCameraRelayGateway) OpenRelaySession(_ context.Context, req *proto.OpenRelaySessionRequest) (*proto.OpenRelaySessionResponse, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.openRequests = append(f.openRequests, req)
	return &proto.OpenRelaySessionResponse{
		Accepted:           true,
		Message:            "accepted",
		MediaIngestId:      "media-123",
		MaxChunkBytes:      262_144,
		LeaseExpiresAtUnix: time.Now().Add(30 * time.Second).Unix(),
	}, nil
}

func (f *fakeCameraRelayGateway) UploadMedia(_ context.Context, chunks []*proto.MediaChunk) (*proto.UploadMediaResponse, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	copied := make([]*proto.MediaChunk, 0, len(chunks))
	var lastSequence uint64
	for _, chunk := range chunks {
		if chunk == nil {
			continue
		}
		copyChunk, ok := gproto.Clone(chunk).(*proto.MediaChunk)
		if !ok {
			panic("unexpected media chunk clone type")
		}
		copied = append(copied, copyChunk)
		lastSequence = chunk.GetSequence()
	}
	f.uploadBatches = append(f.uploadBatches, copied)
	return &proto.UploadMediaResponse{
		Received:     true,
		LastSequence: lastSequence,
		Message:      f.uploadMessage,
	}, nil
}

func (f *fakeCameraRelayGateway) HeartbeatRelaySession(_ context.Context, req *proto.RelayHeartbeat) (*proto.RelayHeartbeatAck, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.heartbeatReqs = append(f.heartbeatReqs, req)
	return &proto.RelayHeartbeatAck{
		Accepted:           true,
		LeaseExpiresAtUnix: time.Now().Add(30 * time.Second).Unix(),
		Message:            f.heartbeatMessage,
	}, nil
}

func (f *fakeCameraRelayGateway) CloseRelaySession(_ context.Context, req *proto.CloseRelaySessionRequest) (*proto.CloseRelaySessionResponse, error) {
	f.mu.Lock()
	f.closeRequests = append(f.closeRequests, req)
	f.mu.Unlock()

	f.closeNotifyOnce.Do(func() {
		close(f.closeNotifyCh)
	})

	return &proto.CloseRelaySessionResponse{Closed: true, Message: "closed"}, nil
}

type sliceCameraRelayStream struct {
	mu     sync.Mutex
	chunks []*cameraRelayChunk
	index  int
}

func (s *sliceCameraRelayStream) Recv(_ context.Context) (*cameraRelayChunk, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.index >= len(s.chunks) {
		return nil, io.EOF
	}
	chunk := s.chunks[s.index]
	s.index++
	return chunk, nil
}

func (s *sliceCameraRelayStream) Close() error {
	return nil
}

type blockingCameraRelayStream struct{}

func (s *blockingCameraRelayStream) Recv(ctx context.Context) (*cameraRelayChunk, error) {
	<-ctx.Done()
	return nil, ctx.Err()
}

func (s *blockingCameraRelayStream) Close() error {
	return nil
}

type failingCameraRelayStream struct {
	err error
}

func (s *failingCameraRelayStream) Recv(_ context.Context) (*cameraRelayChunk, error) {
	if s.err == nil {
		return nil, errCameraRelayStreamFailed
	}
	return nil, s.err
}

func (s *failingCameraRelayStream) Close() error {
	return nil
}

func TestCameraRelayManagerStartUploadsMediaAndCloses(t *testing.T) {
	t.Parallel()

	gateway := newFakeCameraRelayGateway()
	manager := newCameraRelayManager(gateway, createTestLogger())
	manager.uploadBatchSize = 2
	manager.sourceFactory = func(spec cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		if spec.MediaIngestID != "media-123" {
			t.Fatalf("expected media ingest id to be set before source open, got %q", spec.MediaIngestID)
		}
		return &sliceCameraRelayStream{
			chunks: []*cameraRelayChunk{
				{TrackID: "video", Payload: []byte("a"), Sequence: 1, Codec: "h264", PayloadFormat: "annexb"},
				{TrackID: "video", Payload: []byte("b"), Sequence: 2, IsFinal: true, Codec: "h264", PayloadFormat: "annexb"},
			},
		}, nil
	}

	state, err := manager.Start(context.Background(), cameraRelaySessionSpec{
		RelaySessionID:  "relay-1",
		AgentID:         "agent-1",
		CameraSourceID:  "camera-1",
		StreamProfileID: "main",
		LeaseToken:      "lease-1",
	})
	if err != nil {
		t.Fatalf("Start returned error: %v", err)
	}
	if state.MediaIngestID != "media-123" {
		t.Fatalf("expected media_ingest_id media-123, got %q", state.MediaIngestID)
	}

	select {
	case <-gateway.closeNotifyCh:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for relay session to close")
	}

	gateway.mu.Lock()
	defer gateway.mu.Unlock()

	if len(gateway.openRequests) != 1 {
		t.Fatalf("expected 1 open request, got %d", len(gateway.openRequests))
	}
	if len(gateway.uploadBatches) != 1 {
		t.Fatalf("expected 1 upload batch, got %d", len(gateway.uploadBatches))
	}
	if len(gateway.uploadBatches[0]) != 2 {
		t.Fatalf("expected 2 uploaded chunks, got %d", len(gateway.uploadBatches[0]))
	}
	if len(gateway.heartbeatReqs) != 1 {
		t.Fatalf("expected 1 heartbeat, got %d", len(gateway.heartbeatReqs))
	}
	if len(gateway.closeRequests) != 1 {
		t.Fatalf("expected 1 close request, got %d", len(gateway.closeRequests))
	}
	if got := gateway.closeRequests[0].GetReason(); got != "camera relay source completed" {
		t.Fatalf("expected close reason %q, got %q", "camera relay source completed", got)
	}
}

func TestCameraRelayManagerRejectsDuplicateRelaySession(t *testing.T) {
	t.Parallel()

	gateway := newFakeCameraRelayGateway()
	manager := newCameraRelayManager(gateway, createTestLogger())
	manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		return &blockingCameraRelayStream{}, nil
	}

	_, err := manager.Start(context.Background(), cameraRelaySessionSpec{
		RelaySessionID:  "relay-dup",
		AgentID:         "agent-1",
		CameraSourceID:  "camera-1",
		StreamProfileID: "main",
		LeaseToken:      "lease-1",
	})
	if err != nil {
		t.Fatalf("first Start returned error: %v", err)
	}

	_, err = manager.Start(context.Background(), cameraRelaySessionSpec{
		RelaySessionID:  "relay-dup",
		AgentID:         "agent-1",
		CameraSourceID:  "camera-1",
		StreamProfileID: "main",
		LeaseToken:      "lease-1",
	})
	if !errors.Is(err, errCameraRelaySessionExists) {
		t.Fatalf("expected errCameraRelaySessionExists, got %v", err)
	}

	stopCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := manager.Stop(stopCtx, cameraRelayStopPayload{RelaySessionID: "relay-dup", Reason: "test complete"}); err != nil {
		t.Fatalf("Stop returned error: %v", err)
	}
}

func TestCameraRelayManagerStopsWhenGatewayUploadEntersDrain(t *testing.T) {
	t.Parallel()
	testCameraRelayManagerStopsWhenGatewayEntersDrain(t, "relay-drain-upload-1", "media chunks accepted during relay drain", "", 0)
}

func TestCameraRelayManagerStopsWhenGatewayHeartbeatEntersDrain(t *testing.T) {
	t.Parallel()
	testCameraRelayManagerStopsWhenGatewayEntersDrain(t, "relay-drain-heartbeat-1", "", "core heartbeat accepted during relay drain", 1)
}

func testCameraRelayManagerStopsWhenGatewayEntersDrain(
	t *testing.T,
	relaySessionID string,
	uploadMessage string,
	heartbeatMessage string,
	expectedHeartbeats int,
) {
	t.Helper()

	gateway := newFakeCameraRelayGateway()
	gateway.uploadMessage = uploadMessage
	gateway.heartbeatMessage = heartbeatMessage

	manager := newCameraRelayManager(gateway, createTestLogger())
	manager.uploadBatchSize = 1
	manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		return &sliceCameraRelayStream{
			chunks: []*cameraRelayChunk{
				{TrackID: "video", Payload: []byte("a"), Sequence: 1, Codec: "h264", PayloadFormat: "annexb"},
			},
		}, nil
	}

	if _, err := manager.Start(context.Background(), cameraRelaySessionSpec{
		RelaySessionID:  relaySessionID,
		AgentID:         "agent-1",
		CameraSourceID:  "camera-1",
		StreamProfileID: "main",
		LeaseToken:      "lease-1",
	}); err != nil {
		t.Fatalf("Start returned error: %v", err)
	}

	select {
	case <-gateway.closeNotifyCh:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for relay session to close after drain")
	}

	gateway.mu.Lock()
	defer gateway.mu.Unlock()

	if len(gateway.uploadBatches) != 1 {
		t.Fatalf("expected 1 upload batch, got %d", len(gateway.uploadBatches))
	}
	if len(gateway.heartbeatReqs) != expectedHeartbeats {
		t.Fatalf("expected %d heartbeat(s) before drain close, got %d", expectedHeartbeats, len(gateway.heartbeatReqs))
	}
	if len(gateway.closeRequests) != 1 {
		t.Fatalf("expected 1 close request, got %d", len(gateway.closeRequests))
	}
	if got := gateway.closeRequests[0].GetReason(); got != relayDrainAcknowledgedReason {
		t.Fatalf("expected close reason %q, got %q", relayDrainAcknowledgedReason, got)
	}
}

func TestCameraRelayManagerClosesUpstreamWhenCameraSourceStartupFails(t *testing.T) {
	t.Parallel()

	gateway := newFakeCameraRelayGateway()
	manager := newCameraRelayManager(gateway, createTestLogger())
	manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		return nil, errRTSPDialFailed
	}

	_, err := manager.Start(context.Background(), cameraRelaySessionSpec{
		RelaySessionID:  "relay-source-fail-1",
		AgentID:         "agent-1",
		CameraSourceID:  "camera-1",
		StreamProfileID: "main",
		LeaseToken:      "lease-1",
	})
	if err == nil {
		t.Fatal("expected source startup failure, got nil")
	}
	if got := err.Error(); got != "rtsp dial failed" {
		t.Fatalf("expected source startup error, got %q", got)
	}

	select {
	case <-gateway.closeNotifyCh:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for upstream relay close after source startup failure")
	}

	gateway.mu.Lock()
	defer gateway.mu.Unlock()

	if len(gateway.openRequests) != 1 {
		t.Fatalf("expected 1 open request, got %d", len(gateway.openRequests))
	}
	if len(gateway.closeRequests) != 1 {
		t.Fatalf("expected 1 close request, got %d", len(gateway.closeRequests))
	}
	if got := gateway.closeRequests[0].GetReason(); got != "source_start_failed" {
		t.Fatalf("expected close reason %q, got %q", "source_start_failed", got)
	}

	stopCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := manager.Stop(stopCtx, cameraRelayStopPayload{RelaySessionID: "relay-source-fail-1"}); !errors.Is(err, errCameraRelaySessionNotFound) {
		t.Fatalf("expected errCameraRelaySessionNotFound after startup failure cleanup, got %v", err)
	}
}

func TestCameraRelayManagerClosesUpstreamWhenPluginStreamFails(t *testing.T) {
	t.Parallel()

	gateway := newFakeCameraRelayGateway()
	manager := newCameraRelayManager(gateway, createTestLogger())
	manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		t.Fatal("expected plugin source factory to be used")
		return nil, nil
	}
	manager.pluginSourceFactory = func(_ context.Context, spec cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		if spec.PluginAssignmentID != "streaming-plugin-1" {
			t.Fatalf("unexpected plugin assignment id: %s", spec.PluginAssignmentID)
		}
		return &failingCameraRelayStream{err: errPluginTerminatedUnexpectedly}, nil
	}

	if _, err := manager.Start(context.Background(), cameraRelaySessionSpec{
		RelaySessionID:     "relay-plugin-fail-1",
		AgentID:            "agent-1",
		CameraSourceID:     "camera-1",
		StreamProfileID:    "main",
		LeaseToken:         "lease-1",
		PluginAssignmentID: "streaming-plugin-1",
	}); err != nil {
		t.Fatalf("Start returned error: %v", err)
	}

	select {
	case <-gateway.closeNotifyCh:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for upstream relay close after plugin stream failure")
	}

	gateway.mu.Lock()
	defer gateway.mu.Unlock()

	if len(gateway.openRequests) != 1 {
		t.Fatalf("expected 1 open request, got %d", len(gateway.openRequests))
	}
	if len(gateway.closeRequests) != 1 {
		t.Fatalf("expected 1 close request, got %d", len(gateway.closeRequests))
	}
	if got := gateway.closeRequests[0].GetReason(); got != "camera relay source failed" {
		t.Fatalf("expected close reason %q, got %q", "camera relay source failed", got)
	}
}

func TestNormalizeCameraRelaySpecRequiresFields(t *testing.T) {
	t.Parallel()

	_, err := normalizeCameraRelaySpec(cameraRelaySessionSpec{})
	if err == nil {
		t.Fatal("expected validation error, got nil")
	}
	if got := err.Error(); got != "relay_session_id is required" {
		t.Fatalf("expected relay_session_id validation error, got %q", got)
	}
}

func TestDefaultCameraRelaySourceRequiresSourceURL(t *testing.T) {
	t.Parallel()

	_, err := defaultCameraRelaySource(cameraRelaySessionSpec{})
	if err == nil {
		t.Fatal("expected source_url validation error, got nil")
	}
	if got := err.Error(); got != "source_url is required" {
		t.Fatalf("expected source_url validation error, got %q", got)
	}
}

func TestParseCameraRelayRTSPTransport(t *testing.T) {
	t.Parallel()

	if _, err := parseCameraRelayRTSPTransport("tcp"); err != nil {
		t.Fatalf("expected tcp transport to parse, got %v", err)
	}
	if _, err := parseCameraRelayRTSPTransport("udp"); err != nil {
		t.Fatalf("expected udp transport to parse, got %v", err)
	}
	if _, err := parseCameraRelayRTSPTransport("bogus"); err == nil {
		t.Fatal("expected invalid transport to fail")
	}
}
