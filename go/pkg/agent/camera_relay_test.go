package agent

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/bluenviron/gortsplib/v5"
	"github.com/bluenviron/gortsplib/v5/pkg/base"
	"github.com/bluenviron/gortsplib/v5/pkg/description"
	"github.com/bluenviron/gortsplib/v5/pkg/format"
	"github.com/bluenviron/gortsplib/v5/pkg/liberrors"
	"github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/rs/zerolog"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	gproto "google.golang.org/protobuf/proto"
)

const (
	relayDrainAcknowledgedReason = "camera relay drain acknowledged"
	relayTestMediaIngestID       = "media-123"
)

var (
	errCameraRelayStreamFailed      = errors.New("camera relay stream failed")
	errRTSPDialFailed               = errors.New("rtsp dial failed")
	errPluginTerminatedUnexpectedly = errors.New("plugin terminated unexpectedly")
	errSyntheticCloseFailure        = errors.New("synthetic close failure")
	// crypto/tls reports a peer alert with an unexported type; this has its text.
	errSyntheticTLSAlert  = errors.New("tls: handshake failure")
	errSyntheticReadError = errors.New("connection stalled")
)

type fakeCameraRelayGateway struct {
	mu               sync.Mutex
	gatewayID        string
	uploadMessage    string
	heartbeatMessage string
	uploadErr        error
	uploadAttempts   int
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
		MediaIngestId:      relayTestMediaIngestID,
		MaxChunkBytes:      1_048_576,
		LeaseExpiresAtUnix: time.Now().Add(30 * time.Second).Unix(),
	}, nil
}

func (f *fakeCameraRelayGateway) UploadMedia(_ context.Context, chunks []*proto.MediaChunk) (*proto.UploadMediaResponse, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.uploadAttempts++
	if f.uploadErr != nil {
		return nil, f.uploadErr
	}
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

type cameraRelayRPCServer struct {
	proto.UnimplementedCameraMediaServiceServer
	blockedOperation string
	failureOperation string
	failureCode      codes.Code
	entered          chan struct{}
	closed           chan *proto.CloseRelaySessionRequest
}

func (s *cameraRelayRPCServer) result(ctx context.Context, operation, relayID string) error {
	if relayID == "relay-interrupted-1" && operation == s.blockedOperation {
		close(s.entered)
		<-ctx.Done()
		return status.FromContextError(ctx.Err()).Err()
	}
	if relayID == "relay-rejected-1" && operation == s.failureOperation {
		return status.Error(s.failureCode, "synthetic camera RPC failure")
	}
	return nil
}

func (s *cameraRelayRPCServer) OpenRelaySession(ctx context.Context, req *proto.OpenRelaySessionRequest) (*proto.OpenRelaySessionResponse, error) {
	if err := s.result(ctx, "open", req.GetRelaySessionId()); err != nil {
		return nil, err
	}
	return &proto.OpenRelaySessionResponse{Accepted: true, MediaIngestId: "media-synthetic-1"}, nil
}

func (s *cameraRelayRPCServer) UploadMedia(stream grpc.ClientStreamingServer[proto.MediaChunk, proto.UploadMediaResponse]) error {
	var relayID string
	var sequence uint64
	for {
		chunk, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		relayID = chunk.GetRelaySessionId()
		sequence = chunk.GetSequence()
	}
	if err := s.result(stream.Context(), "upload", relayID); err != nil {
		return err
	}
	return stream.SendAndClose(&proto.UploadMediaResponse{Received: true, LastSequence: sequence})
}

func (s *cameraRelayRPCServer) Heartbeat(ctx context.Context, req *proto.RelayHeartbeat) (*proto.RelayHeartbeatAck, error) {
	if err := s.result(ctx, "heartbeat", req.GetRelaySessionId()); err != nil {
		return nil, err
	}
	return &proto.RelayHeartbeatAck{Accepted: true}, nil
}

func (s *cameraRelayRPCServer) CloseRelaySession(ctx context.Context, req *proto.CloseRelaySessionRequest) (*proto.CloseRelaySessionResponse, error) {
	if err := s.result(ctx, "close", req.GetRelaySessionId()); err != nil {
		return nil, err
	}
	s.closed <- req
	return &proto.CloseRelaySessionResponse{Closed: true}, nil
}

func newCameraRelayRPCClient(t *testing.T, service proto.CameraMediaServiceServer) (*agentgateway.GatewayClient, *grpc.Server, string) {
	t.Helper()
	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer()
	proto.RegisterCameraMediaServiceServer(server, service)
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(server.Stop)
	client := agentgateway.NewGatewayClient(listener.Addr().String(), nil, createTestLogger())
	t.Cleanup(func() { _ = client.Disconnect() })
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	if err := client.Connect(ctx); err != nil {
		t.Fatalf("connect real gateway client: %v", err)
	}
	return client, server, listener.Addr().String()
}

func TestCameraRelayManagerStopCancelsMediaRPCWithoutDisconnecting(t *testing.T) {
	t.Setenv("SR_ALLOW_INSECURE", "true")
	for _, operation := range []string{"upload", "heartbeat"} {
		t.Run(operation, func(t *testing.T) {
			service := &cameraRelayRPCServer{
				blockedOperation: operation,
				entered:          make(chan struct{}),
				closed:           make(chan *proto.CloseRelaySessionRequest, 2),
			}
			gateway, _, _ := newCameraRelayRPCClient(t, service)
			manager := newCameraRelayManager(gateway, createTestLogger())
			manager.uploadBatchSize = 1
			manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
				return &sliceCameraRelayStream{chunks: []*cameraRelayChunk{
					{TrackID: "video", Payload: []byte("invented-frame"), Sequence: 1, Codec: "h264", PayloadFormat: "annexb"},
				}}, nil
			}
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			_, err := manager.Start(ctx, cameraRelaySessionSpec{
				RelaySessionID: "relay-interrupted-1", AgentID: "agent-synthetic-1", CameraSourceID: "camera-synthetic-1",
				StreamProfileID: "main", LeaseToken: "lease-synthetic-1",
			})
			if err != nil {
				t.Fatalf("Start: %v", err)
			}
			select {
			case <-service.entered:
			case <-ctx.Done():
				t.Fatalf("%s did not start", operation)
			}
			if err := manager.Stop(ctx, cameraRelayStopPayload{RelaySessionID: "relay-interrupted-1", Reason: "operator stop"}); err != nil {
				t.Fatalf("Stop: %v", err)
			}
			select {
			case req := <-service.closed:
				if req.GetReason() != "operator stop" || req.GetMediaIngestId() != "media-synthetic-1" {
					t.Fatalf("unexpected cleanup request: %v", req)
				}
			case <-ctx.Done():
				t.Fatal("upstream cleanup was not delivered")
			}
			if !gateway.IsConnected() {
				t.Fatal("intentional cancellation disconnected the shared gateway")
			}
			resp, err := gateway.UploadMedia(ctx, []*proto.MediaChunk{{RelaySessionId: "relay-survivor-1", Payload: []byte("fresh-frame"), Sequence: 2}})
			if err != nil || !resp.GetReceived() || resp.GetLastSequence() != 2 {
				t.Fatalf("sibling relay upload after cancellation: response=%v error=%v", resp, err)
			}
		})
	}
}

func TestCameraGatewayRPCErrorClassificationAndRecovery(t *testing.T) {
	t.Setenv("SR_ALLOW_INSECURE", "true")
	for _, operation := range []string{"open", "upload", "heartbeat", "close"} {
		for _, code := range []codes.Code{codes.Canceled, codes.DeadlineExceeded, codes.NotFound, codes.PermissionDenied, codes.Unavailable} {
			t.Run(operation+"/"+code.String(), func(t *testing.T) {
				service := &cameraRelayRPCServer{failureOperation: operation, failureCode: code, closed: make(chan *proto.CloseRelaySessionRequest, 1)}
				gateway, _, _ := newCameraRelayRPCClient(t, service)
				ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
				defer cancel()
				var err error
				switch operation {
				case "open":
					_, err = gateway.OpenRelaySession(ctx, &proto.OpenRelaySessionRequest{RelaySessionId: "relay-rejected-1"})
				case "upload":
					_, err = gateway.UploadMedia(ctx, []*proto.MediaChunk{{RelaySessionId: "relay-rejected-1", Payload: []byte("invented-payload")}})
				case "heartbeat":
					_, err = gateway.HeartbeatRelaySession(ctx, &proto.RelayHeartbeat{RelaySessionId: "relay-rejected-1"})
				case "close":
					_, err = gateway.CloseRelaySession(ctx, &proto.CloseRelaySessionRequest{RelaySessionId: "relay-rejected-1"})
				}
				if status.Code(err) != code || !strings.Contains(status.Convert(err).Message(), "synthetic camera RPC failure") {
					t.Fatalf("lost actionable RPC error: %v", err)
				}
				if code == codes.Unavailable {
					if gateway.IsConnected() {
						t.Fatal("transport failure did not disconnect")
					}
					if err := gateway.Connect(ctx); err != nil {
						t.Fatalf("reconnect after transport failure: %v", err)
					}
				} else if !gateway.IsConnected() {
					t.Fatal("session-local error disconnected the shared gateway")
				}
				resp, err := gateway.CloseRelaySession(ctx, &proto.CloseRelaySessionRequest{RelaySessionId: "relay-cleanup-1", Reason: "test cleanup"})
				if err != nil || !resp.GetClosed() {
					t.Fatalf("cleanup after RPC error: response=%v error=%v", resp, err)
				}
				select {
				case <-service.closed:
				case <-ctx.Done():
					t.Fatal("gateway did not receive cleanup")
				}
			})
		}
	}
}

