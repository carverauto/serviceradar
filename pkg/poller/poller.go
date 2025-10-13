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

package poller

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const (
	grpcRetries      = 3
	defaultTimeout   = 30 * time.Second
	stopTimeout      = 10 * time.Second
	serviceTypeSweep = "sweep"
	serviceTypeSync  = "sync"
	checkTypeGRPC    = "grpc"
)

var (
	errStreamStatusNotReceived = fmt.Errorf("core indicated streaming status report was not received")
)

// safeIntToInt32 safely converts an int to int32, capping at int32 max value
func safeIntToInt32(val int) int32 {
	if val > math.MaxInt32 {
		return math.MaxInt32
	}

	if val < math.MinInt32 {
		return math.MinInt32
	}

	return int32(val)
}

// formatBytes converts bytes to human readable format
func formatBytes(bytes int) string {
	const unit = 1024

	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}

	div, exp := int64(unit), 0

	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}

	return fmt.Sprintf("%.1f %ciB", float64(bytes)/float64(div), "KMGTPE"[exp])
}

// New creates a new poller instance.
func New(ctx context.Context, config *Config, clock Clock, log logger.Logger) (*Poller, error) {
	if clock == nil {
		clock = realClock{}
	}

	p := &Poller{
		config:   *config,
		agents:   make(map[string]*AgentPoller),
		done:     make(chan struct{}),
		clock:    clock,
		logger:   log,
		reloadCh: make(chan time.Duration, 1),
	}

	if p.config.KVDomain != "" {
		p.logger.Info().Str("kv_domain", p.config.KVDomain).Msg("Poller configured KV JetStream domain")
	}

	if p.config.CoreAddress != "" && p.PollFunc == nil {
		if err := p.connectToCore(ctx); err != nil {
			return nil, fmt.Errorf("failed to connect to core service: %w", err)
		}
	}

	if p.PollFunc == nil {
		if err := p.initializeAgentPollers(ctx); err != nil {
			if p.grpcClient != nil {
				_ = p.grpcClient.Close()
			}

			return nil, fmt.Errorf("failed to initialize agent pollers: %w", err)
		}
	}

	return p, nil
}

// Start implements the lifecycle.Service interface.
func (p *Poller) Start(ctx context.Context) error {
	interval := time.Duration(p.config.PollInterval)
	p.ticker = p.clock.Ticker(interval)

	defer func() {
		if p.ticker != nil {
			p.ticker.Stop()
		}
	}()

	p.logger.Info().Dur("interval", interval).Msg("Starting poller")

	p.startWg.Add(1)
	defer p.startWg.Done()

	p.wg.Add(1)
	defer p.wg.Done()

	if err := p.poll(ctx); err != nil {
		p.logger.Error().Err(err).Msg("Error during initial poll")
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-p.done:
			return nil
		case <-p.ticker.Chan():
			p.wg.Add(1)

			go func() {
				defer p.wg.Done()

				if err := p.poll(ctx); err != nil {
					p.logger.Error().Err(err).Msg("Error during poll")
				}
			}()
		case newInterval := <-p.reloadCh:
			// Hot-reload: update ticker interval
			if p.ticker != nil {
				p.ticker.Stop()
			}
			p.ticker = p.clock.Ticker(newInterval)
			p.logger.Info().Dur("interval", newInterval).Msg("Poll interval hot-reloaded")
		}
	}
}

// Stop implements the lifecycle.Service interface.
func (p *Poller) Stop(ctx context.Context) error {
	_, cancel := context.WithTimeout(ctx, stopTimeout)
	defer cancel()

	p.closeOnce.Do(func() {
		close(p.done)
	})

	p.startWg.Wait()
	p.wg.Wait()

	p.mu.Lock()
	defer p.mu.Unlock()

	if p.coreClient != nil {
		if err := p.grpcClient.Close(); err != nil {
			p.logger.Error().Err(err).Msg("Error closing core client")
		}
	}

	for name, agentPoller := range p.agents {
		if agentPoller.clientConn != nil {
			if err := agentPoller.clientConn.Close(); err != nil {
				p.logger.Error().Err(err).Str("agent", name).Msg("Error closing agent connection")
			}
		}
	}

	p.agents = make(map[string]*AgentPoller)
	p.coreClient = nil

	return nil
}

