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
	"hash/fnv"
	"runtime"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// resultKey uniquely identifies a stored result
type resultKey struct {
	host string
	port int
	mode models.SweepMode
}

const (
	defaultCleanupInterval = 10 * time.Minute
	// Preallocation hint for total results across all shards.
	// For 60-100k hosts x ~10 ports, expect ~600k-1M entries.
	defaultMaxResults = 1000000
	// Minimum per-shard capacity to avoid too-small initial allocations
	minShardCapacity = 1024
)

// InMemoryStore implements Store interface for temporary storage.
type InMemoryStore struct {
	// Sharded to reduce lock contention under high write rates
	shards      []*storeShard
	shardCount  int
	processor   ResultProcessor
	maxResults  int
	cleanupDone chan struct{}
	lastCleanup time.Time
	logger      logger.Logger
}

// storeShard holds a partition of results and its own lock.
type storeShard struct {
	mu      sync.RWMutex
	results []models.Result
	index   map[resultKey]int
}

// NewInMemoryStore creates a new in-memory store for sweep results.
func NewInMemoryStore(processor ResultProcessor, log logger.Logger) Store {
	// Choose shard count based on CPUs for better parallel writes.
	const (
		minShards = 4  // Minimum shards for decent parallelism
		maxShards = 16 // Maximum shards to avoid excessive overhead
	)

	shards := runtime.GOMAXPROCS(0)
	if shards < minShards {
		shards = minShards
	}

	if shards > maxShards {
		shards = maxShards
	}

	s := &InMemoryStore{
		shards:      make([]*storeShard, shards),
		shardCount:  shards,
		processor:   processor,
		maxResults:  defaultMaxResults,
		cleanupDone: make(chan struct{}),
		logger:      log,
	}

	// Pre-allocate per-shard capacity to reduce growslice.
	// We divide the max across shards; this is a hint, not a hard cap.
	perCap := defaultMaxResults / shards
	if perCap < minShardCapacity {
		perCap = minShardCapacity
	}

	for i := 0; i < shards; i++ {
		s.shards[i] = &storeShard{
			results: make([]models.Result, 0, perCap),
			index:   make(map[resultKey]int, perCap),
		}
	}

	// Start cleanup goroutine
	go s.periodicCleanup()

	return s
}

func (s *InMemoryStore) periodicCleanup() {
	ticker := time.NewTicker(defaultCleanupInterval)
	defer ticker.Stop()

	for {
		select {
		case <-s.cleanupDone:
			return
		case <-ticker.C:
			// Emit shard metrics before/after cleanup to observe load and retention
			s.logShardMetrics()
			s.cleanOldResults()
		}
	}
}

// logShardMetrics logs per-shard sizes and capacities for visibility under load.
func (s *InMemoryStore) logShardMetrics() {
	sizes := make([]int, s.shardCount)
	caps := make([]int, s.shardCount)
	total := 0

	for i := 0; i < s.shardCount; i++ {
		sh := s.shards[i]
		sh.mu.RLock()
		sizes[i] = len(sh.results)
		caps[i] = cap(sh.results)
		total += sizes[i]

		sh.mu.RUnlock()
	}

	s.logger.Debug().
		Int("shards", s.shardCount).
		Int("total_results", total).
		Ints("shard_sizes", sizes).
		Ints("shard_caps", caps).
		Msg("InMemoryStore shard metrics")
}

