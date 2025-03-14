package sweeper

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/scan"
)

const (
	defaultInterval = 5 * time.Minute
	scanTimeout     = 2 * time.Minute // Timeout for individual scan operations
)

// NetworkSweeper implements the Sweeper interface.
type NetworkSweeper struct {
	config      *models.Config
	icmpScanner scan.Scanner
	tcpScanner  scan.Scanner
	store       Store
	processor   ResultProcessor
	mu          sync.RWMutex
	done        chan struct{}
	lastSweep   time.Time
}

// NewNetworkSweeper creates a new scanner for network sweeping.
func NewNetworkSweeper(config *models.Config, store Store, processor ResultProcessor) (*NetworkSweeper, error) {
	if config == nil {
		return nil, fmt.Errorf("config cannot be nil")
	}

	// Initialize scanners
	icmpScanner, err := scan.NewICMPSweeper(config.Timeout, config.ICMPRateLimit)
	if err != nil {
		return nil, fmt.Errorf("failed to create ICMP scanner: %w", err)
	}
	tcpScanner := scan.NewTCPSweeper(config.Timeout, config.Concurrency)

	// Default interval if not set
	if config.Interval == 0 {
		config.Interval = defaultInterval
	}

	log.Printf("Creating NetworkSweeper with interval: %v", config.Interval)

	return &NetworkSweeper{
		config:      config,
		icmpScanner: icmpScanner,
		tcpScanner:  tcpScanner,
		store:       store,
		processor:   processor,
		done:        make(chan struct{}),
	}, nil
}

// Start begins periodic sweeping based on configuration.
func (s *NetworkSweeper) Start(ctx context.Context) error {
	log.Printf("Starting network sweeper with interval %v", s.config.Interval)

	// Run initial sweep with a timeout
	log.Printf("Running initial sweep...")
	initialCtx, initialCancel := context.WithTimeout(ctx, scanTimeout)
	if err := s.runSweep(initialCtx); err != nil {
		initialCancel()
		log.Printf("Initial sweep failed: %v", err)
		// Continue anyway - we'll try again on the next tick
	} else {
		log.Printf("Initial sweep completed successfully")
	}
	initialCancel()

	s.mu.Lock()
	s.lastSweep = time.Now()
	s.mu.Unlock()

	// Set up ticker for periodic sweeps
	ticker := time.NewTicker(s.config.Interval)
	defer ticker.Stop()

	log.Printf("Entering sweep loop with interval %v", s.config.Interval)

	// Main loop
	for {
		select {
		case <-ctx.Done():
			log.Printf("Context canceled, stopping sweeper")
			return ctx.Err()
		case <-s.done:
			log.Printf("Received done signal, stopping sweeper")
			return nil
		case t := <-ticker.C:
			log.Printf("Ticker fired at %v, starting periodic sweep", t.Format(time.RFC3339))

			// Create a timeout context for this sweep
			sweepCtx, sweepCancel := context.WithTimeout(ctx, scanTimeout)
			if err := s.runSweep(sweepCtx); err != nil {
				log.Printf("Periodic sweep failed: %v", err)
			} else {
				log.Printf("Periodic sweep completed successfully")
			}
			sweepCancel()

			s.mu.Lock()
			s.lastSweep = time.Now()
			s.mu.Unlock()
		}
	}
}

