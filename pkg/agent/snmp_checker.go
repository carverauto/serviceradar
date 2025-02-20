package agent

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/checker"
	"github.com/mfreeman451/serviceradar/pkg/checker/snmp"
	"github.com/mfreeman451/serviceradar/pkg/config"
	"github.com/mfreeman451/serviceradar/pkg/grpc"
	"github.com/mfreeman451/serviceradar/proto"
)

const (
	defaultConfigPath = "/etc/serviceradar/checkers"
	defaultInterval   = 60 * time.Second
	pollTimeout       = 5 * time.Second
	grpcRetries       = 3
)

// SNMPChecker implements the checker.Checker interface for SNMP monitoring
type SNMPChecker struct {
	config      *snmp.Config
	client      *grpc.ClientConn
	agentClient proto.AgentServiceClient
	interval    time.Duration
	mu          sync.RWMutex
	wg          sync.WaitGroup
	done        chan struct{}
}

// NewSNMPChecker creates a new SNMP checker that connects to an external SNMP checker process
func NewSNMPChecker(address string) (checker.Checker, error) {
	log.Printf("Creating new SNMP checker client for address: %s", address)

	// Load configuration
	configPath := filepath.Join(defaultConfigPath, "snmp.json")
	if _, err := os.Stat(configPath); err != nil {
		return nil, fmt.Errorf("config file error: %w", err)
	}

	var cfg snmp.Config
	if err := config.LoadAndValidate(configPath, &cfg); err != nil {
		return nil, fmt.Errorf("failed to load SNMP config: %w", err)
	}

	// Create gRPC client connection to the SNMP checker process
	client, err := grpc.NewClient(
		context.Background(),
		address,
		grpc.WithMaxRetries(grpcRetries),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create gRPC client: %w", err)
	}

	// Create agent service client
	agentClient := proto.NewAgentServiceClient(client.GetConnection())

	// Create checker instance
	c := &SNMPChecker{
		config:      &cfg,
		client:      client,
		agentClient: agentClient,
		interval:    defaultInterval,
		done:        make(chan struct{}),
	}

	return c, nil
}

// Check implements the checker.Checker interface
func (c *SNMPChecker) Check(ctx context.Context) (bool, string) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	// Create check request
	req := &proto.StatusRequest{
		ServiceType: "snmp",
		ServiceName: "snmp",
	}

	// Get status through agent service
	resp, err := c.agentClient.GetStatus(ctx, req)
	if err != nil {
		log.Printf("Failed to get SNMP status: %v", err)
		return false, fmt.Sprintf("Failed to get status: %v", err)
	}

	return resp.Available, resp.Message
}

// Start begins health checking of the SNMP service
func (c *SNMPChecker) Start(ctx context.Context) error {
	// Start health checking loop
	c.wg.Add(1)
	go c.healthCheckLoop(ctx)

	log.Printf("Started SNMP checker monitoring")
	return nil
}

// Stop gracefully shuts down the checker
func (c *SNMPChecker) Stop(ctx context.Context) error {
	log.Printf("Stopping SNMP checker...")

	// Signal health check loop to stop
	close(c.done)

	// Wait for health checking to complete with timeout
	done := make(chan struct{})
	go func() {
		c.wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		log.Printf("SNMP checker monitoring stopped")
	case <-ctx.Done():
		return fmt.Errorf("timeout waiting for SNMP checker to stop: %w", ctx.Err())
	}

	// Close gRPC client
	if err := c.client.Close(); err != nil {
		return fmt.Errorf("failed to close gRPC client: %w", err)
	}

	return nil
}

// healthCheckLoop runs the main health checking loop
func (c *SNMPChecker) healthCheckLoop(ctx context.Context) {
	defer c.wg.Done()

	ticker := time.NewTicker(c.interval)
	defer ticker.Stop()

	// Do initial health check
	if err := c.checkHealth(ctx); err != nil {
		log.Printf("Initial SNMP health check failed: %v", err)
	}

	for {
		select {
		case <-ctx.Done():
			log.Printf("Context cancelled, stopping SNMP health checks")
			return
		case <-c.done:
			log.Printf("Received stop signal, stopping SNMP health checks")
			return
		case <-ticker.C:
			if err := c.checkHealth(ctx); err != nil {
				log.Printf("SNMP health check failed: %v", err)
			}
		}
	}
}

// checkHealth performs a single health check
func (c *SNMPChecker) checkHealth(ctx context.Context) error {
	// Create timeout context for this check
	checkCtx, cancel := context.WithTimeout(ctx, time.Duration(c.config.Timeout))
	defer cancel()

	// Check if the SNMP service is healthy
	healthy, err := c.client.CheckHealth(checkCtx, "")
	if err != nil {
		return fmt.Errorf("health check failed: %w", err)
	}

	if !healthy {
		return fmt.Errorf("SNMP service reported unhealthy")
	}

	log.Printf("SNMP service health check passed")

	return nil
}