// Close handles cleanup of resources.
func (p *Poller) Close() error {
	var errs []error

	p.closeOnce.Do(func() { close(p.done) })
	p.mu.Lock()

	defer p.mu.Unlock()

	if p.grpcClient != nil {
		if err := p.grpcClient.Close(); err != nil {
			errs = append(errs, fmt.Errorf("error closing core client: %w", err))
		}
	}

	for name, agentPoller := range p.agents {
		if agentPoller.clientConn != nil {
			if err := agentPoller.clientConn.Close(); err != nil {
				errs = append(errs, fmt.Errorf("%w: %s (%w)", errClosing, name, err))
			}
		}
	}

	if len(errs) > 0 {
		return fmt.Errorf("%w: %v", errClosing, errs)
	}

	return nil
}

func (p *Poller) connectToCore(ctx context.Context) error {
	clientCfg := grpc.ClientConfig{
		Address:    p.config.CoreAddress,
		MaxRetries: grpcRetries,
		Logger:     p.logger,
	}

	if p.config.Security != nil {
		provider, err := grpc.NewSecurityProvider(ctx, p.config.Security, p.logger)
		if err != nil {
			return fmt.Errorf("failed to create security provider: %w", err)
		}

		clientCfg.SecurityProvider = provider
	}

	p.logger.Info().Str("address", p.config.CoreAddress).Msg("Connecting to core service")

	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		return fmt.Errorf("failed to create core client: %w", err)
	}

	p.grpcClient = client
	p.coreClient = proto.NewPollerServiceClient(client.GetConnection())

	return nil
}

func (p *Poller) initializeAgentPollers(ctx context.Context) error {
	for agentName := range p.config.Agents {
		agentConfig := p.config.Agents[agentName]

		clientCfg := grpc.ClientConfig{
			Address:    agentConfig.Address,
			MaxRetries: grpcRetries,
			Logger:     p.logger,
		}

		if agentConfig.Security != nil {
			provider, err := grpc.NewSecurityProvider(ctx, agentConfig.Security, p.logger)
			if err != nil {
				return fmt.Errorf("failed to create security provider for agent %s: %w", agentName, err)
			}

			clientCfg.SecurityProvider = provider
		}

		p.logger.Info().Str("agent", agentName).Str("address", agentConfig.Address).
			Msg("Connecting to agent and creating poller")

		client, err := grpc.NewClient(ctx, clientCfg)
		if err != nil {
			return fmt.Errorf("failed to connect to agent %s: %w", agentName, err)
		}

		agentServiceClient := proto.NewAgentServiceClient(client.GetConnection())

		agentPoller := newAgentPoller(agentName, &agentConfig, agentServiceClient, p)
		agentPoller.clientConn = client

		p.agents[agentName] = agentPoller
	}

	return nil
}

func (p *Poller) poll(ctx context.Context) error {
	if p.PollFunc != nil {
		return p.PollFunc(ctx)
	}

	p.logger.Info().Msg("Starting polling cycle")

	var wg sync.WaitGroup

	statusChan := make(chan *proto.ServiceStatus, 100)

	for agentName := range p.config.Agents {
		agentPoller, exists := p.agents[agentName]
		if !exists {
			continue
		}

		wg.Add(1)

		go func(name string, ap *AgentPoller) {
			defer wg.Done()

			if ap.clientConn != nil {
				healthy, err := ap.clientConn.CheckHealth(ctx, "AgentService")
				if err != nil || !healthy {
					p.logger.Warn().Str("agent", name).Err(err).Bool("healthy", healthy).Msg("Agent health check failed")
				}
			}

			statuses := ap.ExecuteChecks(ctx)

			for _, s := range statuses {
				statusChan <- s
			}

			resultsStatuses := ap.ExecuteResults(ctx)

			for _, s := range resultsStatuses {
				statusChan <- s
			}
		}(agentName, agentPoller)
	}

	go func() {
		wg.Wait()
		close(statusChan)
	}()

	allStatuses := make([]*proto.ServiceStatus, 0, 100)

	for serviceStatus := range statusChan {
		allStatuses = append(allStatuses, serviceStatus)
	}

	p.logger.Info().Int("total_statuses", len(allStatuses)).Msg("Polling cycle completed")

	return p.reportToCore(ctx, allStatuses)
}

