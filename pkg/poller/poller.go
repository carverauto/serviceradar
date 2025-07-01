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
	"log"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

const (
	grpcRetries    = 3
	defaultTimeout = 30 * time.Second
	stopTimeout    = 10 * time.Second
)

// New creates a new poller instance.
func New(ctx context.Context, config *Config, clock Clock) (*Poller, error) {
	if clock == nil {
		clock = realClock{}
	}

	p := &Poller{
		config: *config,
		agents: make(map[string]*AgentConnection),
		done:   make(chan struct{}),
		clock:  clock,
	}

	// Only connect to core if CoreAddress is set and PollFunc isn’t overriding default behavior
	if p.config.CoreAddress != "" && p.PollFunc == nil {
		if err := p.connectToCore(ctx); err != nil {
			return nil, fmt.Errorf("failed to connect to core service: %w", err)
		}
	}

	// Initialize agent connections only if not using PollFunc exclusively
	if p.PollFunc == nil {
		if err := p.initializeAgentConnections(ctx); err != nil {
			_ = p.grpcClient.Close()

			return nil, fmt.Errorf("failed to initialize agent connections: %w", err)
		}
	}

	return p, nil
}

// Start implements the lifecycle.Service interface.
func (p *Poller) Start(ctx context.Context) error {
	interval := time.Duration(p.config.PollInterval)

	ticker := p.clock.Ticker(interval)
	defer ticker.Stop()

	log.Printf("Starting poller with interval %v", interval)

	p.startWg.Add(1) // Track Start goroutine
	defer p.startWg.Done()

	p.wg.Add(1)
	defer p.wg.Done()

	// Initial poll
	if err := p.poll(ctx); err != nil {
		log.Printf("Error during initial poll: %v", err)
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
					log.Printf("Error during poll: %v", err)
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
			log.Printf("Error closing core client: %v", err)
		}
	}

	// Wait for any active agent connections to finish
	for name, agent := range p.agents {
		if agent.client != nil {
			if err := agent.client.Close(); err != nil {
				log.Printf("Error closing agent connection %s: %v", name, err)
			}
		}
	}

	// Clear the maps to prevent any lingering references
	p.agents = make(map[string]*AgentConnection)
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
	for name, agent := range p.agents {
		if agent.client != nil {
			if err := agent.client.Close(); err != nil {
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
	timeout time.Duration,
	poller *Poller) *AgentPoller {
	return &AgentPoller{
		name:    name,
		config:  config,
		client:  client,
		timeout: timeout,
		poller:  poller,
	}
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

			svcCheck := newServiceCheck(ap.client, check, ap.poller.config.PollerID, ap.name)
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

func newServiceCheck(client proto.AgentServiceClient, check Check, pollerID, agentName string) *ServiceCheck {
	return &ServiceCheck{
		client:    client,
		check:     check,
		pollerID:  pollerID,
		agentName: agentName,
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

	log.Printf("Sending StatusRequest: %+v", req)

	status, err := sc.client.GetStatus(ctx, req)
	if err != nil {
		log.Printf("Service check failed for %s: %v", sc.check.Name, err)

		msg := "Service check failed"

		message, err := json.Marshal(map[string]string{"error": msg})
		if err != nil {
			log.Printf("Failed to marshal error message: %v", err)

			message = []byte(msg) // Fallback to plain string if marshal fails
		}

		return &proto.ServiceStatus{
			ServiceName: sc.check.Name,
			Available:   false,
			Message:     message,
			ServiceType: sc.check.Type,
			PollerId:    sc.pollerID,
		}
	}

	log.Printf("Received StatusResponse from %v: available=%v, message=%s, type=%s",
		sc.check.Name,
		status.Available,
		status.Message,
		status.ServiceType,
	)

	return &proto.ServiceStatus{
		ServiceName:  sc.check.Name,
		Available:    status.Available,
		Message:      status.Message,
		ServiceType:  sc.check.Type,
		ResponseTime: status.ResponseTime,
		AgentId:      status.AgentId,
		PollerId:     sc.pollerID,
	}
}

// Connection management methods.
func (p *Poller) getAgentConnection(agentName string) (*AgentConnection, error) {
	p.mu.RLock()
	defer p.mu.RUnlock()

	agent, exists := p.agents[agentName]
	if !exists {
		return nil, fmt.Errorf("%w: %s", ErrNoConnectionForAgent, agentName)
	}

	return agent, nil
}

func (p *Poller) ensureAgentHealth(ctx context.Context, agentName string, config *AgentConfig, agent *AgentConnection) error {
	healthy, err := agent.client.CheckHealth(ctx, "AgentService")
	if err != nil || !healthy {
		if err := p.reconnectAgent(ctx, agentName, config); err != nil {
			return fmt.Errorf("%w: %s (%w)", ErrAgentUnhealthy, agentName, err)
		}
	}

	return nil
}

func (p *Poller) reconnectAgent(ctx context.Context, agentName string, config *AgentConfig) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	// Close existing connection if it exists
	if agent, exists := p.agents[agentName]; exists {
		if err := agent.client.Close(); err != nil {
			log.Printf("Error closing existing connection for agent %s: %v", agentName, err)
		}
	}

	// Use ClientConfig instead of ConnectionConfig
	clientCfg := grpc.ClientConfig{
		Address:    config.Address,
		MaxRetries: grpcRetries,
	}

	if p.config.Security != nil {
		provider, err := grpc.NewSecurityProvider(ctx, p.config.Security)
		if err != nil {
			return fmt.Errorf("failed to create security provider: %w", err)
		}

		clientCfg.SecurityProvider = provider
	}

	log.Printf("Reconnecting to agent %s at %s", agentName, config.Address)

	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		return fmt.Errorf("failed to reconnect to agent %s: %w", agentName, err)
	}

	p.agents[agentName] = &AgentConnection{
		client:       client,
		agentName:    agentName,
		healthClient: healthpb.NewHealthClient(client.GetConnection()),
	}

	return nil
}

func (p *Poller) connectToCore(ctx context.Context) error {
	// Use ClientConfig instead of ConnectionConfig
	clientCfg := grpc.ClientConfig{
		Address:    p.config.CoreAddress,
		MaxRetries: grpcRetries,
	}

	if p.config.Security != nil {
		provider, err := grpc.NewSecurityProvider(ctx, p.config.Security)
		if err != nil {
			return fmt.Errorf("failed to create security provider: %w", err)
		}

		clientCfg.SecurityProvider = provider
	}

	log.Printf("Connecting to core service at %s", p.config.CoreAddress)

	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		return fmt.Errorf("failed to create core client: %w", err)
	}

	p.grpcClient = client
	p.coreClient = proto.NewPollerServiceClient(client.GetConnection())

	return nil
}

func (p *Poller) initializeAgentConnections(ctx context.Context) error {
	for agentName := range p.config.Agents {
		agentConfig := p.config.Agents[agentName]

		// Use ClientConfig instead of ConnectionConfig
		clientCfg := grpc.ClientConfig{
			Address:    agentConfig.Address,
			MaxRetries: grpcRetries,
		}

		if p.config.Security != nil {
			provider, err := grpc.NewSecurityProvider(ctx, p.config.Security)
			if err != nil {
				return fmt.Errorf("failed to create security provider for agent %s: %w", agentName, err)
			}

			clientCfg.SecurityProvider = provider
		}

		log.Printf("Connecting to agent %s at %s", agentName, agentConfig.Address)

		client, err := grpc.NewClient(ctx, clientCfg)
		if err != nil {
			return fmt.Errorf("failed to connect to agent %s: %w", agentName, err)
		}

		p.agents[agentName] = &AgentConnection{
			client:       client,
			agentName:    agentName,
			healthClient: healthpb.NewHealthClient(client.GetConnection()),
		}
	}

	return nil
}

// Poll execution methods.
func (p *Poller) poll(ctx context.Context) error {
	if p.PollFunc != nil {
		return p.PollFunc(ctx)
	}

	var allStatuses []*proto.ServiceStatus

	for agentName := range p.config.Agents {
		agentConfig := p.config.Agents[agentName]

		conn, err := p.getAgentConnection(agentName)
		if err != nil {
			if err = p.reconnectAgent(ctx, agentName, &agentConfig); err != nil {
				log.Printf("Failed to reconnect to agent %s: %v", agentName, err)
				continue
			}

			conn, _ = p.getAgentConnection(agentName)
		}

		// Check health before polling
		healthy, err := conn.client.CheckHealth(ctx, "AgentService")
		if err != nil || !healthy {
			if err = p.reconnectAgent(ctx, agentName, &agentConfig); err != nil {
				log.Printf("Agent %s unhealthy: %v", agentName, err)

				continue
			}
		}

		statuses, err := p.pollAgent(ctx, agentName, &agentConfig)
		if err != nil {
			log.Printf("Error polling agent %s: %v", agentName, err)

			continue
		}

		allStatuses = append(allStatuses, statuses...)
	}

	return p.reportToCore(ctx, allStatuses)
}

func (p *Poller) pollAgent(
	ctx context.Context,
	agentName string,
	agentConfig *AgentConfig) ([]*proto.ServiceStatus, error) {
	agent, err := p.getAgentConnection(agentName)
	if err != nil {
		return nil, err
	}

	if err := p.ensureAgentHealth(ctx, agentName, agentConfig, agent); err != nil {
		return nil, err
	}

	client := proto.NewAgentServiceClient(agent.client.GetConnection())
	poller := newAgentPoller(agentName, agentConfig, client, defaultTimeout, p)

	statuses := poller.ExecuteChecks(ctx)

	return statuses, nil
}

func (p *Poller) reportToCore(ctx context.Context, statuses []*proto.ServiceStatus) error {
	log.Printf("Reporting %d statuses for poller %s at %s",
		len(statuses), p.config.PollerID, time.Now().Format(time.RFC3339Nano))

	// Add PollerID to each ServiceStatus if missing
	for i, status := range statuses {
		// Add the poller ID to each status
		status.PollerId = p.config.PollerID

		// add the partition to each status
		status.Partition = p.config.Partition

		// Determine the correct AgentID to use - prefer response AgentId, fall back to configured agent name
		agentID := status.AgentId
		if agentID == "" {
			log.Printf("Warning: AgentID empty in response for service %s, using configured agent name as fallback", status.ServiceName)
			// We need to extract this from the service status creation context
			// For now, we'll handle this in the enhancement function
		}

		// Enhance ALL service responses with infrastructure identity
		enhancedMessage, err := p.enhanceServicePayload(string(status.Message), agentID, status.Partition, status.ServiceType, status.ServiceName)
		if err != nil {
			log.Printf("Warning: Failed to enhance payload for service %s: %v", status.ServiceName, err)
		} else {
			status.Message = []byte(enhancedMessage)
		}

		log.Printf("Partition: %s, PollerID: %s, ServiceName: %s, AgentID: %s",
			status.Partition, status.PollerId, status.ServiceName, status.AgentId)

		// Log warning if AgentID is missing (debugging aid)
		if status.AgentId == "" {
			log.Printf("Warning: ServiceStatus[%d] for %s has empty AgentID",
				i, status.ServiceName)
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
		log.Printf("SNMP original message: AgentID='%s', Message='%s'", agentID, originalMessage)
	}
	
	// Validate and normalize the original message to ensure it's valid JSON
	var serviceData json.RawMessage
	
	// Try to parse original message as JSON
	if originalMessage == "" {
		// Empty message - use empty JSON object
		log.Printf("Warning: Empty message for service %s/%s", serviceType, serviceName)
		serviceData = json.RawMessage("{}")
	} else if json.Valid([]byte(originalMessage)) {
		// Valid JSON - use as-is
		serviceData = json.RawMessage(originalMessage)
	} else {
		// Invalid JSON (likely plain text error) - wrap in JSON object
		log.Printf("Warning: Invalid JSON for service %s/%s, wrapping: %s", serviceType, serviceName, originalMessage)
		errorWrapper := map[string]string{"message": originalMessage}
		wrappedJSON, err := json.Marshal(errorWrapper)
		if err != nil {
			return "", fmt.Errorf("failed to wrap non-JSON message: %w", err)
		}
		serviceData = json.RawMessage(wrappedJSON)
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
