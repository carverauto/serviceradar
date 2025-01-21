package sweeper

import (
	"context"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

// InMemoryStore implements Store interface for temporary storage.
type InMemoryStore struct {
	mu        sync.RWMutex
	results   []models.Result
	processor ResultProcessor
}

// NewInMemoryStore creates a new in-memory store for sweep results.
func NewInMemoryStore(processor ResultProcessor) Store {
	return &InMemoryStore{
		results:   make([]models.Result, 0),
		processor: processor,
	}
}

// SaveHostResult updates the last-seen time (and possibly availability)
// for the given host. For in-memory store, we'll store the latest host
// result for each host.
func (s *InMemoryStore) SaveHostResult(_ context.Context, result *models.HostResult) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	for i := range s.results {
		// use index to avoid copying the entire Result struct
		existing := &s.results[i]

		// guard clause to skip non-matching hosts
		if existing.Target.Host != result.Host {
			continue
		}

		// Found matching host; update LastSeen and availability
		existing.LastSeen = result.LastSeen
		if result.Available {
			existing.Available = true
		}

		return nil
	}

	return nil
}

// GetHostResults returns a slice of HostResult based on the provided filter.
func (s *InMemoryStore) GetHostResults(_ context.Context, filter *models.ResultFilter) ([]models.HostResult, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	// group results by host
	hostMap := make(map[string]*models.HostResult)

	for i := range s.results {
		r := &s.results[i]
		if !s.matchesFilter(r, filter) {
			continue
		}

		host, exists := hostMap[r.Target.Host]
		if !exists {
			host = &models.HostResult{
				Host:        r.Target.Host,
				FirstSeen:   r.FirstSeen,
				LastSeen:    r.LastSeen,
				Available:   false,
				PortResults: make([]*models.PortResult, 0),
			}
			hostMap[r.Target.Host] = host
		}

		if r.Available {
			host.Available = true

			if r.Target.Mode == models.ModeTCP {
				portResult := &models.PortResult{
					Port:      r.Target.Port,
					Available: true,
					RespTime:  r.RespTime,
				}
				host.PortResults = append(host.PortResults, portResult)
			}
		}

		// update timestamps
		if r.FirstSeen.Before(host.FirstSeen) {
			host.FirstSeen = r.FirstSeen
		}

		if r.LastSeen.After(host.LastSeen) {
			host.LastSeen = r.LastSeen
		}
	}

	// Convert map to slice
	hosts := make([]models.HostResult, 0, len(hostMap))
	for _, host := range hostMap {
		hosts = append(hosts, *host)
	}

	return hosts, nil
}

// GetSweepSummary gathers high-level sweep information.
func (s *InMemoryStore) GetSweepSummary(_ context.Context) (*models.SweepSummary, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	hostMap := make(map[string]*models.HostResult)
	portCounts := make(map[int]int)
	totalHosts := 0

	var lastSweep time.Time

	for i := range s.results {
		r := &s.results[i]

		// track latest sweep time
		if r.LastSeen.After(lastSweep) {
			lastSweep = r.LastSeen
		}

		// count ports
		if r.Available && r.Target.Mode == models.ModeTCP {
			portCounts[r.Target.Port]++
		}

		// group by host
		host, exists := hostMap[r.Target.Host]
		if !exists {
			totalHosts++
			host = &models.HostResult{
				Host:        r.Target.Host,
				FirstSeen:   r.FirstSeen,
				LastSeen:    r.LastSeen,
				Available:   false,
				PortResults: make([]*models.PortResult, 0),
			}
			hostMap[r.Target.Host] = host
		}

		if r.Available {
			host.Available = true
		}
	}

	// Count available hosts
	availableHosts := 0
	hosts := make([]models.HostResult, 0, len(hostMap))

	for _, host := range hostMap {
		if host.Available {
			availableHosts++
		}

		hosts = append(hosts, *host)
	}

	// Create port counts
	ports := make([]models.PortCount, 0, len(portCounts))
	for port, count := range portCounts {
		ports = append(ports, models.PortCount{
			Port:      port,
			Available: count,
		})
	}

	summary := &models.SweepSummary{
		Network:        "",
		TotalHosts:     totalHosts,
		AvailableHosts: availableHosts,
		LastSweep:      lastSweep.Unix(),
		Hosts:          hosts,
		Ports:          ports,
	}

	return summary, nil
}

// SaveResult stores (or updates) a Result in memory.
func (s *InMemoryStore) SaveResult(ctx context.Context, result *models.Result) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Use a context with timeout for potential long-running operations
	var cancel context.CancelFunc
	_, cancel = context.WithTimeout(ctx, dbOperationTimeout)
	defer cancel()

	for i := range s.results {
		// Compare individual fields of Target instead of the whole struct
		if s.results[i].Target.Host == result.Target.Host &&
			s.results[i].Target.Port == result.Target.Port &&
			s.results[i].Target.Mode == result.Target.Mode {
			s.results[i] = *result
			return nil
		}
	}

	// If not found, append it
	s.results = append(s.results, *result)

	return nil
}

// GetResults returns a list of Results that match the filter.
func (s *InMemoryStore) GetResults(_ context.Context, filter *models.ResultFilter) ([]models.Result, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	filtered := make([]models.Result, 0, len(s.results))

	for i := range s.results {
		r := &s.results[i]
		if s.matchesFilter(r, filter) {
			filtered = append(filtered, *r)
		}
	}

	return filtered, nil
}

// PruneResults removes old results that haven't been seen since 'age' ago.
func (s *InMemoryStore) PruneResults(_ context.Context, age time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	cutoff := time.Now().Add(-age)
	newResults := make([]models.Result, 0, len(s.results))

	for i := range s.results {
		r := &s.results[i]
		if r.LastSeen.After(cutoff) {
			newResults = append(newResults, *r)
		}
	}

	s.results = newResults

	return nil
}

// matchesFilter checks if a Result matches the provided filter.
func (*InMemoryStore) matchesFilter(result *models.Result, filter *models.ResultFilter) bool {
	checks := []func(*models.Result, *models.ResultFilter) bool{
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
func checkTimeRange(result *models.Result, filter *models.ResultFilter) bool {
	if !filter.StartTime.IsZero() && result.LastSeen.Before(filter.StartTime) {
		return false
	}

	if !filter.EndTime.IsZero() && result.LastSeen.After(filter.EndTime) {
		return false
	}

	return true
}

// checkHost verifies if the result matches the specified host.
func checkHost(result *models.Result, filter *models.ResultFilter) bool {
	return filter.Host == "" || result.Target.Host == filter.Host
}

// checkPort verifies if the result matches the specified port.
func checkPort(result *models.Result, filter *models.ResultFilter) bool {
	return filter.Port == 0 || result.Target.Port == filter.Port
}

// checkAvailability verifies if the result matches the specified availability.
func checkAvailability(result *models.Result, filter *models.ResultFilter) bool {
	return filter.Available == nil || result.Available == *filter.Available
}
