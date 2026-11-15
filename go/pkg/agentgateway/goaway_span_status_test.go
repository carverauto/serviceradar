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

package agentgateway

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.opentelemetry.io/otel/attribute"
	otelcodes "go.opentelemetry.io/otel/codes"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/connectivity"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"

	"github.com/carverauto/serviceradar/proto"
)

const controlStreamSpanName = "monitoring.AgentGatewayService/ControlStream"

// heldControlStreamServer holds every control stream open until the server
// stops, the way the gateway holds an agent's control stream.
type heldControlStreamServer struct {
	proto.UnimplementedAgentGatewayServiceServer
	opened chan struct{}
}

func (s *heldControlStreamServer) ControlStream(
	stream grpc.BidiStreamingServer[proto.ControlStreamRequest, proto.ControlStreamResponse],
) error {
	s.opened <- struct{}{}
	<-stream.Context().Done()

	return stream.Context().Err()
}

// A control stream cut off by a planned server drain (GOAWAY NO_ERROR, as in a
// gateway rollout) is not an error span; a connection lost without that GOAWAY
// still is. Both end in Unavailable, so only the GOAWAY tells them apart.
func TestControlStreamSpanStatusWhenGatewayGoesAway(t *testing.T) {
	cases := []struct {
		name       string
		drainFirst bool
		wantStatus otelcodes.Code
		wantGoAway bool
	}{
		{name: "graceful drain", drainFirst: true, wantStatus: otelcodes.Ok, wantGoAway: true},
		{name: "connection lost", drainFirst: false, wantStatus: otelcodes.Error, wantGoAway: false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			recorder := tracetest.NewSpanRecorder()
			tracerProvider := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder))
			t.Cleanup(func() { _ = tracerProvider.Shutdown(context.Background()) })

			listener := bufconn.Listen(1 << 20)
			server := grpc.NewServer()
			gateway := &heldControlStreamServer{opened: make(chan struct{}, 1)}
			proto.RegisterAgentGatewayServiceServer(server, gateway)

			go func() { _ = server.Serve(listener) }()

			t.Cleanup(server.Stop)

			conn, err := grpc.NewClient(
				"passthrough:///bufconn",
				grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
					return listener.DialContext(ctx)
				}),
				grpc.WithTransportCredentials(insecure.NewCredentials()),
				grpc.WithStatsHandler(drainAwareClientHandler{
					Handler: otelgrpc.NewClientHandler(otelgrpc.WithTracerProvider(tracerProvider)),
				}),
			)
			require.NoError(t, err)
			t.Cleanup(func() { _ = conn.Close() })

			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()

			stream, err := proto.NewAgentGatewayServiceClient(conn).ControlStream(ctx)
			require.NoError(t, err)

			select {
			case <-gateway.opened:
			case <-ctx.Done():
				t.Fatal("control stream never reached the gateway")
			}

			if tc.drainFirst {
				go server.GracefulStop()

				// The client leaves Ready once it has read the GOAWAY.
				require.True(t, conn.WaitForStateChange(ctx, connectivity.Ready), "client never saw the GOAWAY")
			}

			// GracefulStop waits for open streams; Stop cuts them, as a
			// rollout's grace period ending does.
			server.Stop()

			_, err = stream.Recv()
			require.Equal(t, codes.Unavailable, status.Code(err), "stream error: %v", err)

			if tc.drainFirst {
				require.Contains(t, err.Error(), "received prior goaway: code: NO_ERROR")
			} else {
				require.NotContains(t, err.Error(), "goaway")
			}

			var span sdktrace.ReadOnlySpan
			require.Eventually(t, func() bool {
				for _, ended := range recorder.Ended() {
					if ended.Name() == controlStreamSpanName {
						span = ended
						return true
					}
				}

				return false
			}, 5*time.Second, 10*time.Millisecond, "control stream span never ended")

			assert.Equal(t, tc.wantStatus, span.Status().Code, "span status: %+v", span.Status())
			assert.Contains(t, span.Attributes(), attribute.String("rpc.response.status_code", "UNAVAILABLE"))

			goAway := attribute.String("rpc.grpc.goaway", "NO_ERROR")
			if tc.wantGoAway {
				assert.Contains(t, span.Attributes(), goAway)
			} else {
				assert.NotContains(t, span.Attributes(), goAway)
			}
		})
	}
}
