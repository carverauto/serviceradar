/*
 * Copyright 2025 Carver Automation Corporation.
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

// Package agentgateway pkg/agentgateway/gateway_client.go
package agentgateway

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/connectivity"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/keepalive"
	"google.golang.org/grpc/status"
	goproto "google.golang.org/protobuf/proto"

	srgrpc "github.com/carverauto/serviceradar/go/pkg/grpc"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

var (
	// ErrGatewayNotConnected indicates the gateway client is not connected.
	ErrGatewayNotConnected = errors.New("gateway client not connected")
	// ErrGatewayAddrRequired indicates gateway_addr is required in configuration.
	ErrGatewayAddrRequired = errors.New("gateway_addr is required for push mode")
	// ErrEnrollmentRejected indicates the gateway rejected agent enrollment.
	ErrEnrollmentRejected = errors.New("agent enrollment rejected by gateway")
	// ErrSecurityRequired indicates security configuration is required for production.
	ErrSecurityRequired = errors.New("security configuration required: set SR_ALLOW_INSECURE=true for development")
	// ErrNoChunksToSend indicates no valid status chunks were provided for streaming.
	ErrNoChunksToSend = errors.New("no status chunks to send")
	// ErrStreamStatusChunkTooLarge indicates a status stream chunk exceeds the per-message budget.
	ErrStreamStatusChunkTooLarge = errors.New("stream status chunk too large")
	// ErrStreamStatusBudgetExceeded indicates a status stream exceeds the per-stream byte budget.
	ErrStreamStatusBudgetExceeded = errors.New("stream status byte budget exceeded")
	// ErrNoConfigChunks indicates a streamed config response did not contain chunks.
	ErrNoConfigChunks = errors.New("stream config response contained no chunks")
	// ErrConfigChunkTooLarge indicates a streamed config chunk exceeds the per-message budget.
	ErrConfigChunkTooLarge = errors.New("stream config chunk too large")
	// ErrConfigStreamBudgetExceeded indicates a streamed config exceeds the per-stream byte budget.
	ErrConfigStreamBudgetExceeded = errors.New("stream config byte budget exceeded")
	// ErrInvalidConfigStream indicates a streamed config response is malformed.
	ErrInvalidConfigStream = errors.New("invalid stream config response")
	// ErrConnectionShutdown indicates the gRPC connection entered shutdown state.
	ErrConnectionShutdown = errors.New("connection shutdown")
)

const (
	defaultPushInterval   = 30 * time.Second
	defaultConnectTimeout = 10 * time.Second
	defaultReconnectDelay = 5 * time.Second
	maxReconnectDelay     = 60 * time.Second
	defaultPushTimeout    = 30 * time.Second
	defaultConfigTimeout  = 30 * time.Second
	defaultKeepaliveTime  = 30 * time.Second
	defaultKeepaliveTTL   = 10 * time.Second
	streamStatusChunkMax  = 16 * 1024 * 1024
	streamStatusWindowMax = 64 * 1024 * 1024
	streamConfigChunkMax  = 2 * 1024 * 1024
	streamConfigWindowMax = 64 * 1024 * 1024
)

// GatewayClient manages the connection to the agent-gateway and pushes status updates.
type GatewayClient struct {
	mu                         sync.RWMutex
	conn                       *grpc.ClientConn
	client                     proto.AgentGatewayServiceClient
	addr                       string
	security                   *models.SecurityConfig
	securityProvider           srgrpc.SecurityProvider
	connected                  bool
	reconnectDelay             time.Duration
	gatewayID                  string
	logger                     logger.Logger
	remoteCaptureClientFactory func(grpc.ClientConnInterface) proto.RemotePacketCaptureServiceClient
}

// StreamRemoteCapture opens the remote-capture HTTP/2 stream on the existing
// managed gateway connection. It must not dial: capture traffic shares the
// agent's already-authenticated mTLS channel with every other gateway RPC.
func (g *GatewayClient) StreamRemoteCapture(
	ctx context.Context,
) (grpc.BidiStreamingClient[proto.RemotePacketCaptureClientMessage, proto.RemotePacketCaptureServerMessage], error) {
	g.mu.RLock()
	conn := g.conn
	connected := g.connected
	factory := g.remoteCaptureClientFactory
	g.mu.RUnlock()

	if !connected || conn == nil {
		return nil, ErrGatewayNotConnected
	}

	if factory == nil {
		factory = proto.NewRemotePacketCaptureServiceClient
	}

	stream, err := factory(conn).StreamCapture(ctx)
	if err != nil {
		g.logger.Error().Err(err).Msg("Failed to create remote capture stream")
		g.markDisconnected()
		return nil, fmt.Errorf("failed to create remote capture stream: %w", err)
	}

	return stream, nil
}

// NewGatewayClient creates a new gateway client.
func NewGatewayClient(addr string, security *models.SecurityConfig, log logger.Logger) *GatewayClient {
	return &GatewayClient{
		addr:           addr,
		security:       security,
		reconnectDelay: defaultReconnectDelay,
		logger:         log,
	}
}

// Connect establishes a connection to the gateway.
func (g *GatewayClient) Connect(ctx context.Context) error {
	var (
		staleConn     *grpc.ClientConn
		staleProvider srgrpc.SecurityProvider
	)

	g.mu.Lock()
	if g.addr == "" {
		g.mu.Unlock()
		return ErrGatewayAddrRequired
	}

	if g.conn != nil {
		if g.conn.GetState() == connectivity.Ready && g.connected {
			g.mu.Unlock()
			return nil // Already connected and ready
		}
		// Connection exists but isn't healthy; force reconnect.
		staleConn = g.conn
		staleProvider = g.securityProvider
		g.conn = nil
		g.client = nil
		g.connected = false
		g.securityProvider = nil
	}

	g.mu.Unlock()

	if staleConn != nil {
		_ = staleConn.Close()
	}
	if staleProvider != nil {
		_ = staleProvider.Close()
	}

	g.logger.Info().Str("addr", g.addr).Msg("Connecting to agent-gateway")

	opts, provider, err := g.buildDialOptions(ctx)
	if err != nil {
		return fmt.Errorf("failed to build dial options: %w", err)
	}

	connectCtx, cancel := context.WithTimeout(ctx, defaultConnectTimeout)
	defer cancel()

	conn, err := grpc.NewClient(g.addr, opts...)
	if err != nil {
		if provider != nil {
			_ = provider.Close()
		}
		return fmt.Errorf("failed to connect to gateway at %s: %w", g.addr, err)
	}

	conn.Connect()
	for state := conn.GetState(); state != connectivity.Ready; state = conn.GetState() {
		if state == connectivity.Shutdown {
			_ = conn.Close()
			if provider != nil {
				_ = provider.Close()
			}
			return fmt.Errorf("failed to connect to gateway at %s: %w", g.addr, ErrConnectionShutdown)
		}
		if !conn.WaitForStateChange(connectCtx, state) {
			_ = conn.Close()
			if provider != nil {
				_ = provider.Close()
			}
			return fmt.Errorf("failed to connect to gateway at %s: %w", g.addr, connectCtx.Err())
		}
	}

	g.mu.Lock()
	if g.conn != nil && g.connected && g.conn.GetState() == connectivity.Ready {
		g.mu.Unlock()
		_ = conn.Close()
		if provider != nil {
			_ = provider.Close()
		}
		return nil
	}
	g.conn = conn
	g.client = proto.NewAgentGatewayServiceClient(conn)
	g.connected = true
	g.reconnectDelay = defaultReconnectDelay // Reset backoff on successful connection
	g.securityProvider = provider
	g.mu.Unlock()

	g.logger.Info().Str("addr", g.addr).Msg("Connected to agent-gateway")

	return nil
}

// buildDialOptions constructs gRPC dial options based on security configuration.
func (g *GatewayClient) buildDialOptions(ctx context.Context) ([]grpc.DialOption, srgrpc.SecurityProvider, error) {
	opts := []grpc.DialOption{
		grpc.WithKeepaliveParams(keepalive.ClientParameters{
			Time:                defaultKeepaliveTime,
			Timeout:             defaultKeepaliveTTL,
			PermitWithoutStream: true,
		}),
		// Create client spans and propagate W3C trace context to the gateway.
		grpc.WithStatsHandler(otelgrpc.NewClientHandler()),
	}

	if g.security != nil && g.security.Mode != "" && g.security.Mode != models.SecurityModeNone {
		// Create security provider using the standard pattern
		provider, err := srgrpc.NewSecurityProvider(ctx, g.security, g.logger)
		if err != nil {
			return nil, nil, fmt.Errorf("failed to create security provider: %w", err)
		}

		// Get client credentials from the provider
		creds, err := provider.GetClientCredentials(ctx)
		if err != nil {
			_ = provider.Close()
			return nil, nil, fmt.Errorf("failed to get client credentials: %w", err)
		}

		opts = append(opts, creds)
		return opts, provider, nil
	} else {
		// Insecure connections require explicit opt-in via environment variable
		// to prevent accidental plaintext gRPC in production deployments
		if os.Getenv("SR_ALLOW_INSECURE") != "true" {
			return nil, nil, ErrSecurityRequired
		}

		g.logger.Warn().Msg("Using insecure connection to gateway (SR_ALLOW_INSECURE=true)")
		opts = append(opts, grpc.WithTransportCredentials(insecure.NewCredentials()))
	}

	return opts, nil, nil
}

// Disconnect closes the connection to the gateway.
func (g *GatewayClient) Disconnect() error {
	var (
		conn     *grpc.ClientConn
		provider srgrpc.SecurityProvider
		closeErr error
	)

	g.mu.Lock()
	conn = g.conn
	provider = g.securityProvider
	g.conn = nil
	g.client = nil
	g.securityProvider = nil
	g.connected = false
	g.mu.Unlock()

	if conn != nil {
		if err := conn.Close(); err != nil {
			g.logger.Warn().Err(err).Msg("Error closing gateway connection")
			closeErr = errors.Join(closeErr, err)
		}
	}

	if provider != nil {
		if err := provider.Close(); err != nil {
			g.logger.Warn().Err(err).Msg("Error closing security provider")
			closeErr = errors.Join(closeErr, err)
		}
	}

	g.logger.Info().Msg("Disconnected from agent-gateway")
	return closeErr
}

// IsConnected returns whether the client is currently connected.
func (g *GatewayClient) IsConnected() bool {
	g.mu.RLock()
	defer g.mu.RUnlock()
	if !g.connected || g.conn == nil {
		return false
	}
	switch g.conn.GetState() {
	case connectivity.Ready, connectivity.Idle:
		return true
	case connectivity.Connecting, connectivity.TransientFailure, connectivity.Shutdown:
		return false
	}
	return false
}

// PushStatus sends a batch of service statuses to the gateway.
func (g *GatewayClient) PushStatus(ctx context.Context, req *proto.GatewayStatusRequest) (*proto.GatewayStatusResponse, error) {
	g.mu.RLock()
	client := g.client
	connected := g.connected
	g.mu.RUnlock()

	if !connected || client == nil {
		return nil, ErrGatewayNotConnected
	}

	pushCtx, cancel := context.WithTimeout(ctx, defaultPushTimeout)
	defer cancel()

	resp, err := client.PushStatus(pushCtx, req)
	if err != nil {
		g.logger.Error().Err(err).Msg("Failed to push status to gateway")
		// Mark as disconnected on error to trigger reconnect
		g.markDisconnected()
		return nil, fmt.Errorf("failed to push status: %w", err)
	}

	return resp, nil
}

// StreamStatus streams service status chunks to the gateway.
func (g *GatewayClient) StreamStatus(ctx context.Context, chunks []*proto.GatewayStatusChunk) (*proto.GatewayStatusResponse, error) {
	g.mu.RLock()
	client := g.client
	connected := g.connected
	g.mu.RUnlock()

	if !connected || client == nil {
		return nil, ErrGatewayNotConnected
	}

	validChunks, err := validateStreamStatusChunks(chunks)
	if err != nil {
		return nil, err
	}

	// For streaming, a fixed short timeout can cancel long chunk sequences.
	// Prefer the caller context; higher-level code can set deadlines if desired.
	stream, err := client.StreamStatus(ctx)
	if err != nil {
		g.markDisconnected()
		return nil, fmt.Errorf("failed to create stream: %w", err)
	}

	for _, chunk := range validChunks {
		if err := ctx.Err(); err != nil {
			_ = stream.CloseSend()
			return nil, err
		}

		if err := stream.Send(chunk); err != nil {
			// Ensure stream is closed on send error to prevent resource leak
			_ = stream.CloseSend()
			g.markDisconnected()
			return nil, fmt.Errorf("failed to send chunk: %w", err)
		}
	}

	resp, err := stream.CloseAndRecv()
	if err != nil {
		g.markDisconnected()
		return nil, fmt.Errorf("failed to receive response: %w", err)
	}

	return resp, nil
}

func validateStreamStatusChunks(chunks []*proto.GatewayStatusChunk) ([]*proto.GatewayStatusChunk, error) {
	validChunks := make([]*proto.GatewayStatusChunk, 0, len(chunks))
	totalBytes := 0

	for idx, chunk := range chunks {
		if chunk == nil {
			continue
		}

		chunkBytes := goproto.Size(chunk)
		if chunkBytes > streamStatusChunkMax {
			return nil, fmt.Errorf("%w: chunk %d has %d bytes; max %d", ErrStreamStatusChunkTooLarge, idx, chunkBytes, streamStatusChunkMax)
		}

		totalBytes += chunkBytes
		if totalBytes > streamStatusWindowMax {
			return nil, fmt.Errorf("%w: stream has %d bytes; max %d", ErrStreamStatusBudgetExceeded, totalBytes, streamStatusWindowMax)
		}

		validChunks = append(validChunks, chunk)
	}

	if len(validChunks) == 0 {
		return nil, ErrNoChunksToSend
	}

	return validChunks, nil
}

// markDisconnected marks the client as disconnected and tears down the current connection.
func (g *GatewayClient) markDisconnected() {
	var (
		conn     *grpc.ClientConn
		provider srgrpc.SecurityProvider
	)

	g.mu.Lock()
	g.connected = false
	// Detach resources under lock
	conn = g.conn
	provider = g.securityProvider
	g.conn = nil
	g.client = nil
	g.securityProvider = nil
	g.mu.Unlock()

	// Close outside lock to avoid holding lock during potentially slow I/O
	if conn != nil {
		_ = conn.Close()
	}
	if provider != nil {
		_ = provider.Close()
	}
}

// ReconnectWithBackoff attempts to reconnect with exponential backoff.
func (g *GatewayClient) ReconnectWithBackoff(ctx context.Context) error {
	g.mu.Lock()
	delay := g.reconnectDelay
	g.logger.Info().Dur("delay", delay).Msg("Attempting to reconnect to gateway")
	g.mu.Unlock()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(delay):
	}

	// Another goroutine may have reconnected while we were sleeping.
	if g.IsConnected() {
		return nil
	}

	// Close existing connection if any
	_ = g.Disconnect()

	err := g.Connect(ctx)
	if err != nil {
		// Increase backoff for next attempt
		g.mu.Lock()
		g.reconnectDelay = min(g.reconnectDelay*2, maxReconnectDelay)
		g.mu.Unlock()
		return err
	}

	return nil
}

// GetReconnectDelay returns the current reconnect delay.
func (g *GatewayClient) GetReconnectDelay() time.Duration {
	g.mu.RLock()
	defer g.mu.RUnlock()
	return g.reconnectDelay
}

// Hello sends an enrollment request to the gateway.
// This should be called on agent startup to announce the agent and register with the gateway.
func (g *GatewayClient) Hello(ctx context.Context, req *proto.AgentHelloRequest) (*proto.AgentHelloResponse, error) {
	g.mu.RLock()
	client := g.client
	connected := g.connected
	g.mu.RUnlock()

	if !connected || client == nil {
		return nil, ErrGatewayNotConnected
	}

	helloCtx, cancel := context.WithTimeout(ctx, defaultConnectTimeout)
	defer cancel()

	resp, err := client.Hello(helloCtx, req)
	if err != nil {
		g.logger.Error().Err(err).Msg("Failed to send Hello to gateway")
		g.markDisconnected()
		return nil, fmt.Errorf("failed to send Hello: %w", err)
	}

	if !resp.Accepted {
		return nil, fmt.Errorf("%w: %s", ErrEnrollmentRejected, resp.Message)
	}

	g.logger.Info().
		Str("agent_id", resp.AgentId).
		Str("gateway_id", resp.GatewayId).
		Int32("heartbeat_interval_sec", resp.HeartbeatIntervalSec).
		Bool("config_outdated", resp.ConfigOutdated).
		Msg("Agent enrolled with gateway")

	g.mu.Lock()
	g.gatewayID = resp.GatewayId
	g.mu.Unlock()

	return resp, nil
}

// GetGatewayID returns the gateway ID assigned during enrollment.
func (g *GatewayClient) GetGatewayID() string {
	g.mu.RLock()
	defer g.mu.RUnlock()
	return g.gatewayID
}

// GetConfig fetches the agent's configuration from the gateway.
// Supports versioning - returns not_modified if config hasn't changed.
func (g *GatewayClient) GetConfig(ctx context.Context, req *proto.AgentConfigRequest) (*proto.AgentConfigResponse, error) {
	resp, err := g.getConfigStream(ctx, req)
	if err == nil {
		g.logConfigResponse(req, resp)
		return resp, nil
	}

	if errors.Is(err, ErrGatewayNotConnected) {
		return nil, err
	}

	if status.Code(err) != codes.Unimplemented {
		g.logger.Error().Err(err).Msg("Failed to stream config from gateway")
		return nil, fmt.Errorf("failed to stream config: %w", err)
	}

	g.logger.Debug().Msg("Gateway does not support streamed config; falling back to unary GetConfig")

	resp, err = g.getConfigUnary(ctx, req)
	if err != nil {
		return nil, err
	}

	g.logConfigResponse(req, resp)
	return resp, nil
}

func (g *GatewayClient) getConfigUnary(ctx context.Context, req *proto.AgentConfigRequest) (*proto.AgentConfigResponse, error) {
	g.mu.RLock()
	client := g.client
	connected := g.connected
	g.mu.RUnlock()

	if !connected || client == nil {
		return nil, ErrGatewayNotConnected
	}

	configCtx, cancel := context.WithTimeout(ctx, defaultConfigTimeout)
	defer cancel()

	resp, err := client.GetConfig(configCtx, req)
	if err != nil {
		g.logger.Error().Err(err).Msg("Failed to get config from gateway")
		g.markDisconnected()
		return nil, fmt.Errorf("failed to get config: %w", err)
	}

	return resp, nil
}

func (g *GatewayClient) getConfigStream(ctx context.Context, req *proto.AgentConfigRequest) (*proto.AgentConfigResponse, error) {
	g.mu.RLock()
	client := g.client
	connected := g.connected
	g.mu.RUnlock()

	if !connected || client == nil {
		return nil, ErrGatewayNotConnected
	}

	configCtx, cancel := context.WithTimeout(ctx, defaultConfigTimeout)
	defer cancel()

	stream, err := client.StreamConfig(configCtx, req)
	if err != nil {
		if status.Code(err) != codes.Unimplemented {
			g.markDisconnected()
		}

		return nil, err
	}

	chunks := make([]*proto.AgentConfigChunk, 0)

	for {
		chunk, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			if status.Code(err) != codes.Unimplemented {
				g.markDisconnected()
			}

			return nil, err
		}

		chunks = append(chunks, chunk)
	}

	return reassembleConfigChunks(chunks)
}

func (g *GatewayClient) logConfigResponse(req *proto.AgentConfigRequest, resp *proto.AgentConfigResponse) {
	switch {
	case resp.NotModified:
		g.logger.Debug().Str("version", resp.ConfigVersion).Msg("Agent config not modified")
	case req != nil && req.ConfigVersion != "" && resp.ConfigVersion == req.ConfigVersion:
		resp.NotModified = true
		g.logger.Debug().Str("version", resp.ConfigVersion).Msg("Agent config not modified")
	default:
		g.logger.Info().
			Str("version", resp.ConfigVersion).
			Int32("heartbeat_interval_sec", resp.HeartbeatIntervalSec).
			Int32("config_poll_interval_sec", resp.ConfigPollIntervalSec).
			Int("checks_count", len(resp.Checks)).
			Msg("Received new agent config from gateway")
	}
}

func reassembleConfigChunks(chunks []*proto.AgentConfigChunk) (*proto.AgentConfigResponse, error) {
	if len(chunks) == 0 {
		return nil, ErrNoConfigChunks
	}

	var (
		payload       []byte
		totalChunks   int32 = -1
		configVersion string
		configTs      int64
		notModified   bool
		payloadSha256 string
		sawFinal      bool
		payloadBytes  int
	)

	for expectedIndex, chunk := range chunks {
		if chunk == nil {
			return nil, fmt.Errorf("%w: nil chunk at index %d", ErrInvalidConfigStream, expectedIndex)
		}

		chunkBytes := goproto.Size(chunk)
		if chunkBytes > streamConfigChunkMax {
			return nil, fmt.Errorf("%w: chunk %d has %d bytes; max %d", ErrConfigChunkTooLarge, expectedIndex, chunkBytes, streamConfigChunkMax)
		}

		payloadBytes += len(chunk.Payload)
		if payloadBytes > streamConfigWindowMax {
			return nil, fmt.Errorf("%w: stream payload has %d bytes; max %d", ErrConfigStreamBudgetExceeded, payloadBytes, streamConfigWindowMax)
		}

		if chunk.ChunkIndex != int32(expectedIndex) {
			return nil, fmt.Errorf("%w: chunk index %d, want %d", ErrInvalidConfigStream, chunk.ChunkIndex, expectedIndex)
		}
		if chunk.TotalChunks <= 0 {
			return nil, fmt.Errorf("%w: total_chunks must be positive", ErrInvalidConfigStream)
		}

		if expectedIndex == 0 {
			totalChunks = chunk.TotalChunks
			configVersion = chunk.ConfigVersion
			configTs = chunk.ConfigTimestamp
			notModified = chunk.NotModified
			payloadSha256 = chunk.PayloadSha256
		} else {
			if chunk.TotalChunks != totalChunks {
				return nil, fmt.Errorf("%w: total_chunks changed from %d to %d", ErrInvalidConfigStream, totalChunks, chunk.TotalChunks)
			}
			if chunk.ConfigVersion != configVersion || chunk.ConfigTimestamp != configTs || chunk.NotModified != notModified || chunk.PayloadSha256 != payloadSha256 {
				return nil, fmt.Errorf("%w: chunk metadata changed at index %d", ErrInvalidConfigStream, expectedIndex)
			}
		}

		if chunk.IsFinal {
			if sawFinal {
				return nil, fmt.Errorf("%w: multiple final chunks", ErrInvalidConfigStream)
			}
			if chunk.ChunkIndex != chunk.TotalChunks-1 {
				return nil, fmt.Errorf("%w: final chunk index %d does not match total_chunks %d", ErrInvalidConfigStream, chunk.ChunkIndex, chunk.TotalChunks)
			}

			sawFinal = true
		} else if chunk.ChunkIndex == chunk.TotalChunks-1 {
			return nil, fmt.Errorf("%w: last chunk missing final marker", ErrInvalidConfigStream)
		}

		payload = append(payload, chunk.Payload...)
	}

	if int32(len(chunks)) != totalChunks {
		return nil, fmt.Errorf("%w: received %d chunks, want %d", ErrInvalidConfigStream, len(chunks), totalChunks)
	}
	if !sawFinal {
		return nil, fmt.Errorf("%w: missing final chunk", ErrInvalidConfigStream)
	}

	if payloadSha256 == "" {
		return nil, fmt.Errorf("%w: missing payload checksum", ErrInvalidConfigStream)
	}

	sum := sha256.Sum256(payload)
	if hex.EncodeToString(sum[:]) != payloadSha256 {
		return nil, fmt.Errorf("%w: payload checksum mismatch", ErrInvalidConfigStream)
	}

	resp := &proto.AgentConfigResponse{}
	if err := goproto.Unmarshal(payload, resp); err != nil {
		return nil, fmt.Errorf("%w: decode config response: %w", ErrInvalidConfigStream, err)
	}
	if resp.ConfigVersion != configVersion || resp.ConfigTimestamp != configTs || resp.NotModified != notModified {
		return nil, fmt.Errorf("%w: decoded response metadata does not match stream metadata", ErrInvalidConfigStream)
	}

	return resp, nil
}

// ControlStream opens the bidirectional control stream for commands and push-config.
func (g *GatewayClient) ControlStream(ctx context.Context) (grpc.BidiStreamingClient[proto.ControlStreamRequest, proto.ControlStreamResponse], error) {
	g.mu.RLock()
	client := g.client
	connected := g.connected
	g.mu.RUnlock()

	if !connected || client == nil {
		return nil, ErrGatewayNotConnected
	}

	stream, err := client.ControlStream(ctx)
	if err != nil {
		g.logger.Error().Err(err).Msg("Failed to open control stream to gateway")
		g.markDisconnected()
		return nil, fmt.Errorf("failed to open control stream: %w", err)
	}

	return stream, nil
}

// ResolveCredentialGrant resolves a scoped credential broker grant through the agent-gateway.
func (g *GatewayClient) ResolveCredentialGrant(
	ctx context.Context,
	req *proto.CredentialBrokerResolveRequest,
) (*proto.CredentialBrokerResolveResponse, error) {
	g.mu.RLock()
	client := g.client
	connected := g.connected
	g.mu.RUnlock()

	if !connected || client == nil {
		return nil, ErrGatewayNotConnected
	}

	resp, err := client.ResolveCredentialGrant(ctx, req)
	if err != nil {
		return nil, fmt.Errorf("resolve credential grant: %w", err)
	}

	return resp, nil
}

// ResolveAutomationLaunchEnvelope resolves a single-use callback bearer through
// the agent-gateway's distinct mTLS-authenticated launch-envelope RPC.
func (g *GatewayClient) ResolveAutomationLaunchEnvelope(
	ctx context.Context,
	req *proto.AutomationLaunchEnvelopeResolveRequest,
) (*proto.AutomationLaunchEnvelopeResolveResponse, error) {
	g.mu.RLock()
	client := g.client
	connected := g.connected
	g.mu.RUnlock()

	if !connected || client == nil {
		return nil, ErrGatewayNotConnected
	}

	resp, err := client.ResolveAutomationLaunchEnvelope(ctx, req)
	if err != nil {
		return nil, fmt.Errorf("resolve automation launch envelope: %w", err)
	}

	return resp, nil
}

// OpenRelaySession reserves an authenticated camera media ingress session.
func (g *GatewayClient) OpenRelaySession(ctx context.Context, req *proto.OpenRelaySessionRequest) (*proto.OpenRelaySessionResponse, error) {
	g.mu.RLock()
	conn := g.conn
	connected := g.connected
	g.mu.RUnlock()

	if !connected || conn == nil {
		return nil, ErrGatewayNotConnected
	}

	client := proto.NewCameraMediaServiceClient(conn)
	resp, err := client.OpenRelaySession(ctx, req)
	if err != nil {
		g.logger.Error().Err(err).Msg("Failed to open camera relay session at gateway")
		g.markDisconnected()
		return nil, fmt.Errorf("failed to open relay session: %w", err)
	}

	return resp, nil
}

// UploadMedia streams camera media chunks to the gateway over the dedicated media service.
func (g *GatewayClient) UploadMedia(ctx context.Context, chunks []*proto.MediaChunk) (*proto.UploadMediaResponse, error) {
	g.mu.RLock()
	conn := g.conn
	connected := g.connected
	g.mu.RUnlock()

	if !connected || conn == nil {
		return nil, ErrGatewayNotConnected
	}

	client := proto.NewCameraMediaServiceClient(conn)
	stream, err := client.UploadMedia(ctx)
	if err != nil {
		g.logger.Error().Err(err).Msg("Failed to create camera media upload stream")
		g.markDisconnected()
		return nil, fmt.Errorf("failed to create media upload stream: %w", err)
	}

	sentAny := false
	for _, chunk := range chunks {
		if chunk == nil {
			continue
		}
		sentAny = true
		if err := stream.Send(chunk); err != nil {
			_ = stream.CloseSend()
			g.markDisconnected()
			return nil, fmt.Errorf("failed to send media chunk: %w", err)
		}
	}

	if !sentAny {
		_ = stream.CloseSend()
		return nil, ErrNoChunksToSend
	}

	resp, err := stream.CloseAndRecv()
	if err != nil {
		g.markDisconnected()
		return nil, fmt.Errorf("failed to receive media upload response: %w", err)
	}

	return resp, nil
}

// HeartbeatRelaySession renews the lease for an active camera relay session.
func (g *GatewayClient) HeartbeatRelaySession(ctx context.Context, req *proto.RelayHeartbeat) (*proto.RelayHeartbeatAck, error) {
	g.mu.RLock()
	conn := g.conn
	connected := g.connected
	g.mu.RUnlock()

	if !connected || conn == nil {
		return nil, ErrGatewayNotConnected
	}

	client := proto.NewCameraMediaServiceClient(conn)
	resp, err := client.Heartbeat(ctx, req)
	if err != nil {
		g.logger.Error().Err(err).Msg("Failed to heartbeat camera relay session")
		g.markDisconnected()
		return nil, fmt.Errorf("failed to heartbeat relay session: %w", err)
	}

	return resp, nil
}

// CloseRelaySession closes an active camera relay session at the gateway.
func (g *GatewayClient) CloseRelaySession(ctx context.Context, req *proto.CloseRelaySessionRequest) (*proto.CloseRelaySessionResponse, error) {
	g.mu.RLock()
	conn := g.conn
	connected := g.connected
	g.mu.RUnlock()

	if !connected || conn == nil {
		return nil, ErrGatewayNotConnected
	}

	client := proto.NewCameraMediaServiceClient(conn)
	resp, err := client.CloseRelaySession(ctx, req)
	if err != nil {
		g.logger.Error().Err(err).Msg("Failed to close camera relay session")
		g.markDisconnected()
		return nil, fmt.Errorf("failed to close relay session: %w", err)
	}

	return resp, nil
}

// OpenDesktopMediaSession reserves an authenticated desktop media ingress session.
func (g *GatewayClient) OpenDesktopMediaSession(
	ctx context.Context,
	req *proto.OpenDesktopMediaSessionRequest,
) (*proto.OpenDesktopMediaSessionResponse, error) {
	g.mu.RLock()
	conn := g.conn
	connected := g.connected
	g.mu.RUnlock()

	if !connected || conn == nil {
		return nil, ErrGatewayNotConnected
	}

	client := proto.NewDesktopMediaServiceClient(conn)
	resp, err := client.OpenDesktopMediaSession(ctx, req)
	if err != nil {
		g.logger.Error().Err(err).Msg("Failed to open desktop media session at gateway")
		g.markDisconnected()
		return nil, fmt.Errorf("failed to open desktop media session: %w", err)
	}

	return resp, nil
}

// StreamDesktopMedia opens the bidirectional desktop media stream for screen frames and flow-control acks.
func (g *GatewayClient) StreamDesktopMedia(
	ctx context.Context,
) (grpc.BidiStreamingClient[proto.DesktopMediaClientMessage, proto.DesktopMediaServerMessage], error) {
	g.mu.RLock()
	conn := g.conn
	connected := g.connected
	g.mu.RUnlock()

	if !connected || conn == nil {
		return nil, ErrGatewayNotConnected
	}

	client := proto.NewDesktopMediaServiceClient(conn)
	stream, err := client.StreamDesktopMedia(ctx)
	if err != nil {
		g.logger.Error().Err(err).Msg("Failed to create desktop media stream")
		g.markDisconnected()
		return nil, fmt.Errorf("failed to create desktop media stream: %w", err)
	}

	return stream, nil
}

// HeartbeatDesktopMediaSession renews the lease for an active desktop media session.
func (g *GatewayClient) HeartbeatDesktopMediaSession(
	ctx context.Context,
	req *proto.DesktopMediaHeartbeat,
) (*proto.DesktopMediaHeartbeatAck, error) {
	g.mu.RLock()
	conn := g.conn
	connected := g.connected
	g.mu.RUnlock()

	if !connected || conn == nil {
		return nil, ErrGatewayNotConnected
	}

	client := proto.NewDesktopMediaServiceClient(conn)
	resp, err := client.Heartbeat(ctx, req)
	if err != nil {
		g.logger.Error().Err(err).Msg("Failed to heartbeat desktop media session")
		g.markDisconnected()
		return nil, fmt.Errorf("failed to heartbeat desktop media session: %w", err)
	}

	return resp, nil
}

// CloseDesktopMediaSession closes an active desktop media session at the gateway.
func (g *GatewayClient) CloseDesktopMediaSession(
	ctx context.Context,
	req *proto.CloseDesktopMediaSessionRequest,
) (*proto.CloseDesktopMediaSessionResponse, error) {
	g.mu.RLock()
	conn := g.conn
	connected := g.connected
	g.mu.RUnlock()

	if !connected || conn == nil {
		return nil, ErrGatewayNotConnected
	}

	client := proto.NewDesktopMediaServiceClient(conn)
	resp, err := client.CloseDesktopMediaSession(ctx, req)
	if err != nil {
		g.logger.Error().Err(err).Msg("Failed to close desktop media session")
		g.markDisconnected()
		return nil, fmt.Errorf("failed to close desktop media session: %w", err)
	}

	return resp, nil
}
