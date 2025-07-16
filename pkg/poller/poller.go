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

// New creates a new poller instance.
func New(ctx context.Context, config *Config, clock Clock, log logger.Logger) (*Poller, error) {
	if clock == nil {
		clock = realClock{}
	}

	p := &Poller{
		config:           *config,
		agents:           make(map[string]*AgentPoller),
		done:             make(chan struct{}),
		clock:            clock,
		logger:           log,
		agentCompletions: make(map[string]*proto.SweepCompletionStatus),
	}

	// Only connect to core if CoreAddress is set and PollFunc isn’t overriding default behavior
	if p.config.CoreAddress != "" && p.PollFunc == nil {
		if err := p.connectToCore(ctx); err != nil {
			return nil, fmt.Errorf("failed to connect to core service: %w", err)
		}
	}

	// Initialize agent pollers only if not using PollFunc exclusively
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

	p.startWg.Add(1) // Track Start goroutine
	defer p.startWg.Done()

	p.wg.Add(1)
	defer p.wg.Done()

	// Initial poll
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
		close(p.done) // Signal shutdown
	})

	p.startWg.Wait() // Wait for Start to exit
	p.wg.Wait()      // Wait for all polling goroutines to finish

	p.mu.Lock()
	defer p.mu.Unlock()

	// Close core client first
	if p.coreClient != nil {
		if err := p.grpcClient.Close(); err != nil {
			p.logger.Error().Err(err).Msg("Error closing core client")
		}
	}

	// Wait for any active agent connections to finish
	for name, agentPoller := range p.agents {
		if agentPoller.clientConn != nil {
			if err := agentPoller.clientConn.Close(); err != nil {
				p.logger.Error().Err(err).Str("agent", name).Msg("Error closing agent connection")
			}
		}
	}

	// Clear the maps to prevent any lingering references
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

	// Close core client
	if p.grpcClient != nil {
		if err := p.grpcClient.Close(); err != nil {
			errs = append(errs, fmt.Errorf("error closing core client: %w", err))
		}
	}

	// Close all agent connections
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

	// Initialize results pollers for checks that have results_interval configured
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

	// Close results channel when all checks complete
	go func() {
		wg.Wait()
		close(results)
	}()

	// Collect results
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
		// Check if this results poller is due for execution
		if now.Sub(resultsPoller.lastResults) >= resultsPoller.interval {
			wg.Add(1)

			go func(rp *ResultsPoller) {
				defer wg.Done()

				status := rp.executeGetResults(checkCtx)
				if status != nil {
					results <- status
				}
				// Always update lastResults to prevent continuous retries for unsupported services
				rp.lastResults = now
			}(resultsPoller)
		}
	}

	// Close results channel when all results complete
	go func() {
		wg.Wait()
		close(results)
	}()

	// Collect results
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

	status, err := sc.client.GetStatus(ctx, req)
	if err != nil {
		sc.logger.Error().
			Err(err).
			Str("service_name", sc.check.Name).
			Str("service_type", sc.check.Type).
			Str("agent_name", sc.agentName).
			Str("poller_id", sc.pollerID).
			Msg("Service check failed")

		msg := "Service check failed"

		message, err := json.Marshal(map[string]string{"error": msg})
		if err != nil {
			sc.logger.Warn().
				Err(err).
				Str("service_name", sc.check.Name).
				Msg("Failed to marshal error message, using fallback")

			message = []byte(msg) // Fallback to plain string if marshal fails
		}

		return &proto.ServiceStatus{
			ServiceName: sc.check.Name,
			Available:   false,
			Message:     message,
			ServiceType: sc.check.Type,
			PollerId:    sc.pollerID,
			Source:      "status",
		}
	}

	sc.logger.Debug().
		Str("service_name", sc.check.Name).
		Str("service_type", sc.check.Type).
		Str("agent_name", sc.agentName).
		Bool("available", status.Available).
		Msg("Service check completed successfully")

	return &proto.ServiceStatus{
		ServiceName:  sc.check.Name,
		Available:    status.Available,
		Message:      status.Message,
		ServiceType:  sc.check.Type,
		ResponseTime: status.ResponseTime,
		AgentId:      status.AgentId,
		PollerId:     sc.pollerID,
		Source:       "status",
	}
}

