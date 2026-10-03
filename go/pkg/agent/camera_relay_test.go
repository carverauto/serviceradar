package agent

import (
	"context"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/bluenviron/gortsplib/v5"
	"github.com/bluenviron/gortsplib/v5/pkg/base"
	"github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/proto"
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

//nolint:gocyclo // One startup-stop race: allocation, cancellation, cleanup, and a later relay stay in one scenario.
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
	spec := cameraRelaySessionSpec{
		RelaySessionID: "relay-allocation-delay-1", AgentID: "agent-invented-4", CameraSourceID: "camera-invented-4",
		StreamProfileID: "main", LeaseToken: "lease-invented-4",
	}
	startResult := make(chan error, 1)
	go func() { _, err := manager.Start(ctx, spec); startResult <- err }()
	select {
	case <-service.allocated:
	case <-ctx.Done():
		t.Fatal("upstream ingress was not allocated")
	}
	stopCtx := &cameraRelayStopWaitContext{Context: ctx, waiting: make(chan struct{})}
	stopResult := make(chan error, 1)
	go func() {
		stopResult <- manager.Stop(stopCtx, cameraRelayStopPayload{RelaySessionID: spec.RelaySessionID, Reason: "operator pending-open stop"})
	}()
	select {
	case <-stopCtx.waiting:
	case <-ctx.Done():
		t.Fatal("Stop did not begin waiting")
	}
	select {
	case err := <-stopResult:
		t.Fatalf("Stop completed before the allocated ingress open response: %v", err)
	default:
	}
	close(service.releaseOpen)
	select {
	case req := <-service.closeEntered:
		if req.GetReason() != "operator pending-open stop" || req.GetAgentId() != spec.AgentID {
			t.Fatalf("unexpected allocated ingress cleanup: %v", req)
		}
	case err := <-stopResult:
		t.Fatalf("Stop completed before allocated ingress cleanup: %v", err)
	case <-ctx.Done():
		t.Fatal("allocated ingress cleanup did not reach gateway")
	}
	select {
	case err := <-startResult:
		t.Fatalf("Start completed before upstream close: %v", err)
	case err := <-stopResult:
		t.Fatalf("Stop completed before upstream close: %v", err)
	default:
	}
	if _, err := manager.Start(ctx, spec); !errors.Is(err, errCameraRelaySessionExists) {
		t.Fatalf("upstream close released session ownership too early: %v", err)
	}
	close(service.releaseClose)
	select {
	case err := <-stopResult:
		if err != nil {
			t.Fatalf("Stop after upstream close: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("Stop did not complete after upstream close")
	}
	select {
	case <-service.ingressDone:
	default:
		t.Fatal("Stop reported success with an allocated ingress")
	}
	select {
	case err := <-startResult:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("stopped startup: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("stopped startup did not return")
	}
	select {
	case req := <-service.closed:
		if req.GetRelaySessionId() != spec.RelaySessionID || req.GetMediaIngestId() != "media-allocation-delay-1" {
			t.Fatalf("wrong ingress closed: %v", req)
		}
	default:
		t.Fatal("upstream close was not acknowledged")
	}
	if !gateway.IsConnected() {
		t.Fatal("pending-open Stop disconnected the shared gateway")
	}
	if err := manager.Stop(ctx, cameraRelayStopPayload{RelaySessionID: spec.RelaySessionID}); !errors.Is(err, errCameraRelaySessionNotFound) {
		t.Fatalf("closed ingress remained registered: %v", err)
	}
	manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		return &sliceCameraRelayStream{chunks: []*cameraRelayChunk{{TrackID: "video", Payload: []byte("invented-recovery-frame"), Sequence: 4, IsFinal: true}}}, nil
	}
	spec.RelaySessionID = "relay-allocation-recovery-1"
	if _, err := manager.Start(ctx, spec); err != nil {
		t.Fatalf("fresh relay after pending-open cleanup: %v", err)
	}
	select {
	case req := <-service.closed:
		if req.GetRelaySessionId() != spec.RelaySessionID || req.GetReason() != cameraRelayReasonSourceCompleted {
			t.Fatalf("unexpected recovery cleanup: %v", req)
		}
	case <-ctx.Done():
		t.Fatal("fresh relay did not upload and close")
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
			} else if req := gateway.closeRequests[0]; req.GetReason() != "operator startup stop" || req.GetMediaIngestId() != relayTestMediaIngestID {
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

func TestCameraRelayTimestampDecoderStartsAtZeroAndAdvancesMonotonically(t *testing.T) {
	t.Parallel()

	decoder := newCameraRelayTimestampDecoder(90_000)

	if got := decoder.Decode(1_000); got != 0 {
		t.Fatalf("expected first decode to start at 0, got %d", got)
	}

	got := decoder.Decode(4_000)
	want := int64(3_000) * int64(time.Second) / 90_000
	if got != want {
		t.Fatalf("expected pts %d, got %d", want, got)
	}

	got = decoder.Decode(7_000)
	want = int64(6_000) * int64(time.Second) / 90_000
	if got != want {
		t.Fatalf("expected cumulative pts %d, got %d", want, got)
	}
}

func TestCameraRelayTimestampDecoderHandlesRTPWraparound(t *testing.T) {
	t.Parallel()

	decoder := newCameraRelayTimestampDecoder(90_000)
	decoder.Decode(^uint32(0) - 100)

	got := decoder.Decode(200)
	want := int64(301) * int64(time.Second) / 90_000
	if got != want {
		t.Fatalf("expected wraparound pts %d, got %d", want, got)
	}
}
