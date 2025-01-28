// Package poller pkg/poller/poller.go

package poller

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/grpc"
	"github.com/mfreeman451/serviceradar/proto"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

const (
	grpcRetries    = 3
	defaultTimeout = 30 * time.Second
)

var (
	ErrInvalidDuration      = fmt.Errorf("invalid duration")
	ErrNoConnectionForAgent = fmt.Errorf("no connection found for agent")
	ErrAgentUnhealthy       = fmt.Errorf("agent is unhealthy")
	errClosing              = errors.New("error closing")
)

// AgentConnection represents a connection to an agent.
type AgentConnection struct {
	client       *grpc.ClientConn
	agentName    string
	healthClient healthpb.HealthClient
}

// Poller represents the monitoring poller.
type Poller struct {
	proto.UnimplementedPollerServiceServer
	config      Config
	cloudClient proto.PollerServiceClient
	grpcClient  *grpc.ClientConn
	mu          sync.RWMutex
	agents      map[string]*AgentConnection
}

// ServiceCheck manages a single service check operation.
type ServiceCheck struct {
	client proto.AgentServiceClient
	check  Check
}

// New creates a new poller instance.
func New(ctx context.Context, config *Config) (*Poller, error) {
	// Set up the poller -> cloud gRPC connection
	client, err := grpc.NewClient(ctx, config.CloudAddress,
		grpc.WithMaxRetries(grpcRetries),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create cloud client: %w", err)
	}

	p := &Poller{
		config:      *config,
		cloudClient: proto.NewPollerServiceClient(client.GetConnection()),
		grpcClient:  client,
		agents:      make(map[string]*AgentConnection),
	}

	// Initialize agent connections
	if err := p.initializeAgentConnections(ctx); err != nil {
		_ = client.Close()
		return nil, fmt.Errorf("failed to initialize agent connections: %w", err)
	}

	return p, nil
}

// Duration is a wrapper around time.Duration for JSON unmarshaling.
type Duration time.Duration

func (d *Duration) UnmarshalJSON(b []byte) error {
	var v interface{}
	if err := json.Unmarshal(b, &v); err != nil {
		return err
	}

	switch value := v.(type) {
	case float64:
		*d = Duration(time.Duration(value))
	case string:
		tmp, err := time.ParseDuration(value)
		if err != nil {
			return err
		}

		*d = Duration(tmp)
	default:
		return ErrInvalidDuration
	}

	return nil
}

// Start implements the lifecycle.Service interface.
func (p *Poller) Start(ctx context.Context) error {
	interval := time.Duration(p.config.PollInterval)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	log.Printf("Starting poller with interval %v", interval)

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

// Stop implements the lifecycle.Service interface.
func (p *Poller) Stop() error {
	return p.Close()
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

func newServiceCheck(client proto.AgentServiceClient, check Check) *ServiceCheck {
	return &ServiceCheck{
		client: client,
		check:  check,
	}
}

func (sc *ServiceCheck) execute(ctx context.Context) *proto.ServiceStatus {
	req := &proto.StatusRequest{
		ServiceName: sc.check.Name,
		ServiceType: sc.check.Type,
		Details:     sc.check.Details,
	}

	if sc.check.Type == "port" {
		req.Port = sc.check.Port
	}

	log.Printf("Sending StatusRequest: %+v", req)

	status, err := sc.client.GetStatus(ctx, req)
	if err != nil {
		return &proto.ServiceStatus{
			ServiceName: sc.check.Name,
			Available:   false,
			Message:     err.Error(),
			ServiceType: sc.check.Type,
		}
	}

	// Pass through response_time from the service check
	return &proto.ServiceStatus{
		ServiceName:  sc.check.Name,
		Available:    status.Available,
		Message:      status.Message,
		ServiceType:  sc.check.Type,
		ResponseTime: status.ResponseTime,
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

func (p *Poller) ensureAgentHealth(ctx context.Context, agentName string, config AgentConfig, agent *AgentConnection) error {
	healthy, err := agent.client.CheckHealth(ctx, "AgentService")
	if err != nil || !healthy {
		if err := p.reconnectAgent(ctx, agentName, config); err != nil {
			return fmt.Errorf("%w: %s (%w)", ErrAgentUnhealthy, agentName, err)
		}
	}

	return nil
}

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
		client:       client,
		agentName:    agentName,
		healthClient: healthpb.NewHealthClient(client.GetConnection()),
	}

	return nil
}

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
			client:       client,
			agentName:    agentName,
			healthClient: healthpb.NewHealthClient(client.GetConnection()),
		}
	}

	return nil
}

// Poll execution methods.
func (p *Poller) poll(ctx context.Context) error {
	var allStatuses []*proto.ServiceStatus

	for agentName, agentConfig := range p.config.Agents {
		conn, err := p.getAgentConnection(agentName)
		if err != nil {
			if err = p.reconnectAgent(ctx, agentName, agentConfig); err != nil {
				log.Printf("Failed to reconnect to agent %s: %v", agentName, err)

				continue
			}

			conn, _ = p.getAgentConnection(agentName)
		}

		// Check health before polling
		healthy, err := conn.client.CheckHealth(ctx, "AgentService")
		if err != nil || !healthy {
			if err = p.reconnectAgent(ctx, agentName, agentConfig); err != nil {
				log.Printf("Agent %s unhealthy: %v", agentName, err)

				continue
			}
		}

		statuses, err := p.pollAgent(ctx, agentName, agentConfig)
		if err != nil {
			log.Printf("Error polling agent %s: %v", agentName, err)

			continue
		}

		allStatuses = append(allStatuses, statuses...)
	}

	return p.reportToCloud(ctx, allStatuses)
}

func (p *Poller) pollAgent(ctx context.Context, agentName string, agentConfig AgentConfig) ([]*proto.ServiceStatus, error) {
	agent, err := p.getAgentConnection(agentName)
	if err != nil {
		return nil, err
	}

	if err := p.ensureAgentHealth(ctx, agentName, agentConfig, agent); err != nil {
		return nil, err
	}

	client := proto.NewAgentServiceClient(agent.client.GetConnection())
	poller := newAgentPoller(agentName, agentConfig, client, defaultTimeout)

	statuses := poller.ExecuteChecks(ctx)

	if err := p.processSweepData(statuses); err != nil {
		log.Printf("Error processing sweep data: %v", err)
	}

	return statuses, nil
}

func (p *Poller) processSweepData(statuses []*proto.ServiceStatus) error {
	for _, status := range statuses {
		if status.ServiceType == "sweep" && status.Available {
			if err := p.processSweepStatus(status); err != nil {
				return err
			}
		}
	}

	return nil
}

func (*Poller) processSweepStatus(status *proto.ServiceStatus) error {
	var sweepData map[string]interface{}
	if err := json.Unmarshal([]byte(status.Message), &sweepData); err != nil {
		return fmt.Errorf("error parsing sweep data: %w", err)
	}

	if hosts, ok := sweepData["hosts"].([]interface{}); ok {
		for _, h := range hosts {
			if host, ok := h.(map[string]interface{}); ok {
				if icmpStatus, ok := host["icmp_status"].(map[string]interface{}); ok {
					log.Printf("Forwarding ICMP data for host %v: %+v", host["host"], icmpStatus)
				}
			}
		}
	}

	return nil
}

func (p *Poller) reportToCloud(ctx context.Context, statuses []*proto.ServiceStatus) error {
	log.Printf("Reporting to cloud: PollerID=%s, Timestamp=%d, Services=%d", p.config.PollerID, time.Now().Unix(), len(statuses))

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
