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
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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

func newAgentPoller(
	name string,
	config *AgentConfig,
	client proto.AgentServiceClient,
	poller *Poller) *AgentPoller {
	ap := &AgentPoller{
		name:    name,
		config:  config,
		client:  client,
		timeout: defaultTimeout,
		poller:  poller,
	}

	for _, check := range config.Checks {
		if check.ResultsInterval != nil {
			resultsPoller := &ResultsPoller{
				client:    client,
				check:     check,
				pollerID:  poller.config.PollerID,
				agentName: name,
				interval:  time.Duration(*check.ResultsInterval),
				poller:    poller,
				logger:    poller.logger,
			}
			ap.resultsPollers = append(ap.resultsPollers, resultsPoller)
		}
	}

	return ap
}

// ExecuteChecks runs all configured service checks for the agent.
func (ap *AgentPoller) ExecuteChecks(ctx context.Context) []*proto.ServiceStatus {
	checkCtx, cancel := context.WithTimeout(ctx, ap.timeout)
	defer cancel()

	results := make(chan *proto.ServiceStatus, len(ap.config.Checks))
	statuses := make([]*proto.ServiceStatus, 0, len(ap.config.Checks))

	var wg sync.WaitGroup

	for _, check := range ap.config.Checks {
		wg.Add(1)

		go func(check Check) {
			defer wg.Done()

			svcCheck := newServiceCheck(ap.client, check, ap.poller.config.PollerID, ap.name, ap.poller.logger)

			results <- svcCheck.execute(checkCtx)
		}(check)
	}

	go func() {
		wg.Wait()
		close(results)
	}()

	for result := range results {
		statuses = append(statuses, result)
	}

	return statuses
}

// ExecuteResults runs GetResults calls for services that need it and are due for polling.
func (ap *AgentPoller) ExecuteResults(ctx context.Context) []*proto.ServiceStatus {
	checkCtx, cancel := context.WithTimeout(ctx, ap.timeout)
	defer cancel()

	results := make(chan *proto.ServiceStatus, len(ap.resultsPollers))
	statuses := make([]*proto.ServiceStatus, 0, len(ap.resultsPollers))

	var wg sync.WaitGroup

	now := time.Now()

	for _, resultsPoller := range ap.resultsPollers {
		if now.Sub(resultsPoller.lastResults) >= resultsPoller.interval {
			wg.Add(1)

			go func(rp *ResultsPoller) {
				defer wg.Done()

				statusResult := rp.executeGetResults(checkCtx)
				if statusResult != nil {
					results <- statusResult
				}

				rp.lastResults = now
			}(resultsPoller)
		}
	}

	go func() {
		wg.Wait()
		close(results)
	}()

	for result := range results {
		statuses = append(statuses, result)
	}

	return statuses
}

func newServiceCheck(client proto.AgentServiceClient, check Check, pollerID, agentName string, logger logger.Logger) *ServiceCheck {
	return &ServiceCheck{
		client:    client,
		check:     check,
		pollerID:  pollerID,
		agentName: agentName,
		logger:    logger,
	}
}

