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

	filtered := make([]Result, 0)

	for _, result := range s.results {
		if s.matchesFilter(&result, filter) {
			filtered = append(filtered, result)
		}
	}

	return filtered, nil
}

func (s *InMemoryStore) matchesFilter(result *Result, filter *ResultFilter) bool {
	// Check time range if specified
	if !filter.StartTime.IsZero() && result.LastSeen.Before(filter.StartTime) {
		return false
	}

	if !filter.EndTime.IsZero() && result.LastSeen.After(filter.EndTime) {
		return false
	}

	// Check host if specified
	if filter.Host != "" && result.Target.Host != filter.Host {
		return false
	}

	// Check port if specified
	if filter.Port != 0 && result.Target.Port != filter.Port {
		return false
	}

	// Check availability if specified
	if filter.Available != nil && result.Available != *filter.Available {
		return false
	}

	return true
}

func (s *InMemoryStore) PruneResults(_ context.Context, age time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	cutoff := time.Now().Add(-age)
	newResults := make([]Result, 0)

	for _, result := range s.results {
		if result.LastSeen.After(cutoff) {
			newResults = append(newResults, result)
		}
	}

	s.results = newResults
	return nil
}
