package scan

import (
	"context"
	"log"
	"sync"

	"github.com/carverauto/serviceradar/pkg/models"
)

// ScannerFactory creates appropriate scanners based on configuration
type ScannerFactory struct {
	config *models.Config
}

// NewScannerFactory creates a new scanner factory
func NewScannerFactory(config *models.Config) *ScannerFactory {
	return &ScannerFactory{config: config}
}

// CreateScanners creates and returns appropriate scanners for the configuration
func (f *ScannerFactory) CreateScanners() map[models.SweepMode]Scanner {
	scanners := make(map[models.SweepMode]Scanner)

	// Check which scan modes are enabled
	for _, mode := range f.config.SweepModes {
		switch mode {
		case models.ModeICMP:
			// Check for high-performance mode flag
			if f.config.EnableHighPerformanceICMP {
				log.Printf("Creating high-performance ICMP scanner with rate limit %d/s",
					f.config.ICMPRateLimit)
				scanner, err := NewFastICMPScanner(f.config.Timeout, f.config.ICMPRateLimit)
				if err != nil {
					log.Printf("Failed to create high-performance ICMP scanner: %v. Falling back to standard scanner.", err)
					scanner = NewICMPScanner(f.config.Timeout, f.config.ICMPCount)
				}
				scanners[models.ModeICMP] = scanner
			} else {
				// Use the standard ICMP scanner
				scanners[models.ModeICMP] = NewICMPScanner(f.config.Timeout, f.config.ICMPCount)
			}
		case models.ModeTCP:
			scanners[models.ModeTCP] = NewTCPScanner(f.config.Timeout, f.config.Concurrency)
		}
	}

	return scanners
}

// MultiProtocolScanner combines multiple protocol-specific scanners
type MultiProtocolScanner struct {
	scanners map[models.SweepMode]Scanner
}

// NewMultiProtocolScanner creates a new scanner that can handle multiple protocols
func NewMultiProtocolScanner(scanners map[models.SweepMode]Scanner) *MultiProtocolScanner {
	return &MultiProtocolScanner{scanners: scanners}
}

// Scan performs scanning for all targets, routing them to the appropriate scanner
func (m *MultiProtocolScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	// Group targets by protocol
	targetsByMode := make(map[models.SweepMode][]models.Target)
	for _, target := range targets {
		targetsByMode[target.Mode] = append(targetsByMode[target.Mode], target)
	}

	// Create a combined result channel
	combinedResults := make(chan models.Result, 10000)

	// Keep track of active scanners
	var wg sync.WaitGroup

	// Start each protocol scanner
	for mode, modeTargets := range targetsByMode {
		scanner, ok := m.scanners[mode]
		if !ok {
			log.Printf("Warning: No scanner available for mode %s, skipping %d targets",
				mode, len(modeTargets))
			continue
		}

		log.Printf("Starting %s scan for %d targets", mode, len(modeTargets))
		results, err := scanner.Scan(ctx, modeTargets)
		if err != nil {
			log.Printf("Error starting %s scan: %v", mode, err)
			continue
		}

		// Process results from this scanner
		wg.Add(1)
		go func(results <-chan models.Result) {
			defer wg.Done()
			for result := range results {
				select {
				case combinedResults <- result:
					// Successfully forwarded result
				case <-ctx.Done():
					return
				}
			}
		}(results)
	}

	// Close the combined channel when all scanners are done
	go func() {
		wg.Wait()
		close(combinedResults)
		log.Printf("All scanners completed, results channel closed")
	}()

	return combinedResults, nil
}

// Stop terminates all scanners
func (m *MultiProtocolScanner) Stop(ctx context.Context) error {
	var lastErr error

	for mode, scanner := range m.scanners {
		if err := scanner.Stop(ctx); err != nil {
			lastErr = err
			log.Printf("Error stopping %s scanner: %v", mode, err)
		}
	}

	return lastErr
}

// Update the models.Config struct to support the new scanner
// Add these fields to your models.Config struct:
//
// EnableHighPerformanceICMP bool          `json:"high_perf_icmp,omitempty"`
// ICMPRateLimit            int           `json:"icmp_rate_limit,omitempty"`