func (sc *ServiceCheck) execute(ctx context.Context) *proto.ServiceStatus {
	req := &proto.StatusRequest{
		ServiceName: sc.check.Name,
		ServiceType: sc.check.Type,
		AgentId:     sc.agentName,
		PollerId:    sc.pollerID,
		Details:     sc.check.Details,
	}

	if sc.check.Type == "port" {
		req.Port = sc.check.Port
	}

	sc.logger.Debug().
		Str("service_name", sc.check.Name).
		Str("service_type", sc.check.Type).
		Str("agent_name", sc.agentName).
		Str("poller_id", sc.pollerID).
		Msg("Executing service check")

	getStatus, err := sc.client.GetStatus(ctx, req)
	if err != nil {
		sc.logger.Error().Err(err).
			Str("service_name", sc.check.Name).
			Str("service_type", sc.check.Type).
			Str("agent_name", sc.agentName).
			Str("poller_id", sc.pollerID).
			Msg("Service check failed")

		msg := "Service check failed"

		message, err := json.Marshal(map[string]string{"error": msg})
		if err != nil {
			sc.logger.Warn().Err(err).Str("service_name", sc.check.Name).Msg("Failed to marshal error message, using fallback")

			message = []byte(msg)
		}

		return &proto.ServiceStatus{
			ServiceName: sc.check.Name,
			Available:   false,
			Message:     message,
			ServiceType: sc.check.Type,
			PollerId:    sc.pollerID,
			Source:      "getStatus",
		}
	}

	sc.logger.Debug().
		Str("service_name", sc.check.Name).
		Str("service_type", sc.check.Type).
		Str("agent_name", sc.agentName).
		Bool("available", getStatus.Available).
		Msg("Service check completed successfully")

	return &proto.ServiceStatus{
		ServiceName:  sc.check.Name,
		Available:    getStatus.Available,
		Message:      getStatus.Message,
		ServiceType:  sc.check.Type,
		ResponseTime: getStatus.ResponseTime,
		AgentId:      getStatus.AgentId,
		PollerId:     sc.pollerID,
		Source:       "getStatus",
	}
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

	// Use streaming if we have a large number of services (20k+ threshold)
	const streamingThreshold = 100 // Use 100 services as threshold for now

	if len(statuses) > streamingThreshold {
		p.logger.Info().Int("service_count", len(statuses)).Msg("Using streaming to report large dataset to core")
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

// executeGetResults now routes to the correct method based on service type.
func (rp *ResultsPoller) executeGetResults(ctx context.Context) *proto.ServiceStatus {
	req := rp.buildResultsRequest()

	var results *proto.ResultsResponse

	var err error

	// Route based on service type or service name - use streaming for services that handle large datasets
	if rp.check.Type == serviceTypeSync || rp.check.Type == serviceTypeSweep ||
		rp.check.Name == serviceTypeSync || strings.Contains(rp.check.Name, serviceTypeSync) {
		rp.logger.Info().
			Str("service_name", rp.check.Name).
			Str("service_type", rp.check.Type).
			Msg("Using streaming method for large dataset service")

		results, err = rp.executeStreamResults(ctx, req)
	} else {
		rp.logger.Debug().Str("service_name", rp.check.Name).Msg("Using unary method for service")

		results, err = rp.client.GetResults(ctx, req)
	}

	if err != nil {
		return rp.handleGetResultsError(err)
	}

	if results == nil {
		rp.logger.Warn().Str("service_name", rp.check.Name).Msg("GetResults returned nil response, skipping")
		return nil
	}

	rp.logSuccessfulGetResults(results)
	rp.updateSequenceTracking(results)

	if rp.shouldSkipCoreSubmission(results) {
		return nil
	}

	return rp.convertToServiceStatus(results)
}

// executeStreamResults handles the gRPC streaming for large datasets.
func (rp *ResultsPoller) executeStreamResults(ctx context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	rp.logger.Info().Str("service_name", req.ServiceName).Str("service_type", req.ServiceType).Msg("Starting StreamResults call")

	stream, err := rp.client.StreamResults(ctx, req)
	if err != nil {
		rp.logger.Error().Err(err).Str("service_name", req.ServiceName).Msg("Failed to initiate StreamResults")
		return nil, err
	}

	var dataBuffer bytes.Buffer

	var finalChunk *proto.ResultsChunk

	startTime := time.Now()
	chunksReceived := 0

	for {
		chunk, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			rp.logger.Info().Str("service_name", req.ServiceName).Int("chunks_received", chunksReceived).Msg("Stream ended normally")
			break // End of stream
		}

		if err != nil {
			rp.logger.Error().Err(err).
				Str("service_name", req.ServiceName).
				Int("chunks_received", chunksReceived).
				Msg("Error receiving chunk from stream")

			return nil, fmt.Errorf("failed to receive chunk: %w", err)
		}

		chunksReceived++

		rp.logger.Debug().
			Str("service_name", req.ServiceName).
			Int("chunk_index", int(chunk.ChunkIndex)).
			Int("chunk_size", len(chunk.Data)).
			Bool("is_final", chunk.IsFinal).
			Msg("Received chunk")

		if _, err := dataBuffer.Write(chunk.Data); err != nil {
			rp.logger.Error().Err(err).Str("service_name", req.ServiceName).Msg("Failed to write chunk to buffer")
			return nil, fmt.Errorf("failed to write chunk to buffer: %w", err)
		}

		if chunk.IsFinal {
			finalChunk = chunk

			rp.logger.Info().Str("service_name", req.ServiceName).Int("total_chunks", chunksReceived).Msg("Received final chunk")

			break
		}
	}

	if finalChunk == nil {
		rp.logger.Error().
			Str("service_name", req.ServiceName).
			Int("chunks_received", chunksReceived).
			Msg("Stream completed without a final chunk")

		return nil, fmt.Errorf("stream completed without a final chunk")
	}

	rp.logger.Info().
		Str("service_name", req.ServiceName).
		Int("total_chunks", int(finalChunk.TotalChunks)).
		Int("data_size_bytes", dataBuffer.Len()).
		Msg("Successfully received all chunks from stream")

	// Assemble the final ResultsResponse from the chunks
	return &proto.ResultsResponse{
		Available:       true,
		Data:            dataBuffer.Bytes(),
		ServiceName:     req.ServiceName,
		ServiceType:     req.ServiceType,
		ResponseTime:    time.Since(startTime).Nanoseconds(),
		AgentId:         req.AgentId,
		PollerId:        req.PollerId,
		Timestamp:       finalChunk.Timestamp,
		CurrentSequence: finalChunk.CurrentSequence,
		HasNewData:      true, // Assume new data if we streamed
	}, nil
}

func (rp *ResultsPoller) buildResultsRequest() *proto.ResultsRequest {
	req := &proto.ResultsRequest{
		ServiceName:  rp.check.Name,
		ServiceType:  rp.check.Type,
		AgentId:      rp.agentName,
		PollerId:     rp.pollerID,
		Details:      rp.check.Details,
		LastSequence: rp.lastSequence,
	}

	rp.logger.Debug().
		Str("service_name", rp.check.Name).
		Str("service_type", rp.check.Type).
		Str("agent_name", rp.agentName).
		Str("poller_id", rp.pollerID).
		Msg("Executing GetResults call")

	return req
}

func (rp *ResultsPoller) handleGetResultsError(err error) *proto.ServiceStatus {
	if status.Code(err) == codes.Unimplemented {
		rp.logger.Debug().
			Str("service_name", rp.check.Name).
			Str("service_type", rp.check.Type).
			Str("agent_name", rp.agentName).
			Msg("Service does not support GetResults - skipping")

		return nil
	}

	rp.logger.Error().
		Err(err).
		Str("service_name", rp.check.Name).
		Str("service_type", rp.check.Type).
		Str("agent_name", rp.agentName).
		Str("poller_id", rp.pollerID).
		Msg("GetResults call failed")

	return &proto.ServiceStatus{
		ServiceName: rp.check.Name,
		Available:   false,
		Message:     []byte(fmt.Sprintf(`{"error": "GetResults failed: %v"}`, err)),
		ServiceType: rp.check.Type,
		PollerId:    rp.pollerID,
		AgentId:     rp.agentName,
		Source:      "results",
	}
}

func (rp *ResultsPoller) logSuccessfulGetResults(results *proto.ResultsResponse) {
	rp.logger.Debug().
		Str("service_name", rp.check.Name).
		Str("service_type", rp.check.Type).
		Str("agent_name", rp.agentName).
		Bool("available", results.Available).
		Str("current_sequence", results.CurrentSequence).
		Bool("has_new_data", results.HasNewData).
		Int("data_length", len(results.Data)).
		Msg("GetResults call processed successfully")
}

func (rp *ResultsPoller) updateSequenceTracking(results *proto.ResultsResponse) {
	if results.CurrentSequence != "" {
		rp.lastSequence = results.CurrentSequence
	}
}

func (rp *ResultsPoller) shouldSkipCoreSubmission(results *proto.ResultsResponse) bool {
	if rp.check.Name == serviceTypeSync || strings.Contains(rp.check.Name, serviceTypeSync) {
		if !results.HasNewData {
			rp.logger.Debug().
				Str("service_name", rp.check.Name).
				Msg("Sync service has no new data, but submitting full list to core for state reconciliation.")
		}

		return false
	}

	if !results.HasNewData && rp.check.Type == serviceTypeSweep {
		rp.logger.Debug().
			Str("service_name", rp.check.Name).
			Str("service_type", rp.check.Type).
			Str("sequence", results.CurrentSequence).
			Msg("No new data from sweep service, skipping core submission")

		return true
	}

	return false
}

func (rp *ResultsPoller) convertToServiceStatus(results *proto.ResultsResponse) *proto.ServiceStatus {
	// Determine the correct service type to send to core
	serviceType := rp.check.Type
	if rp.check.Name == serviceTypeSync || strings.Contains(rp.check.Name, serviceTypeSync) {
		// For sync services, always use "sync" as the service type for core processing
		serviceType = serviceTypeSync
		rp.logger.Info().
			Str("service_name", rp.check.Name).
			Str("original_service_type", rp.check.Type).
			Str("core_service_type", serviceType).
			Bool("has_new_data", results.HasNewData).
			Str("sequence", results.CurrentSequence).
			Int("data_length", len(results.Data)).
			Msg("Converting sync service results to ServiceStatus for core submission")
	}

	return &proto.ServiceStatus{
		ServiceName:  rp.check.Name,
		Available:    results.Available,
		Message:      results.Data,
		ServiceType:  serviceType,
		ResponseTime: results.ResponseTime,
		AgentId:      results.AgentId,
		PollerId:     rp.pollerID,
		Source:       "results",
	}
}
