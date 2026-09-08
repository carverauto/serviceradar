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
	"sync"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	goplugin "github.com/hashicorp/go-plugin"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// GRPCPlugin adapts an Addon implementation to the go-plugin gRPC transport. The
// server side carries Impl; the client side leaves it nil and returns an Addon
// client from GRPCClient.
type GRPCPlugin struct {
	goplugin.NetRPCUnsupportedPlugin
	Impl Addon
}

var _ goplugin.GRPCPlugin = (*GRPCPlugin)(nil)

// GRPCServer registers the add-on implementation with the plugin's gRPC server.
func (p *GRPCPlugin) GRPCServer(_ *goplugin.GRPCBroker, s *grpc.Server) error {
	addonpb.RegisterAddonServiceServer(s, &grpcServer{impl: p.Impl})
	return nil
}

// GRPCClient returns an Addon backed by the plugin's gRPC client connection.
func (p *GRPCPlugin) GRPCClient(_ context.Context, _ *goplugin.GRPCBroker, c *grpc.ClientConn) (interface{}, error) {
	return &grpcClient{client: addonpb.NewAddonServiceClient(c)}, nil
}

// ServerPluginSet is the plugin set an add-on serves (used by the SDK).
func ServerPluginSet(impl Addon) goplugin.PluginSet {
	return goplugin.PluginSet{PluginName: &GRPCPlugin{Impl: impl}}
}

// ClientPluginSet is the plugin set the agent dispenses (used by the manager).
func ClientPluginSet() goplugin.PluginSet {
	return goplugin.PluginSet{PluginName: &GRPCPlugin{}}
}

// grpcServer adapts an Addon to the generated AddonServiceServer.
type grpcServer struct {
	addonpb.UnimplementedAddonServiceServer
	impl Addon
}

func (s *grpcServer) Info(ctx context.Context, _ *addonpb.InfoRequest) (*addonpb.InfoResponse, error) {
	info, err := s.impl.Info(ctx)
	if err != nil {
		return nil, err
	}
	return &addonpb.InfoResponse{
		Id:           info.ID,
		Version:      info.Version,
		Capabilities: info.Capabilities,
	}, nil
}

func (s *grpcServer) Configure(ctx context.Context, req *addonpb.ConfigureRequest) (*addonpb.ConfigureResponse, error) {
	res, err := s.impl.Configure(ctx, req.GetConfigJson())
	if err != nil {
		return nil, err
	}
	return &addonpb.ConfigureResponse{
		ConfigHash: res.ConfigHash,
		Accepted:   res.Accepted,
		Error:      res.Error,
	}, nil
}

func (s *grpcServer) Health(ctx context.Context, _ *addonpb.HealthRequest) (*addonpb.HealthResponse, error) {
	h, err := s.impl.Health(ctx)
	if err != nil {
		return nil, err
	}
	return &addonpb.HealthResponse{
		Status:            healthStatusToProto(h.Status),
		Version:           h.Version,
		DegradationReason: h.DegradationReason,
	}, nil
}

func (s *grpcServer) StreamTelemetry(
	_ *addonpb.StreamTelemetryRequest,
	stream addonpb.AddonService_StreamTelemetryServer,
) error {
	source, ok := s.impl.(TelemetrySource)
	if !ok {
		return nil
	}

	batches, err := source.StreamTelemetry(stream.Context())
	if err != nil {
		return err
	}

	for {
		select {
		case <-stream.Context().Done():
			return stream.Context().Err()
		case batch, ok := <-batches:
			if !ok {
				return nil
			}
			if batch == nil {
				continue
			}
			if err := stream.Send(batch); err != nil {
				return err
			}
		}
	}
}

func (s *grpcServer) StreamArtifacts(
	_ *addonpb.StreamArtifactsRequest,
	stream addonpb.AddonService_StreamArtifactsServer,
) error {
	source, ok := s.impl.(ArtifactSource)
	if !ok {
		return nil
	}

	chunks, err := source.StreamArtifacts(stream.Context())
	if err != nil {
		return err
	}

	for {
		select {
		case <-stream.Context().Done():
			return stream.Context().Err()
		case chunk, ok := <-chunks:
			if !ok {
				return nil
			}
			if chunk == nil {
				continue
			}
			if err := stream.Send(chunk); err != nil {
				return err
			}
		}
	}
}