func (p *Poller) reportToCore(ctx context.Context, statuses []*proto.ServiceStatus) error {
	p.logger.Info().
		Int("statusCount", len(statuses)).
		Str("pollerID", p.config.PollerID).
		Time("timestamp", time.Now()).
		Msg("Reporting statuses")

	for i, serviceStatus := range statuses {
		serviceStatus.PollerId = p.config.PollerID
		serviceStatus.Partition = p.config.Partition

		agentID := serviceStatus.AgentId
		if agentID == "" {
			p.logger.Warn().Str("serviceName", serviceStatus.ServiceName).Msg("AgentID empty in response, using configured agent name as fallback")
		}

		if serviceStatus.ServiceType != "sync" {
			enhancedMessage, err := p.enhanceServicePayload(
				string(serviceStatus.Message),
				agentID,
				serviceStatus.Partition,
				serviceStatus.ServiceType,
				serviceStatus.ServiceName,
			)
			if err != nil {
				p.logger.Warn().Err(err).Str("serviceName", serviceStatus.ServiceName).Msg("Failed to enhance payload")
			} else {
				serviceStatus.Message = []byte(enhancedMessage)
			}
		}

		p.logger.Debug().
			Str("partition", serviceStatus.Partition).
			Str("pollerID", serviceStatus.PollerId).
			Str("serviceName", serviceStatus.ServiceName).
			Str("agentID", serviceStatus.AgentId).
			Msg("Service serviceStatus details")

		if serviceStatus.AgentId == "" {
			p.logger.Warn().Int("index", i).Str("serviceName", serviceStatus.ServiceName).Msg("ServiceStatus has empty AgentID")
		}
	}

	// Calculate total data size to determine if we should use streaming
	// Default gRPC max message size is 4MB, so we'll use streaming if we're close to that
	const maxSafeMessageSize = 1 * 1024 * 1024 // 1MB - use streaming more aggressively

	const streamingServiceCountThreshold = 5 // Lower threshold to use streaming for fewer services

	totalDataSize := 0

	for _, status := range statuses {
		messageSize := 0

		if status.Message != nil {
			messageSize = len(status.Message)
			totalDataSize += messageSize
		}

		// Add rough estimate for other fields (service name, type, etc.)
		totalDataSize += 200 // Approximate overhead per service

		// Log large messages for debugging
		if messageSize > 1024*1024 { // Log if message > 1MB
			p.logger.Info().
				Str("service_name", status.ServiceName).
				Str("service_type", status.ServiceType).
				Int("message_size_bytes", messageSize).
				Str("message_size_human", formatBytes(messageSize)).
				Msg("Large message detected in service status")
		}
	}

	useStreaming := totalDataSize > maxSafeMessageSize || len(statuses) > streamingServiceCountThreshold

	sendReport := func() error {
		if useStreaming {
			p.logger.Info().
				Int("service_count", len(statuses)).
				Int("total_data_size_bytes", totalDataSize).
				Int("max_safe_size_bytes", maxSafeMessageSize).
				Msg("Using streaming to report large dataset to core")

			return p.reportToCoreStreaming(ctx, statuses)
		}

		_, err := p.coreClient.ReportStatus(ctx, &proto.PollerStatusRequest{
			Services:  statuses,
			PollerId:  p.config.PollerID,
			Timestamp: time.Now().Unix(),
			Partition: p.config.Partition,
			SourceIp:  p.config.SourceIP,
		})
		if err != nil {
			return fmt.Errorf("failed to report serviceStatus to core: %w", err)
		}

		return nil
	}

	if err := sendReport(); err != nil {
		if !p.shouldReconnect(err) {
			return err
		}

		p.logger.Warn().Err(err).Msg("Reporting to core failed, attempting reconnect")

		if reconnectErr := p.reconnectCore(ctx); reconnectErr != nil {
			return fmt.Errorf("core report failed (%v) and reconnect attempt failed: %w", err, reconnectErr)
		}

		p.logger.Info().Msg("Successfully reconnected to core, retrying status report")

		if retryErr := sendReport(); retryErr != nil {
			return retryErr
		}
	}

	return nil
}