func (s *InMemoryStore) cleanOldResults() {
	// Time-aware cleanup: keep items seen in the last N minutes
	const keepWindow = 30 * time.Minute

	cutoff := time.Now().Add(-keepWindow)

	totalOrig := 0
	totalRemoved := 0

	for i := 0; i < s.shardCount; i++ {
		sh := s.shards[i]
		sh.mu.Lock()

		originalCount := len(sh.results)
		totalOrig += originalCount
		filtered := sh.results[:0]

		for j := range sh.results {
			if sh.results[j].LastSeen.After(cutoff) {
				filtered = append(filtered, sh.results[j])
			}
		}

		sh.results = filtered
		removed := originalCount - len(sh.results)
		totalRemoved += removed

		// Rebuild index after filtering
		sh.index = make(map[resultKey]int, len(sh.results))
		for j := range sh.results {
			r := &sh.results[j]
			sh.index[resultKey{host: r.Target.Host, port: r.Target.Port, mode: r.Target.Mode}] = j
		}

		sh.mu.Unlock()
	}

	if totalRemoved > 0 {
		s.logger.Debug().
			Int("originalCount", totalOrig).
			Int("removedCount", totalRemoved).
			Int("remainingCount", totalOrig-totalRemoved).
			Dur("keepWindow", keepWindow).
			Msg("Cleaned old results by LastSeen")
	}

	s.lastCleanup = time.Now()
}

func (s *InMemoryStore) Close() error {
	close(s.cleanupDone)

	return nil
}

// SaveHostResult updates the last-seen time (and possibly availability)
// for the given host. For in-memory store, we'll store the latest host
// result for each host.
func (s *InMemoryStore) SaveHostResult(_ context.Context, result *models.HostResult) error {
	// Rare path; scan all shards for matching host entries and update timestamps.
	for i := 0; i < s.shardCount; i++ {
		sh := s.shards[i]
		sh.mu.Lock()

		for j := range sh.results {
			existing := &sh.results[j]
			if existing.Target.Host != result.Host {
				continue
			}

			existing.LastSeen = result.LastSeen
			if result.Available {
				existing.Available = true
			}
		}

		sh.mu.Unlock()
	}

	return nil
}