// RelayOtlp bridges the generated bidi stream to the optional OtlpRelaySource
// contract. Add-ons that do not advertise otlp-relay:v1 (and so do not
// implement OtlpRelaySource) report UNIMPLEMENTED, mirroring the Rust SDK's
// default, so a misdirected agent fails loudly instead of silently dropping
// an acked relay.
func (s *grpcServer) RelayOtlp(stream addonpb.AddonService_RelayOtlpServer) error {
	source, ok := s.impl.(OtlpRelaySource)
	if !ok {
		return status.Error(codes.Unimplemented, "add-on does not implement otlp-relay:v1")
	}

	ctx := stream.Context()
	acks := make(chan uint64)
	go func() {
		defer close(acks)
		for {
			ack, err := stream.Recv()
			if err != nil {
				return
			}
			select {
			case acks <- ack.GetAckedRelayId():
			case <-ctx.Done():
				return
			}
		}
	}()

	frames, err := source.RelayOtlp(ctx, acks)
	if err != nil {
		return err
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case frame, ok := <-frames:
			if !ok {
				return nil
			}
			if frame == nil {
				continue
			}
			if err := stream.Send(frame); err != nil {
				return err
			}
		}
	}
}

// StreamMetricFeed bridges the generated bidi stream to the optional
// MetricFeedSink contract. Add-ons that do not advertise metric-feed:v1 (and so
// do not implement MetricFeedSink) report UNIMPLEMENTED instead of silently
// dropping analysis input.
func (s *grpcServer) StreamMetricFeed(stream addonpb.AddonService_StreamMetricFeedServer) error {
	sink, ok := s.impl.(MetricFeedSink)
	if !ok {
		return status.Error(codes.Unimplemented, "add-on does not implement metric-feed:v1")
	}

	ctx := stream.Context()
	frames := make(chan *addonpb.MetricFeedFrame)
	go func() {
		defer close(frames)
		for {
			frame, err := stream.Recv()
			if err != nil {
				return
			}
			select {
			case frames <- frame:
			case <-ctx.Done():
				return
			}
		}
	}()

	acks, err := sink.StreamMetricFeed(ctx, frames)
	if err != nil {
		return err
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case ack, ok := <-acks:
			if !ok {
				return nil
			}
			if err := stream.Send(&addonpb.MetricFeedAck{AckedFeedId: ack}); err != nil {
				return err
			}
		}
	}
}

func (s *grpcServer) RunCommand(
	ctx context.Context,
	req *addonpb.RunCommandRequest,
) (*addonpb.RunCommandResponse, error) {
	handler, ok := s.impl.(CommandHandler)
	if !ok {
		return &addonpb.RunCommandResponse{
			Success: false,
			Message: "addon command handler unavailable",
		}, nil
	}

	result, err := handler.RunCommand(ctx, CommandRequest{
		CommandID:    req.GetCommandId(),
		CommandType:  req.GetCommandType(),
		ActionID:     req.GetActionId(),
		Schema:       req.GetSchema(),
		PayloadJSON:  req.GetPayloadJson(),
		DeadlineUnix: req.GetDeadlineUnix(),
		Metadata:     req.GetMetadata(),
	})
	if err != nil {
		return nil, err
	}

	return &addonpb.RunCommandResponse{
		Success:     result.Success,
		Message:     result.Message,
		PayloadJson: result.PayloadJSON,
		Metadata:    result.Metadata,
	}, nil
}

// grpcClient adapts the generated AddonServiceClient to the Addon interface.
type grpcClient struct {
	client addonpb.AddonServiceClient

	streamLossOnce sync.Once
	streamLoss     chan StreamLossEvent

	diagnostics     chan StreamDiagnostic
	diagnosticsOnce sync.Once
}

var _ Addon = (*grpcClient)(nil)
var _ TelemetryClient = (*grpcClient)(nil)
var _ ArtifactClient = (*grpcClient)(nil)
var _ CommandClient = (*grpcClient)(nil)
var _ OtlpRelayClient = (*grpcClient)(nil)
var _ MetricFeedClient = (*grpcClient)(nil)
var _ StreamLossDiagnostics = (*grpcClient)(nil)
var _ StreamDiagnosticsClient = (*grpcClient)(nil)

func (c *grpcClient) StreamLossEvents() <-chan StreamLossEvent {
	return c.streamLossEvents()
}

