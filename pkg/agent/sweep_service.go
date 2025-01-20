// Package agent pkg/agent/sweep_service.go
package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/mfreeman451/serviceradar/pkg/sweeper"
	"github.com/mfreeman451/serviceradar/proto"
)

// SweepService implements sweeper.SweepService and provides network scanning capabilities.
type SweepService struct {
	scanner   sweeper.Scanner
	store     sweeper.Store
	processor sweeper.ResultProcessor
	mu        sync.RWMutex
	closed    chan struct{}
	config    *models.Config
}

// NewSweepService creates a new sweep service with default configuration.
func NewSweepService(config *models.Config) (*SweepService, error) {
	// Apply default configuration
	config = applyDefaultConfig(config)

	log.Printf("Creating sweep service with config: %+v", config)

	// Create components
	scanner := sweeper.NewCombinedScanner(config.Timeout, config.Concurrency, config.ICMPCount)
	store := sweeper.NewInMemoryStore()
	processor := sweeper.NewDefaultProcessor()

	return &SweepService{
		scanner:   scanner,
		store:     store,
		processor: processor,
		closed:    make(chan struct{}),
		config:    config,
	}, nil
}

func applyDefaultConfig(config *models.Config) *models.Config {
	// Ensure we have default sweep modes
	if len(config.SweepModes) == 0 {
		config.SweepModes = []models.SweepMode{
			models.ModeTCP,
			models.ModeICMP,
		}
	}

	// Set reasonable defaults
	if config.Timeout == 0 {
		config.Timeout = 2 * time.Second
	}

	if config.Concurrency == 0 {
		config.Concurrency = 100
	}

	if config.ICMPCount == 0 {
		config.ICMPCount = 3
	}

	return config
}

func (s *SweepService) Start(ctx context.Context) error {
	log.Printf("Starting sweep service with config: %+v", s.config)

	// Start periodic sweeps
	go s.sweepLoop(ctx)

	return nil
}

func (s *SweepService) sweepLoop(ctx context.Context) {
	ticker := time.NewTicker(s.config.Interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-s.closed:
			return
		case <-ticker.C:
			if err := s.performSweep(ctx); err != nil {
				log.Printf("Error during sweep: %v", err)
			}
		}
	}
}

func (s *SweepService) performSweep(ctx context.Context) error {
	// Generate targets based on configuration
	targets, err := generateTargets(s.config)
	if err != nil {
		return fmt.Errorf("failed to generate targets: %w", err)
	}

	// Reset processor state
	s.processor.Reset()

	// Start the scan
	results, err := s.scanner.Scan(ctx, targets)
	if err != nil {
		return fmt.Errorf("scan failed: %w", err)
	}

	// Process results as they come in
	for result := range results {
		// Store the result
		if err := s.store.SaveResult(ctx, &result); err != nil {
			log.Printf("Failed to save result: %v", err)
			continue
		}

		// Process the result
		if err := s.processor.Process(&result); err != nil {
			log.Printf("Failed to process result: %v", err)
			continue
		}
	}

	return nil
}

func (s *SweepService) Stop() error {
	close(s.closed)
	return s.scanner.Stop()
}

// identifyService maps common port numbers to service names.
/*
func identifyService(port int) string {
	commonPorts := map[int]string{
		21:   "FTP",
		22:   "SSH",
		23:   "Telnet",
		25:   "SMTP",
		53:   "DNS",
		80:   "HTTP",
		110:  "POP3",
		143:  "IMAP",
		443:  "HTTPS",
		3306: "MySQL",
		5432: "PostgreSQL",
		6379: "Redis",
		8080: "HTTP-Alt",
		8443: "HTTPS-Alt",
		9000: "Kadcast", // Dusk network port
	}

	if service, ok := commonPorts[port]; ok {
		return service
	}

	return fmt.Sprintf("Port-%d", port)
}
*/

func (s *SweepService) GetStatus(_ context.Context) (*proto.StatusResponse, error) {
	if s == nil {
		log.Printf("Warning: Sweep service not initialized")

		return &proto.StatusResponse{
			Available:   false,
			Message:     "Sweep service not initialized",
			ServiceName: "network_sweep",
			ServiceType: "sweep",
		}, nil
	}

	// Get current summary from processor
	summary, err := s.processor.GetSummary()
	if err != nil {
		log.Printf("Error getting sweep summary: %v", err)
		return nil, fmt.Errorf("failed to get sweep summary: %w", err)
	}

	// Convert to JSON for the message field
	statusJSON, err := json.Marshal(summary)
	if err != nil {
		log.Printf("Error marshaling sweep status: %v", err)
		return nil, fmt.Errorf("failed to marshal sweep status: %w", err)
	}

	// Return status response
	return &proto.StatusResponse{
		Available:   true,
		Message:     string(statusJSON),
		ServiceName: "network_sweep",
		ServiceType: "sweep",
	}, nil
}

// UpdateConfig updates the sweep configuration.
func (s *SweepService) UpdateConfig(config *models.Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Apply default configuration
	config = applyDefaultConfig(config)
	s.config = config

	return nil
}

// Close implements io.Closer.
func (s *SweepService) Close() error {
	return s.Stop()
}

func generateTargets(config *models.Config) ([]models.Target, error) {
	var targets []models.Target

	// For each network
	for _, network := range config.Networks {
		// Generate IP addresses for the network
		ips, err := sweeper.GenerateIPsFromCIDR(network)
		if err != nil {
			return nil, fmt.Errorf("failed to generate IPs for %s: %w", network, err)
		}

		// For each IP, create appropriate targets
		for _, ip := range ips {
			// Add ICMP target if enabled
			if models.ContainsMode(config.SweepModes, models.ModeICMP) {
				targets = append(targets, models.Target{
					Host: ip.String(),
					Mode: models.ModeICMP,
				})
			}

			// Add TCP targets if enabled
			if models.ContainsMode(config.SweepModes, models.ModeTCP) {
				for _, port := range config.Ports {
					targets = append(targets, models.Target{
						Host: ip.String(),
						Port: port,
						Mode: models.ModeTCP,
					})
				}
			}
		}
	}

	return targets, nil
}