func (p *Poller) reconnectCore(ctx context.Context) error {
	reconnectCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	p.mu.Lock()
	defer p.mu.Unlock()

	if p.grpcClient != nil {
		if err := p.grpcClient.Close(); err != nil {
			p.logger.Warn().Err(err).Msg("Failed to close existing core client during reconnect")
		}
		p.grpcClient = nil
		p.coreClient = nil
	}

	return p.connectToCore(reconnectCtx)
}

func (p *Poller) shouldReconnect(err error) bool {
	if err == nil {
		return false
	}

	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}

	if statusErr, ok := status.FromError(err); ok {
		switch statusErr.Code() {
		case codes.Unavailable, codes.ResourceExhausted, codes.DeadlineExceeded:
			return true
		case codes.Canceled:
			return false
		}
	}

	errMsg := err.Error()
	if errMsg == "" {
		return false
	}

	return strings.Contains(errMsg, "connection error") ||
		strings.Contains(errMsg, "transport: Error while dialing") ||
		strings.Contains(errMsg, "name resolver error") ||
		strings.Contains(errMsg, "connection refused") ||
		strings.Contains(errMsg, "i/o timeout")
}

// reportToCoreStreaming sends service statuses to core using streaming for large datasets
func (p *Poller) reportToCoreStreaming(ctx context.Context, statuses []*proto.ServiceStatus) error {
	stream, err := p.coreClient.StreamStatus(ctx)
	if err != nil {
		return fmt.Errorf("failed to create stream to core: %w", err)
	}

	defer func() {
		if closeErr := stream.CloseSend(); closeErr != nil {
			p.logger.Warn().Err(closeErr).Msg("Failed to close stream")
		}
	}()

	p.logger.Info().
		Int("total_services", len(statuses)).
		Msg("Starting streaming status report to core")

	// Calculate and send chunks
	chunkPlan := p.calculateChunkPlan(statuses)
	if err := p.sendChunks(stream, statuses, chunkPlan); err != nil {
		return err
	}

	// Wait for and validate response
	return p.handleStreamResponse(stream, len(statuses))
}

// UpdateConfig applies updated configuration at runtime.
// PollInterval changes will be picked up on next restart; agents/core/security trigger immediate reconnection/rebuild.
func (p *Poller) UpdateConfig(ctx context.Context, cfg *Config) error {
	if cfg == nil {
		return nil
	}
	// Update logger level if configured
	if cfg.Logging != nil {
		lvl := strings.ToLower(cfg.Logging.Level)
		switch lvl {
		case "debug":
			p.logger.SetDebug(true)
		default:
			p.logger.SetDebug(false)
		}
		p.logger.Info().Str("level", cfg.Logging.Level).Msg("Poller logger level updated")
	}
	// Determine if core connection needs to be rebuilt
	reconnectCore := (cfg.CoreAddress != p.config.CoreAddress)
	if (cfg.Security != nil && p.config.Security != nil) && (cfg.Security.TLS != p.config.Security.TLS || cfg.Security.Mode != p.config.Security.Mode) {
		reconnectCore = true
	}
	// Detect poll interval change
	intervalChanged := time.Duration(cfg.PollInterval) != time.Duration(p.config.PollInterval)
	// Apply config
	p.config = *cfg
	// If interval changed, request ticker reload (non-blocking, drop stale)
	if intervalChanged {
		newDur := time.Duration(cfg.PollInterval)
		select {
		case <-p.done:
			// shutting down; ignore
		default:
			// try to drain existing queued value to avoid backlog
			select {
			case <-p.reloadCh:
			default:
			}
			select {
			case p.reloadCh <- newDur:
			default:
			}
		}
	}
	if reconnectCore {
		if p.grpcClient != nil {
			_ = p.grpcClient.Close()
			p.grpcClient = nil
			p.coreClient = nil
		}
		if err := p.connectToCore(ctx); err != nil {
			p.logger.Error().Err(err).Msg("Failed to reconnect to core")
		} else {
			p.logger.Info().Msg("Reconnected to core after config change")
		}
	}
	// Rebuild agent pollers
	p.mu.Lock()
	for name, ap := range p.agents {
		if ap.clientConn != nil {
			_ = ap.clientConn.Close()
			p.logger.Info().Str("agent", name).Msg("Closed agent connection")
		}
	}
	p.agents = make(map[string]*AgentPoller)
	p.mu.Unlock()
	if err := p.initializeAgentPollers(ctx); err != nil {
		p.logger.Error().Err(err).Msg("Failed to rebuild agent pollers")
	} else {
		p.logger.Info().Msg("Rebuilt agent pollers from updated config")
	}
	return nil
}

