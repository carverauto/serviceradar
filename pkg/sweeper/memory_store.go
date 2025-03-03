/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Package sweeper pkg/sweeper/memory_store.go
package sweeper

import (
	"context"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultCleanupInterval = 5 * time.Minute
	defaultMaxResults      = 1000
)

// InMemoryStore implements Store interface for temporary storage.
type InMemoryStore struct {
	mu          sync.RWMutex
	results     []models.Result
	processor   ResultProcessor
	maxResults  int
	cleanupDone chan struct{}
}

// NewInMemoryStore creates a new in-memory store for sweep results.
func NewInMemoryStore(processor ResultProcessor) Store {
	store := &InMemoryStore{
		results:     make([]models.Result, 0),
		processor:   processor,
		maxResults:  defaultMaxResults,
		cleanupDone: make(chan struct{}),
	}

	// Start cleanup goroutine
	go store.periodicCleanup()

	return store
}

func (s *InMemoryStore) periodicCleanup() {
	ticker := time.NewTicker(defaultCleanupInterval)
	defer ticker.Stop()

	for {
		select {
		case <-s.cleanupDone:
			return
		case <-ticker.C:
			s.cleanOldResults()
		}
	}
}

func (s *InMemoryStore) cleanOldResults() {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Keep only the most recent results
	if len(s.results) > s.maxResults {
		// Calculate how many to remove
		removeCount := len(s.results) - s.maxResults

		// Keep the most recent results (which are at the end)
		s.results = s.results[removeCount:]
	}
}

func (s *InMemoryStore) Close() error {
	close(s.cleanupDone)

	return nil
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

	hostMap := make(map[string]*models.HostResult)

	// First pass: collect base host information
	for i := range s.results {
		r := &s.results[i]
		if !s.matchesFilter(r, filter) {
			continue
		}

		s.processHostResult(r, hostMap)
	}

	return s.convertToSlice(hostMap), nil
}

func (s *InMemoryStore) processHostResult(r *models.Result, hostMap map[string]*models.HostResult) {
	host := s.getOrCreateHost(r, hostMap)

	if !r.Available {
		if r.Target.Mode == models.ModeICMP {
			s.updateICMPStatus(host, r)
		}

		return
	}

	host.Available = true

	if r.Target.Mode == models.ModeICMP {
		s.updateICMPStatus(host, r)
	} else if r.Target.Mode == models.ModeTCP {
		s.processPortResult(host, r)
	}

	s.updateHostTimestamps(host, r)
}

func (*InMemoryStore) getOrCreateHost(r *models.Result, hostMap map[string]*models.HostResult) *models.HostResult {
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

	return host
}

func (s *InMemoryStore) processPortResult(host *models.HostResult, r *models.Result) {
	portResult := s.findPortResult(host, r.Target.Port)
	if portResult == nil {
		portResult = &models.PortResult{
			Port:      r.Target.Port,
			Available: true,
			RespTime:  r.RespTime,
		}
		host.PortResults = append(host.PortResults, portResult)
	} else {
		portResult.Available = true
		portResult.RespTime = r.RespTime
	}
}

func (*InMemoryStore) findPortResult(host *models.HostResult, port int) *models.PortResult {
	for _, pr := range host.PortResults {
		if pr.Port == port {
			return pr
		}
	}

	return nil
}

func (*InMemoryStore) updateHostTimestamps(host *models.HostResult, r *models.Result) {
	if r.FirstSeen.Before(host.FirstSeen) {
		host.FirstSeen = r.FirstSeen
	}

	if r.LastSeen.After(host.LastSeen) {
		host.LastSeen = r.LastSeen
	}
}

func (*InMemoryStore) convertToSlice(hostMap map[string]*models.HostResult) []models.HostResult {
	hosts := make([]models.HostResult, 0, len(hostMap))
	for _, host := range hostMap {
		hosts = append(hosts, *host)
	}

	return hosts
}