func (c *grpcClient) streamLossEvents() chan StreamLossEvent {
	c.streamLossOnce.Do(func() {
		c.streamLoss = make(chan StreamLossEvent, 32)
	})
	return c.streamLoss
}

func (c *grpcClient) emitStreamLoss(ctx context.Context, streamName string, operation string, err error) {
	if err == nil || ctx.Err() != nil {
		return
	}

	event := StreamLossEvent{
		Stream:    streamName,
		Operation: operation,
		EOF:       errors.Is(err, io.EOF),
	}
	if !event.EOF {
		event.Err = err
	}

	select {
	case c.streamLossEvents() <- event:
	default:
	}
}

func (c *grpcClient) StreamDiagnostics() <-chan StreamDiagnostic {
	c.ensureDiagnostics()
	return c.diagnostics
}

func (c *grpcClient) Info(ctx context.Context) (Info, error) {
	resp, err := c.client.Info(ctx, &addonpb.InfoRequest{})
	if err != nil {
		return Info{}, err
	}
	return Info{
		ID:           resp.GetId(),
		Version:      resp.GetVersion(),
		Capabilities: resp.GetCapabilities(),
	}, nil
}

func (c *grpcClient) Configure(ctx context.Context, configJSON []byte) (ConfigureResult, error) {
	resp, err := c.client.Configure(ctx, &addonpb.ConfigureRequest{ConfigJson: configJSON})
	if err != nil {
		return ConfigureResult{}, err
	}
	return ConfigureResult{
		ConfigHash: resp.GetConfigHash(),
		Accepted:   resp.GetAccepted(),
		Error:      resp.GetError(),
	}, nil
}

func (c *grpcClient) Health(ctx context.Context) (Health, error) {
	resp, err := c.client.Health(ctx, &addonpb.HealthRequest{})
	if err != nil {
		return Health{}, err
	}
	return Health{
		Status:            healthStatusFromProto(resp.GetStatus()),
		Version:           resp.GetVersion(),
		DegradationReason: resp.GetDegradationReason(),
	}, nil
}

func (c *grpcClient) StreamTelemetry(ctx context.Context) (<-chan *addonpb.TelemetryBatch, error) {
	stream, err := c.client.StreamTelemetry(ctx, &addonpb.StreamTelemetryRequest{
		Capability: CapabilityNativeTelemetryV1,
	})
	if err != nil {
		return nil, err
	}

	out := make(chan *addonpb.TelemetryBatch)
	go func() {
		defer close(out)
		for {
			batch, err := stream.Recv()
			if err != nil {
				c.emitStreamLoss(ctx, StreamNameTelemetry, StreamOperationRecv, err)
				c.emitStreamDiagnostic(ctx, StreamNameTelemetry, err)
				return
			}
			select {
			case out <- batch:
			case <-ctx.Done():
				return
			}
		}
	}()

	return out, nil
}

func (c *grpcClient) StreamArtifacts(ctx context.Context) (<-chan *addonpb.ArtifactUploadChunk, error) {
	stream, err := c.client.StreamArtifacts(ctx, &addonpb.StreamArtifactsRequest{
		Capability: CapabilityArtifactStagingV1,
	})
	if err != nil {
		return nil, err
	}

	out := make(chan *addonpb.ArtifactUploadChunk)
	go func() {
		defer close(out)
		for {
			chunk, err := stream.Recv()
			if err != nil {
				c.emitStreamLoss(ctx, StreamNameArtifacts, StreamOperationRecv, err)
				c.emitStreamDiagnostic(ctx, StreamNameArtifacts, err)
				return
			}
			select {
			case out <- chunk:
			case <-ctx.Done():
				return
			}
		}
	}()

	return out, nil
}

// RelayOtlp opens the acked OTLP relay stream against the remote add-on. The
// returned frames channel yields the add-on's OtlpRelayFrame messages and is
// closed when the stream ends; the caller sends cumulative ack watermarks on
// the returned acks channel only after gateway acceptance, and closes it to
// half-close the send direction.
func (c *grpcClient) RelayOtlp(ctx context.Context) (<-chan *addonpb.OtlpRelayFrame, chan<- uint64, error) {
	stream, err := c.client.RelayOtlp(ctx)
	if err != nil {
		return nil, nil, err
	}

	frames := make(chan *addonpb.OtlpRelayFrame)
	go func() {
		defer close(frames)
		for {
			frame, err := stream.Recv()
			if err != nil {
				c.emitStreamLoss(ctx, StreamNameOtlpRelay, StreamOperationRecv, err)
				return
			}
			select {
			case frames <- frame:
			case <-ctx.Done():
				return
			}
		}
	}()

	acks := make(chan uint64)
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case watermark, ok := <-acks:
				if !ok {
					_ = stream.CloseSend()
					return
				}
				if err := stream.Send(&addonpb.OtlpRelayAck{AckedRelayId: watermark}); err != nil {
					c.emitStreamLoss(ctx, StreamNameOtlpRelay, StreamOperationSend, err)
					return
				}
			}
		}
	}()

	return frames, acks, nil
}

