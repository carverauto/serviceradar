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

	"google.golang.org/grpc"
	"google.golang.org/grpc/connectivity"
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
	gatewayID        string
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
	var opts []grpc.DialOption

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

	// For streaming, a fixed short timeout can cancel long chunk sequences.
	// Prefer the caller context; higher-level code can set deadlines if desired.
	stream, err := client.StreamStatus(ctx)
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

const fileChunkSize = 64 * 1024 // 64KB chunk size for file transfers

// UploadFile streams a local file to the gateway for storage.
// Used after a TFTP receive to upload the captured file to core storage.
func (g *GatewayClient) UploadFile(ctx context.Context, sessionID, filename, filePath string) (*proto.FileUploadResponse, error) {
	g.mu.RLock()
	client := g.client
	connected := g.connected
	g.mu.RUnlock()

	if !connected || client == nil {
		return nil, ErrGatewayNotConnected
	}

	file, err := os.Open(filePath)
	if err != nil {
		return nil, fmt.Errorf("open file for upload: %w", err)
	}
	defer file.Close()

	fi, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("stat file for upload: %w", err)
	}

	totalSize := fi.Size()

	stream, err := client.UploadFile(ctx)
	if err != nil {
		g.markDisconnected()
		return nil, fmt.Errorf("failed to open upload stream: %w", err)
	}

	hasher := sha256.New()
	buf := make([]byte, fileChunkSize)
	var offset int64

	firstChunk := true

	for {
		n, readErr := file.Read(buf)
		if n > 0 {
			data := buf[:n]
			_, _ = hasher.Write(data)

			isLast := readErr == io.EOF || (offset+int64(n)) >= totalSize
			contentHash := ""

			if isLast {
				contentHash = hex.EncodeToString(hasher.Sum(nil))
			}

			chunk := &proto.FileChunk{
				SessionId:   sessionID,
				Data:        data,
				Offset:      offset,
				IsLast:      isLast,
				ContentHash: contentHash,
			}

			if firstChunk {
				chunk.Filename = filename
				chunk.TotalSize = totalSize
				firstChunk = false
			}

			if sendErr := stream.Send(chunk); sendErr != nil {
				return nil, fmt.Errorf("failed to send file chunk: %w", sendErr)
			}

			offset += int64(n)

			if isLast {
				break
			}
		}

		if readErr != nil {
			if readErr == io.EOF {
				break
			}

			return nil, fmt.Errorf("read file for upload: %w", readErr)
		}
	}

	resp, err := stream.CloseAndRecv()
	if err != nil {
		return nil, fmt.Errorf("failed to receive upload response: %w", err)
	}

	g.logger.Info().
		Str("session_id", sessionID).
		Str("filename", filename).
		Int64("bytes", offset).
		Bool("success", resp.Success).
		Msg("File upload completed")

	return resp, nil
}

// DownloadFile downloads a file from the gateway to a local destination path.
// Used before a TFTP serve to stage a software image from core storage.
func (g *GatewayClient) DownloadFile(ctx context.Context, req *proto.FileDownloadRequest, destPath string) error {
	g.mu.RLock()
	client := g.client
	connected := g.connected
	g.mu.RUnlock()

	if !connected || client == nil {
		return ErrGatewayNotConnected
	}

	stream, err := client.DownloadFile(ctx, req)
	if err != nil {
		g.markDisconnected()
		return fmt.Errorf("failed to open download stream: %w", err)
	}

	file, err := os.OpenFile(destPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o640)
	if err != nil {
		return fmt.Errorf("create destination file: %w", err)
	}
	defer file.Close()

	hasher := sha256.New()
	var totalBytes int64
	var serverHash string

	for {
		chunk, recvErr := stream.Recv()
		if recvErr != nil {
			if recvErr == io.EOF {
				break
			}

			return fmt.Errorf("receive download chunk: %w", recvErr)
		}

		if len(chunk.Data) > 0 {
			if _, writeErr := file.Write(chunk.Data); writeErr != nil {
				return fmt.Errorf("write download chunk: %w", writeErr)
			}

			_, _ = hasher.Write(chunk.Data)
			totalBytes += int64(len(chunk.Data))
		}

		if chunk.IsLast {
			serverHash = chunk.ContentHash

			break
		}
	}

	// Verify hash if server provided one
	if serverHash != "" {
		computed := hex.EncodeToString(hasher.Sum(nil))
		if computed != serverHash {
			// Remove the corrupt file
			_ = os.Remove(destPath)

			return fmt.Errorf("download hash mismatch: expected %s, got %s", serverHash, computed)
		}
	}

	// Also verify against expected hash from request if provided
	if req.ExpectedHash != "" {
		computed := hex.EncodeToString(hasher.Sum(nil))
		if computed != req.ExpectedHash {
			_ = os.Remove(destPath)

			return fmt.Errorf("download hash mismatch with expected: expected %s, got %s", req.ExpectedHash, computed)
		}
	}

	g.logger.Info().
		Str("session_id", req.SessionId).
		Str("dest_path", destPath).
		Int64("bytes", totalBytes).
		Msg("File download completed")

	return nil
}
