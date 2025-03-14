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
)

// NetworkSweeper implements the Sweeper interface using the new scan package.
type NetworkSweeper struct {
	config      *models.Config
	IcmpScanner scan.Scanner
	tcpScanner  scan.Scanner
	store       Store
	processor   ResultProcessor
	mu          sync.RWMutex
	done        chan struct{}
	lastSweep   time.Time
}

func NewNetworkSweeper(config *models.Config, store Store, processor ResultProcessor) (*NetworkSweeper, error) {
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

	return &NetworkSweeper{
		config:      config,
		IcmpScanner: icmpScanner,
		tcpScanner:  tcpScanner,
		store:       store,
		processor:   processor,
		done:        make(chan struct{}),
	}, nil
}

func (s *NetworkSweeper) Start(ctx context.Context) error {
	// Initial sweep
	if err := s.runSweep(ctx); err != nil {
		log.Printf("Initial sweep failed: %v", err)
		return err
	}

	s.mu.Lock()
	s.lastSweep = time.Now()
	s.mu.Unlock()

	ticker := time.NewTicker(s.config.Interval)
	defer ticker.Stop()

	log.Printf("Sweeper started with interval %v", s.config.Interval)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-s.done:
			return nil
		case <-ticker.C:
			log.Printf("Starting periodic sweep")
			if err := s.runSweep(ctx); err != nil {
				log.Printf("Periodic sweep failed: %v", err)
			} else {
				log.Printf("Periodic sweep completed successfully")
			}
			s.mu.Lock()
			s.lastSweep = time.Now()
			s.mu.Unlock()
		}
	}
}

func (s *NetworkSweeper) runSweep(ctx context.Context) error {

	targets, err := s.generateTargets()
	if err != nil {
		return fmt.Errorf("failed to generate targets: %w", err)
	}

	// Split targets by mode
	var icmpTargets, tcpTargets []models.Target
	for _, t := range targets {
		switch t.Mode {
		case models.ModeICMP:
			icmpTargets = append(icmpTargets, t)
		case models.ModeTCP:
			tcpTargets = append(tcpTargets, t)
		}
	}

	log.Printf("Starting network sweep with %d ICMP targets and %d TCP targets",
		len(icmpTargets), len(tcpTargets))

	// Run scans concurrently
	var wg sync.WaitGroup
	errCh := make(chan error, 2)
	results := make(chan models.Result, len(targets))

	if len(icmpTargets) > 0 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			icmpResults, err := s.IcmpScanner.Scan(ctx, icmpTargets)
			if err != nil {
				errCh <- fmt.Errorf("ICMP scan failed: %w", err)
				return
			}
			for r := range icmpResults {
				results <- r
			}
		}()
	}

	if len(tcpTargets) > 0 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			tcpResults, err := s.tcpScanner.Scan(ctx, tcpTargets)
			if err != nil {
				errCh <- fmt.Errorf("TCP scan failed: %w", err)
				return
			}
			for r := range tcpResults {
				results <- r
			}
		}()
	}

	// Close results channel when scans complete
	go func() {
		wg.Wait()
		close(results)
	}()

	// Process results
	var icmpSuccess, tcpSuccess, totalResults int
	uniqueHosts := make(map[string]struct{})
	for r := range results {
		totalResults++
		uniqueHosts[r.Target.Host] = struct{}{}
		if err := s.processResult(ctx, &r); err != nil {
			log.Printf("Failed to process result for %s: %v", r.Target.Host, err)
			continue
		}
		if r.Available {
			switch r.Target.Mode {
			case models.ModeICMP:
				icmpSuccess++
			case models.ModeTCP:
				tcpSuccess++
			}
		}
	}

	// Check for scan errors
	select {
	case err := <-errCh:
		return err
	default:
	}

	log.Printf("Sweep completed: %d results, %d successful (%d ICMP, %d TCP), %d unique hosts",
		totalResults, icmpSuccess+tcpSuccess, icmpSuccess, tcpSuccess, len(uniqueHosts))
	return nil
}

func (s *NetworkSweeper) processResult(ctx context.Context, result *models.Result) error {
	ctx, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
	defer cancel()

	if err := s.processor.Process(result); err != nil {
		return fmt.Errorf("processor error: %w", err)
	}
	if err := s.store.SaveResult(ctx, result); err != nil {
		return fmt.Errorf("store error: %w", err)
	}
	return nil
}

func (s *NetworkSweeper) Stop(ctx context.Context) error {
	close(s.done)
	if err := s.IcmpScanner.Stop(ctx); err != nil {
		log.Printf("Failed to stop ICMP scanner: %v", err)
	}
	if err := s.tcpScanner.Stop(ctx); err != nil {
		log.Printf("Failed to stop TCP scanner: %v", err)
	}
	return nil
}

func (s *NetworkSweeper) GetResults(ctx context.Context, filter *models.ResultFilter) ([]models.Result, error) {
	return s.store.GetResults(ctx, filter)
}

func (s *NetworkSweeper) GetConfig() models.Config {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return *s.config
}

func (s *NetworkSweeper) UpdateConfig(config models.Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.config = &config
	return nil
}

func (s *NetworkSweeper) generateTargets() ([]models.Target, error) {
	var targets []models.Target
	for _, network := range s.config.Networks {
		ips, err := scan.ExpandCIDR(network)
		if err != nil {
			return nil, fmt.Errorf("failed to expand CIDR %s: %w", network, err)
		}
		for _, ip := range ips {
			if containsMode(s.config.SweepModes, models.ModeICMP) {
				targets = append(targets, scan.TargetFromIP(ip, models.ModeICMP))
			}
			if containsMode(s.config.SweepModes, models.ModeTCP) {
				for _, port := range s.config.Ports {
					targets = append(targets, scan.TargetFromIP(ip, models.ModeTCP, port))
				}
			}
		}
	}
	return targets, nil
}

func containsMode(modes []models.SweepMode, mode models.SweepMode) bool {
	for _, m := range modes {
		if m == mode {
			return true
		}
	}
	return false
}
