// Package sweeper pkg/sweeper/memory_store.go
package sweeper

import (
	"context"
	"sync"
	"time"
)

// InMemoryStore implements Store interface for temporary storage.
type InMemoryStore struct {
	mu      sync.RWMutex
	results []Result
}

// filterCheck is a type for individual filter checks.
type filterCheck func(*Result, *ResultFilter) bool

// NewInMemoryStore creates a new in-memory store for sweep results.
func NewInMemoryStore() Store {
	return &InMemoryStore{
		results: make([]Result, 0),
	}
}

func (s *InMemoryStore) SaveResult(_ context.Context, result *Result) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Check if we already have a result for this target
	for i, existing := range s.results {
		if existing.Target == result.Target {
			// Update existing result
			s.results[i] = *result
			return nil
		}
	}

	// Add new result
	s.results = append(s.results, *result)

	return nil
}

func (s *InMemoryStore) GetResults(_ context.Context, filter *ResultFilter) ([]Result, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	filtered := make([]Result, 0, len(s.results))

	for _, result := range s.results {
		if s.matchesFilter(&result, filter) {
			filtered = append(filtered, result)
		}
	}

	return filtered, nil
}

// matchesFilter checks if a result matches all filter criteria.
func (*InMemoryStore) matchesFilter(result *Result, filter *ResultFilter) bool {
	checks := []filterCheck{
		checkTimeRange,
		checkHost,
		checkPort,
		checkAvailability,
	}

	for _, check := range checks {
		if !check(result, filter) {
			return false
		}
	}

	return true
}

// checkTimeRange verifies if the result falls within the specified time range.
func checkTimeRange(result *Result, filter *ResultFilter) bool {
	if !filter.StartTime.IsZero() && result.LastSeen.Before(filter.StartTime) {
		return false
	}

	if !filter.EndTime.IsZero() && result.LastSeen.After(filter.EndTime) {
		return false
	}

	return true
}

// checkHost verifies if the result matches the specified host.
func checkHost(result *Result, filter *ResultFilter) bool {
	return filter.Host == "" || result.Target.Host == filter.Host
}

// checkPort verifies if the result matches the specified port.
func checkPort(result *Result, filter *ResultFilter) bool {
	return filter.Port == 0 || result.Target.Port == filter.Port
}

// checkAvailability verifies if the result matches the specified availability.
func checkAvailability(result *Result, filter *ResultFilter) bool {
	return filter.Available == nil || result.Available == *filter.Available
}

func (s *InMemoryStore) PruneResults(_ context.Context, age time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	cutoff := time.Now().Add(-age)
	newResults := make([]Result, 0, len(s.results))

	for _, result := range s.results {
		if result.LastSeen.After(cutoff) {
			newResults = append(newResults, result)
		}
	}

	s.results = newResults

	return nil
}