func TestCameraGatewayTransportFailureRecovers(t *testing.T) {
	t.Setenv("SR_ALLOW_INSECURE", "true")
	service := &cameraRelayRPCServer{blockedOperation: "upload", entered: make(chan struct{}), closed: make(chan *proto.CloseRelaySessionRequest, 1)}
	gateway, server, address := newCameraRelayRPCClient(t, service)
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	result := make(chan error, 1)
	go func() {
		_, err := gateway.UploadMedia(ctx, []*proto.MediaChunk{{RelaySessionId: "relay-interrupted-1", Payload: []byte("invented-transport-frame")}})
		result <- err
	}()
	select {
	case <-service.entered:
	case <-ctx.Done():
		t.Fatal("upload did not reach gateway")
	}
	server.Stop()
	select {
	case err := <-result:
		if status.Code(err) != codes.Unavailable {
			t.Fatalf("transport failure: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("transport failure did not return")
	}
	if gateway.IsConnected() {
		t.Fatal("lost transport still marked connected")
	}
	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	replacement := grpc.NewServer()
	proto.RegisterCameraMediaServiceServer(replacement, &cameraRelayRPCServer{closed: make(chan *proto.CloseRelaySessionRequest, 1)})
	go func() { _ = replacement.Serve(listener) }()
	t.Cleanup(replacement.Stop)
	if err := gateway.Connect(ctx); err != nil {
		t.Fatalf("reconnect to recovered gateway: %v", err)
	}
	resp, err := gateway.UploadMedia(ctx, []*proto.MediaChunk{{RelaySessionId: "relay-recovered-1", Payload: []byte("invented-recovery-frame"), Sequence: 3}})
	if err != nil || !resp.GetReceived() || resp.GetLastSequence() != 3 {
		t.Fatalf("upload after transport recovery: response=%v error=%v", resp, err)
	}
}

type allocatedCameraRelayRPCServer struct {
	*cameraRelayRPCServer
	allocated    chan struct{}
	releaseOpen  chan struct{}
	closeEntered chan *proto.CloseRelaySessionRequest
	releaseClose chan struct{}
	ingressDone  chan struct{}
}

func (s *allocatedCameraRelayRPCServer) OpenRelaySession(ctx context.Context, req *proto.OpenRelaySessionRequest) (*proto.OpenRelaySessionResponse, error) {
	if req.GetRelaySessionId() != "relay-allocation-delay-1" {
		return s.cameraRelayRPCServer.OpenRelaySession(ctx, req)
	}
	close(s.allocated)
	select {
	case <-s.releaseOpen:
		return &proto.OpenRelaySessionResponse{Accepted: true, MediaIngestId: "media-allocation-delay-1"}, nil
	case <-ctx.Done():
		return nil, status.FromContextError(ctx.Err()).Err()
	}
}

func (s *allocatedCameraRelayRPCServer) CloseRelaySession(ctx context.Context, req *proto.CloseRelaySessionRequest) (*proto.CloseRelaySessionResponse, error) {
	if req.GetRelaySessionId() != "relay-allocation-delay-1" {
		return s.cameraRelayRPCServer.CloseRelaySession(ctx, req)
	}
	if req.GetMediaIngestId() != "media-allocation-delay-1" {
		return nil, status.Error(codes.NotFound, "synthetic ingress ID mismatch")
	}
	s.closeEntered <- req
	select {
	case <-s.releaseClose:
		close(s.ingressDone)
		return s.cameraRelayRPCServer.CloseRelaySession(ctx, req)
	case <-ctx.Done():
		return nil, status.FromContextError(ctx.Err()).Err()
	}
}

type cameraRelayStopWaitContext struct {
	context.Context
	waiting chan struct{}
	once    sync.Once
}

func (c *cameraRelayStopWaitContext) Done() <-chan struct{} {
	c.once.Do(func() { close(c.waiting) })
	return c.Context.Done()
}

// pendingOpenStopScenario drives one startup-stop race: Stop arrives while
// the gateway has allocated an ingress but not yet answered OpenRelaySession.
// Each method is one phase of that single scenario and must run in order.
type pendingOpenStopScenario struct {
	t           *testing.T
	ctx         context.Context
	service     *allocatedCameraRelayRPCServer
	gateway     *agentgateway.GatewayClient
	manager     *cameraRelayManager
	spec        cameraRelaySessionSpec
	startResult chan error
	stopResult  chan error
}

func TestCameraRelayManagerStopClosesIngressAllocatedBeforeOpenResponse(t *testing.T) {
	t.Setenv("SR_ALLOW_INSECURE", "true")
	service := &allocatedCameraRelayRPCServer{
		cameraRelayRPCServer: &cameraRelayRPCServer{closed: make(chan *proto.CloseRelaySessionRequest, 1)},
		allocated:            make(chan struct{}), releaseOpen: make(chan struct{}),
		closeEntered: make(chan *proto.CloseRelaySessionRequest, 1), releaseClose: make(chan struct{}),
		ingressDone: make(chan struct{}),
	}
	gateway, _, _ := newCameraRelayRPCClient(t, service)
	manager := newCameraRelayManager(gateway, createTestLogger())
	manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		t.Error("stopped relay reached source startup")
		return &blockingCameraRelayStream{}, nil
	}
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	scenario := &pendingOpenStopScenario{
		t: t, ctx: ctx, service: service, gateway: gateway, manager: manager,
		spec: cameraRelaySessionSpec{
			RelaySessionID: "relay-allocation-delay-1", AgentID: "agent-invented-4", CameraSourceID: "camera-invented-4",
			StreamProfileID: "main", LeaseToken: "lease-invented-4",
		},
		startResult: make(chan error, 1),
		stopResult:  make(chan error, 1),
	}

	scenario.startUntilIngressAllocated()
	scenario.stopWhileOpenPending()
	scenario.releaseOpenAndAwaitIngressCleanup()
	scenario.releaseCloseAndAwaitStop()
	scenario.assertSessionReleased()
	scenario.assertFreshRelayRuns()
}

func (s *pendingOpenStopScenario) startUntilIngressAllocated() {
	s.t.Helper()
	go func() { _, err := s.manager.Start(s.ctx, s.spec); s.startResult <- err }()
	select {
	case <-s.service.allocated:
	case <-s.ctx.Done():
		s.t.Fatal("upstream ingress was not allocated")
	}
}

func (s *pendingOpenStopScenario) stopWhileOpenPending() {
	s.t.Helper()
	stopCtx := &cameraRelayStopWaitContext{Context: s.ctx, waiting: make(chan struct{})}
	go func() {
		s.stopResult <- s.manager.Stop(stopCtx, cameraRelayStopPayload{RelaySessionID: s.spec.RelaySessionID, Reason: "operator pending-open stop"})
	}()
	select {
	case <-stopCtx.waiting:
	case <-s.ctx.Done():
		s.t.Fatal("Stop did not begin waiting")
	}
	select {
	case err := <-s.stopResult:
		s.t.Fatalf("Stop completed before the allocated ingress open response: %v", err)
	default:
	}
}

func (s *pendingOpenStopScenario) releaseOpenAndAwaitIngressCleanup() {
	s.t.Helper()
	close(s.service.releaseOpen)
	select {
	case req := <-s.service.closeEntered:
		if req.GetReason() != "operator pending-open stop" || req.GetAgentId() != s.spec.AgentID {
			s.t.Fatalf("unexpected allocated ingress cleanup: %v", req)
		}
	case err := <-s.stopResult:
		s.t.Fatalf("Stop completed before allocated ingress cleanup: %v", err)
	case <-s.ctx.Done():
		s.t.Fatal("allocated ingress cleanup did not reach gateway")
	}
	select {
	case err := <-s.startResult:
		s.t.Fatalf("Start completed before upstream close: %v", err)
	case err := <-s.stopResult:
		s.t.Fatalf("Stop completed before upstream close: %v", err)
	default:
	}
	if _, err := s.manager.Start(s.ctx, s.spec); !errors.Is(err, errCameraRelaySessionExists) {
		s.t.Fatalf("upstream close released session ownership too early: %v", err)
	}
}

func (s *pendingOpenStopScenario) releaseCloseAndAwaitStop() {
	s.t.Helper()
	close(s.service.releaseClose)
	select {
	case err := <-s.stopResult:
		if err != nil {
			s.t.Fatalf("Stop after upstream close: %v", err)
		}
	case <-s.ctx.Done():
		s.t.Fatal("Stop did not complete after upstream close")
	}
	select {
	case <-s.service.ingressDone:
	default:
		s.t.Fatal("Stop reported success with an allocated ingress")
	}
	select {
	case err := <-s.startResult:
		if !errors.Is(err, context.Canceled) {
			s.t.Fatalf("stopped startup: %v", err)
		}
	case <-s.ctx.Done():
		s.t.Fatal("stopped startup did not return")
	}
}

func (s *pendingOpenStopScenario) assertSessionReleased() {
	s.t.Helper()
	select {
	case req := <-s.service.closed:
		if req.GetRelaySessionId() != s.spec.RelaySessionID || req.GetMediaIngestId() != "media-allocation-delay-1" {
			s.t.Fatalf("wrong ingress closed: %v", req)
		}
	default:
		s.t.Fatal("upstream close was not acknowledged")
	}
	if !s.gateway.IsConnected() {
		s.t.Fatal("pending-open Stop disconnected the shared gateway")
	}
	if err := s.manager.Stop(s.ctx, cameraRelayStopPayload{RelaySessionID: s.spec.RelaySessionID}); !errors.Is(err, errCameraRelaySessionNotFound) {
		s.t.Fatalf("closed ingress remained registered: %v", err)
	}
}

func (s *pendingOpenStopScenario) assertFreshRelayRuns() {
	s.t.Helper()
	s.manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		return &sliceCameraRelayStream{chunks: []*cameraRelayChunk{{TrackID: "video", Payload: []byte("invented-recovery-frame"), Sequence: 4, IsFinal: true}}}, nil
	}
	spec := s.spec
	spec.RelaySessionID = "relay-allocation-recovery-1"
	if _, err := s.manager.Start(s.ctx, spec); err != nil {
		s.t.Fatalf("fresh relay after pending-open cleanup: %v", err)
	}
	select {
	case req := <-s.service.closed:
		if req.GetRelaySessionId() != spec.RelaySessionID || req.GetReason() != cameraRelayReasonSourceCompleted {
			s.t.Fatalf("unexpected recovery cleanup: %v", req)
		}
	case <-s.ctx.Done():
		s.t.Fatal("fresh relay did not upload and close")
	}
}

type startupCameraRelayStream struct {
	*sliceCameraRelayStream
	closed chan struct{}
}

func (s *startupCameraRelayStream) Close() error {
	close(s.closed)
	return nil
}

