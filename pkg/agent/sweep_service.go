// Package agent pkg/agent/sweep_service.go
package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/mfreeman451/homemon/pkg/sweeper"
	"github.com/mfreeman451/homemon/proto"
)

type SweepService struct {
	sweeper sweeper.Sweeper
	mu      sync.RWMutex
	closed  chan struct{}
	config  sweeper.Config
	results []sweeper.Result
}

// NewSweepService creates a new sweep service.
func NewSweepService(config sweeper.Config) (*SweepService, error) {
	// Create network sweeper instance
	sw := sweeper.NewNetworkSweeper(config)

	return &SweepService{
		sweeper: sw,
		closed:  make(chan struct{}),
		config:  config,
		results: make([]sweeper.Result, 0),
	}, nil
}

func (s *SweepService) Start(ctx context.Context) error {
	log.Printf("Starting sweep service with config: %+v", s.config)
	return s.sweeper.Start(ctx)
}

func (s *SweepService) Stop() error {
	close(s.closed)
	return s.sweeper.Stop()
}

func (s *SweepService) GetStatus(ctx context.Context) (*proto.StatusResponse, error) {
	if s == nil {
		return &proto.StatusResponse{
			Available:   false,
			Message:     "Sweep service not initialized",
			ServiceName: "network_sweep",
			ServiceType: "sweep",
		}, nil
	}

	// Get latest results
	results, err := s.sweeper.GetResults(ctx, &sweeper.ResultFilter{
		StartTime: time.Now().Add(-s.config.Interval),
	})
	if err != nil {
		return nil, fmt.Errorf("failed to get sweep results: %w", err)
	}

	// Aggregate results
	portCounts := make(map[int]int)
	hostsSeen := make(map[string]bool)
	hostsAvailable := make(map[string]bool)

	for _, result := range results {
		hostsSeen[result.Target.Host] = true
		if result.Available {
			hostsAvailable[result.Target.Host] = true
			portCounts[result.Target.Port]++
		}
	}

	// Create sweep status
	status := map[string]interface{}{
		"network":         s.config.Networks[0],
		"total_hosts":     len(hostsSeen),
		"available_hosts": len(hostsAvailable),
		"last_sweep":      time.Now().Unix(),
		"ports":           make([]map[string]interface{}, 0, len(portCounts)),
	}

	for port, count := range portCounts {
		status["ports"] = append(status["ports"].([]map[string]interface{}), map[string]interface{}{
			"port":      port,
			"available": count,
		})
	}

	// Convert to JSON for the message field
	statusJSON, err := json.Marshal(status)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal sweep status: %w", err)
	}

	return &proto.StatusResponse{
		Available:   true,
		Message:     string(statusJSON),
		ServiceName: "network_sweep",
		ServiceType: "sweep",
	}, nil
}

// UpdateConfig updates the sweep configuration.
func (s *SweepService) UpdateConfig(config sweeper.Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.config = config

	return s.sweeper.UpdateConfig(config)
}

// Close implements io.Closer.
func (s *SweepService) Close() error {
	return s.Stop()
}
