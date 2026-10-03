package agentgateway

import (
	"context"
	"net"
	"testing"

	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

// cameraRelayStatusServer fails every relay RPC with one fixed status, the way
// the gateway reports a relay-level or a connection-level failure.
type cameraRelayStatusServer struct {
	proto.UnimplementedCameraMediaServiceServer
	err error
}

func (s *cameraRelayStatusServer) Heartbeat(context.Context, *proto.RelayHeartbeat) (*proto.RelayHeartbeatAck, error) {
	return nil, s.err
}

func (s *cameraRelayStatusServer) UploadMedia(stream grpc.ClientStreamingServer[proto.MediaChunk, proto.UploadMediaResponse]) error {
	for {
		if _, err := stream.Recv(); err != nil {
			return s.err
		}
	}
}

func connectedClientForCameraRelayServer(t *testing.T, rpcErr error) *GatewayClient {
	t.Helper()

	listener := bufconn.Listen(1 << 20)
	server := grpc.NewServer()
	proto.RegisterCameraMediaServiceServer(server, &cameraRelayStatusServer{err: rpcErr})

	go func() { _ = server.Serve(listener) }()

	t.Cleanup(server.Stop)

	conn, err := grpc.NewClient(
		"passthrough:///bufconn",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return listener.DialContext(ctx)
		}),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	require.NoError(t, err)

	client := NewGatewayClient("gateway.example.test:50052", nil, logger.NewTestLogger())
	client.conn = conn
	client.connected = true

	t.Cleanup(func() {
		if client.conn != nil {
			_ = client.conn.Close()
		}
	})

	return client
}

// A relay that fails at the gateway or its core side must not cost the agent
// its gateway connection: every other stream rides on it, including the
// relay's own close. Only a transport failure (codes.Unavailable) drops it.
func TestCameraRelayErrorsDropConnectionOnlyOnTransportFailure(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name          string
		rpcErr        error
		wantConnected bool
	}{
		{name: "relay aborted", rpcErr: status.Error(codes.Aborted, "failed to forward media stream"), wantConnected: true},
		{name: "relay not found", rpcErr: status.Error(codes.NotFound, "relay session not found"), wantConnected: true},
		{name: "transport unavailable", rpcErr: status.Error(codes.Unavailable, "connection lost"), wantConnected: false},
	}

	calls := []struct {
		name string
		call func(context.Context, *GatewayClient) error
	}{
		{
			name: "heartbeat",
			call: func(ctx context.Context, client *GatewayClient) error {
				_, err := client.HeartbeatRelaySession(ctx, &proto.RelayHeartbeat{RelaySessionId: "relay-1"})
				return err
			},
		},
		{
			name: "upload",
			call: func(ctx context.Context, client *GatewayClient) error {
				_, err := client.UploadMedia(ctx, []*proto.MediaChunk{{RelaySessionId: "relay-1", Payload: []byte{1}}})
				return err
			},
		},
	}

	for _, tt := range tests {
		for _, rpc := range calls {
			t.Run(tt.name+"/"+rpc.name, func(t *testing.T) {
				t.Parallel()

				client := connectedClientForCameraRelayServer(t, tt.rpcErr)

				err := rpc.call(t.Context(), client)
				require.Error(t, err)
				require.Equal(t, status.Code(tt.rpcErr), status.Code(err))

				client.mu.RLock()
				connected := client.connected
				client.mu.RUnlock()
				require.Equal(t, tt.wantConnected, connected)
			})
		}
	}
}
