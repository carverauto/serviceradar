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
	"fmt"
	"math"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	grpcRetries      = 3
	defaultTimeout   = 30 * time.Second
	stopTimeout      = 10 * time.Second
	serviceTypeSweep = "sweep"
	serviceTypeSync  = "sync"
	checkTypeGRPC    = "grpc"
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
		config: *config,
		agents: make(map[string]*AgentPoller),
		done:   make(chan struct{}),
		clock:  clock,
		logger: log,
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
	ticker := p.clock.Ticker(interval)

	defer ticker.Stop()
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
		case <-ticker.Chan():
			p.wg.Add(1)

			go func() {
				defer p.wg.Done()

				if err := p.poll(ctx); err != nil {
					p.logger.Error().Err(err).Msg("Error during poll")
				}
			}()
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

		if p.config.Security != nil {
			provider, err := grpc.NewSecurityProvider(ctx, p.config.Security, p.logger)
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
	const maxSafeMessageSize = 3 * 1024 * 1024 // 3MB to be safe (leaving room for other fields)

	const streamingServiceCountThreshold = 100 // Also use streaming for many services

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

	// Use streaming if data is large OR if we have many services
	if totalDataSize > maxSafeMessageSize || len(statuses) > streamingServiceCountThreshold {
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

// reportToCoreStreaming sends service statuses to core using streaming for large datasets
func (p *Poller) reportToCoreStreaming(ctx context.Context, statuses []*proto.ServiceStatus) error {
	const chunkSize = 100 // Services per chunk

	stream, err := p.coreClient.StreamStatus(ctx)
	if err != nil {
		return fmt.Errorf("failed to create stream to core: %w", err)
	}

	defer func() {
		if closeErr := stream.CloseSend(); closeErr != nil {
			p.logger.Warn().Err(closeErr).Msg("Failed to close stream")
		}
	}()

	totalChunks := (len(statuses) + chunkSize - 1) / chunkSize
	timestamp := time.Now().Unix()

	p.logger.Info().
		Int("total_services", len(statuses)).
		Int("chunk_size", chunkSize).
		Int("total_chunks", totalChunks).
		Msg("Starting streaming status report to core")

	// Send data in chunks
	for i := 0; i < len(statuses); i += chunkSize {
		end := i + chunkSize

		if end > len(statuses) {
			end = len(statuses)
		}

		chunkIndex := i / chunkSize
		chunk := &proto.PollerStatusChunk{
			Services:    statuses[i:end],
			PollerId:    p.config.PollerID,
			AgentId:     "", // Will be extracted from individual services
			Timestamp:   timestamp,
			Partition:   p.config.Partition,
			SourceIp:    p.config.SourceIP,
			IsFinal:     end == len(statuses),
			ChunkIndex:  safeIntToInt32(chunkIndex),
			TotalChunks: safeIntToInt32(totalChunks),
		}

		p.logger.Debug().
			Int("chunk_index", chunkIndex).
			Int("chunk_services", len(chunk.Services)).
			Bool("is_final", chunk.IsFinal).
			Msg("Sending chunk to core")

		if sendErr := stream.Send(chunk); sendErr != nil {
			return fmt.Errorf("failed to send chunk %d: %w", chunkIndex, sendErr)
		}
	}

	// Wait for response
	response, err := stream.CloseAndRecv()
	if err != nil {
		return fmt.Errorf("failed to receive response from core stream: %w", err)
	}

	if !response.Received {
		return fmt.Errorf("core indicated streaming status report was not received")
	}

	p.logger.Info().
		Int("total_services", len(statuses)).
		Int("chunks_sent", totalChunks).
		Msg("Successfully completed streaming status report to core")

	return nil
}

func (p *Poller) enhanceServicePayload(originalMessage, agentID, partition, serviceType, serviceName string) (string, error) {
	if serviceType == "snmp" {
		p.logger.Debug().Str("agentID", agentID).Str("message", originalMessage).Msg("SNMP original message")
	}

	var serviceData json.RawMessage

	if originalMessage == "" {
		p.logger.Warn().Str("serviceType", serviceType).Str("serviceName", serviceName).Msg("Empty message for service")

		serviceData = json.RawMessage("{}")
	} else if json.Valid([]byte(originalMessage)) {
		serviceData = json.RawMessage(originalMessage)
	} else {
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
