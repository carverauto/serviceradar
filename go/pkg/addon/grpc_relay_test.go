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
	"errors"
	"io"
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

var errTelemetryTransportFailed = errors.New("telemetry transport failed")

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

type metricFeedAddon struct {
	baseAddon
	received chan *addonpb.MetricFeedFrame
}

func (a *metricFeedAddon) StreamMetricFeed(
	ctx context.Context,
	frames <-chan *addonpb.MetricFeedFrame,
) (<-chan uint64, error) {
	acks := make(chan uint64)
	go func() {
		defer close(acks)
		for {
			select {
			case <-ctx.Done():
				return
			case frame, ok := <-frames:
				if !ok {
					return
				}
				select {
				case a.received <- frame:
				case <-ctx.Done():
					return
				}
				select {
				case acks <- frame.GetFeedId():
				case <-ctx.Done():
					return
				}
			}
		}
	}()
	return acks, nil
}

type telemetryClosingAddon struct {
	baseAddon
}

func (a telemetryClosingAddon) StreamTelemetry(context.Context) (<-chan *addonpb.TelemetryBatch, error) {
	batches := make(chan *addonpb.TelemetryBatch)
	close(batches)
	return batches, nil
}

type errorTelemetryAddon struct {
	baseAddon
}

func (errorTelemetryAddon) StreamTelemetry(context.Context) (<-chan *addonpb.TelemetryBatch, error) {
	return nil, errTelemetryTransportFailed
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

func TestStreamMetricFeedRoundTrip(t *testing.T) {
	impl := &metricFeedAddon{received: make(chan *addonpb.MetricFeedFrame, 8)}
	client := dialRelayClient(t, impl)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	frames, acks, err := client.StreamMetricFeed(ctx)
	if err != nil {
		t.Fatalf("StreamMetricFeed: %v", err)
	}

	wantFrames := []*addonpb.MetricFeedFrame{
		{
			FeedId: 1,
			Source: &addonpb.TelemetrySource{
				SourceType:     "sysmon",
				SourceInstance: "agent-local",
				Metadata: map[string]string{
					"contract": CapabilityMetricFeedV1,
				},
			},
			Payload: []byte("metric-batch-1"),
		},
		{
			FeedId: 2,
			Source: &addonpb.TelemetrySource{
				SourceType:     "snmp",
				SourceInstance: "agent-local",
			},
			Payload: []byte("metric-batch-2"),
		},
	}

	for _, frame := range wantFrames {
		frames <- frame
		select {
		case got := <-impl.received:
			if got.GetFeedId() != frame.GetFeedId() || string(got.GetPayload()) != string(frame.GetPayload()) {
				t.Fatalf("received frame = %+v, want %+v", got, frame)
			}
		case <-ctx.Done():
			t.Fatal("timed out waiting for add-on to receive metric feed frame")
		}
		select {
		case got := <-acks:
			if got != frame.GetFeedId() {
				t.Fatalf("ack = %d, want %d", got, frame.GetFeedId())
			}
		case <-ctx.Done():
			t.Fatal("timed out waiting for metric feed ack")
		}
	}
	close(frames)

	assertStreamDiagnostic(t, client, "metric_feed_ack", StreamEndEOF)
}

func TestStreamTelemetryEmitsEOFDiagnostic(t *testing.T) {
	client := dialRelayClient(t, telemetryClosingAddon{})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	batches, err := client.StreamTelemetry(ctx)
	if err != nil {
		t.Fatalf("StreamTelemetry: %v", err)
	}
	for range batches {
		t.Fatal("unexpected telemetry batch")
	}

	select {
	case event := <-client.StreamLossEvents():
		if event.Stream != StreamNameTelemetry {
			t.Fatalf("stream = %q, want %q", event.Stream, StreamNameTelemetry)
		}
		if event.Operation != StreamOperationRecv {
			t.Fatalf("operation = %q, want %q", event.Operation, StreamOperationRecv)
		}
		if !event.EOF {
			t.Fatalf("EOF = false, want true: %+v", event)
		}
		if event.Err != nil {
			t.Fatalf("Err = %v, want nil for EOF", event.Err)
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for stream-loss diagnostic")
	}
}

func TestStreamLossDiagnosticDistinguishesTransportError(t *testing.T) {
	client := &grpcClient{}
	ctx := context.Background()

	client.emitStreamLoss(ctx, StreamNameMetricFeed, StreamOperationSend, status.Error(codes.Unavailable, "transport down"))
	client.emitStreamLoss(ctx, StreamNameTelemetry, StreamOperationRecv, io.EOF)

	select {
	case event := <-client.StreamLossEvents():
		if event.Stream != StreamNameMetricFeed || event.Operation != StreamOperationSend {
			t.Fatalf("event = %+v, want metric feed send", event)
		}
		if event.EOF {
			t.Fatalf("EOF = true, want false: %+v", event)
		}
		if status.Code(event.Err) != codes.Unavailable {
			t.Fatalf("Err = %v, want UNAVAILABLE", event.Err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for transport-error diagnostic")
	}

	select {
	case event := <-client.StreamLossEvents():
		if event.Stream != StreamNameTelemetry || event.Operation != StreamOperationRecv {
			t.Fatalf("event = %+v, want telemetry recv", event)
		}
		if !event.EOF || event.Err != nil {
			t.Fatalf("event = %+v, want clean EOF event", event)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for EOF diagnostic")
	}
}

func TestStreamMetricFeedUnimplementedWithoutCapability(t *testing.T) {
	client := dialRelayClient(t, baseAddon{})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	frames, acks, err := client.StreamMetricFeed(ctx)
	if err != nil {
		t.Fatalf("StreamMetricFeed open: %v", err)
	}
	close(frames)
	if ack, ok := <-acks; ok {
		t.Fatalf("expected no acks from a feed-less add-on, got %d", ack)
	}

	stream, err := client.client.StreamMetricFeed(ctx)
	if err != nil {
		t.Fatalf("raw StreamMetricFeed open: %v", err)
	}
	_, err = stream.Recv()
	if status.Code(err) != codes.Unimplemented {
		t.Fatalf("expected UNIMPLEMENTED, got %v", err)
	}
}

func TestStreamTelemetryReportsEOFDiagnostic(t *testing.T) {
	client := dialRelayClient(t, baseAddon{})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	batches, err := client.StreamTelemetry(ctx)
	if err != nil {
		t.Fatalf("StreamTelemetry open: %v", err)
	}
	if batch, ok := <-batches; ok {
		t.Fatalf("expected no telemetry batches, got %+v", batch)
	}

	assertStreamDiagnostic(t, client, "telemetry", StreamEndEOF)
}

func TestStreamTelemetryReportsErrorDiagnostic(t *testing.T) {
	client := dialRelayClient(t, errorTelemetryAddon{})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	batches, err := client.StreamTelemetry(ctx)
	if err != nil {
		t.Fatalf("StreamTelemetry open: %v", err)
	}
	if batch, ok := <-batches; ok {
		t.Fatalf("expected no telemetry batches, got %+v", batch)
	}

	assertStreamDiagnostic(t, client, "telemetry", StreamEndError)
}

func TestStreamArtifactsReportsEOFDiagnostic(t *testing.T) {
	client := dialRelayClient(t, baseAddon{})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	chunks, err := client.StreamArtifacts(ctx)
	if err != nil {
		t.Fatalf("StreamArtifacts open: %v", err)
	}
	if chunk, ok := <-chunks; ok {
		t.Fatalf("expected no artifact chunks, got %+v", chunk)
	}

	assertStreamDiagnostic(t, client, "artifacts", StreamEndEOF)
}

func TestClassifyStreamEnd(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if got := classifyStreamEnd(context.Background(), io.EOF); got != StreamEndEOF {
		t.Fatalf("EOF kind = %s, want %s", got, StreamEndEOF)
	}
	if got := classifyStreamEnd(ctx, context.Canceled); got != StreamEndContext {
		t.Fatalf("context kind = %s, want %s", got, StreamEndContext)
	}
	if got := classifyStreamEnd(context.Background(), status.Error(codes.Unavailable, "down")); got != StreamEndError {
		t.Fatalf("transport kind = %s, want %s", got, StreamEndError)
	}
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

func assertStreamDiagnostic(
	t *testing.T,
	client *grpcClient,
	stream string,
	kind StreamEndKind,
) {
	t.Helper()

	select {
	case got := <-client.StreamDiagnostics():
		if got.Stream != stream || got.Kind != kind {
			t.Fatalf("diagnostic = {%s %s %v}, want stream=%s kind=%s", got.Stream, got.Kind, got.Err, stream, kind)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for %s diagnostic", stream)
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