func TestCameraRelayManagerStopDuringSourceStartup(t *testing.T) {
	t.Parallel()
	for _, scenario := range []struct {
		name              string
		plugin            bool
		obeysCancellation bool
		fails             bool
	}{
		{name: "native late source"},
		{name: "native startup failure", fails: true},
		{name: "plugin cancellation", plugin: true, obeysCancellation: true},
		{name: "plugin cancelled startup failure", plugin: true, obeysCancellation: true, fails: true},
		{name: "plugin late source", plugin: true},
		{name: "plugin startup failure", plugin: true, fails: true},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			gateway := newFakeCameraRelayGateway()
			manager := newCameraRelayManager(gateway, createTestLogger())
			entered := make(chan struct{})
			release := make(chan struct{})
			stream := &startupCameraRelayStream{
				sliceCameraRelayStream: &sliceCameraRelayStream{chunks: []*cameraRelayChunk{{Payload: []byte("invented-startup-frame"), Sequence: 1, IsFinal: true}}},
				closed:                 make(chan struct{}),
			}
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			open := func(sourceCtx context.Context, _ cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
				close(entered)
				if scenario.obeysCancellation {
					<-sourceCtx.Done()
					if scenario.fails {
						return nil, errRTSPDialFailed
					}
					return nil, sourceCtx.Err()
				}
				select {
				case <-release:
				case <-ctx.Done():
					return nil, ctx.Err()
				}
				if scenario.fails {
					return nil, errRTSPDialFailed
				}
				return stream, nil
			}
			spec := cameraRelaySessionSpec{
				RelaySessionID: "relay-startup-1", AgentID: "agent-synthetic-2", CameraSourceID: "camera-synthetic-2",
				StreamProfileID: "main", LeaseToken: "lease-synthetic-2",
			}
			if scenario.plugin {
				spec.PluginAssignmentID = "plugin-synthetic-1"
				manager.pluginSourceFactory = open
			} else {
				manager.sourceFactory = func(spec cameraRelaySessionSpec) (cameraRelayChunkStream, error) { return open(ctx, spec) }
			}
			started := make(chan error, 1)
			go func() { _, err := manager.Start(ctx, spec); started <- err }()
			select {
			case <-entered:
			case <-ctx.Done():
				t.Fatal("source startup did not begin")
			}
			stopCtx, cancelStop := context.WithCancel(ctx)
			defer cancelStop()
			if !scenario.obeysCancellation {
				cancelStop()
			}
			if err := manager.Stop(stopCtx, cameraRelayStopPayload{RelaySessionID: spec.RelaySessionID, Reason: "operator startup stop"}); err != nil && !errors.Is(err, context.Canceled) {
				t.Fatalf("Stop: %v", err)
			}
			close(release)
			wantErr := context.Canceled
			if scenario.fails {
				wantErr = errRTSPDialFailed
			}
			select {
			case err := <-started:
				if !errors.Is(err, wantErr) {
					t.Fatalf("Start after Stop: got %v, want %v", err, wantErr)
				}
			case <-ctx.Done():
				t.Fatal("cancelled startup did not finish")
			}
			if !scenario.fails && !scenario.obeysCancellation {
				select {
				case <-stream.closed:
				default:
					t.Fatal("late source was not closed")
				}
			}
			gateway.mu.Lock()
			if len(gateway.uploadBatches) != 0 || len(gateway.heartbeatReqs) != 0 || len(gateway.closeRequests) != 1 {
				t.Errorf("stopped startup: uploads=%d heartbeats=%d closes=%d", len(gateway.uploadBatches), len(gateway.heartbeatReqs), len(gateway.closeRequests))
			} else if req := gateway.closeRequests[0]; req.GetReason() != "operator startup stop" || req.GetMediaIngestId() != relayTestMediaIngestID || req.GetFailureReason() != "" {
				t.Errorf("unexpected startup cleanup: %v", req)
			}
			gateway.mu.Unlock()
			if err := manager.Stop(ctx, cameraRelayStopPayload{RelaySessionID: spec.RelaySessionID}); !errors.Is(err, errCameraRelaySessionNotFound) {
				t.Fatalf("startup session remained registered: %v", err)
			}
			manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) { return &blockingCameraRelayStream{}, nil }
			spec.PluginAssignmentID = ""
			if _, err := manager.Start(ctx, spec); err != nil {
				t.Fatalf("restart after cancelled startup: %v", err)
			}
			if err := manager.Stop(ctx, cameraRelayStopPayload{RelaySessionID: spec.RelaySessionID}); err != nil {
				t.Fatalf("normal cleanup after restart: %v", err)
			}
		})
	}
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

// The identity belongs to the source registry, survives relay/control lifetimes,
// and changes when that registry is replaced. It never proves the old source stopped.
func TestCameraRelayRuntimeIncarnation(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var previous string
	for _, runtimeID := range []string{"first", "replacement"} {
		gateway := newFakeCameraRelayGateway()
		manager := newCameraRelayManager(gateway, createTestLogger())
		manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
			return &blockingCameraRelayStream{}, nil
		}
		var current string
		for _, relayID := range []string{"one", "two"} {
			sessionID := runtimeID + "-" + relayID
			_, err := manager.Start(ctx, cameraRelaySessionSpec{
				RelaySessionID: sessionID, AgentID: "agent-example",
				CameraSourceID: "camera-example", StreamProfileID: "main", LeaseToken: "lease-example",
			})
			if err != nil {
				t.Fatalf("Start: %v", err)
			}
			if err := manager.Stop(ctx, cameraRelayStopPayload{RelaySessionID: sessionID}); err != nil {
				t.Fatalf("Stop: %v", err)
			}
			gateway.mu.Lock()
			request := gateway.openRequests[len(gateway.openRequests)-1]
			gateway.mu.Unlock()
			wire, err := gproto.Marshal(request)
			if err != nil {
				t.Fatal(err)
			}
			var received proto.OpenRelaySessionRequest
			if err := gproto.Unmarshal(wire, &received); err != nil {
				t.Fatal(err)
			}
			got := received.GetSourceIncarnationId()
			if got == "" {
				t.Fatal("source runtime identity missing on media open")
			}
			if current != "" && got != current {
				t.Fatal("relay replacement changed runtime identity")
			}
			current = got
		}
		if current == previous {
			t.Fatal("new source runtime inherited its predecessor identity")
		}
		previous = current
	}
}