// GetHostResults returns a slice of HostResult based on the provided filter.
func (s *InMemoryStore) GetHostResults(_ context.Context, filter *models.ResultFilter) ([]models.HostResult, error) {
	hostMap := make(map[string]*models.HostResult)

	// First pass: collect base host information across shards
	for i := 0; i < s.shardCount; i++ {
		sh := s.shards[i]
		sh.mu.RLock()

		for j := range sh.results {
			r := &sh.results[j]
			if !s.matchesFilter(r, filter) {
				continue
			}

			s.processHostResult(r, hostMap)
		}

		sh.mu.RUnlock()
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

	switch r.Target.Mode {
	case models.ModeICMP:
		s.updateICMPStatus(host, r)
	case models.ModeTCP:
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
	hostMap, portCounts, lastSweep := s.processResults()

	summary := s.buildSummary(hostMap, portCounts, lastSweep)

	return summary, nil
}

func (s *InMemoryStore) processResults() (hostResults map[string]*models.HostResult, portCounts map[int]int, lastSweep time.Time) {
	hostResults = make(map[string]*models.HostResult)
	portCounts = make(map[int]int)

	for i := 0; i < s.shardCount; i++ {
		sh := s.shards[i]
		sh.mu.RLock()

		for j := range sh.results {
			r := &sh.results[j]
			s.updateLastSweep(r, &lastSweep)
			s.updateHostAndPortResults(r, hostResults, portCounts)
		}

		sh.mu.RUnlock()
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

	if r.Target.Mode == models.ModeICMP {
		s.updateICMPStatus(host, r)
	}

	if r.Available {
		host.Available = true

		if r.Target.Mode == models.ModeTCP {
			s.updateTCPPortResults(host, r, portCounts)
		}
	}
}

func (*InMemoryStore) updateICMPStatus(host *models.HostResult, r *models.Result) {
	if host.ICMPStatus == nil {
		host.ICMPStatus = &models.ICMPStatus{}
	}

	host.ICMPStatus.Available = r.Available

	host.ICMPStatus.RoundTrip = r.RespTime

	host.ICMPStatus.PacketLoss = r.PacketLoss
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
	sh := s.selectShard(result.Target.Host, result.Target.Port, result.Target.Mode)
	sh.mu.Lock()

	key := resultKey{host: result.Target.Host, port: result.Target.Port, mode: result.Target.Mode}

	if idx, ok := sh.index[key]; ok {
		sh.results[idx] = *result
		sh.mu.Unlock()

		return nil
	}

	sh.results = append(sh.results, *result)
	sh.index[key] = len(sh.results) - 1
	sh.mu.Unlock()

	return nil
}

// GetResults returns a list of Results that match the filter.
func (s *InMemoryStore) GetResults(_ context.Context, filter *models.ResultFilter) ([]models.Result, error) {
	// Estimate capacity by summing per-shard lengths (racy but only for hinting)
	est := 0
	for i := 0; i < s.shardCount; i++ {
		est += len(s.shards[i].results)
	}

	filtered := make([]models.Result, 0, est)
	// Iterate shards
	for i := 0; i < s.shardCount; i++ {
		sh := s.shards[i]
		sh.mu.RLock()

		for j := range sh.results {
			r := &sh.results[j]
			if s.matchesFilter(r, filter) {
				filtered = append(filtered, *r)
			}
		}

		sh.mu.RUnlock()
	}

	return filtered, nil
}

// PruneResults removes old results that haven't been seen since 'age' ago.
func (s *InMemoryStore) PruneResults(_ context.Context, age time.Duration) error {
	cutoff := time.Now().Add(-age)

	for i := 0; i < s.shardCount; i++ {
		sh := s.shards[i]
		sh.mu.Lock()
		newResults := make([]models.Result, 0, len(sh.results))

		for j := range sh.results {
			r := &sh.results[j]
			if r.LastSeen.After(cutoff) {
				newResults = append(newResults, *r)
			}
		}

		sh.results = newResults
		sh.index = make(map[resultKey]int, len(sh.results))

		for j := range sh.results {
			r := &sh.results[j]
			sh.index[resultKey{host: r.Target.Host, port: r.Target.Port, mode: r.Target.Mode}] = j
		}

		sh.mu.Unlock()
	}

	return nil
}

// matchesFilter checks if a Result matches the provided filter.
// If filter is nil, matches all results.
func (*InMemoryStore) matchesFilter(result *models.Result, filter *models.ResultFilter) bool {
	if filter == nil {
		return true
	}

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
	if filter == nil {
		return true
	}

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
	if filter == nil {
		return true
	}

	return filter.Host == "" || result.Target.Host == filter.Host
}

// checkPort verifies if the result matches the specified port.
func checkPort(result *models.Result, filter *models.ResultFilter) bool {
	if filter == nil {
		return true
	}

	return filter.Port == 0 || result.Target.Port == filter.Port
}

// checkAvailability verifies if the result matches the specified availability.
func checkAvailability(result *models.Result, filter *models.ResultFilter) bool {
	if filter == nil {
		return true
	}

	return filter.Available == nil || result.Available == *filter.Available
}

// selectShard hashes the key to a shard index.
func (s *InMemoryStore) selectShard(host string, port int, mode models.SweepMode) *storeShard {
	// FNV-1a over host | mode | port
	h := fnv.New32a()
	_, _ = h.Write([]byte(host))
	_, _ = h.Write([]byte(string(mode)))
	// mix in port (2 bytes) to avoid collisions across same host/mode
	var b [2]byte
	// Safe conversion: network ports are 0-65535, fits in uint16
	var u uint16
	if port < 0 || port > 65535 {
		u = 0 // Default to port 0 for invalid ports
	} else {
		u = uint16(port) // #nosec G115 - port is validated to be within uint16 range
	}

	b[0] = byte(u)
	b[1] = byte(u >> 8)
	_, _ = h.Write(b[:])

	// Safe conversion: shardCount should be positive and reasonable
	if s.shardCount <= 0 {
		return s.shards[0] // Default to first shard if invalid count
	}

	idx := int(h.Sum32() % uint32(s.shardCount)) // #nosec G115 - shardCount is validated to be positive

	return s.shards[idx]
}