// Connection management methods.
// Note: Agent connections are now managed by long-lived AgentPoller instances
// created once at startup in initializeAgentPollers()

func (p *Poller) connectToCore(ctx context.Context) error {
	// Use ClientConfig instead of ConnectionConfig
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
		// Use ClientConfig instead of ConnectionConfig
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

		p.logger.Info().Str("agent", agentName).Str("address", agentConfig.Address).Msg("Connecting to agent and creating poller")

		client, err := grpc.NewClient(ctx, clientCfg)
		if err != nil {
			return fmt.Errorf("failed to connect to agent %s: %w", agentName, err)
		}

		// Create the AgentServiceClient
		agentServiceClient := proto.NewAgentServiceClient(client.GetConnection())

		// Create the AgentPoller ONCE and store it.
		// It will now persist across poll cycles.
		agentPoller := newAgentPoller(agentName, &agentConfig, agentServiceClient, p)
		agentPoller.clientConn = client // Store the grpc.Client for lifecycle management
		p.agents[agentName] = agentPoller
	}

	return nil
}

// Poll execution methods.
func (p *Poller) poll(ctx context.Context) error {
	if p.PollFunc != nil {
		return p.PollFunc(ctx)
	}

	// Pre-allocate slice for better performance
	allStatuses := make([]*proto.ServiceStatus, 0, len(p.config.Agents)*10) // Estimate 10 statuses per agent

	var wg sync.WaitGroup

	statusChan := make(chan *proto.ServiceStatus, 100) // Buffer channel

	for agentName := range p.config.Agents {
		wg.Add(1)

		go func(name string) {
			defer wg.Done()

			// Retrieve the EXISTING, long-lived AgentPoller
			agentPoller, exists := p.agents[name]
			if !exists {
				p.logger.Error().Str("agent", name).Msg("Poller for agent not found during poll cycle")
				return
			}

			// Optional health check - use the stored grpc.Client
			if agentPoller.clientConn != nil {
				healthy, err := agentPoller.clientConn.CheckHealth(ctx, "AgentService")
				if err != nil || !healthy {
					p.logger.Warn().Str("agent", name).Err(err).Bool("healthy", healthy).Msg("Agent health check failed")
				}
			}

			// Execute checks
			statuses := agentPoller.ExecuteChecks(ctx)
			for _, s := range statuses {
				statusChan <- s
			}

			// Execute results
			resultsStatuses := agentPoller.ExecuteResults(ctx)
			for _, s := range resultsStatuses {
				statusChan <- s
			}
		}(agentName)
	}

	go func() {
		wg.Wait()
		close(statusChan)
	}()

	for status := range statusChan {
		allStatuses = append(allStatuses, status)
	}

	return p.reportToCore(ctx, allStatuses)
}

func (p *Poller) reportToCore(ctx context.Context, statuses []*proto.ServiceStatus) error {
	p.logger.Info().
		Int("statusCount", len(statuses)).
		Str("pollerID", p.config.PollerID).
		Time("timestamp", time.Now()).
		Msg("Reporting statuses")

	// Add PollerID to each ServiceStatus if missing
	for i, status := range statuses {
		// Add the poller ID to each status
		status.PollerId = p.config.PollerID

		// add the partition to each status
		status.Partition = p.config.Partition

		// Determine the correct AgentID to use - prefer response AgentId, fall back to configured agent name
		agentID := status.AgentId
		if agentID == "" {
			p.logger.Warn().Str("serviceName", status.ServiceName).Msg("AgentID empty in response, using configured agent name as fallback")
		}

		// Enhance ALL service responses with infrastructure identity
		enhancedMessage, err := p.enhanceServicePayload(string(status.Message), agentID, status.Partition, status.ServiceType, status.ServiceName)
		if err != nil {
			p.logger.Warn().Err(err).Str("serviceName", status.ServiceName).Msg("Failed to enhance payload")
		} else {
			status.Message = []byte(enhancedMessage)
		}

		p.logger.Debug().
			Str("partition", status.Partition).
			Str("pollerID", status.PollerId).
			Str("serviceName", status.ServiceName).
			Str("agentID", status.AgentId).
			Msg("Service status details")

		// Log warning if AgentID is missing (debugging aid)
		if status.AgentId == "" {
			p.logger.Warn().Int("index", i).Str("serviceName", status.ServiceName).Msg("ServiceStatus has empty AgentID")
		}
	}

	_, err := p.coreClient.ReportStatus(ctx, &proto.PollerStatusRequest{
		Services:  statuses,
		PollerId:  p.config.PollerID,
		Timestamp: time.Now().Unix(),
		Partition: p.config.Partition,
		SourceIp:  p.config.SourceIP,
	})
	if err != nil {
		return fmt.Errorf("failed to report status to core: %w", err)
	}

	return nil
}

