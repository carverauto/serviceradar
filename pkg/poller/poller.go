// Package poller provides functionality for polling agent status
package poller

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/mfreeman451/homemon/pkg/grpc"
	"github.com/mfreeman451/homemon/proto"
)

var (
	errClosing = errors.New("error closing")
)

// ServiceCheck manages a single service check operation.
type ServiceCheck struct {
	client proto.AgentServiceClient
	check  Check
}

// New creates a new poller instance.
func New(ctx context.Context, config Config) (*Poller, error) {
	client, err := grpc.NewClient(ctx, config.CloudAddress,
		grpc.WithMaxRetries(grpcRetries),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create cloud client: %w", err)
	}

	p := &Poller{
		config:      config,
		cloudClient: proto.NewPollerServiceClient(client.GetConnection()),
		grpcClient:  client,
		agents:      make(map[string]*AgentConnection),
	}

	if err := p.initializeAgentConnections(ctx); err != nil {
		_ = client.Close()
		return nil, fmt.Errorf("failed to initialize agent connections: %w", err)
	}

	return p, nil
}

// getAgentConnection safely retrieves an agent connection.
func (p *Poller) getAgentConnection(agentName string) (*AgentConnection, error) {
	p.mu.RLock()
	defer p.mu.RUnlock()

	agent, exists := p.agents[agentName]
	if !exists {
		return nil, fmt.Errorf("%w: %s", ErrNoConnectionForAgent, agentName)
	}

	return agent, nil
}

// ensureAgentHealth verifies agent health and reconnects if necessary.
func (p *Poller) ensureAgentHealth(ctx context.Context, agentName string, config AgentConfig, agent *AgentConnection) error {
	healthy, err := agent.client.CheckHealth(ctx, "AgentService")
	if err != nil || !healthy {
		if err := p.reconnectAgent(ctx, agentName, config); err != nil {
			return fmt.Errorf("%w: %s (%w)", ErrAgentUnhealthy, agentName, err)
		}
	}

	return nil
}

// processSweepStatus handles sweep status processing.
func (*Poller) processSweepStatus(status *proto.ServiceStatus) error {
	var sweepData SweepData
	if err := json.Unmarshal([]byte(status.Message), &sweepData); err != nil {
		return fmt.Errorf("failed to parse sweep data: %w", err)
	}

	return nil
}

// initializeAgentConnections creates initial connections to all agents.
func (p *Poller) initializeAgentConnections(ctx context.Context) error {
	for agentName, agentConfig := range p.config.Agents {
		client, err := grpc.NewClient(
			ctx,
			agentConfig.Address,
			grpc.WithMaxRetries(grpcRetries),
		)
		if err != nil {
			return fmt.Errorf("failed to connect to agent %s: %w", agentName, err)
		}

		p.agents[agentName] = &AgentConnection{
			client:    client,
			agentName: agentName,
		}
	}

	return nil
}

// reconnectAgent closes the existing connection and creates a new one.
func (p *Poller) reconnectAgent(ctx context.Context, agentName string, config AgentConfig) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	// Close existing connection if it exists
	if agent, exists := p.agents[agentName]; exists {
		if err := agent.client.Close(); err != nil {
			log.Printf("Error closing existing connection for agent %s: %v", agentName, err)
		}
	}

	// Create new connection
	client, err := grpc.NewClient(
		ctx,
		config.Address,
		grpc.WithMaxRetries(grpcRetries),
	)
	if err != nil {
		return fmt.Errorf("failed to reconnect to agent %s: %w", agentName, err)
	}

	p.agents[agentName] = &AgentConnection{
		client:    client,
		agentName: agentName,
	}

	return nil
}