// runSweep executes a single network sweep.
func (s *NetworkSweeper) runSweep(ctx context.Context) error {
	// Get the current time for logging
	startTime := time.Now()

	// Generate targets from config
	targets, err := s.generateTargets()
	if err != nil {
		return fmt.Errorf("failed to generate targets: %w", err)
	}

	// Split targets by mode for appropriate scanners
	var icmpTargets, tcpTargets []models.Target
	for _, t := range targets {
		switch t.Mode {
		case models.ModeICMP:
			icmpTargets = append(icmpTargets, t)
		case models.ModeTCP:
			tcpTargets = append(tcpTargets, t)
		}
	}

	log.Printf("Starting sweep with %d ICMP targets and %d TCP targets",
		len(icmpTargets), len(tcpTargets))

	// Run ICMP scan if we have targets
	var icmpSuccess, tcpSuccess, totalResults int
	uniqueHosts := make(map[string]struct{})

	if len(icmpTargets) > 0 {
		log.Printf("Running ICMP scan...")
		icmpResults, err := s.icmpScanner.Scan(ctx, icmpTargets)
		if err != nil {
			return fmt.Errorf("ICMP scan failed: %w", err)
		}

		// Process ICMP results
		for result := range icmpResults {
			totalResults++
			uniqueHosts[result.Target.Host] = struct{}{}

			if err := s.processResult(ctx, &result); err != nil {
				log.Printf("Failed to process ICMP result for %s: %v", result.Target.Host, err)
				continue
			}

			if result.Available {
				icmpSuccess++
			}
		}
		log.Printf("ICMP scan complete: %d results, %d successful", totalResults, icmpSuccess)
	}

	// Run TCP scan if we have targets
	if len(tcpTargets) > 0 {
		log.Printf("Running TCP scan...")
		tcpResults, err := s.tcpScanner.Scan(ctx, tcpTargets)
		if err != nil {
			return fmt.Errorf("TCP scan failed: %w", err)
		}

		// Process TCP results
		tcpTotal := 0
		for result := range tcpResults {
			totalResults++
			tcpTotal++
			uniqueHosts[result.Target.Host] = struct{}{}

			if err := s.processResult(ctx, &result); err != nil {
				log.Printf("Failed to process TCP result for %s:%d: %v",
					result.Target.Host, result.Target.Port, err)
				continue
			}

			if result.Available {
				tcpSuccess++
			}
		}
		log.Printf("TCP scan complete: %d results, %d successful", tcpTotal, tcpSuccess)
	}

	duration := time.Since(startTime)
	log.Printf("Sweep completed in %v: %d results, %d successful (%d ICMP, %d TCP), %d unique hosts",
		duration, totalResults, icmpSuccess+tcpSuccess, icmpSuccess, tcpSuccess, len(uniqueHosts))

	return nil
}

// processResult processes a single scan result.
func (s *NetworkSweeper) processResult(ctx context.Context, result *models.Result) error {
	// Create a timeout context to prevent blocking
	ctx, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
	defer cancel()

	// Process through processor first
	if err := s.processor.Process(result); err != nil {
		return fmt.Errorf("processor error: %w", err)
	}

	// Then store the result
	if err := s.store.SaveResult(ctx, result); err != nil {
		return fmt.Errorf("store error: %w", err)
	}

	return nil
}

// Stop gracefully stops sweeping.
func (s *NetworkSweeper) Stop(ctx context.Context) error {
	log.Printf("Stopping network sweeper")
	close(s.done)

	// Stop the scanners
	if err := s.icmpScanner.Stop(ctx); err != nil {
		log.Printf("Failed to stop ICMP scanner: %v", err)
	}

	if err := s.tcpScanner.Stop(ctx); err != nil {
		log.Printf("Failed to stop TCP scanner: %v", err)
	}

	return nil
}

// GetResults retrieves sweep results based on filter.
func (s *NetworkSweeper) GetResults(ctx context.Context, filter *models.ResultFilter) ([]models.Result, error) {
	log.Printf("Getting results with filter: %+v", filter)
	return s.store.GetResults(ctx, filter)
}

// GetConfig returns current sweeper configuration.
func (s *NetworkSweeper) GetConfig() models.Config {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return *s.config
}

// UpdateConfig updates sweeper configuration.
func (s *NetworkSweeper) UpdateConfig(config models.Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	log.Printf("Updating sweeper config: %+v", config)
	s.config = &config
	return nil
}

// generateTargets creates scan targets from the configuration.
func (s *NetworkSweeper) generateTargets() ([]models.Target, error) {
	var targets []models.Target

	// Track total hosts for metadata
	totalHostCount := 0

	// Generate targets for each network
	for _, network := range s.config.Networks {
		ips, err := scan.ExpandCIDR(network)
		if err != nil {
			return nil, fmt.Errorf("failed to expand CIDR %s: %w", network, err)
		}

		// Update total count
		totalHostCount += len(ips)

		// Create metadata for this network
		metadata := map[string]interface{}{
			"network":     network,
			"total_hosts": len(ips),
		}

		// Create targets for each IP
		for _, ip := range ips {
			// Add ICMP targets if enabled
			if containsMode(s.config.SweepModes, models.ModeICMP) {
				target := scan.TargetFromIP(ip, models.ModeICMP)
				target.Metadata = metadata
				targets = append(targets, target)
			}

			// Add TCP targets if enabled
			if containsMode(s.config.SweepModes, models.ModeTCP) {
				for _, port := range s.config.Ports {
					target := scan.TargetFromIP(ip, models.ModeTCP, port)
					target.Metadata = metadata
					targets = append(targets, target)
				}
			}
		}
	}

	log.Printf("Generated %d targets from %d networks (total hosts: %d)",
		len(targets), len(s.config.Networks), totalHostCount)

	return targets, nil
}

// containsMode checks if a mode is in a slice of modes.
func containsMode(modes []models.SweepMode, mode models.SweepMode) bool {
	for _, m := range modes {
		if m == mode {
			return true
		}
	}
	return false
}
