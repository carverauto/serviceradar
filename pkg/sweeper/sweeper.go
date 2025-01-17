package sweeper

import (
	"context"
	"sync"
	"time"
)

// NetworkSweeper implements the Sweeper interface
type NetworkSweeper struct {
	config  Config
	scanner Scanner
	store   Store
	mu      sync.RWMutex
	done    chan struct{}
}

func NewNetworkSweeper(config Config, scanner Scanner, store Store) *NetworkSweeper {
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
				return err
			}
		}
	}
}

func (s *NetworkSweeper) Stop() error {
	close(s.done)
	return s.scanner.Stop()
}

func (s *NetworkSweeper) GetResults(ctx context.Context, filter ResultFilter) ([]Result, error) {
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
	targets, err := generateTargets(s.config)
	if err != nil {
		return err
	}

	results, err := s.scanner.Scan(ctx, targets)
	if err != nil {
		return err
	}

	for result := range results {
		if err := s.store.SaveResult(ctx, result); err != nil {
			return err
		}
	}

	return nil
}