// Start begins the polling loop.
func (p *Poller) Start(ctx context.Context) error {
	ticker := time.NewTicker(time.Duration(p.config.PollInterval))
	defer ticker.Stop()

	log.Printf("Starting poller with interval %v", time.Duration(p.config.PollInterval))

	// Initial poll
	if err := p.poll(ctx); err != nil {
		log.Printf("Error during initial poll: %v", err)
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			if err := p.poll(ctx); err != nil {
				log.Printf("Error during poll: %v", err)
			}
		}
	}
}

// Close closes all connections.
func (p *Poller) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	var errs []error

	// Close cloud client
	if p.grpcClient != nil {
		if err := p.grpcClient.Close(); err != nil {
			errs = append(errs, fmt.Errorf("error closing cloud client: %w", err))
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

func newServiceCheck(client proto.AgentServiceClient, check Check) *ServiceCheck {
	return &ServiceCheck{
		client: client,
		check:  check,
	}
}

func (sc *ServiceCheck) execute(ctx context.Context) *proto.ServiceStatus {
	status, err := sc.client.GetStatus(ctx, &proto.StatusRequest{
		ServiceName: sc.check.Name,
		ServiceType: sc.check.Type,
		Details:     sc.check.Details,
		Port:        sc.check.Port,
	})

	if err != nil {
		return &proto.ServiceStatus{
			ServiceName: sc.check.Name,
			Available:   false,
			Message:     err.Error(),
			ServiceType: sc.check.Type,
		}
	}

	return &proto.ServiceStatus{
		ServiceName: sc.check.Name,
		Available:   status.Available,
		Message:     status.Message,
		ServiceType: sc.check.Type,
	}
}

// AgentPoller manages polling operations for a single agent.
type AgentPoller struct {
	client  proto.AgentServiceClient
	name    string
	config  AgentConfig
	timeout time.Duration
}

func newAgentPoller(name string, config AgentConfig, client proto.AgentServiceClient, timeout time.Duration) *AgentPoller {
	return &AgentPoller{
		name:    name,
		config:  config,
		client:  client,
		timeout: timeout,
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

			svcCheck := newServiceCheck(ap.client, check)
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

// pollAgent polls a single agent.
func (p *Poller) pollAgent(ctx context.Context, agentName string, agentConfig AgentConfig) ([]*proto.ServiceStatus, error) {
	// Get agent connection
	agent, err := p.getAgentConnection(agentName)
	if err != nil {
		return nil, err
	}

	// Ensure agent is healthy
	if err := p.ensureAgentHealth(ctx, agentName, agentConfig, agent); err != nil {
		return nil, err
	}

	// Create agent poller
	client := proto.NewAgentServiceClient(agent.client.GetConnection())
	poller := newAgentPoller(agentName, agentConfig, client, defaultTimeout)

	// Execute checks
	statuses := poller.ExecuteChecks(ctx)

	// Process sweep results if any
	for _, status := range statuses {
		if status.ServiceType == "sweep" && status.Available {
			if err := p.processSweepStatus(status); err != nil {
				log.Printf("Error processing sweep status for agent %s: %v", agentName, err)
			}
		}
	}

	return statuses, nil
}

// poll performs a complete polling cycle across all agents.
func (p *Poller) poll(ctx context.Context) error {
	var allStatuses []*proto.ServiceStatus

	for agentName, agentConfig := range p.config.Agents {
		log.Printf("Polling agent %s...", agentName)

		statuses, err := p.pollAgent(ctx, agentName, agentConfig)
		if err != nil {
			log.Printf("Error polling agent %s: %v", agentName, err)
			continue
		}

		allStatuses = append(allStatuses, statuses...)
	}

	return p.reportToCloud(ctx, allStatuses)
}

func (p *Poller) reportToCloud(ctx context.Context, statuses []*proto.ServiceStatus) error {
	_, err := p.cloudClient.ReportStatus(ctx, &proto.PollerStatusRequest{
		Services:  statuses,
		PollerId:  p.config.PollerID,
		Timestamp: time.Now().Unix(),
	})

	if err != nil {
		return fmt.Errorf("failed to report status to cloud: %w", err)
	}

	return nil
}