func TestCameraRelayManagerStartUploadsMediaAndCloses(t *testing.T) {
	t.Parallel()

	gateway := newFakeCameraRelayGateway()
	manager := newCameraRelayManager(gateway, createTestLogger())
	manager.uploadBatchSize = 2
	manager.sourceFactory = func(spec cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		if spec.MediaIngestID != relayTestMediaIngestID {
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
	if state.MediaIngestID != relayTestMediaIngestID {
		t.Fatalf("expected media_ingest_id %q, got %q", relayTestMediaIngestID, state.MediaIngestID)
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
	if got := gateway.closeRequests[0].GetReason(); got != cameraRelayReasonSourceCompleted {
		t.Fatalf("expected close reason %q, got %q", cameraRelayReasonSourceCompleted, got)
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

// gatedCameraRelayStream keeps source teardown pending after upstream has closed.
type gatedCameraRelayStream struct {
	blockingCameraRelayStream
	closing  chan struct{}
	release  chan struct{}
	ctx      context.Context
	closeErr error
}

func (s *gatedCameraRelayStream) Close() error {
	close(s.closing)
	select {
	case <-s.release:
	case <-s.ctx.Done():
	}
	return s.closeErr
}

func TestCameraRelayManagerReservesSourceProfileUntilClose(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	gateway := newFakeCameraRelayGateway()
	manager := newCameraRelayManager(gateway, createTestLogger())
	spec := cameraRelaySessionSpec{
		RelaySessionID: "relay-owner", AgentID: "agent-synthetic", CameraSourceID: "camera-synthetic",
		StreamProfileID: "main", LeaseToken: "lease-synthetic",
	}
	opening := make(chan struct{})
	releaseOpen := make(chan struct{})
	stream := &gatedCameraRelayStream{closing: make(chan struct{}), release: make(chan struct{}), ctx: ctx}
	manager.sourceFactory = func(candidate cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		if candidate.RelaySessionID != spec.RelaySessionID {
			return &blockingCameraRelayStream{}, nil
		}
		close(opening)
		select {
		case <-releaseOpen:
			return stream, nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	started := make(chan error, 1)
	go func() { _, err := manager.Start(ctx, spec); started <- err }()
	select {
	case <-opening:
	case <-ctx.Done():
		t.Fatal("source startup did not begin")
	}

	competitor := spec
	competitor.RelaySessionID = "relay-replacement"
	// Normalization must not turn whitespace into a distinct physical owner.
	competitor.CameraSourceID = " " + spec.CameraSourceID + " "
	competitor.StreamProfileID = " " + spec.StreamProfileID + " "
	assertRejected := func(phase string) {
		t.Helper()
		gateway.mu.Lock()
		before := len(gateway.openRequests)
		gateway.mu.Unlock()
		if _, err := manager.Start(ctx, competitor); err == nil {
			t.Fatalf("%s: another relay opened the same camera/profile", phase)
		}
		gateway.mu.Lock()
		after := len(gateway.openRequests)
		gateway.mu.Unlock()
		if after != before {
			t.Fatalf("%s: rejected source reached upstream admission", phase)
		}
	}
	assertRejected("source opening")
	close(releaseOpen)
	select {
	case err := <-started:
		if err != nil {
			t.Fatalf("Start: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("source startup did not complete")
	}
	assertRejected("source running")

	// Profiles are independent; a reservation must not block other cameras either.
	for _, sibling := range []cameraRelaySessionSpec{
		{RelaySessionID: "relay-sub", AgentID: spec.AgentID, CameraSourceID: spec.CameraSourceID, StreamProfileID: "sub", LeaseToken: "lease-sub"},
		{RelaySessionID: "relay-other", AgentID: spec.AgentID, CameraSourceID: "camera-other", StreamProfileID: spec.StreamProfileID, LeaseToken: "lease-other"},
	} {
		if _, err := manager.Start(ctx, sibling); err != nil {
			t.Fatalf("independent source/profile refused: %v", err)
		}
		if err := manager.Stop(ctx, cameraRelayStopPayload{RelaySessionID: sibling.RelaySessionID}); err != nil {
			t.Fatalf("independent source/profile cleanup: %v", err)
		}
	}

	// A caller giving up on Stop must not release the still-closing source.
	stopCtx, cancelStop := context.WithCancel(ctx)
	cancelStop()
	if err := manager.Stop(stopCtx, cameraRelayStopPayload{RelaySessionID: spec.RelaySessionID}); !errors.Is(err, context.Canceled) {
		t.Fatalf("Stop with expired caller: %v", err)
	}
	select {
	case <-stream.closing:
	case <-ctx.Done():
		t.Fatal("source teardown did not begin")
	}
	assertRejected("source closing")
	close(stream.release)
	if err := manager.Stop(ctx, cameraRelayStopPayload{RelaySessionID: spec.RelaySessionID}); err != nil && !errors.Is(err, errCameraRelaySessionNotFound) {
		t.Fatalf("source teardown: %v", err)
	}
	if _, err := manager.Start(ctx, competitor); err != nil {
		t.Fatalf("replacement after source close: %v", err)
	}
	if err := manager.Stop(ctx, cameraRelayStopPayload{RelaySessionID: competitor.RelaySessionID}); err != nil {
		t.Fatalf("replacement cleanup: %v", err)
	}
}

func TestCameraRelayManagerDoesNotRetryFailedUpload(t *testing.T) {
	t.Parallel()
	gateway := newFakeCameraRelayGateway()
	gateway.uploadErr = status.Error(codes.DeadlineExceeded, "synthetic upload already accepted or timed out")
	manager := newCameraRelayManager(gateway, createTestLogger())
	manager.uploadBatchSize = 1
	manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		return &sliceCameraRelayStream{chunks: []*cameraRelayChunk{
			{TrackID: "video", Payload: []byte("invented-frame-1"), Sequence: 1, Codec: "h264", PayloadFormat: "annexb"},
			{TrackID: "video", Payload: []byte("invented-frame-2"), Sequence: 2, Codec: "h264", PayloadFormat: "annexb"},
		}}, nil
	}
	if _, err := manager.Start(context.Background(), cameraRelaySessionSpec{
		RelaySessionID: "relay-no-retry-1", AgentID: "agent-synthetic-3", CameraSourceID: "camera-synthetic-3",
		StreamProfileID: "main", LeaseToken: "lease-synthetic-3",
	}); err != nil {
		t.Fatalf("Start: %v", err)
	}
	select {
	case <-gateway.closeNotifyCh:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for upstream close after a failed upload")
	}
	gateway.mu.Lock()
	defer gateway.mu.Unlock()
	if gateway.uploadAttempts != 1 {
		t.Fatalf("upload attempts = %d, want 1 (no automatic retry)", gateway.uploadAttempts)
	}
	if len(gateway.closeRequests) != 1 || gateway.closeRequests[0].GetReason() != cameraRelayReasonUploadFailed {
		t.Fatalf("unexpected cleanup after failed upload: %+v", gateway.closeRequests)
	}
}

type eofStatusCameraRelayServer struct {
	proto.UnimplementedCameraMediaServiceServer
	code   codes.Code
	closed chan *proto.CloseRelaySessionRequest
}

func (s *eofStatusCameraRelayServer) UploadMedia(grpc.ClientStreamingServer[proto.MediaChunk, proto.UploadMediaResponse]) error {
	// Return before reading so the client's Send observes io.EOF and must
	// recover this status from CloseAndRecv.
	return status.Error(s.code, "synthetic ingress status during send")
}

func (s *eofStatusCameraRelayServer) CloseRelaySession(_ context.Context, req *proto.CloseRelaySessionRequest) (*proto.CloseRelaySessionResponse, error) {
	s.closed <- req
	return &proto.CloseRelaySessionResponse{Closed: true}, nil
}

func TestCameraGatewaySendEOFSurfacesServerStatus(t *testing.T) {
	t.Setenv("SR_ALLOW_INSECURE", "true")
	for _, code := range []codes.Code{codes.NotFound, codes.DeadlineExceeded, codes.Unavailable} {
		t.Run(code.String(), func(t *testing.T) {
			service := &eofStatusCameraRelayServer{code: code, closed: make(chan *proto.CloseRelaySessionRequest, 1)}
			gateway, _, _ := newCameraRelayRPCClient(t, service)
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			_, err := gateway.UploadMedia(ctx, []*proto.MediaChunk{{
				RelaySessionId: "relay-eof-1", Payload: []byte("invented-eof-frame"), Sequence: 1,
			}})
			if status.Code(err) != code || !strings.Contains(status.Convert(err).Message(), "synthetic ingress status during send") {
				t.Fatalf("send EOF hid the server status: %v", err)
			}
			if code == codes.Unavailable {
				if gateway.IsConnected() {
					t.Fatal("unavailable send failure left the shared gateway connected")
				}
				return
			}
			if !gateway.IsConnected() {
				t.Fatal("non-unavailable send failure disconnected the shared gateway")
			}
			resp, err := gateway.CloseRelaySession(ctx, &proto.CloseRelaySessionRequest{RelaySessionId: "relay-eof-cleanup-1", Reason: "test cleanup"})
			if err != nil || !resp.GetClosed() {
				t.Fatalf("cleanup after send EOF: response=%v error=%v", resp, err)
			}
		})
	}
}

// blockingUploadGateway holds every upload until the caller's context ends and
// records whether a close arrived while an upload was still in flight.
type blockingUploadGateway struct {
	*fakeCameraRelayGateway

	uploadStarted     chan struct{}
	uploadStartedOnce sync.Once
	inFlight          sync.Mutex
	uploading         bool
	closedMidUpload   bool
}

func (g *blockingUploadGateway) UploadMedia(ctx context.Context, _ []*proto.MediaChunk) (*proto.UploadMediaResponse, error) {
	g.inFlight.Lock()
	g.uploading = true
	g.inFlight.Unlock()
	g.uploadStartedOnce.Do(func() { close(g.uploadStarted) })

	<-ctx.Done()

	g.inFlight.Lock()
	g.uploading = false
	g.inFlight.Unlock()

	return nil, ctx.Err()
}

func (g *blockingUploadGateway) CloseRelaySession(ctx context.Context, req *proto.CloseRelaySessionRequest) (*proto.CloseRelaySessionResponse, error) {
	g.inFlight.Lock()
	if g.uploading {
		g.closedMidUpload = true
	}
	g.inFlight.Unlock()

	return g.fakeCameraRelayGateway.CloseRelaySession(ctx, req)
}

// Stop must not close the upstream relay while an upload for it is in flight:
// the upstream ends the relay on close, so the queued upload would fail and
// read as an unreachable core. The session goroutine closes once its upload
// has returned, with the reason Stop was given.
func TestCameraRelayManagerStopClosesAfterInFlightUploadReturns(t *testing.T) {
	t.Parallel()

	gateway := &blockingUploadGateway{
		fakeCameraRelayGateway: newFakeCameraRelayGateway(),
		uploadStarted:          make(chan struct{}),
	}

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
		RelaySessionID:  "relay-stop-mid-upload-1",
		AgentID:         "agent-1",
		CameraSourceID:  "camera-1",
		StreamProfileID: "main",
		LeaseToken:      "lease-1",
	}); err != nil {
		t.Fatalf("Start returned error: %v", err)
	}

	select {
	case <-gateway.uploadStarted:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for the upload to start")
	}

	stopCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	if err := manager.Stop(stopCtx, cameraRelayStopPayload{RelaySessionID: "relay-stop-mid-upload-1", Reason: "viewer idle timeout"}); err != nil {
		t.Fatalf("Stop returned error: %v", err)
	}

	gateway.inFlight.Lock()
	closedMidUpload := gateway.closedMidUpload
	gateway.inFlight.Unlock()

	if closedMidUpload {
		t.Fatal("upstream relay was closed while an upload was still in flight")
	}

	gateway.mu.Lock()
	defer gateway.mu.Unlock()

	if len(gateway.closeRequests) != 1 {
		t.Fatalf("expected 1 close request, got %d", len(gateway.closeRequests))
	}
	if got := gateway.closeRequests[0].GetReason(); got != "viewer idle timeout" {
		t.Fatalf("expected close reason %q, got %q", "viewer idle timeout", got)
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

	refused := fmt.Errorf("describe rtsp stream: %w", &net.OpError{
		Op:   "dial",
		Net:  "tcp",
		Addr: &net.TCPAddr{IP: net.ParseIP("192.0.2.10"), Port: 7441},
		Err:  &os.SyscallError{Syscall: "connect", Err: syscall.ECONNREFUSED},
	})
	wantFailure := "connect_refused: describe rtsp stream: dial tcp 192.0.2.10:7441: connect: connection refused"

	gateway := newFakeCameraRelayGateway()
	manager := newCameraRelayManager(gateway, createTestLogger())
	manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		return nil, refused
	}

	_, err := manager.Start(context.Background(), cameraRelaySessionSpec{
		RelaySessionID:  "relay-source-fail-1",
		AgentID:         "agent-1",
		CameraSourceID:  "camera-1",
		StreamProfileID: "main",
		LeaseToken:      "lease-1",
	})
	if !errors.Is(err, syscall.ECONNREFUSED) {
		t.Fatalf("expected source startup failure wrapping the dial error, got %v", err)
	}
	// The command result carries the classified reason, never the raw source error.
	if got, want := err.Error(), "camera source failed to start: "+wantFailure; got != want {
		t.Fatalf("expected source startup error %q, got %q", want, got)
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
	if got := gateway.closeRequests[0].GetReason(); got != cameraRelayReasonSourceStartFail {
		t.Fatalf("expected close reason %q, got %q", cameraRelayReasonSourceStartFail, got)
	}
	if got := gateway.closeRequests[0].GetFailureReason(); got != wantFailure {
		t.Fatalf("expected failure reason %q, got %q", wantFailure, got)
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
	if got, want := gateway.closeRequests[0].GetFailureReason(), "unknown: plugin terminated unexpectedly"; got != want {
		t.Fatalf("expected failure reason %q, got %q", want, got)
	}
}

// expiringContext reaches its deadline when the test closes expired, so the
// deadline lands at a chosen point in the relay's startup.
type expiringContext struct {
	context.Context
	expired chan struct{}
}

func (c *expiringContext) Done() <-chan struct{} {
	return c.expired
}

func (c *expiringContext) Err() error {
	select {
	case <-c.expired:
		return context.DeadlineExceeded
	default:
		return nil
	}
}

// A source that fails after the relay's own context expired is still a source
// failure. An operator stop suppresses the failure reason whatever the source
// returned; a cancelled parent suppresses it only when the source reports that
// cancellation.
func TestCameraRelayManagerReportsStartFailureAfterContextDeadline(t *testing.T) {
	t.Parallel()

	timedOutDial := &net.OpError{
		Op: "dial", Net: "tcp", Addr: &net.TCPAddr{IP: net.ParseIP("192.0.2.10"), Port: 7441},
		Err: context.DeadlineExceeded,
	}
	const (
		stopReason  = "operator deadline stop"
		endCancel   = "parent cancelled"
		endStop     = "operator stop"
		cancelledAs = "camera source start cancelled"
	)
	for _, scenario := range []struct {
		name string
		open func() (cameraRelayChunkStream, error)
		// end is how the startup ends: the parent's deadline when empty.
		end string
		// wantClass is the reported failure class; empty means none.
		wantClass string
	}{
		{
			name:      "dial ran out of time",
			open:      func() (cameraRelayChunkStream, error) { return nil, timedOutDial },
			wantClass: cameraRelayFailureConnectTimeout,
		},
		{
			name:      "bare deadline from the source",
			open:      func() (cameraRelayChunkStream, error) { return nil, context.DeadlineExceeded },
			wantClass: cameraRelayFailureStartDeadline,
		},
		{
			name:      "source opened after the deadline",
			open:      func() (cameraRelayChunkStream, error) { return &blockingCameraRelayStream{}, nil },
			wantClass: cameraRelayFailureStartDeadline,
		},
		{
			name: "bare cancel after the parent was cancelled",
			open: func() (cameraRelayChunkStream, error) { return nil, context.Canceled },
			end:  endCancel,
		},
		{
			name: "bare deadline after an operator stop",
			open: func() (cameraRelayChunkStream, error) { return nil, context.DeadlineExceeded },
			end:  endStop,
		},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			t.Parallel()

			gateway := newFakeCameraRelayGateway()
			manager := newCameraRelayManager(gateway, createTestLogger())
			expiring := &expiringContext{Context: t.Context(), expired: make(chan struct{})}
			cancellable, cancelParent := context.WithCancel(t.Context())
			defer cancelParent()
			var ctx context.Context = expiring
			if scenario.end == endCancel {
				ctx = cancellable
			}
			entered := make(chan struct{})
			manager.pluginSourceFactory = func(sourceCtx context.Context, _ cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
				close(entered)
				<-sourceCtx.Done()
				return scenario.open()
			}
			spec := cameraRelaySessionSpec{
				RelaySessionID: "relay-deadline-1", AgentID: "agent-synthetic-3", CameraSourceID: "camera-synthetic-3",
				StreamProfileID: "main", LeaseToken: "lease-synthetic-3", PluginAssignmentID: "plugin-synthetic-3",
			}

			started := make(chan error, 1)
			go func() { _, err := manager.Start(ctx, spec); started <- err }()
			select {
			case <-entered:
			case <-time.After(3 * time.Second):
				t.Fatal("source startup did not begin")
			}
			switch scenario.end {
			case endStop:
				stopCtx, cancelStop := context.WithCancel(t.Context())
				cancelStop()
				if err := manager.Stop(stopCtx, cameraRelayStopPayload{RelaySessionID: spec.RelaySessionID, Reason: stopReason}); err != nil && !errors.Is(err, context.Canceled) {
					t.Fatalf("Stop: %v", err)
				}
			case endCancel:
				cancelParent()
			default:
				close(expiring.expired)
			}
			var err error
			select {
			case err = <-started:
			case <-time.After(3 * time.Second):
				t.Fatal("startup did not finish")
			}
			var startErr *cameraRelaySourceStartError
			if !errors.As(err, &startErr) {
				t.Fatalf("Start: got %v, want the sanitized source start error", err)
			}

			gateway.mu.Lock()
			defer gateway.mu.Unlock()
			if len(gateway.closeRequests) != 1 {
				t.Fatalf("expected 1 close request, got %d", len(gateway.closeRequests))
			}
			req := gateway.closeRequests[0]
			if scenario.end == endStop {
				if req.GetReason() != stopReason || req.GetFailureReason() != "" {
					t.Errorf("close: got reason %q failure %q, want %q and no failure", req.GetReason(), req.GetFailureReason(), stopReason)
				}
				return
			}
			if scenario.end == endCancel {
				if req.GetReason() != cameraRelayReasonSourceStartFail || req.GetFailureReason() != "" || err.Error() != cancelledAs {
					t.Errorf("close: got reason %q failure %q start error %q, want %q, no failure and %q",
						req.GetReason(), req.GetFailureReason(), err, cameraRelayReasonSourceStartFail, cancelledAs)
				}
				return
			}
			if req.GetReason() != cameraRelayReasonSourceStartFail {
				t.Errorf("close reason: got %q, want %q", req.GetReason(), cameraRelayReasonSourceStartFail)
			}
			failure := req.GetFailureReason()
			if !strings.HasPrefix(failure, scenario.wantClass+": ") {
				t.Errorf("failure reason: got %q, want class %q with a detail", failure, scenario.wantClass)
			}
			// The command result carries the sanitized reason, never the raw error.
			if got, want := err.Error(), "camera source failed to start: "+failure; got != want {
				t.Errorf("start error: got %q, want %q", got, want)
			}
		})
	}
}

type gatedFailingCameraRelayStream struct {
	entered chan struct{}
	release chan struct{}
	err     error
}

func (s *gatedFailingCameraRelayStream) Recv(context.Context) (*cameraRelayChunk, error) {
	close(s.entered)
	<-s.release
	return nil, s.err
}

func (s *gatedFailingCameraRelayStream) Close() error {
	return nil
}

// A source error that arrives after the relay context is cancelled is decided
// by whether an operator asked the session to stop, not by the context; the
// source reporting that cancellation itself is not a failure.
func TestCameraRelayManagerStopFlagDecidesRacingSourceFailure(t *testing.T) {
	t.Parallel()

	refused := &net.OpError{
		Op: "dial", Net: "tcp", Addr: &net.TCPAddr{IP: net.ParseIP("192.0.2.10"), Port: 7441},
		Err: &os.SyscallError{Syscall: "connect", Err: syscall.ECONNREFUSED},
	}
	for _, scenario := range []struct {
		name        string
		stop        bool
		err         error
		wantReason  string
		wantFailure string
	}{
		{name: "operator stop", stop: true, err: errRTSPDialFailed, wantReason: "operator racing stop", wantFailure: ""},
		{
			name: "parent cancelled, source refused the connection", err: refused,
			wantReason: "camera relay source failed", wantFailure: "connect_refused: dial tcp 192.0.2.10:7441: connect: connection refused",
		},
		{name: "parent cancelled, source reports the cancellation", err: context.Canceled, wantReason: "camera relay cancelled", wantFailure: ""},
		{
			name: "parent cancelled, source reports a deadline", err: context.DeadlineExceeded,
			wantReason: "camera relay cancelled", wantFailure: "start_deadline_exceeded: context deadline exceeded",
		},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			t.Parallel()

			gateway := newFakeCameraRelayGateway()
			manager := newCameraRelayManager(gateway, createTestLogger())
			stream := &gatedFailingCameraRelayStream{entered: make(chan struct{}), release: make(chan struct{}), err: scenario.err}
			manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) { return stream, nil }
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()

			spec := cameraRelaySessionSpec{
				RelaySessionID: "relay-race-1", AgentID: "agent-synthetic-4", CameraSourceID: "camera-synthetic-4",
				StreamProfileID: "main", LeaseToken: "lease-synthetic-4",
			}
			if _, err := manager.Start(ctx, spec); err != nil {
				t.Fatalf("Start: %v", err)
			}
			<-stream.entered
			if scenario.stop {
				stopCtx, cancelStop := context.WithCancel(t.Context())
				cancelStop()
				if err := manager.Stop(stopCtx, cameraRelayStopPayload{RelaySessionID: spec.RelaySessionID, Reason: "operator racing stop"}); err != nil && !errors.Is(err, context.Canceled) {
					t.Fatalf("Stop: %v", err)
				}
			} else {
				cancel()
			}
			close(stream.release)

			select {
			case <-gateway.closeNotifyCh:
			case <-time.After(3 * time.Second):
				t.Fatal("timed out waiting for upstream relay close")
			}
			gateway.mu.Lock()
			defer gateway.mu.Unlock()
			req := gateway.closeRequests[0]
			if req.GetReason() != scenario.wantReason || req.GetFailureReason() != scenario.wantFailure {
				t.Errorf("close: got reason %q failure %q, want %q and %q", req.GetReason(), req.GetFailureReason(), scenario.wantReason, scenario.wantFailure)
			}
		})
	}
}

// closeGatedLogger pauses the relay's close path at its "stopping" log line,
// after the source error was classified and before the upstream close is sent.
type closeGatedLogger struct {
	logger.Logger
	events zerolog.Logger
}

func (l closeGatedLogger) Info() *zerolog.Event {
	return l.events.Info()
}

type closeGatedHook struct {
	entered chan struct{}
	release chan struct{}
}

func (h closeGatedHook) Run(_ *zerolog.Event, _ zerolog.Level, message string) {
	if message == "Camera relay session stopping" {
		close(h.entered)
		<-h.release
	}
}

// A stop that lands after the source error was classified, but before the
// upstream close is sent, closes with no failure reason.
func TestCameraRelayManagerStopAfterSourceErrorSendsNoFailure(t *testing.T) {
	t.Parallel()

	gateway := newFakeCameraRelayGateway()
	hook := closeGatedHook{entered: make(chan struct{}), release: make(chan struct{})}
	manager := newCameraRelayManager(gateway, closeGatedLogger{
		Logger: createTestLogger(),
		events: zerolog.New(io.Discard).Hook(hook),
	})
	manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		return &failingCameraRelayStream{err: errRTSPDialFailed}, nil
	}

	spec := cameraRelaySessionSpec{
		RelaySessionID: "relay-late-stop-1", AgentID: "agent-synthetic-5", CameraSourceID: "camera-synthetic-5",
		StreamProfileID: "main", LeaseToken: "lease-synthetic-5",
	}
	if _, err := manager.Start(t.Context(), spec); err != nil {
		t.Fatalf("Start: %v", err)
	}
	<-hook.entered
	stopCtx, cancelStop := context.WithCancel(t.Context())
	cancelStop()
	if err := manager.Stop(stopCtx, cameraRelayStopPayload{RelaySessionID: spec.RelaySessionID, Reason: "operator late stop"}); err != nil && !errors.Is(err, context.Canceled) {
		t.Fatalf("Stop: %v", err)
	}
	close(hook.release)

	select {
	case <-gateway.closeNotifyCh:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for upstream relay close")
	}
	gateway.mu.Lock()
	defer gateway.mu.Unlock()
	if got := gateway.closeRequests[0].GetFailureReason(); got != "" {
		t.Errorf("close after a stop sent failure reason %q, want none", got)
	}
}

// orderedCloseCameraRelayStream fails its Recv once released and records, when
// it is closed, whether the relay had already sent its upstream close. A second
// Close panics on the closed channel: a source is closed exactly once.
type orderedCloseCameraRelayStream struct {
	upstreamClosed      <-chan struct{}
	release             chan struct{}
	onClose             func()
	closed              chan struct{}
	closedAfterUpstream bool
}

func (s *orderedCloseCameraRelayStream) Recv(context.Context) (*cameraRelayChunk, error) {
	<-s.release
	return nil, errRTSPDialFailed
}

func (s *orderedCloseCameraRelayStream) Close() error {
	select {
	case <-s.upstreamClosed:
		s.closedAfterUpstream = true
	default:
	}
	if s.onClose != nil {
		s.onClose()
	}
	close(s.closed)
	return nil
}

// The relay tells Core the session closed before it tears the camera source
// down, on a failed start that already holds a source and on a session that
// fails later, so a stop landing during the source close cannot erase a failure
// that was already reported.
func TestCameraRelayManagerClosesUpstreamBeforeSource(t *testing.T) {
	t.Parallel()

	for _, scenario := range []struct {
		name            string
		session         bool
		stopDuringClose bool
		wantReason      string
		wantFailure     string
	}{
		{name: "start failure", wantReason: cameraRelayReasonSourceStartFail, wantFailure: "start_deadline_exceeded: context deadline exceeded"},
		{name: "start failure, stop during source close", stopDuringClose: true, wantReason: cameraRelayReasonSourceStartFail, wantFailure: "start_deadline_exceeded: context deadline exceeded"},
		{name: "session failure", session: true, wantReason: "camera relay source failed", wantFailure: "unknown: rtsp dial failed"},
		{name: "session failure, stop during source close", session: true, stopDuringClose: true, wantReason: "camera relay source failed", wantFailure: "unknown: rtsp dial failed"},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			t.Parallel()

			gateway := newFakeCameraRelayGateway()
			manager := newCameraRelayManager(gateway, createTestLogger())
			spec := cameraRelaySessionSpec{
				RelaySessionID: "relay-close-order-1", AgentID: "agent-synthetic-6", CameraSourceID: "camera-synthetic-6",
				StreamProfileID: "main", LeaseToken: "lease-synthetic-6",
			}
			stream := &orderedCloseCameraRelayStream{
				upstreamClosed: gateway.closeNotifyCh, release: make(chan struct{}), closed: make(chan struct{}),
			}
			var stopErr error
			if scenario.stopDuringClose {
				stream.onClose = func() {
					stopCtx, cancelStop := context.WithCancel(t.Context())
					cancelStop()
					stopErr = manager.Stop(stopCtx, cameraRelayStopPayload{RelaySessionID: spec.RelaySessionID, Reason: "operator teardown stop"})
				}
			}
			ctx := &expiringContext{Context: t.Context(), expired: make(chan struct{})}
			if scenario.session {
				manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) { return stream, nil }
			} else {
				// The source opens after the relay's start deadline passed.
				spec.PluginAssignmentID = "plugin-synthetic-6"
				manager.pluginSourceFactory = func(sourceCtx context.Context, _ cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
					close(ctx.expired)
					<-sourceCtx.Done()
					return stream, nil
				}
			}

			_, err := manager.Start(ctx, spec)
			if scenario.session {
				if err != nil {
					t.Fatalf("Start: %v", err)
				}
				handle := manager.lookupSession(spec.RelaySessionID)
				close(stream.release)
				select {
				case <-handle.done:
				case <-time.After(3 * time.Second):
					t.Fatal("session did not finish")
				}
			} else if err == nil {
				t.Fatal("Start: got nil, want a failed start")
			}

			select {
			case <-stream.closed:
			default:
				t.Fatal("source was not closed")
			}
			if !stream.closedAfterUpstream {
				t.Error("source was closed before the upstream close was sent")
			}
			if scenario.stopDuringClose && !errors.Is(stopErr, context.Canceled) {
				t.Fatalf("stop during source close did not reach the session: %v", stopErr)
			}
			gateway.mu.Lock()
			defer gateway.mu.Unlock()
			if len(gateway.closeRequests) != 1 {
				t.Fatalf("expected 1 close request, got %d", len(gateway.closeRequests))
			}
			req := gateway.closeRequests[0]
			if req.GetReason() != scenario.wantReason || req.GetFailureReason() != scenario.wantFailure {
				t.Errorf("close: got reason %q failure %q, want %q and %q", req.GetReason(), req.GetFailureReason(), scenario.wantReason, scenario.wantFailure)
			}
		})
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

	_, err := defaultCameraRelaySource(cameraRelaySessionSpec{}, createTestLogger())
	if err == nil {
		t.Fatal("expected source_url validation error, got nil")
	}
	if got := err.Error(); got != "source_url is required" {
		t.Fatalf("expected source_url validation error, got %q", got)
	}
}

