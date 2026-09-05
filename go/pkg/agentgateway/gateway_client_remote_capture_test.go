package agentgateway

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

type captureServiceClientStub struct {
	stream grpc.BidiStreamingClient[
		proto.RemotePacketCaptureClientMessage,
		proto.RemotePacketCaptureServerMessage,
	]
}

func (s captureServiceClientStub) StreamCapture(
	context.Context,
	...grpc.CallOption,
) (grpc.BidiStreamingClient[proto.RemotePacketCaptureClientMessage, proto.RemotePacketCaptureServerMessage], error) {
	return s.stream, nil
}

func TestRemoteCaptureMultiplexesOnTheExistingGatewayConnection(t *testing.T) {
	// The assertion is deliberately at the client-construction seam. If this
	// method grows its own grpc.Dial/TLS setup, the factory no longer receives
	// the exact managed connection established by Connect and this test fails.
	existing := &grpc.ClientConn{}
	client := NewGatewayClient("gateway.example.test:50052", nil, logger.NewTestLogger())
	client.conn = existing
	client.connected = true

	var received grpc.ClientConnInterface
	client.remoteCaptureClientFactory = func(conn grpc.ClientConnInterface) proto.RemotePacketCaptureServiceClient {
		received = conn
		return captureServiceClientStub{}
	}

	stream, err := client.StreamRemoteCapture(context.Background())
	require.NoError(t, err)
	require.Nil(t, stream)
	require.Same(t, existing, received,
		"remote capture must use the existing mTLS HTTP/2 connection, not open a second TCP/TLS session")
	require.Same(t, existing, client.conn)
}