// chunkPlan holds the chunking strategy for streaming
type chunkPlan struct {
	totalChunks  int
	maxChunkSize int
	timestamp    int64
}

// calculateChunkPlan determines how to chunk the services for streaming
func (p *Poller) calculateChunkPlan(statuses []*proto.ServiceStatus) chunkPlan {
	const maxChunkSize = 3 * 1024 * 1024 // 3MB to stay under 4MB gRPC limit

	actualChunkCount := 0

	for _, status := range statuses {
		messageSize := p.getMessageSize(status)

		if messageSize > maxChunkSize {
			chunks := (messageSize + maxChunkSize - 1) / maxChunkSize
			actualChunkCount += chunks
		} else {
			actualChunkCount++
		}
	}

	return chunkPlan{
		totalChunks:  actualChunkCount,
		maxChunkSize: maxChunkSize,
		timestamp:    time.Now().Unix(),
	}
}

// getMessageSize safely gets the message size from a service status
func (*Poller) getMessageSize(status *proto.ServiceStatus) int {
	if status.Message != nil {
		return len(status.Message)
	}

	return 0
}

// sendChunks sends all service chunks according to the plan
func (p *Poller) sendChunks(stream proto.PollerService_StreamStatusClient, statuses []*proto.ServiceStatus, plan chunkPlan) error {
	chunkIndex := 0

	for _, status := range statuses {
		messageSize := p.getMessageSize(status)

		if messageSize > plan.maxChunkSize {
			if err := p.sendLargeServiceChunks(stream, status, messageSize, plan, &chunkIndex); err != nil {
				return err
			}
		} else {
			if err := p.sendSingleServiceChunk(stream, status, messageSize, plan, &chunkIndex); err != nil {
				return err
			}
		}
	}

	return nil
}

// sendLargeServiceChunks splits and sends a large service message
func (p *Poller) sendLargeServiceChunks(
	stream proto.PollerService_StreamStatusClient,
	status *proto.ServiceStatus,
	messageSize int,
	plan chunkPlan,
	chunkIndex *int) error {
	p.logger.Info().
		Str("service_name", status.ServiceName).
		Int("message_size_bytes", messageSize).
		Str("message_size_human", formatBytes(messageSize)).
		Int("chunks_needed", (messageSize+plan.maxChunkSize-1)/plan.maxChunkSize).
		Msg("Splitting large service message into chunks")

	for offset := 0; offset < messageSize; offset += plan.maxChunkSize {
		end := offset + plan.maxChunkSize
		if end > messageSize {
			end = messageSize
		}

		partialStatus := &proto.ServiceStatus{
			ServiceName:  status.ServiceName,
			Available:    status.Available,
			Message:      status.Message[offset:end],
			ServiceType:  status.ServiceType,
			ResponseTime: status.ResponseTime,
			AgentId:      status.AgentId,
			PollerId:     status.PollerId,
			Partition:    status.Partition,
		}

		chunk := p.createChunk([]*proto.ServiceStatus{partialStatus}, plan, *chunkIndex)

		p.logger.Debug().
			Int("chunk_index", *chunkIndex).
			Str("service_name", status.ServiceName).
			Int("offset", offset).
			Int("chunk_size", end-offset).
			Bool("is_final", chunk.IsFinal).
			Msg("Sending partial service chunk to core")

		if err := stream.Send(chunk); err != nil {
			return fmt.Errorf("failed to send chunk %d: %w", *chunkIndex, err)
		}

		*chunkIndex++
	}

	return nil
}