func assertCameraRelayFailureDetailSafe(t *testing.T, detail string) {
	t.Helper()

	if len(detail) > maxCameraRelayFailureDetail {
		t.Errorf("detail is %d bytes, want at most %d: %q", len(detail), maxCameraRelayFailureDetail, detail)
	}
	for _, r := range detail {
		if r < 0x20 || r > 0x7e {
			t.Errorf("detail contains non-printable %U: %q", r, detail)
		}
	}
	// Invented credential material; none of it may survive.
	for _, secret := range []string{"viewer", "hunter2", "AbCdEf0123TokenXyz", "enableSrtp", "sig=", "?"} {
		if strings.Contains(detail, secret) {
			t.Errorf("detail leaks %q: %q", secret, detail)
		}
	}
}

func TestClassifyCameraRelayFailure(t *testing.T) {
	t.Parallel()

	const leakyURL = "rtsps://viewer:hunter2@camera01.example.com:7441/AbCdEf0123TokenXyz?enableSrtp"

	dial := func(err error) error {
		return &net.OpError{Op: "dial", Net: "tcp", Addr: &net.TCPAddr{IP: net.ParseIP("192.0.2.10"), Port: 7441}, Err: err}
	}
	status := func(code base.StatusCode, message string) error {
		return fmt.Errorf("describe rtsp stream: %w", liberrors.ErrClientBadStatusCode{Code: code, Message: message})
	}
	video := func(formats ...format.Format) *description.Media {
		return &description.Media{Type: description.MediaTypeVideo, Formats: formats}
	}
	audio := &description.Media{Type: description.MediaTypeAudio, Formats: []format.Format{&format.G711{MULaw: true, SampleRate: 8000, ChannelCount: 1}}}
	_, badURLErr := newRTSPCameraRelayStream(cameraRelaySessionSpec{SourceURL: "rtsps://viewer:hunter2@camera01.example.com:notaport/AbCdEf0123TokenXyz?enableSrtp"}, createTestLogger())
	_, badSchemeErr := defaultCameraRelaySource(cameraRelaySessionSpec{SourceURL: "https://viewer:hunter2@camera01.example.com/AbCdEf0123TokenXyz"}, createTestLogger())

	tests := []struct {
		name       string
		err        error
		wantClass  string
		wantDetail string
	}{
		{"unauthorized", status(base.StatusUnauthorized, "Unauthorized"), cameraRelayFailureAuthentication, "describe rtsp stream: bad status code: 401 (Unauthorized)"},
		{"forbidden", status(base.StatusForbidden, "Forbidden"), cameraRelayFailureAuthentication, "describe rtsp stream: bad status code: 403 (Forbidden)"},
		{"unknown alias", status(base.StatusNotFound, "Not Found"), cameraRelayFailureNotFound, "describe rtsp stream: bad status code: 404 (Not Found)"},
		{"other status", status(base.StatusServiceUnavailable, "Service Unavailable"), cameraRelayFailureRTSPRequest, "describe rtsp stream: bad status code: 503 (Service Unavailable)"},
		{"refused", dial(&os.SyscallError{Syscall: "connect", Err: syscall.ECONNREFUSED}), cameraRelayFailureConnectRefused, "dial tcp 192.0.2.10:7441: connect: connection refused"},
		{"connect timeout", dial(context.DeadlineExceeded), cameraRelayFailureConnectTimeout, "dial tcp 192.0.2.10:7441: context deadline exceeded"},
		{"unreachable", dial(&os.SyscallError{Syscall: "connect", Err: syscall.EHOSTUNREACH}), cameraRelayFailureHostUnreachable, "dial tcp 192.0.2.10:7441: connect: no route to host"},
		{"dns", dial(&net.DNSError{Err: "no such host", Name: "camera01.example.com", IsNotFound: true}), cameraRelayFailureDNS, "dial tcp 192.0.2.10:7441: lookup camera01.example.com: no such host"},
		{"untrusted certificate", &tls.CertificateVerificationError{Err: x509.UnknownAuthorityError{}}, cameraRelayFailureTLSCertificate, "tls: failed to verify certificate: x509: certificate signed by unknown authority"},
		{"not tls", tls.RecordHeaderError{Msg: "first record does not look like a TLS handshake"}, cameraRelayFailureTLSHandshake, "tls: first record does not look like a TLS handshake"},
		{"tls alert", &net.OpError{Op: "remote error", Err: errSyntheticTLSAlert}, cameraRelayFailureTLSHandshake, "remote error: tls: handshake failure"},
		{"no response", fmt.Errorf("describe rtsp stream: %w", liberrors.ErrClientRequestTimedOut{}), cameraRelayFailureResponseTimeout, "describe rtsp stream: request timed out"},
		{"no media", liberrors.ErrClientTCPTimeout{}, cameraRelayFailureNoMedia, "TCP timeout"},
		{"closed by server", fmt.Errorf("describe rtsp stream: %w", io.EOF), cameraRelayFailureUpstreamClosed, "describe rtsp stream: EOF"},
		{"h265 only", cameraRelayMissingH264Error(&description.Session{Medias: []*description.Media{audio, video(&format.H265{PayloadTyp: 96})}}), cameraRelayFailureUnsupportedCodec, "rtsp stream video codec is not supported, H264 is required: camera offers H265"},
		{"audio only", cameraRelayMissingH264Error(&description.Session{Medias: []*description.Media{audio}}), cameraRelayFailureNoVideoTrack, "rtsp stream has no video track"},
		{"no keyframe", fmt.Errorf("%w within %s (%d packets before the stream clock started, %d access units before a usable IDR)", errCameraRelayNoKeyframe, cameraRelayFirstKeyframeTimeout, 3, 41), cameraRelayFailureNoKeyframe, "rtsp stream produced no decodable h264 keyframe within 30s (3 packets before the stream clock started, 41 access units before a usable IDR)"},
		{"invalid url", badURLErr, cameraRelayFailureInvalidSourceConfig, "source_url is not a valid rtsp url"},
		{"wrong scheme", badSchemeErr, cameraRelayFailureInvalidSourceConfig, "unsupported camera relay source, an rtsp or rtsps url is required"},
		{"unclassified error quoting the url", fmt.Errorf("read %q: %w", leakyURL, errSyntheticReadError), cameraRelayFailureUnknown, `read "[url]": connection stalled`},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			got := classifyCameraRelayFailure(tt.err)
			if got.Class != tt.wantClass || got.Detail != tt.wantDetail {
				t.Fatalf("classify(%v) = {%q, %q}, want {%q, %q}", tt.err, got.Class, got.Detail, tt.wantClass, tt.wantDetail)
			}
			assertCameraRelayFailureDetailSafe(t, got.Detail)
		})
	}
}

