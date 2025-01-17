// Package poller pkg/poller/poller.go
package poller

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/mfreeman451/homemon/pkg/grpc"
	"github.com/mfreeman451/homemon/proto"
)

const (
	grpcRetries    = 3
	defaultTimeout = 30 * time.Second
)

var (
	ErrInvalidDuration      = fmt.Errorf("invalid duration")
	ErrNoConnectionForAgent = fmt.Errorf("no connection found for agent")
	ErrAgentUnhealthy       = fmt.Errorf("agent is unhealthy")
)

type SweepData struct {
	Network        string       `json:"network"`
	TotalHosts     int32        `json:"total_hosts"`
	AvailableHosts int32        `json:"available_hosts"`
	LastSweep      int64        `json:"last_sweep"`
	Ports          []PortStatus `json:"ports"`
}

type PortStatus struct {
	Port      int32 `json:"port"`
	Available int32 `json:"available"`
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

// Check represents a service check configuration.
type Check struct {
	Type    string `json:"service_type"`
	Name    string `json:"service_name"`
	Details string `json:"details,omitempty"`
	Port    int32  `json:"port,omitempty"`
}

// AgentConfig represents configuration for a single agent.
type AgentConfig struct {
	Address string  `json:"address"`
	Checks  []Check `json:"checks"`
}

// Config represents the poller configuration.
type Config struct {
	Agents       map[string]AgentConfig `json:"agents"`
	CloudAddress string                 `json:"cloud_address"`
	PollInterval Duration               `json:"poll_interval"`
	PollerID     string                 `json:"poller_id"`
}

// AgentConnection represents a connection to an agent.
type AgentConnection struct {
	client    *grpc.ClientConn
	agentName string
}

// Poller represents the monitoring poller.
type Poller struct {
	config      Config
	cloudClient proto.PollerServiceClient
	grpcClient  *grpc.ClientConn
	mu          sync.RWMutex
	agents      map[string]*AgentConnection
}

func New(ctx context.Context, config Config) (*Poller, error) {
	// Create gRPC client connection
	client, err := grpc.NewClient(ctx, config.CloudAddress,
		grpc.WithMaxRetries(grpcRetries),
	)
	if err != nil {
		return nil, err
	}

	p := &Poller{
		config:      config,
		cloudClient: proto.NewPollerServiceClient(client.GetConnection()),
		grpcClient:  client,
		agents:      make(map[string]*AgentConnection),
	}

	// Initialize connections to all agents
	if err := p.initializeAgentConnections(ctx); err != nil {
		err := client.Close()
		if err != nil {
			return nil, err
		}

		return nil, fmt.Errorf("failed to initialize agent connections: %w", err)
	}

	return p, nil
}

// initializeAgentConnections creates connections to all agents.
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

// pollAgent polls a single agent.
func (p *Poller) pollAgent(ctx context.Context, agentName string, agentConfig AgentConfig) ([]*proto.ServiceStatus, error) {
	p.mu.RLock()
	agent, exists := p.agents[agentName]
	p.mu.RUnlock()

	if !exists {
		return nil, fmt.Errorf("pollAgent error: %q - %w", agentName, ErrNoConnectionForAgent)
	}

	// Check agent health first
	healthy, err := agent.client.CheckHealth(ctx, "AgentService")
	if err != nil || !healthy {
		// Try to reconnect
		if err := p.reconnectAgent(ctx, agentName, agentConfig); err != nil {
			return nil, fmt.Errorf("pollAgent error: %q - %w", agentName, ErrAgentUnhealthy)
		}
	}

	client := proto.NewAgentServiceClient(agent.client.GetConnection())
	statuses := make([]*proto.ServiceStatus, 0, len(agentConfig.Checks))

	// Create a channel for collecting results
	results := make(chan *proto.ServiceStatus, len(agentConfig.Checks))
	errors := make(chan error, len(agentConfig.Checks))

	// Create a context with timeout for the checks
	checkCtx, cancel := context.WithTimeout(ctx, defaultTimeout)
	defer cancel()

	// Launch goroutine for each check
	var wg sync.WaitGroup
	for _, check := range agentConfig.Checks {
		wg.Add(1)

		go func(check Check) {
			defer wg.Done()

			status, err := client.GetStatus(checkCtx, &proto.StatusRequest{
				ServiceName: check.Name,
				ServiceType: check.Type,
				Details:     check.Details,
				Port:        check.Port,
			})

			if err != nil {
				errors <- fmt.Errorf("error checking %s: %w", check.Type, err)
				results <- &proto.ServiceStatus{
					ServiceName: check.Name,
					Available:   false,
					Message:     err.Error(),
					ServiceType: check.Type,
				}

				return
			}

			results <- &proto.ServiceStatus{
				ServiceName: check.Name,
				Available:   status.Available,
				Message:     status.Message,
				ServiceType: check.Type,
			}

			// Handle sweep service status specially
			if check.Type == "sweep" {
				if err := p.handleSweepStatus(status, results); err != nil {
					errors <- fmt.Errorf("error handling sweep status: %w", err)
				}
				return
			}

			results <- &proto.ServiceStatus{
				ServiceName: check.Name,
				Available:   status.Available,
				Message:     status.Message,
				ServiceType: check.Type,
			}
		}(check)
	}

	// Wait for all checks to complete or context to cancel
	go func() {
		wg.Wait()
		close(results)
		close(errors)
	}()

	// Collect results
	for status := range results {
		statuses = append(statuses, status)
	}

	// Log any errors
	for err := range errors {
		log.Printf("Error polling agent %s: %v", agentName, err)
	}

	return statuses, nil
}

// handleSweepStatus processes sweep service results
func (p *Poller) handleSweepStatus(status *proto.StatusResponse, results chan<- *proto.ServiceStatus) error {
	// Parse sweep data from message
	var sweepData SweepData
	if err := json.Unmarshal([]byte(status.Message), &sweepData); err != nil {
		return fmt.Errorf("failed to parse sweep data: %w", err)
	}

	// Create service status with sweep data
	results <- &proto.ServiceStatus{
		ServiceName: "network_sweep",
		ServiceType: "sweep",
		Available:   status.Available,
		Message:     status.Message, // Keep original JSON for cloud processing
	}

	return nil
}

// reconnectAgent closes the existing connection and creates a new one.
func (p *Poller) reconnectAgent(ctx context.Context, agentName string, config AgentConfig) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	// Close existing connection if it exists
	if agent, exists := p.agents[agentName]; exists {
		err := agent.client.Close()
		if err != nil {
			return err
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

// poll performs a single poll cycle.
func (p *Poller) poll(ctx context.Context) error {
	log.Printf("Starting poll cycle...")

	allStatuses := make([]*proto.ServiceStatus, 0)

	for agentName, agentConfig := range p.config.Agents {
		log.Printf("Polling agent %s...", agentName)

		statuses, err := p.pollAgent(ctx, agentName, agentConfig)
		if err != nil {
			log.Printf("Error polling agent %s: %v", agentName, err)
			continue
		}

		// Log each service status
		for _, status := range statuses {
			log.Printf("Agent %s service %s status: available=%v message=%s",
				agentName, status.ServiceName, status.Available, status.Message)
		}

		allStatuses = append(allStatuses, statuses...)
	}

	log.Printf("Reporting status to cloud service...")

	_, err := p.cloudClient.ReportStatus(ctx, &proto.PollerStatusRequest{
		Services:  allStatuses,
		PollerId:  p.config.PollerID,
		Timestamp: time.Now().Unix(),
	})

	if err != nil {
		return fmt.Errorf("failed to report status: %w", err)
	}

	log.Printf("Poll cycle completed successfully")

	return nil
}

// Start begins the polling loop.
func (p *Poller) Start(ctx context.Context) error {
	ticker := time.NewTicker(time.Duration(p.config.PollInterval))
	defer ticker.Stop()

	log.Printf("Starting poller with interval %v", time.Duration(p.config.PollInterval))

	// Do an initial poll immediately
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

	// Close cloud client
	if p.grpcClient != nil {
		err := p.grpcClient.Close()
		if err != nil {
			return err
		}
	}

	// Close all agent connections
	for _, agent := range p.agents {
		if agent.client != nil {
			err := agent.client.Close()
			if err != nil {
				return err
			}
		}
	}

	return nil
}