// GetSweepSummary gathers high-level sweep information.
func (s *InMemoryStore) GetSweepSummary(_ context.Context) (*models.SweepSummary, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	hostMap, portCounts, lastSweep := s.processResults()

	summary := s.buildSummary(hostMap, portCounts, lastSweep)

	return summary, nil
}

func (s *InMemoryStore) processResults() (hostResults map[string]*models.HostResult, portCounts map[int]int, lastSweep time.Time) {
	hostResults = make(map[string]*models.HostResult)
	portCounts = make(map[int]int)

	for i := range s.results {
		r := &s.results[i]
		s.updateLastSweep(r, &lastSweep)
		s.updateHostAndPortResults(r, hostResults, portCounts)
	}

	return hostResults, portCounts, lastSweep
}

func (*InMemoryStore) updateLastSweep(r *models.Result, lastSweep *time.Time) {
	if r.LastSeen.After(*lastSweep) {
		*lastSweep = r.LastSeen
	}
}

func (s *InMemoryStore) updateHostAndPortResults(r *models.Result, hostMap map[string]*models.HostResult, portCounts map[int]int) {
	host := s.getOrCreateHost(r, hostMap)

	if r.Available {
		host.Available = true
		s.updateHostBasedOnMode(r, host, portCounts)
	} else if r.Target.Mode == models.ModeICMP {
		s.updateICMPStatus(host, r)
	}
}

func (s *InMemoryStore) updateHostBasedOnMode(r *models.Result, host *models.HostResult, portCounts map[int]int) {
	switch r.Target.Mode {
	case models.ModeICMP:
		s.updateICMPStatus(host, r)
	case models.ModeTCP:
		s.updateTCPPortResults(host, r, portCounts)
	}
}

func (*InMemoryStore) updateICMPStatus(host *models.HostResult, r *models.Result) {
	if host.ICMPStatus == nil {
		host.ICMPStatus = &models.ICMPStatus{}
	}

	host.ICMPStatus.Available = true

	host.ICMPStatus.RoundTrip = r.RespTime

	host.ICMPStatus.PacketLoss = 0
}

func (*InMemoryStore) updateTCPPortResults(host *models.HostResult, r *models.Result, portCounts map[int]int) {
	portCounts[r.Target.Port]++

	found := false

	for _, port := range host.PortResults {
		if port.Port == r.Target.Port {
			port.Available = true
			port.RespTime = r.RespTime
			found = true

			break
		}
	}

	if !found {
		host.PortResults = append(host.PortResults, &models.PortResult{
			Port:      r.Target.Port,
			Available: true,
			RespTime:  r.RespTime,
		})
	}
}

func (*InMemoryStore) buildSummary(
	hostMap map[string]*models.HostResult, portCounts map[int]int, lastSweep time.Time) *models.SweepSummary {
	availableHosts := 0
	hosts := make([]models.HostResult, 0, len(hostMap))

	for _, host := range hostMap {
		if host.Available {
			availableHosts++
		}

		hosts = append(hosts, *host)
	}

	ports := make([]models.PortCount, 0, len(portCounts))
	for port, count := range portCounts {
		ports = append(ports, models.PortCount{
			Port:      port,
			Available: count,
		})
	}

	return &models.SweepSummary{
		TotalHosts:     len(hostMap),
		AvailableHosts: availableHosts,
		LastSweep:      lastSweep.Unix(),
		Hosts:          hosts,
		Ports:          ports,
	}
}

// SaveResult stores (or updates) a Result in memory.
func (s *InMemoryStore) SaveResult(_ context.Context, result *models.Result) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Find existing result for this host and mode
	for i := range s.results {
		if s.results[i].Target.Host == result.Target.Host &&
			s.results[i].Target.Mode == result.Target.Mode &&
			s.results[i].Target.Port == result.Target.Port {
			// Update existing result
			s.results[i] = *result
			return nil
		}
	}

	// If no existing result found, append new one
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