func TestSanitizeCameraRelayFailureDetail(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		raw  string
		want string
	}{
		{"url with userinfo, alias token and query", "describe rtsps://viewer:hunter2@camera01.example.com:7441/AbCdEf0123TokenXyz?enableSrtp failed", "describe [url] failed"},
		{"bare userinfo and path", "dial viewer:hunter2@camera01.example.com:7441/AbCdEf0123TokenXyz refused", "dial camera01.example.com:7441 refused"},
		{"host path without port", "GET camera01.example.com/AbCdEf0123TokenXyz failed", "GET camera01.example.com failed"},
		{"bare userinfo before underscore host", "dial viewer:hunter2@nvr_01.example.com refused", "dial nvr_01.example.com refused"},
		{"rtsp url with userinfo", "rtsp://viewer:hunter2@192.0.2.10:554/stream", "[url]"},
		{"email address kept", "certificate issued for deploy@host01.example.com", "certificate issued for deploy@host01.example.com"},
		{"contact address kept", "contact ops@example.com", "contact ops@example.com"},
		{"time at word kept", "12:30@noon", "12:30@noon"},
		{"path token", "SETUP /AbCdEf0123TokenXyz/trackID=1 rejected", "SETUP [path] rejected"},
		{"query string", "token rejected: ?sig=AbCdEf0123TokenXyz", "token rejected:"},
		{"non-printable bytes", "bad\x00status\r\nlineé\x7f", "bad status line"},
		{"oversized", strings.Repeat("timeout ", 200), strings.TrimSpace(strings.Repeat("timeout ", 25))},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			got := sanitizeCameraRelayFailureDetail(tt.raw)
			if got != tt.want {
				t.Fatalf("sanitize(%q) = %q, want %q", tt.raw, got, tt.want)
			}
			assertCameraRelayFailureDetailSafe(t, got)
		})
	}
}