// metricFeedSendBuffer bounds the in-flight MetricFeedFrames buffered toward a
// slow add-on before the agent's non-blocking feed starts dropping.
const metricFeedSendBuffer = 256

// StreamMetricFeed opens the local metric feed against the remote add-on. The
// caller sends MetricFeedFrame messages on the returned frames channel (closing
// it half-closes the send direction) and reads cumulative ack watermarks on the
// returned acks channel for flow control. The data direction is the inverse of
// RelayOtlp: here the agent is the producer.
func (c *grpcClient) StreamMetricFeed(ctx context.Context) (chan<- *addonpb.MetricFeedFrame, <-chan uint64, error) {
	streamCtx, cancel := context.WithCancel(ctx)
	stream, err := c.client.StreamMetricFeed(streamCtx)
	if err != nil {
		cancel()
		return nil, nil, err
	}

	// Buffered so the caller's non-blocking sends can absorb a burst while a
	// slow stream.Send drains; this buffer is the in-flight bound for the feed.
	frames := make(chan *addonpb.MetricFeedFrame, metricFeedSendBuffer)
	go func() {
		for {
			select {
			case <-streamCtx.Done():
				return
			case frame, ok := <-frames:
				if !ok {
					_ = stream.CloseSend()
					return
				}
				if frame == nil {
					continue
				}
				if err := stream.Send(frame); err != nil {
					c.emitStreamLoss(ctx, StreamNameMetricFeed, StreamOperationSend, err)
					c.emitStreamDiagnostic(streamCtx, StreamNameMetricFeed, err)
					cancel()
					return
				}
			}
		}
	}()

	acks := make(chan uint64)
	go func() {
		defer cancel()
		defer close(acks)
		for {
			ack, err := stream.Recv()
			if err != nil {
				c.emitStreamLoss(ctx, StreamNameMetricFeedAck, StreamOperationRecv, err)
				c.emitStreamDiagnostic(streamCtx, StreamNameMetricFeedAck, err)
				return
			}
			select {
			case acks <- ack.GetAckedFeedId():
			case <-streamCtx.Done():
				return
			}
		}
	}()

	return frames, acks, nil
}

func (c *grpcClient) ensureDiagnostics() {
	c.diagnosticsOnce.Do(func() {
		c.diagnostics = make(chan StreamDiagnostic, 16)
	})
}

func (c *grpcClient) emitStreamDiagnostic(ctx context.Context, stream string, err error) {
	if err == nil {
		return
	}

	diagnostic := StreamDiagnostic{
		Stream: stream,
		Kind:   classifyStreamEnd(ctx, err),
		Err:    err,
	}

	c.ensureDiagnostics()
	select {
	case c.diagnostics <- diagnostic:
	default:
	}
}

func classifyStreamEnd(ctx context.Context, err error) StreamEndKind {
	if errors.Is(err, io.EOF) {
		return StreamEndEOF
	}
	if ctx != nil && ctx.Err() != nil {
		return StreamEndContext
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return StreamEndContext
	}
	return StreamEndError
}

func (c *grpcClient) RunCommand(ctx context.Context, request CommandRequest) (CommandResult, error) {
	resp, err := c.client.RunCommand(ctx, &addonpb.RunCommandRequest{
		CommandId:    request.CommandID,
		CommandType:  request.CommandType,
		ActionId:     request.ActionID,
		Schema:       request.Schema,
		PayloadJson:  request.PayloadJSON,
		DeadlineUnix: request.DeadlineUnix,
		Metadata:     request.Metadata,
	})
	if err != nil {
		return CommandResult{}, err
	}

	return CommandResult{
		Success:     resp.GetSuccess(),
		Message:     resp.GetMessage(),
		PayloadJSON: resp.GetPayloadJson(),
		Metadata:    resp.GetMetadata(),
	}, nil
}