// enhanceServicePayload wraps ANY service response with infrastructure identity information.
// This is a fundamental feature that adds poller context to all service messages.
func (p *Poller) enhanceServicePayload(originalMessage, agentID, partition, serviceType, serviceName string) (string, error) {
	// Debug logging for SNMP service to understand what we're getting
	if serviceType == "snmp" {
		p.logger.Debug().Str("agentID", agentID).Str("message", originalMessage).Msg("SNMP original message")
	}

	// Validate and normalize the original message to ensure it's valid JSON
	var serviceData json.RawMessage

	// Try to parse original message as JSON
	if originalMessage == "" {
		// Empty message - use empty JSON object
		p.logger.Warn().Str("serviceType", serviceType).Str("serviceName", serviceName).Msg("Empty message for service")

		serviceData = json.RawMessage("{}")
	} else if json.Valid([]byte(originalMessage)) {
		// Valid JSON - use as-is
		serviceData = json.RawMessage(originalMessage)
	} else {
		// Invalid JSON (likely plain text error) - wrap in JSON object
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

	// Create enhanced payload with infrastructure identity for ANY service type
	enhancedPayload := models.ServiceMetricsPayload{
		PollerID:    p.config.PollerID,
		AgentID:     agentID,
		Partition:   partition,
		ServiceType: serviceType,
		ServiceName: serviceName,
		Data:        serviceData, // Guaranteed valid JSON
	}

	// Marshal enhanced payload back to JSON
	enhancedJSON, err := json.Marshal(enhancedPayload)
	if err != nil {
		return "", fmt.Errorf("failed to marshal enhanced service payload: %w", err)
	}

	return string(enhancedJSON), nil
}

// updateAgentCompletion stores completion status from an agent.
func (p *Poller) updateAgentCompletion(agentName string, status *proto.SweepCompletionStatus) {
	if status == nil {
		return
	}

	p.completionMu.Lock()
	defer p.completionMu.Unlock()

	p.agentCompletions[agentName] = status
	p.logger.Debug().
		Str("agent", agentName).
		Str("status", status.Status.String()).
		Int32("completed", status.CompletedTargets).
		Int32("total", status.TotalTargets).
		Msg("Updated agent completion status")
}

// getAggregatedCompletion aggregates completion status from all agents for forwarding to sync service.
func (p *Poller) getAggregatedCompletion() *proto.SweepCompletionStatus {
	p.completionMu.RLock()
	defer p.completionMu.RUnlock()

	if len(p.agentCompletions) == 0 {
		return nil
	}

	var (
		totalTargets         int32
		completedTargets     int32
		latestStatus         = proto.SweepCompletionStatus_UNKNOWN
		latestCompletionTime int64
		targetSequence       string
	)

	// Aggregate data from all agents
	for agentName, status := range p.agentCompletions {
		if status == nil {
			continue
		}

		totalTargets += status.TotalTargets
		completedTargets += status.CompletedTargets

		// Use the most advanced status (prefer COMPLETED over IN_PROGRESS, etc.)
		if status.Status > latestStatus {
			latestStatus = status.Status
		}

		// Use the latest completion time
		if status.CompletionTime > latestCompletionTime {
			latestCompletionTime = status.CompletionTime
		}

		// Use the first non-empty target sequence (they should all be the same)
		if targetSequence == "" && status.TargetSequence != "" {
			targetSequence = status.TargetSequence
		}

		p.logger.Debug().
			Str("agent", agentName).
			Str("status", status.Status.String()).
			Int32("agent_completed", status.CompletedTargets).
			Int32("agent_total", status.TotalTargets).
			Msg("Processing agent completion for aggregation")
	}

	// If we have completed targets from any agent, consider overall as IN_PROGRESS at minimum
	if completedTargets > 0 && latestStatus == proto.SweepCompletionStatus_UNKNOWN {
		latestStatus = proto.SweepCompletionStatus_IN_PROGRESS
	}

	aggregated := &proto.SweepCompletionStatus{
		Status:           latestStatus,
		CompletionTime:   latestCompletionTime,
		TargetSequence:   targetSequence,
		TotalTargets:     totalTargets,
		CompletedTargets: completedTargets,
	}

	p.logger.Debug().
		Str("aggregated_status", aggregated.Status.String()).
		Int32("total_completed", aggregated.CompletedTargets).
		Int32("total_targets", aggregated.TotalTargets).
		Str("target_sequence", aggregated.TargetSequence).
		Msg("Aggregated completion status for sync forwarding")

	return aggregated
}

// executeGetResults executes a GetResults call for a service.
func (rp *ResultsPoller) executeGetResults(ctx context.Context) *proto.ServiceStatus {
	req := rp.buildResultsRequest()

	results, err := rp.client.GetResults(ctx, req)
	if err != nil {
		return rp.handleGetResultsError(err)
	}

	rp.logSuccessfulGetResults(results)
	rp.updateSequenceTracking(results)
	rp.updateCompletionTracking(results)

	if rp.shouldSkipCoreSubmission(results) {
		return nil
	}

	return rp.convertToServiceStatus(results)
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

	// If this is a sync service, get aggregated completion status from all agents
	if rp.check.Type == checkTypeGRPC && (rp.check.Name == serviceTypeSync || strings.Contains(rp.check.Name, serviceTypeSync)) {
		if aggregatedStatus := rp.poller.getAggregatedCompletion(); aggregatedStatus != nil {
			req.CompletionStatus = aggregatedStatus
			rp.logger.Debug().
				Str("service_name", rp.check.Name).
				Str("completion_status", aggregatedStatus.Status.String()).
				Str("target_sequence", aggregatedStatus.TargetSequence).
				Int32("total_completed", aggregatedStatus.CompletedTargets).
				Int32("total_targets", aggregatedStatus.TotalTargets).
				Msg("Forwarding aggregated completion status to sync service")
		}
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
	// Check if this is an "unimplemented" error, which means the service doesn't support GetResults
	if status.Code(err) == codes.Unimplemented {
		rp.logger.Debug().
			Str("service_name", rp.check.Name).
			Str("service_type", rp.check.Type).
			Str("agent_name", rp.agentName).
			Msg("Service does not support GetResults - skipping")

		return nil // Skip this service for GetResults
	}

	rp.logger.Error().
		Err(err).
		Str("service_name", rp.check.Name).
		Str("service_type", rp.check.Type).
		Str("agent_name", rp.agentName).
		Str("poller_id", rp.pollerID).
		Msg("GetResults call failed")

	// Convert GetResults failure to ServiceStatus format
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
		Msg("GetResults call completed successfully")
}

func (rp *ResultsPoller) updateSequenceTracking(results *proto.ResultsResponse) {
	if results.CurrentSequence != "" {
		rp.lastSequence = results.CurrentSequence
	}
}

func (rp *ResultsPoller) updateCompletionTracking(results *proto.ResultsResponse) {
	if results.SweepCompletion != nil {
		rp.lastCompletionStatus = results.SweepCompletion
		// Update the poller's aggregated completion tracking
		rp.poller.updateAgentCompletion(rp.agentName, results.SweepCompletion)
		rp.logger.Debug().
			Str("service_name", rp.check.Name).
			Str("agent_name", rp.agentName).
			Str("completion_status", results.SweepCompletion.Status.String()).
			Int32("completed_targets", results.SweepCompletion.CompletedTargets).
			Int32("total_targets", results.SweepCompletion.TotalTargets).
			Msg("Updated completion status from agent response")
	}
}

func (rp *ResultsPoller) shouldSkipCoreSubmission(results *proto.ResultsResponse) bool {
	// If there's no new data AND this is a sweep service, skip sending to core to prevent redundant database writes
	// For other service types, we still send the response for compatibility
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
	return &proto.ServiceStatus{
		ServiceName:  rp.check.Name,
		Available:    results.Available,
		Message:      results.Data,
		ServiceType:  rp.check.Type,
		ResponseTime: results.ResponseTime,
		AgentId:      results.AgentId,
		PollerId:     rp.pollerID,
		Source:       "results",
	}
}