func TestNewRTSPCameraRelayClientLeavesRTSPSVerificationEnabledByDefault(t *testing.T) {
	t.Parallel()

	u, err := base.ParseURL("rtsps://192.168.1.1:7441/example")
	if err != nil {
		t.Fatalf("parse url: %v", err)
	}

	transport := gortsplib.ProtocolTCP
	client := newCameraRelayRTSPClient(u, transport, false)

	if client.TLSConfig != nil {
		t.Fatal("expected rtsps client to use default TLS verification when skip verify is disabled")
	}
}

func TestNewRTSPCameraRelayClientEnablesTLSSkipVerifyWhenRequestedForRTSPS(t *testing.T) {
	t.Parallel()

	u, err := base.ParseURL("rtsps://192.168.1.1:7441/example")
	if err != nil {
		t.Fatalf("parse url: %v", err)
	}

	transport := gortsplib.ProtocolTCP
	client := newCameraRelayRTSPClient(u, transport, true)

	if client.TLSConfig == nil {
		t.Fatal("expected TLS config for insecure rtsps client")
	}
	if !client.TLSConfig.InsecureSkipVerify {
		t.Fatal("expected insecure rtsps client to skip TLS verification")
	}
}

func TestNewRTSPCameraRelayClientLeavesRTSPTLSUnset(t *testing.T) {
	t.Parallel()

	u, err := base.ParseURL("rtsp://192.168.1.1:7447/example")
	if err != nil {
		t.Fatalf("parse url: %v", err)
	}

	transport := gortsplib.ProtocolTCP
	client := newCameraRelayRTSPClient(u, transport, true)

	if client.TLSConfig != nil {
		t.Fatal("expected plain rtsp client to leave TLS config unset")
	}
}

func TestParseCameraRelayRTSPTransport(t *testing.T) {
	t.Parallel()

	if _, err := parseCameraRelayRTSPTransport(cameraRelayRTSPTransportTCP); err != nil {
		t.Fatalf("expected tcp transport to parse, got %v", err)
	}
	if _, err := parseCameraRelayRTSPTransport(cameraRelayRTSPTransportUDP); err != nil {
		t.Fatalf("expected udp transport to parse, got %v", err)
	}
	if _, err := parseCameraRelayRTSPTransport("bogus"); err == nil {
		t.Fatal("expected invalid transport to fail")
	}
}

// Teardown can outlive the caller, or return an error even though the upstream
// relay has already closed. Neither case may be reported as completed early.
func TestCameraRelayStopObservationDuringTeardown(t *testing.T) {
	for _, closeErr := range []error{nil, errSyntheticCloseFailure} {
		name := cameraRelayStopStateCompleted
		if closeErr != nil {
			name = cameraRelayStopStateUnresolved
		}
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			manager := newCameraRelayManager(newFakeCameraRelayGateway(), createTestLogger())
			stream := &gatedCameraRelayStream{closing: make(chan struct{}), release: make(chan struct{}), ctx: ctx, closeErr: closeErr}
			manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) { return stream, nil }
			spec := cameraRelaySessionSpec{RelaySessionID: "relay-observed", AgentID: "agent-synthetic", CameraSourceID: "camera-synthetic", StreamProfileID: "main", LeaseToken: "lease-synthetic"}
			if _, err := manager.Start(ctx, spec); err != nil {
				t.Fatal(err)
			}
			cmd := &proto.CommandRequest{CommandId: "synthetic-stop", CreatedAt: time.Now().Unix(), TtlSeconds: 60}
			payload := cameraRelayStopPayload{RelaySessionID: spec.RelaySessionID, SourceIncarnationID: manager.incarnationID}
			query := cameraRelayOperationQuery{OperationID: cmd.CommandId, RelaySessionID: spec.RelaySessionID, SourceIncarnationID: manager.incarnationID}
			caller, cancelCaller := context.WithCancel(ctx)
			cancelCaller()
			if err := manager.StopCommand(caller, cmd, payload); !errors.Is(err, context.Canceled) {
				t.Fatalf("cancelled caller: %v", err)
			}
			select {
			case <-stream.closing:
			case <-ctx.Done():
				t.Fatal("source close did not start")
			}
			if observation, err := manager.ReconcileStop(query); err != nil || observation.State != cameraRelayStopStatePending {
				t.Fatalf("pending observation: %+v, %v", observation, err)
			}
			wrong := query
			wrong.RelaySessionID = "relay-other"
			if _, err := manager.ReconcileStop(wrong); !errors.Is(err, errCameraRelayStopConflict) {
				t.Fatalf("wrong session query: %v", err)
			}
			wrong = query
			wrong.OperationID = "unobserved-stop"
			if observation, err := manager.ReconcileStop(wrong); err != nil || observation.State != cameraRelayStopStateUnknown {
				t.Fatalf("unknown observation: %+v, %v", observation, err)
			}
			newManager := newCameraRelayManager(newFakeCameraRelayGateway(), createTestLogger())
			if _, err := newManager.ReconcileStop(query); !errors.Is(err, errCameraRelayIncarnationMismatch) {
				t.Fatalf("new runtime query: %v", err)
			}
			close(stream.release)
			err := manager.StopCommand(ctx, cmd, payload)
			if (closeErr == nil && err != nil) || (closeErr != nil && !errors.Is(err, errCameraRelaySourceCloseFailed)) {
				t.Fatalf("close outcome: %v", err)
			}
			if observation, err := manager.ReconcileStop(query); err != nil || observation.State != name {
				t.Fatalf("final observation: %+v, %v", observation, err)
			}
		})
	}
}

func TestCameraRelayStopObservationRetention(t *testing.T) {
	for _, capacity := range []bool{false, true} {
		name := "expiry"
		if capacity {
			name = "capacity"
		}
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
			defer cancel()
			manager := newCameraRelayManager(newFakeCameraRelayGateway(), createTestLogger())
			stream := &gatedCameraRelayStream{closing: make(chan struct{}), release: make(chan struct{}), ctx: ctx}
			manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) { return stream, nil }
			spec := cameraRelaySessionSpec{RelaySessionID: "relay-retained", AgentID: "agent-synthetic", CameraSourceID: "camera-synthetic", StreamProfileID: "main", LeaseToken: "lease-synthetic"}
			if _, err := manager.Start(ctx, spec); err != nil {
				t.Fatal(err)
			}
			payload := cameraRelayStopPayload{RelaySessionID: spec.RelaySessionID, SourceIncarnationID: manager.incarnationID}
			cmd := &proto.CommandRequest{CommandId: "synthetic-stop", CreatedAt: time.Now().Unix(), TtlSeconds: 2}
			if capacity {
				cmd.TtlSeconds = 60
			}
			query := cameraRelayOperationQuery{OperationID: cmd.CommandId, RelaySessionID: spec.RelaySessionID, SourceIncarnationID: manager.incarnationID}
			caller, cancelCaller := context.WithCancel(ctx)
			cancelCaller()
			if err := manager.StopCommand(caller, cmd, payload); !errors.Is(err, context.Canceled) {
				t.Fatal(err)
			}
			if capacity {
				for i := 1; i < 4096; i++ {
					next := &proto.CommandRequest{CommandId: fmt.Sprintf("synthetic-stop-%d", i), CreatedAt: cmd.CreatedAt, TtlSeconds: cmd.TtlSeconds}
					if err := manager.StopCommand(caller, next, payload); !errors.Is(err, context.Canceled) {
						t.Fatalf("capture %d: %v", i, err)
					}
				}
				next := &proto.CommandRequest{CommandId: "synthetic-over-capacity", CreatedAt: cmd.CreatedAt, TtlSeconds: cmd.TtlSeconds}
				if err := manager.StopCommand(caller, next, payload); !errors.Is(err, errCameraRelayStopCapacity) {
					t.Fatalf("capacity refusal: %v", err)
				}
				if err := manager.StopCommand(caller, cmd, payload); !errors.Is(err, context.Canceled) {
					t.Fatalf("retained operation at capacity: %v", err)
				}
				if observation, err := manager.ReconcileStop(query); err != nil || observation.State != cameraRelayStopStatePending {
					t.Fatalf("retained observation: %+v, %v", observation, err)
				}
			} else {
				timer := time.NewTimer(time.Until(time.Unix(cmd.CreatedAt+cmd.TtlSeconds, 0)))
				defer timer.Stop()
				select {
				case <-timer.C:
				case <-ctx.Done():
					t.Fatal("deadline wait timed out")
				}
				if observation, err := manager.ReconcileStop(query); err != nil || observation.State != cameraRelayStopStateUnknown {
					t.Fatalf("expired observation: %+v, %v", observation, err)
				}
				if err := manager.StopCommand(caller, cmd, payload); !errors.Is(err, errCameraRelayStopEnvelope) {
					t.Fatalf("expired replay: %v", err)
				}
			}
			close(stream.release)
			if err := manager.Stop(ctx, payload); err != nil && !errors.Is(err, errCameraRelaySessionNotFound) {
				t.Fatal(err)
			}
		})
	}
}

