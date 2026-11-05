package agentgateway

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"strings"
	"testing"

	"go.uber.org/mock/gomock"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	goproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

func TestGetConfigTreatsSameVersionResponseAsNotModified(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentGatewayServiceClient(ctrl)
	client := NewGatewayClient("gateway:50052", nil, logger.NewTestLogger())
	client.client = mockClient
	client.connected = true

	req := &proto.AgentConfigRequest{
		AgentId:       "agent-1",
		ConfigVersion: "vabc123",
	}

	mockClient.EXPECT().
		StreamConfig(gomock.Any(), req).
		Return(nil, status.Error(codes.Unimplemented, "stream config not available"))

	mockClient.EXPECT().
		GetConfig(gomock.Any(), req).
		Return(&proto.AgentConfigResponse{
			NotModified:   false,
			ConfigVersion: "vabc123",
		}, nil)

	resp, err := client.GetConfig(context.Background(), req)
	if err != nil {
		t.Fatalf("GetConfig returned error: %v", err)
	}
	if !resp.NotModified {
		t.Fatal("expected same-version response to be marked not modified")
	}
}

func TestGetConfigUsesStreamedConfig(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentGatewayServiceClient(ctrl)
	client := NewGatewayClient("gateway:50052", nil, logger.NewTestLogger())
	client.client = mockClient
	client.connected = true

	req := &proto.AgentConfigRequest{
		AgentId:       "agent-1",
		ConfigVersion: "vold",
	}
	resp := &proto.AgentConfigResponse{
		ConfigVersion:         "vnew",
		ConfigTimestamp:       1_779_225_600,
		HeartbeatIntervalSec:  30,
		ConfigPollIntervalSec: 60,
		ConfigJson:            []byte(`{"sweep":{"groups":[{"device_targets":[{"network":"10.46.0.10/32"}]}]}}`),
	}

	mockClient.EXPECT().
		StreamConfig(gomock.Any(), req).
		Return(&configChunkStream{chunks: configResponseChunksForTest(t, resp, 32)}, nil)

	got, err := client.GetConfig(context.Background(), req)
	if err != nil {
		t.Fatalf("GetConfig returned error: %v", err)
	}
	if !goproto.Equal(got, resp) {
		t.Fatal("streamed config response did not match original response")
	}
}

func TestReassembleConfigChunksAcceptsLargeDeviceTargetConfig(t *testing.T) {
	t.Parallel()

	deviceTargetJSON := `{"network":"10.46.0.10/32","query_label":"prod","source":"srql","metadata":{"sweep_group_id":"group-1","target_query":"devices where site = 'demo'","device_uid":"dev-1","hostname":"edge-1","discovery_sources":"srql"}}`
	configJSON := `{"sweep":{"groups":[{"name":"srql-production","interval":"5m","device_targets":[` +
		strings.TrimSuffix(strings.Repeat(deviceTargetJSON+",", 25000), ",") +
		`]}}]}}`
	resp := &proto.AgentConfigResponse{
		ConfigVersion:         "vlarge",
		ConfigTimestamp:       1_779_225_600,
		HeartbeatIntervalSec:  30,
		ConfigPollIntervalSec: 60,
		ConfigJson:            []byte(configJSON),
	}

	chunks := configResponseChunksForTest(t, resp, 1024*1024)

	got, err := ReassembleConfigChunks(chunks)
	if err != nil {
		t.Fatalf("ReassembleConfigChunks returned error: %v", err)
	}
	if !goproto.Equal(got, resp) {
		t.Fatal("reassembled config response did not match original response")
	}
	if len(chunks) < 2 {
		t.Fatalf("expected multi-chunk response, got %d chunk(s)", len(chunks))
	}
}

func TestReassembleConfigChunksRejectsChecksumMismatch(t *testing.T) {
	t.Parallel()

	resp := &proto.AgentConfigResponse{
		ConfigVersion:   "v1",
		ConfigTimestamp: 1,
		ConfigJson:      []byte(`{"checks":[]}`),
	}
	chunks := configResponseChunksForTest(t, resp, 1024)
	chunks[0].PayloadSha256 = strings.Repeat("0", 64)

	_, err := ReassembleConfigChunks(chunks)
	if !errors.Is(err, ErrInvalidConfigStream) {
		t.Fatalf("ReassembleConfigChunks error = %v, want %v", err, ErrInvalidConfigStream)
	}
}

func TestReassembleConfigChunksRejectsMetadataMismatch(t *testing.T) {
	t.Parallel()

	resp := &proto.AgentConfigResponse{
		ConfigVersion:   "v1",
		ConfigTimestamp: 1,
		ConfigJson:      []byte(`{"checks":[]}`),
	}
	chunks := configResponseChunksForTest(t, resp, 1024)
	chunks[0].ConfigVersion = "v2"

	_, err := ReassembleConfigChunks(chunks)
	if !errors.Is(err, ErrInvalidConfigStream) {
		t.Fatalf("ReassembleConfigChunks error = %v, want %v", err, ErrInvalidConfigStream)
	}
}

