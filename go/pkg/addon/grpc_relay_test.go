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

package addon

import (
	"context"
	"net"
	"testing"
	"time"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
)

// baseAddon implements only the required Addon contract (no otlp-relay:v1).
type baseAddon struct{}

func (baseAddon) Info(context.Context) (Info, error) {
	return Info{ID: "test", Version: "0.0.0"}, nil
}

func (baseAddon) Configure(context.Context, []byte) (ConfigureResult, error) {
	return ConfigureResult{Accepted: true}, nil
}

func (baseAddon) Health(context.Context) (Health, error) {
	return Health{Status: HealthHealthy}, nil
}

// relayAddon additionally implements OtlpRelaySource: it emits frames with
// relay_ids 1..frameCount, records the ack watermarks it receives, and ends
// the stream once the final frame has been acked (so the round-trip test also
// exercises the clean close path).
type relayAddon struct {
	baseAddon
	frameCount uint64
	acked      chan uint64
}

func (a *relayAddon) RelayOtlp(ctx context.Context, acks <-chan uint64) (<-chan *addonpb.OtlpRelayFrame, error) {
	frames := make(chan *addonpb.OtlpRelayFrame)
	go func() {
		defer close(frames)
		for id := uint64(1); id <= a.frameCount; id++ {
			frame := &addonpb.OtlpRelayFrame{
				RelayId: id,
				Batch: &addonpb.TelemetryBatch{
					Records: []*addonpb.TelemetryRecord{{
						EventId:     "evt",
						PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
						Payload:     []byte("export-request-chunk"),
					}},
				},
			}
			select {
			case frames <- frame:
			case <-ctx.Done():
				return
			}
		}
		// Drain ack watermarks until the final frame is acked, the agent
		// half-closes, or the stream ends.
		for {
			select {
			case watermark, ok := <-acks:
				if !ok {
					return
				}
				select {
				case a.acked <- watermark:
				case <-ctx.Done():
					return
				}
				if watermark >= a.frameCount {
					return
				}
			case <-ctx.Done():
				return
			}
		}
	}()
	return frames, nil
}

// dialRelayClient serves impl over an in-memory bufconn transport and returns
// the SDK client adapter plus a cleanup func.
func dialRelayClient(t *testing.T, impl Addon) *grpcClient {
	t.Helper()

	listener := bufconn.Listen(1 << 20)
	server := grpc.NewServer()
	addonpb.RegisterAddonServiceServer(server, &grpcServer{impl: impl})
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

	return &grpcClient{client: addonpb.NewAddonServiceClient(conn)}
}

func TestRelayOtlpRoundTrip(t *testing.T) {
	impl := &relayAddon{frameCount: 3, acked: make(chan uint64, 8)}
	client := dialRelayClient(t, impl)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	frames, acks, err := client.RelayOtlp(ctx)
	if err != nil {
		t.Fatalf("RelayOtlp: %v", err)
	}

	var last uint64
	for frame := range frames {
		if frame.GetRelayId() != last+1 {
			t.Fatalf("expected relay_id %d, got %d", last+1, frame.GetRelayId())
		}
		if kind := frame.GetBatch().GetRecords()[0].GetPayloadKind(); kind != addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_TRACES {
			t.Fatalf("unexpected payload kind %v", kind)
		}
		last = frame.GetRelayId()
		acks <- last
	}
	if last != impl.frameCount {
		t.Fatalf("expected %d frames, got %d", impl.frameCount, last)
	}
	close(acks)

	// The add-on must have observed every cumulative ack watermark in order.
	for want := uint64(1); want <= impl.frameCount; want++ {
		select {
		case got := <-impl.acked:
			if got != want {
				t.Fatalf("expected ack watermark %d, got %d", want, got)
			}
		case <-ctx.Done():
			t.Fatalf("timed out waiting for ack watermark %d", want)
		}
	}
}

func TestRelayOtlpUnimplementedWithoutCapability(t *testing.T) {
	client := dialRelayClient(t, baseAddon{})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	frames, acks, err := client.RelayOtlp(ctx)
	if err != nil {
		t.Fatalf("RelayOtlp open: %v", err)
	}
	defer close(acks)

	// The stream opens lazily; the UNIMPLEMENTED status surfaces as the recv
	// goroutine closing the frames channel without delivering a frame. Probe
	// the raw client for the status code itself.
	if frame, ok := <-frames; ok {
		t.Fatalf("expected no frames from a relay-less add-on, got relay_id %d", frame.GetRelayId())
	}

	stream, err := client.client.RelayOtlp(ctx)
	if err != nil {
		t.Fatalf("raw RelayOtlp open: %v", err)
	}
	_, err = stream.Recv()
	if status.Code(err) != codes.Unimplemented {
		t.Fatalf("expected UNIMPLEMENTED, got %v", err)
	}
}
