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

// Package agent pkg/agent/gateway_client.go
package agent

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	srgrpc "github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
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
)

const (
	defaultPushInterval    = 30 * time.Second
	defaultConnectTimeout  = 10 * time.Second
	defaultReconnectDelay  = 5 * time.Second
	maxReconnectDelay      = 60 * time.Second
	defaultPushTimeout     = 30 * time.Second
)

// GatewayClient manages the connection to the agent-gateway and pushes status updates.
type GatewayClient struct {
	mu               sync.RWMutex
	conn             *grpc.ClientConn
	client           proto.AgentGatewayServiceClient
	addr             string
	security         *models.SecurityConfig
	securityProvider srgrpc.SecurityProvider
	connected        bool
	reconnectDelay   time.Duration
	logger           logger.Logger
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
	g.mu.Lock()
	defer g.mu.Unlock()

	if g.addr == "" {
		return ErrGatewayAddrRequired
	}

	if g.connected && g.conn != nil {
		return nil // Already connected
	}

	g.logger.Info().Str("addr", g.addr).Msg("Connecting to agent-gateway")

	opts, err := g.buildDialOptions(ctx)
	if err != nil {
		return fmt.Errorf("failed to build dial options: %w", err)
	}

	connectCtx, cancel := context.WithTimeout(ctx, defaultConnectTimeout)
	defer cancel()

	// TODO: Migrate to grpc.NewClient when ready - requires testing lazy connection semantics
	// Add WithBlock to ensure connection is established before returning
	//nolint:staticcheck // SA1019: grpc.DialContext and WithBlock are deprecated but supported through 1.x
	conn, err := grpc.DialContext(connectCtx, g.addr, append(opts, grpc.WithBlock())...)
	if err != nil {
		return fmt.Errorf("failed to connect to gateway at %s: %w", g.addr, err)
	}

	g.conn = conn
	g.client = proto.NewAgentGatewayServiceClient(conn)
	g.connected = true
	g.reconnectDelay = defaultReconnectDelay // Reset backoff on successful connection

	g.logger.Info().Str("addr", g.addr).Msg("Connected to agent-gateway")

	return nil
}

// buildDialOptions constructs gRPC dial options based on security configuration.
func (g *GatewayClient) buildDialOptions(ctx context.Context) ([]grpc.DialOption, error) {
	var opts []grpc.DialOption

	if g.security != nil && g.security.Mode != "" && g.security.Mode != models.SecurityModeNone {
		// Create security provider using the standard pattern
		provider, err := srgrpc.NewSecurityProvider(ctx, g.security, g.logger)
		if err != nil {
			return nil, fmt.Errorf("failed to create security provider: %w", err)
		}

		// Get client credentials from the provider
		creds, err := provider.GetClientCredentials(ctx)
		if err != nil {
			_ = provider.Close()
			return nil, fmt.Errorf("failed to get client credentials: %w", err)
		}

		g.securityProvider = provider
		opts = append(opts, creds)
	} else {
		// Insecure connections require explicit opt-in via environment variable
		// to prevent accidental plaintext gRPC in production deployments
		if os.Getenv("SR_ALLOW_INSECURE") != "true" {
			return nil, ErrSecurityRequired
		}

		g.logger.Warn().Msg("Using insecure connection to gateway (SR_ALLOW_INSECURE=true)")
		opts = append(opts, grpc.WithTransportCredentials(insecure.NewCredentials()))
	}

	return opts, nil
}

// Disconnect closes the connection to the gateway.
func (g *GatewayClient) Disconnect() error {
	g.mu.Lock()
	defer g.mu.Unlock()

	if g.conn != nil {
		if err := g.conn.Close(); err != nil {
			g.logger.Warn().Err(err).Msg("Error closing gateway connection")
		}
		g.conn = nil
		g.client = nil
	}

	if g.securityProvider != nil {
		if err := g.securityProvider.Close(); err != nil {
			g.logger.Warn().Err(err).Msg("Error closing security provider")
		}
		g.securityProvider = nil
	}

	g.connected = false

	g.logger.Info().Msg("Disconnected from agent-gateway")

	return nil
}

// IsConnected returns whether the client is currently connected.
func (g *GatewayClient) IsConnected() bool {
	g.mu.RLock()
	defer g.mu.RUnlock()
	return g.connected
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

	// Add timeout to prevent hanging if gateway is unresponsive
	streamCtx, cancel := context.WithTimeout(ctx, defaultPushTimeout)
	defer cancel()

	stream, err := client.StreamStatus(streamCtx)
	if err != nil {
		g.markDisconnected()
		return nil, fmt.Errorf("failed to create stream: %w", err)
	}

	// Guard against nil/empty chunks to prevent unnecessary stream operations
	sentAny := false
	for _, chunk := range chunks {
		if chunk == nil {
			continue
		}
		sentAny = true
		if err := stream.Send(chunk); err != nil {
			// Ensure stream is closed on send error to prevent resource leak
			_ = stream.CloseSend()
			g.markDisconnected()
			return nil, fmt.Errorf("failed to send chunk: %w", err)
		}
	}

	if !sentAny {
		_ = stream.CloseSend()
		return nil, ErrNoChunksToSend
	}

	resp, err := stream.CloseAndRecv()
	if err != nil {
		g.markDisconnected()
		return nil, fmt.Errorf("failed to receive response: %w", err)
	}

	return resp, nil
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
		Str("tenant_id", resp.TenantId).
		Str("tenant_slug", resp.TenantSlug).
		Int32("heartbeat_interval_sec", resp.HeartbeatIntervalSec).
		Bool("config_outdated", resp.ConfigOutdated).
		Msg("Agent enrolled with gateway")

	return resp, nil
}

// GetConfig fetches the agent's configuration from the gateway.
// Supports versioning - returns not_modified if config hasn't changed.
func (g *GatewayClient) GetConfig(ctx context.Context, req *proto.AgentConfigRequest) (*proto.AgentConfigResponse, error) {
	g.mu.RLock()
	client := g.client
	connected := g.connected
	g.mu.RUnlock()

	if !connected || client == nil {
		return nil, ErrGatewayNotConnected
	}

	configCtx, cancel := context.WithTimeout(ctx, defaultConnectTimeout)
	defer cancel()

	resp, err := client.GetConfig(configCtx, req)
	if err != nil {
		g.logger.Error().Err(err).Msg("Failed to get config from gateway")
		g.markDisconnected()
		return nil, fmt.Errorf("failed to get config: %w", err)
	}

	if resp.NotModified {
		g.logger.Debug().Str("version", resp.ConfigVersion).Msg("Agent config not modified")
	} else {
		g.logger.Info().
			Str("version", resp.ConfigVersion).
			Int32("heartbeat_interval_sec", resp.HeartbeatIntervalSec).
			Int32("config_poll_interval_sec", resp.ConfigPollIntervalSec).
			Int("checks_count", len(resp.Checks)).
			Msg("Received new agent config from gateway")
	}

	return resp, nil
}