func TestReassembleConfigChunksRejectsOutOfOrderChunks(t *testing.T) {
	t.Parallel()

	resp := &proto.AgentConfigResponse{
		ConfigVersion:   "v1",
		ConfigTimestamp: 1,
		ConfigJson:      []byte(strings.Repeat("x", 4096)),
	}
	chunks := configResponseChunksForTest(t, resp, 1024)
	chunks[0], chunks[1] = chunks[1], chunks[0]

	_, err := ReassembleConfigChunks(chunks)
	if !errors.Is(err, ErrInvalidConfigStream) {
		t.Fatalf("ReassembleConfigChunks error = %v, want %v", err, ErrInvalidConfigStream)
	}
}

func TestDesktopMediaMethodsFailWhenDisconnected(t *testing.T) {
	t.Parallel()

	client := NewGatewayClient("gateway:50052", nil, logger.NewTestLogger())
	ctx := context.Background()

	if _, err := client.OpenDesktopMediaSession(ctx, &proto.OpenDesktopMediaSessionRequest{}); !errors.Is(err, ErrGatewayNotConnected) {
		t.Fatalf("OpenDesktopMediaSession error = %v, want %v", err, ErrGatewayNotConnected)
	}

	if _, err := client.StreamDesktopMedia(ctx); !errors.Is(err, ErrGatewayNotConnected) {
		t.Fatalf("StreamDesktopMedia error = %v, want %v", err, ErrGatewayNotConnected)
	}

	if _, err := client.HeartbeatDesktopMediaSession(ctx, &proto.DesktopMediaHeartbeat{}); !errors.Is(err, ErrGatewayNotConnected) {
		t.Fatalf("HeartbeatDesktopMediaSession error = %v, want %v", err, ErrGatewayNotConnected)
	}

	if _, err := client.CloseDesktopMediaSession(ctx, &proto.CloseDesktopMediaSessionRequest{}); !errors.Is(err, ErrGatewayNotConnected) {
		t.Fatalf("CloseDesktopMediaSession error = %v, want %v", err, ErrGatewayNotConnected)
	}
}

func configResponseChunksForTest(t *testing.T, resp *proto.AgentConfigResponse, chunkSize int) []*proto.AgentConfigChunk {
	t.Helper()

	payload, err := goproto.Marshal(resp)
	if err != nil {
		t.Fatalf("marshal config response: %v", err)
	}

	sum := sha256.Sum256(payload)
	checksum := hex.EncodeToString(sum[:])
	totalChunks := (len(payload) + chunkSize - 1) / chunkSize
	if totalChunks == 0 {
		totalChunks = 1
	}

	chunks := make([]*proto.AgentConfigChunk, 0, totalChunks)
	for i := 0; i < totalChunks; i++ {
		offset := i * chunkSize
		end := offset + chunkSize
		if end > len(payload) {
			end = len(payload)
		}

		chunks = append(chunks, &proto.AgentConfigChunk{
			AgentId:         "agent-1",
			ConfigVersion:   resp.ConfigVersion,
			ConfigTimestamp: resp.ConfigTimestamp,
			NotModified:     resp.NotModified,
			Payload:         payload[offset:end],
			IsFinal:         i == totalChunks-1,
			ChunkIndex:      int32(i),
			TotalChunks:     int32(totalChunks),
			PayloadSha256:   checksum,
		})
	}

	return chunks
}

type configChunkStream struct {
	grpc.ClientStream
	chunks []*proto.AgentConfigChunk
	index  int
}

func (s *configChunkStream) Recv() (*proto.AgentConfigChunk, error) {
	if s.index >= len(s.chunks) {
		return nil, io.EOF
	}

	chunk := s.chunks[s.index]
	s.index++

	return chunk, nil
}

// A caller that cancels its Hello (an enrollment whose owner shut down) must not
// tear down the shared connection and its security provider; a transport
// failure still must.
func TestHelloDropsConnectionOnlyOnTransportFailure(t *testing.T) {
	tests := []struct {
		name          string
		callerCancels bool
		rpcErr        error
		wantConnected bool
	}{
		{name: "caller cancelled", callerCancels: true, wantConnected: true},
		{name: "transport unavailable", rpcErr: status.Error(codes.Unavailable, "connection lost"), wantConnected: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctrl := gomock.NewController(t)
			mockClient := proto.NewMockAgentGatewayServiceClient(ctrl)
			client := NewGatewayClient("gateway:50052", nil, logger.NewTestLogger())
			client.client = mockClient
			client.connected = true

			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			if tt.callerCancels {
				cancel()
			}

			mockClient.EXPECT().
				Hello(gomock.Any(), gomock.Any()).
				DoAndReturn(func(rpcCtx context.Context, _ *proto.AgentHelloRequest, _ ...grpc.CallOption) (*proto.AgentHelloResponse, error) {
					if tt.rpcErr != nil {
						return nil, tt.rpcErr
					}
					return nil, status.FromContextError(rpcCtx.Err()).Err()
				})

			_, err := client.Hello(ctx, &proto.AgentHelloRequest{AgentId: "agent-1"})
			if err == nil {
				t.Fatal("Hello returned nil error")
			}
			if connected := client.connected && client.client != nil; connected != tt.wantConnected {
				t.Fatalf("connected after Hello error = %v, want %v", connected, tt.wantConnected)
			}
		})
	}
}
