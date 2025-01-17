// Package sweeper pkg/sweeper/sweeper.go
package sweeper

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"
)

// NetworkSweeper implements the Sweeper interface.
type NetworkSweeper struct {
	config  Config
	scanner Scanner
	store   Store
	mu      sync.RWMutex
	done    chan struct{}
}

// NewNetworkSweeper creates a new instance of NetworkSweeper.
func NewNetworkSweeper(config Config) *NetworkSweeper {
	// Create the TCP scanner
	scanner := NewTCPScanner(config.Timeout, config.Concurrency)

	// Create an in-memory store
	store := NewInMemoryStore()

	return &NetworkSweeper{
		config:  config,
		scanner: scanner,
		store:   store,
		done:    make(chan struct{}),
	}
}

func (s *NetworkSweeper) Start(ctx context.Context) error {
	ticker := time.NewTicker(s.config.Interval)
	defer ticker.Stop()

	// Do initial sweep
	if err := s.runSweep(ctx); err != nil {
		log.Printf("Initial sweep failed: %v", err)
		return err
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-s.done:
			return nil
		case <-ticker.C:
			if err := s.runSweep(ctx); err != nil {
				log.Printf("Periodic sweep failed: %v", err)
				return err
			}
		}
	}
}

func (s *NetworkSweeper) Stop() error {
	close(s.done)
	return s.scanner.Stop()
}

func (s *NetworkSweeper) GetResults(ctx context.Context, filter *ResultFilter) ([]Result, error) {
	return s.store.GetResults(ctx, filter)
}

func (s *NetworkSweeper) GetConfig() Config {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return s.config
}

func (s *NetworkSweeper) UpdateConfig(config Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.config = config

	return nil
}

func (s *NetworkSweeper) runSweep(ctx context.Context) error {
	// Generate targets from configuration
	targets, err := generateTargets(s.config)
	if err != nil {
		return fmt.Errorf("failed to generate targets: %w", err)
	}

	// Start the scan
	results, err := s.scanner.Scan(ctx, targets)
	if err != nil {
		return fmt.Errorf("scan failed: %w", err)
	}

	// Process results as they come in
	for result := range results {
		if err := s.store.SaveResult(ctx, result); err != nil {
			log.Printf("Failed to save result: %v", err)
			continue
		}
	}

	// Prune old results
	if err := s.store.PruneResults(ctx, 24*time.Hour); err != nil {
		log.Printf("Failed to prune old results: %v", err)
	}

	return nil
}