// sendSingleServiceChunk sends a service that fits in one chunk
func (p *Poller) sendSingleServiceChunk(
	stream proto.PollerService_StreamStatusClient,
	status *proto.ServiceStatus,
	messageSize int,
	plan chunkPlan,
	chunkIndex *int) error {
	chunk := p.createChunk([]*proto.ServiceStatus{status}, plan, *chunkIndex)

	p.logger.Debug().
		Int("chunk_index", *chunkIndex).
		Str("service_name", status.ServiceName).
		Int("message_size", messageSize).
		Bool("is_final", chunk.IsFinal).
		Msg("Sending service chunk to core")

	if err := stream.Send(chunk); err != nil {
		return fmt.Errorf("failed to send chunk %d: %w", *chunkIndex, err)
	}

	*chunkIndex++

	return nil
}

// createChunk creates a PollerStatusChunk with the given services
func (p *Poller) createChunk(services []*proto.ServiceStatus, plan chunkPlan, chunkIndex int) *proto.PollerStatusChunk {
	var agentID string
	if len(services) > 0 {
		agentID = services[0].AgentId
	}

	return &proto.PollerStatusChunk{
		Services:    services,
		PollerId:    p.config.PollerID,
		AgentId:     agentID,
		Timestamp:   plan.timestamp,
		Partition:   p.config.Partition,
		SourceIp:    p.config.SourceIP,
		IsFinal:     chunkIndex == plan.totalChunks-1,
		ChunkIndex:  safeIntToInt32(chunkIndex),
		TotalChunks: safeIntToInt32(plan.totalChunks),
	}
}

// handleStreamResponse waits for and validates the stream response
func (p *Poller) handleStreamResponse(stream proto.PollerService_StreamStatusClient, serviceCount int) error {
	response, err := stream.CloseAndRecv()
	if err != nil {
		return fmt.Errorf("failed to receive response from core stream: %w", err)
	}

	if !response.Received {
		return errStreamStatusNotReceived
	}

	p.logger.Info().
		Int("total_services", serviceCount).
		Msg("Successfully completed streaming status report to core")

	return nil
}

func (p *Poller) enhanceServicePayload(originalMessage, agentID, partition, serviceType, serviceName string) (string, error) {
	if serviceType == "snmp" {
		p.logger.Debug().Str("agentID", agentID).Str("message", originalMessage).Msg("SNMP original message")
	}

	var serviceData json.RawMessage

	switch {
	case originalMessage == "":
		p.logger.Warn().Str("serviceType", serviceType).Str("serviceName", serviceName).Msg("Empty message for service")

		serviceData = json.RawMessage("{}")
	case json.Valid([]byte(originalMessage)):
		serviceData = json.RawMessage(originalMessage)
	default:
		p.logger.Warn().
			Str("serviceType", serviceType).
			Str("serviceName", serviceName).
			Str("message", originalMessage).
			Msg("Invalid JSON for service, wrapping")

		errorWrapper := map[string]string{"message": originalMessage}

		wrappedJSON, err := json.Marshal(errorWrapper)
		if err != nil {
			return "", fmt.Errorf("failed to wrap non-JSON message: %w", err)
		}

		serviceData = wrappedJSON
	}

	enhancedPayload := models.ServiceMetricsPayload{
		PollerID:    p.config.PollerID,
		AgentID:     agentID,
		Partition:   partition,
		ServiceType: serviceType,
		ServiceName: serviceName,
		Data:        serviceData,
	}

	enhancedJSON, err := json.Marshal(enhancedPayload)
	if err != nil {
		return "", fmt.Errorf("failed to marshal enhanced service payload: %w", err)
	}

	return string(enhancedJSON), nil
}