func TestCameraRelayOpenFailureReceipt(t *testing.T) {
	t.Parallel()
	gateway := newFakeCameraRelayGateway()
	manager := newCameraRelayManager(gateway, createTestLogger())
	attempts := 0
	manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		attempts++
		return nil, errRTSPDialFailed
	}
	spec := cameraRelaySessionSpec{RelaySessionID: "relay-open-receipt", AgentID: "agent-synthetic", CameraSourceID: "camera-synthetic", StreamProfileID: "main", LeaseToken: "lease-synthetic", SourceURL: "rtsp://camera.example.test/stream"}
	cmd := &proto.CommandRequest{CommandId: "synthetic-open", CreatedAt: time.Now().Unix(), TtlSeconds: 60}
	for i := 0; i < 2; i++ {
		if _, err := manager.StartCommand(t.Context(), cmd, spec); !errors.Is(err, errRTSPDialFailed) {
			t.Fatalf("failed startup receipt %d: %v", i, err)
		}
	}
	query := cameraRelayOperationQuery{OperationID: cmd.CommandId, RelaySessionID: spec.RelaySessionID, SourceIncarnationID: manager.incarnationID}
	if result, err := manager.ReconcileOpen(query); err != nil || result.State != cameraRelayOpenStateFailed || result.CameraSourceID != spec.CameraSourceID || result.StreamProfileID != spec.StreamProfileID {
		t.Fatalf("failed startup observation: %v %v", result, err)
	}
	wrong := query
	wrong.RelaySessionID = "invented-mismatched-relay"
	if _, err := manager.ReconcileOpen(wrong); !errors.Is(err, errCameraRelayStartConflict) {
		t.Fatalf("wrong target: %v", err)
	}
	wrong = query
	wrong.OperationID = "invented-absent-open"
	if result, err := manager.ReconcileOpen(wrong); err != nil || result.State != cameraRelayOpenStateUnknown {
		t.Fatalf("unknown operation: %v %v", result, err)
	}
	if _, err := newCameraRelayManager(gateway, createTestLogger()).ReconcileOpen(query); !errors.Is(err, errCameraRelayIncarnationMismatch) {
		t.Fatalf("old incarnation: %v", err)
	}
	if _, err := manager.ReconcileOpen(cameraRelayOperationQuery{}); !errors.Is(err, errCameraRelayOperationQuery) {
		t.Fatalf("missing identity: %v", err)
	}
	for _, change := range []struct {
		name string
		edit func(*cameraRelaySessionSpec, *proto.CommandRequest)
	}{
		{"session", func(s *cameraRelaySessionSpec, _ *proto.CommandRequest) {
			s.RelaySessionID = "relay-open-receipt-replacement"
		}},
		{"source", func(s *cameraRelaySessionSpec, _ *proto.CommandRequest) {
			s.CameraSourceID = "camera-synthetic-alternate"
		}},
		{"profile", func(s *cameraRelaySessionSpec, _ *proto.CommandRequest) { s.StreamProfileID = "sub" }},
		{"lease", func(s *cameraRelaySessionSpec, _ *proto.CommandRequest) { s.LeaseToken = "lease-synthetic-renewed" }},
		{"plugin", func(s *cameraRelaySessionSpec, _ *proto.CommandRequest) { s.PluginAssignmentID = "invented-plugin" }},
		{"transport", func(s *cameraRelaySessionSpec, _ *proto.CommandRequest) {
			s.RTSPTransport = cameraRelayRTSPTransportUDP
		}},
		{"tls", func(s *cameraRelaySessionSpec, _ *proto.CommandRequest) { s.InsecureSkipVerify = true }},
		{"deadline", func(_ *cameraRelaySessionSpec, c *proto.CommandRequest) { c.TtlSeconds++ }},
		{"creation", func(_ *cameraRelaySessionSpec, c *proto.CommandRequest) { c.CreatedAt++ }},
	} {
		t.Run(change.name, func(t *testing.T) {
			changedSpec := spec
			changedCmd := &proto.CommandRequest{CommandId: cmd.CommandId, CreatedAt: cmd.CreatedAt, TtlSeconds: cmd.TtlSeconds}
			change.edit(&changedSpec, changedCmd)
			if _, err := manager.StartCommand(t.Context(), changedCmd, changedSpec); !errors.Is(err, errCameraRelayStartConflict) {
				t.Fatalf("changed content: %v", err)
			}
		})
	}
	if attempts != 1 || len(gateway.openRequests) != 1 || len(gateway.closeRequests) != 1 {
		t.Fatalf("failed startup repeated work: source=%d opens=%d closes=%d", attempts, len(gateway.openRequests), len(gateway.closeRequests))
	}
	manager.startOperations[cmd.CommandId].expiresAt = time.Now().Add(-time.Second)
	if result, err := manager.ReconcileOpen(query); err != nil || result.State != cameraRelayOpenStateUnknown || result.CameraSourceID != "" {
		t.Fatalf("expired observation: %v %v", result, err)
	}
	cmd.CommandId = "synthetic-new-attempt"
	if _, err := manager.StartCommand(t.Context(), cmd, spec); !errors.Is(err, errRTSPDialFailed) || attempts != 2 {
		t.Fatalf("separate operation could not attempt startup: attempts=%d err=%v", attempts, err)
	}
}

func TestCameraRelayOpenOutcomeOutlivesDeadline(t *testing.T) {
	t.Parallel()
	gateway := newFakeCameraRelayGateway()
	manager := newCameraRelayManager(gateway, createTestLogger())
	createdAt := time.Now().Unix()
	expiresAt := time.Unix(createdAt+2, 0)
	manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		time.Sleep(time.Until(expiresAt) + 50*time.Millisecond)
		return nil, errRTSPDialFailed
	}
	spec := cameraRelaySessionSpec{RelaySessionID: "relay-late-open", AgentID: "agent-synthetic", CameraSourceID: "camera-synthetic", StreamProfileID: "main", LeaseToken: "lease-synthetic"}
	const attempts = 24
	errs := make(chan error, attempts)
	for i := 0; i < attempts; i++ {
		cmd := &proto.CommandRequest{CommandId: fmt.Sprintf("synthetic-late-open-%d", i), CreatedAt: createdAt, TtlSeconds: 2}
		lateSpec := spec
		lateSpec.RelaySessionID = fmt.Sprintf("%s-%d", spec.RelaySessionID, i)
		lateSpec.CameraSourceID = fmt.Sprintf("%s-%d", spec.CameraSourceID, i)
		go func() {
			_, err := manager.StartCommand(t.Context(), cmd, lateSpec)
			errs <- err
		}()
	}
	for i := 0; i < attempts; i++ {
		if err := <-errs; !errors.Is(err, errRTSPDialFailed) {
			t.Fatalf("startup outcome finished after its deadline was replaced by %v", err)
		}
	}

	manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) { return nil, errRTSPDialFailed }
	cmd := &proto.CommandRequest{CommandId: "synthetic-completed-open", CreatedAt: time.Now().Unix(), TtlSeconds: 60}
	if _, err := manager.StartCommand(t.Context(), cmd, spec); !errors.Is(err, errRTSPDialFailed) {
		t.Fatal(err)
	}
	canceled, cancel := context.WithCancel(t.Context())
	cancel()
	for i := 0; i < attempts; i++ {
		if _, err := manager.StartCommand(canceled, cmd, spec); !errors.Is(err, errRTSPDialFailed) {
			t.Fatalf("canceled duplicate of a completed open: %v", err)
		}
	}
	if len(gateway.openRequests) != attempts+1 {
		t.Fatalf("duplicates repeated startup: opens=%d", len(gateway.openRequests))
	}
}

func TestCameraRelayOpenAdmissionBounds(t *testing.T) {
	for _, mode := range []string{"invalid", "expiry", "capacity"} {
		t.Run(mode, func(t *testing.T) {
			t.Parallel()
			gateway := newFakeCameraRelayGateway()
			manager := newCameraRelayManager(gateway, createTestLogger())
			manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) { return nil, errRTSPDialFailed }
			spec := cameraRelaySessionSpec{RelaySessionID: "relay-bounded", AgentID: "agent-synthetic", CameraSourceID: "camera-synthetic", StreamProfileID: "main", LeaseToken: "lease-synthetic"}
			cmd := &proto.CommandRequest{CommandId: "synthetic-open", CreatedAt: time.Now().Unix(), TtlSeconds: 60}
			switch mode {
			case "invalid":
				for _, invalid := range []*proto.CommandRequest{
					nil,
					{CreatedAt: cmd.CreatedAt, TtlSeconds: 60},
					{CommandId: cmd.CommandId, TtlSeconds: 60},
					{CommandId: cmd.CommandId, CreatedAt: cmd.CreatedAt},
					{CommandId: cmd.CommandId, CreatedAt: cmd.CreatedAt, TtlSeconds: -1},
					{CommandId: cmd.CommandId, CreatedAt: cmd.CreatedAt, TtlSeconds: 301},
					{CommandId: cmd.CommandId, CreatedAt: cmd.CreatedAt - 120, TtlSeconds: 60},
					{CommandId: cmd.CommandId, CreatedAt: cmd.CreatedAt + 600, TtlSeconds: 60},
				} {
					if _, err := manager.StartCommand(t.Context(), invalid, spec); !errors.Is(err, errCameraRelayStartEnvelope) {
						t.Fatalf("invalid envelope: %v", err)
					}
				}
				if len(gateway.openRequests) != 0 {
					t.Fatal("invalid envelope opened upstream")
				}
			case "expiry":
				cmd.TtlSeconds = 2
				if _, err := manager.StartCommand(t.Context(), cmd, spec); !errors.Is(err, errRTSPDialFailed) {
					t.Fatal(err)
				}
				timer := time.NewTimer(time.Until(time.Unix(cmd.CreatedAt+cmd.TtlSeconds, 0)))
				defer timer.Stop()
				select {
				case <-timer.C:
				case <-t.Context().Done():
					t.Fatal("deadline wait cancelled")
				}
				if _, err := manager.StartCommand(t.Context(), cmd, spec); !errors.Is(err, errCameraRelayStartEnvelope) || len(gateway.openRequests) != 1 {
					t.Fatalf("expired operation replay: opens=%d err=%v", len(gateway.openRequests), err)
				}
			case "capacity":
				for i := 0; i < 4096; i++ {
					cmd.CommandId = fmt.Sprintf("synthetic-open-%d", i)
					if _, err := manager.StartCommand(t.Context(), cmd, spec); !errors.Is(err, errRTSPDialFailed) {
						t.Fatalf("capture %d: %v", i, err)
					}
				}
				cmd.CommandId = "synthetic-over-capacity"
				if _, err := manager.StartCommand(t.Context(), cmd, spec); !errors.Is(err, errCameraRelayStartCapacity) || len(gateway.openRequests) != 4096 {
					t.Fatalf("capacity: opens=%d err=%v", len(gateway.openRequests), err)
				}
				cmd.CommandId = "synthetic-open-0"
				if _, err := manager.StartCommand(t.Context(), cmd, spec); !errors.Is(err, errRTSPDialFailed) || len(gateway.openRequests) != 4096 {
					t.Fatalf("retained receipt at capacity: opens=%d err=%v", len(gateway.openRequests), err)
				}
			}
		})
	}
}
