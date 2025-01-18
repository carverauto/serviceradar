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

func (s *InMemoryStore) SaveHostResult(_ context.Context, result *HostResult) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// For in-memory store, we'll just store the latest host result for each host
	for i, existingResult := range s.results {
		if existingResult.Target.Host == result.Host {
			// Update LastSeen for matching results
			s.results[i].LastSeen = result.LastSeen
			if result.Available {
				s.results[i].Available = true
			}
			return nil
		}
	}

	return nil
}

func (s *InMemoryStore) GetHostResults(_ context.Context, filter *ResultFilter) ([]HostResult, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	// Group results by host
	hostMap := make(map[string]*HostResult)

	for _, result := range s.results {
		if !s.matchesFilter(&result, filter) {
			continue
		}

		host, exists := hostMap[result.Target.Host]
		if !exists {
			host = &HostResult{
				Host:        result.Target.Host,
				FirstSeen:   result.FirstSeen,
				LastSeen:    result.LastSeen,
				Available:   false,
				PortResults: make([]*PortResult, 0),
			}
			hostMap[result.Target.Host] = host
		}

		if result.Available {
			host.Available = true
			if result.Target.Mode == ModeTCP {
				portResult := &PortResult{
					Port:      result.Target.Port,
					Available: true,
					RespTime:  result.RespTime,
				}
				host.PortResults = append(host.PortResults, portResult)
			}
		}

		// Update timestamps
		if result.FirstSeen.Before(host.FirstSeen) {
			host.FirstSeen = result.FirstSeen
		}
		if result.LastSeen.After(host.LastSeen) {
			host.LastSeen = result.LastSeen
		}
	}

	// Convert map to slice
	hosts := make([]HostResult, 0, len(hostMap))
	for _, host := range hostMap {
		hosts = append(hosts, *host)
	}

	return hosts, nil
}

func (s *InMemoryStore) GetSweepSummary(_ context.Context) (*SweepSummary, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	// Get latest results for summary
	hostMap := make(map[string]*HostResult)
	portCounts := make(map[int]int)
	totalHosts := 0
	var lastSweep time.Time

	for _, result := range s.results {
		// Track latest sweep time
		if result.LastSeen.After(lastSweep) {
			lastSweep = result.LastSeen
		}

		// Count ports
		if result.Available && result.Target.Mode == ModeTCP {
			portCounts[result.Target.Port]++
		}

		// Group by host
		host, exists := hostMap[result.Target.Host]
		if !exists {
			totalHosts++
			host = &HostResult{
				Host:        result.Target.Host,
				FirstSeen:   result.FirstSeen,
				LastSeen:    result.LastSeen,
				Available:   false,
				PortResults: make([]*PortResult, 0),
			}
			hostMap[result.Target.Host] = host
		}

		if result.Available {
			host.Available = true
		}
	}

	// Count available hosts
	availableHosts := 0
	hosts := make([]HostResult, 0, len(hostMap))
	for _, host := range hostMap {
		if host.Available {
			availableHosts++
		}
		hosts = append(hosts, *host)
	}

	// Create port counts
	ports := make([]PortCount, 0, len(portCounts))
	for port, count := range portCounts {
		ports = append(ports, PortCount{
			Port:      port,
			Available: count,
		})
	}

	// Create summary
	summary := &SweepSummary{
		Network:        "", // Will be set by client if needed
		TotalHosts:     totalHosts,
		AvailableHosts: availableHosts,
		LastSweep:      lastSweep,
		Hosts:          hosts,
		Ports:          ports,
	}

	return summary, nil
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
