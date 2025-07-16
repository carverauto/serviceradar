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

package sweeper

import (
	"context"
	"hash/fnv"
	"log"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultShardCount     = 16    // Number of shards for load distribution
	expectedHostsPerShard = 625   // 10,000 hosts / 16 shards
	expectedPortsPerHost  = 5     // Average ports per host
	fastModeThreshold     = 50000 // Skip pool cleanup above this threshold
)

// ProcessorShard represents a single shard of the processor
type ProcessorShard struct {
	mu             sync.RWMutex
	hostMap        map[string]*models.HostResult
	portCounts     map[int]int
	lastSweepTime  time.Time
	firstSeenTimes map[string]time.Time
}

type BaseProcessor struct {
	shards              []*ProcessorShard
	shardCount          int
	totalHosts          int
	totalHostsMu        sync.RWMutex
	hostResultPool      *sync.Pool
	portResultPool      *sync.Pool
	portCount           int // Number of ports being scanned
	config              *models.Config
	configMu            sync.RWMutex
	processedNetworks   map[string]bool // Track which networks we've already processed
	processedNetworksMu sync.RWMutex
}

func NewBaseProcessor(config *models.Config) *BaseProcessor {
	portCount := len(config.Ports)
	if portCount == 0 {
		portCount = 100
	}

	// Pre-allocate pools for production scale
	hostPool := &sync.Pool{
		New: func() interface{} {
			return &models.HostResult{
				PortResults: make([]*models.PortResult, 0, expectedPortsPerHost),
				PortMap:     make(map[int]*models.PortResult, expectedPortsPerHost),
			}
		},
	}

	portPool := &sync.Pool{
		New: func() interface{} {
			return &models.PortResult{}
		},
	}

	// Initialize shards
	shards := make([]*ProcessorShard, defaultShardCount)
	for i := 0; i < defaultShardCount; i++ {
		shards[i] = &ProcessorShard{
			hostMap:        make(map[string]*models.HostResult, expectedHostsPerShard),
			portCounts:     make(map[int]int),
			firstSeenTimes: make(map[string]time.Time, expectedHostsPerShard),
		}
	}

	p := &BaseProcessor{
		shards:            shards,
		shardCount:        defaultShardCount,
		portCount:         portCount,
		config:            config,
		hostResultPool:    hostPool,
		portResultPool:    portPool,
		processedNetworks: make(map[string]bool),
	}

	return p
}

// getShardIndex returns the shard index for a given host using FNV hash
func (p *BaseProcessor) getShardIndex(host string) int {
	h := fnv.New32a()

	_, err := h.Write([]byte(host))
	if err != nil {
		return 0
	}

	return int(h.Sum32()) % p.shardCount
}

func (p *BaseProcessor) UpdateConfig(config *models.Config) {
	p.configMu.Lock()
	defer p.configMu.Unlock()

	oldPortCount := p.portCount
	newPortCount := len(config.Ports)
	if newPortCount == 0 {
		newPortCount = 100
	}

	// Always update the internal config and port count
	p.config = config
	p.portCount = newPortCount

	// The pool doesn't need to be recreated. The "grow on demand" logic
	// will automatically use the new p.portCount when upgrading hosts.
	if newPortCount != oldPortCount {
		log.Printf("Processor config updated. Port count changed from %d to %d.", oldPortCount, newPortCount)
	}
}

// shardCleanupResult holds the results of cleaning up a single shard
type shardCleanupResult struct {
	hosts     []*models.HostResult
	hostCount int
	portCount int
}

func (p *BaseProcessor) cleanup() {
	// Phase 1: Collect hosts from all shards and reset global counters
	allHostsToClean, totalHosts, totalPorts := p.collectHostsFromShards()

	// Reset global counters
	p.resetGlobalCounters()

	// Phase 2: Cleanup and pool recycling
	p.performCleanupAndRecycling(allHostsToClean, totalHosts, totalPorts)
}

// collectHostsFromShards collects hosts from all shards in parallel and returns the results
func (p *BaseProcessor) collectHostsFromShards() (allHostsToClean [][]*models.HostResult, totalHosts, totalPorts int) {
	results := make([]shardCleanupResult, p.shardCount)

	// Collect hosts from all shards in parallel
	var wg sync.WaitGroup

	for i := 0; i < p.shardCount; i++ {
		wg.Add(1)

		go func(shardIndex int) {
			defer wg.Done()

			shard := p.shards[shardIndex]
			shard.mu.Lock()

			hostsToClean := make([]*models.HostResult, 0, len(shard.hostMap))

			var shardPortCount int

			for _, host := range shard.hostMap {
				hostsToClean = append(hostsToClean, host)
				shardPortCount += len(host.PortResults)
			}

			// Reset shard maps
			shard.hostMap = make(map[string]*models.HostResult, expectedHostsPerShard)
			shard.portCounts = make(map[int]int)
			shard.firstSeenTimes = make(map[string]time.Time, expectedHostsPerShard)
			shard.lastSweepTime = time.Time{}

			results[shardIndex] = shardCleanupResult{
				hosts:     hostsToClean,
				hostCount: len(hostsToClean),
				portCount: shardPortCount,
			}

			shard.mu.Unlock()
		}(i)
	}

	wg.Wait()

	// Aggregate results from all shards
	allHostsToClean = make([][]*models.HostResult, p.shardCount)

	for i, result := range results {
		allHostsToClean[i] = result.hosts
		totalHosts += result.hostCount
		totalPorts += result.portCount
	}

	return allHostsToClean, totalHosts, totalPorts
}

// resetGlobalCounters resets the global counters used by the processor
func (p *BaseProcessor) resetGlobalCounters() {
	p.totalHostsMu.Lock()
	p.totalHosts = 0
	p.totalHostsMu.Unlock()

	p.processedNetworksMu.Lock()
	p.processedNetworks = make(map[string]bool)
	p.processedNetworksMu.Unlock()
}

// performCleanupAndRecycling handles the cleanup and recycling of resources
func (p *BaseProcessor) performCleanupAndRecycling(allHostsToClean [][]*models.HostResult, totalHosts, totalPorts int) {
	if totalPorts > fastModeThreshold {
		log.Printf("Cleanup complete (fast mode: %d hosts, %d ports)", totalHosts, totalPorts)
		return
	}

	// Normal cleanup for smaller datasets - parallel processing
	var wg sync.WaitGroup

	for _, hostsToClean := range allHostsToClean {
		wg.Add(1)

		go func(hosts []*models.HostResult) {
			defer wg.Done()
			p.cleanupHostBatch(hosts)
		}(hostsToClean)
	}

	wg.Wait()

	log.Printf("Cleanup complete (%d hosts, %d ports)", totalHosts, totalPorts)
}

// cleanupHostBatch cleans up a batch of hosts and returns them to the pool
func (p *BaseProcessor) cleanupHostBatch(hosts []*models.HostResult) {
	for _, host := range hosts {
		// Clean up port results
		for _, pr := range host.PortResults {
			pr.Port = 0
			pr.Available = false
			pr.RespTime = 0
			pr.Service = ""
			p.portResultPool.Put(pr)
		}

		// Reset host and return to pool
		host.Host = ""
		
		// Explicitly nil out the slices and maps to allow the GC
		// to reclaim the large backing arrays, even if the pool
		// holds onto the HostResult struct itself
		host.PortResults = nil
		host.PortMap = nil

		host.ICMPStatus = nil
		host.ResponseTime = 0
		p.hostResultPool.Put(host)
	}
}

func (p *BaseProcessor) Process(result *models.Result) error {
	// Get the appropriate shard for this host
	shardIndex := p.getShardIndex(result.Target.Host)
	shard := p.shards[shardIndex]

	shard.mu.Lock()
	defer shard.mu.Unlock()

	p.updateLastSweepTime(shard)
	p.updateTotalHosts(result)

	now := time.Now()
	host := p.getOrCreateHost(shard, result.Target.Host, now)

	// Update host timestamps
	host.LastSeen = now

	// Propagate timestamps back to the result so stores have accurate
	// first/last seen values.
	result.FirstSeen = host.FirstSeen
	result.LastSeen = host.LastSeen

	switch result.Target.Mode {
	case models.ModeICMP:
		p.processICMPResult(host, result)

	case models.ModeTCP:
		p.processTCPResult(shard, host, result)
	}

	return nil
}

func (p *BaseProcessor) processTCPResult(shard *ProcessorShard, host *models.HostResult, result *models.Result) {
	if result.Available {
		p.updatePortStatus(shard, host, result)
	}
}

func (p *BaseProcessor) updatePortStatus(shard *ProcessorShard, host *models.HostResult, result *models.Result) {
	// Use port map for O(1) lookup instead of linear search
	if existingPort, exists := host.PortMap[result.Target.Port]; exists {
		// Update existing port result
		existingPort.Available = result.Available
		existingPort.RespTime = result.RespTime

		return
	}

	// If the host's port list is at capacity, it's time to upgrade its storage
	if len(host.PortResults) >= cap(host.PortResults) {
		p.configMu.RLock()
		newCapacity := p.portCount
		p.configMu.RUnlock()

		// Only perform the expensive upgrade if the new capacity is larger
		if newCapacity > cap(host.PortResults) {
			log.Printf("Upgrading port capacity for host %s from %d to %d", host.Host, cap(host.PortResults), newCapacity)
			
			// Re-allocate PortResults slice with the new, larger capacity
			newPortResults := make([]*models.PortResult, len(host.PortResults), newCapacity)
			copy(newPortResults, host.PortResults)
			host.PortResults = newPortResults

			// Re-create PortMap with the new capacity for better performance
			newPortMap := make(map[int]*models.PortResult, newCapacity)
			for k, v := range host.PortMap {
				newPortMap[k] = v
			}
			host.PortMap = newPortMap
		}
	}

	// Create new port result - use pool for allocation
	portResult := p.portResultPool.Get().(*models.PortResult)
	portResult.Port = result.Target.Port
	portResult.Available = result.Available
	portResult.RespTime = result.RespTime
	portResult.Service = ""

	// Add to both slice and map
	host.PortResults = append(host.PortResults, portResult)
	host.PortMap[result.Target.Port] = portResult
	shard.portCounts[result.Target.Port]++
}

func (*BaseProcessor) processICMPResult(host *models.HostResult, result *models.Result) {
	// Always initialize ICMPStatus
	if host.ICMPStatus == nil {
		host.ICMPStatus = &models.ICMPStatus{}
	}

	// Update availability and response time
	if result.Available {
		host.Available = true
		host.ICMPStatus.Available = true
		host.ICMPStatus.PacketLoss = 0
		host.ICMPStatus.RoundTrip = result.RespTime
	} else {
		host.ICMPStatus.Available = false
		host.ICMPStatus.PacketLoss = 100
		host.ICMPStatus.RoundTrip = 0
	}

	// Set the overall response time for the host
	if result.RespTime > 0 {
		host.ResponseTime = result.RespTime
	}
}

// shardSummary holds aggregated data from a single shard
type shardSummary struct {
	hosts          []models.HostResult
	portCounts     map[int]int
	availableHosts int
	icmpHosts      int
	lastSweep      time.Time
	totalHosts     int
}

// collectShardSummaries collects data from all shards in parallel
func (p *BaseProcessor) collectShardSummaries() []shardSummary {
	summaries := make([]shardSummary, p.shardCount)

	var wg sync.WaitGroup

	for i := 0; i < p.shardCount; i++ {
		wg.Add(1)

		go func(shardIndex int) {
			defer wg.Done()

			shard := p.shards[shardIndex]

			shard.mu.RLock()
			defer shard.mu.RUnlock()

			summary := shardSummary{
				hosts:      make([]models.HostResult, 0, len(shard.hostMap)),
				portCounts: make(map[int]int),
				lastSweep:  shard.lastSweepTime,
			}

			// Copy port counts
			for port, count := range shard.portCounts {
				summary.portCounts[port] = count
			}

			// Copy host data
			for _, host := range shard.hostMap {
				if host.Available {
					summary.availableHosts++
				}

				if host.ICMPStatus != nil && host.ICMPStatus.Available {
					summary.icmpHosts++
				}

				summary.hosts = append(summary.hosts, *host)
			}

			summary.totalHosts = len(shard.hostMap)
			summaries[shardIndex] = summary
		}(i)
	}

	wg.Wait()

	return summaries
}

// aggregatedShardSummary holds the combined data from all shard summaries
type aggregatedShardSummary struct {
	hosts          []models.HostResult
	portCounts     map[int]int
	availableHosts int
	icmpHosts      int
	totalHosts     int
	lastSweep      time.Time
}

// aggregateShardSummaries combines data from all shard summaries
func aggregateShardSummaries(summaries []shardSummary) aggregatedShardSummary {
	var result aggregatedShardSummary
	result.hosts = make([]models.HostResult, 0)
	result.portCounts = make(map[int]int)

	for _, summary := range summaries {
		// Aggregate hosts
		result.hosts = append(result.hosts, summary.hosts...)

		// Aggregate port counts
		for port, count := range summary.portCounts {
			result.portCounts[port] += count
		}

		// Aggregate counters
		result.availableHosts += summary.availableHosts
		result.icmpHosts += summary.icmpHosts
		result.totalHosts += summary.totalHosts

		// Find latest sweep time
		if summary.lastSweep.After(result.lastSweep) {
			result.lastSweep = summary.lastSweep
		}
	}

	return result
}

// convertPortCountsToSlice converts a map of port counts to a slice of PortCount structs
func convertPortCountsToSlice(portCounts map[int]int) []models.PortCount {
	ports := make([]models.PortCount, 0, len(portCounts))

	for port, count := range portCounts {
		ports = append(ports, models.PortCount{
			Port:      port,
			Available: count,
		})
	}

	return ports
}

func (p *BaseProcessor) GetSummary(ctx context.Context) (*models.SweepSummary, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
	}

	// Collect data from all shards in parallel
	summaries := p.collectShardSummaries()

	// Aggregate results from all shards
	aggregated := aggregateShardSummaries(summaries)

	// Convert aggregated port counts to slice
	ports := convertPortCountsToSlice(aggregated.portCounts)

	latestSweep := aggregated.lastSweep
	if latestSweep.IsZero() {
		latestSweep = time.Now()
	}

	// Get global total hosts count
	p.totalHostsMu.RLock()
	actualTotalHosts := p.totalHosts
	p.totalHostsMu.RUnlock()

	if actualTotalHosts == 0 {
		actualTotalHosts = aggregated.totalHosts
	}

	log.Printf("Summary stats - Total hosts: %d, Available: %d, ICMP responding: %d, Actual total defined in config: %d",
		aggregated.totalHosts, aggregated.availableHosts, aggregated.icmpHosts, actualTotalHosts)

	return &models.SweepSummary{
		TotalHosts:     actualTotalHosts,
		AvailableHosts: aggregated.availableHosts,
		LastSweep:      latestSweep.Unix(),
		Ports:          ports,
		Hosts:          aggregated.hosts,
	}, nil
}

func (*BaseProcessor) updateLastSweepTime(shard *ProcessorShard) {
	now := time.Now()
	if now.After(shard.lastSweepTime) {
		shard.lastSweepTime = now
	}
}

// updateTotalHosts updates the totalHosts value based on result metadata.
func (p *BaseProcessor) updateTotalHosts(result *models.Result) {
	if !p.hasMetadata(result) {
		return
	}

	totalHosts, ok := p.getTotalHostsFromMetadata(result)
	if !ok {
		return
	}

	if p.shouldUpdateNetworkTotal(result) {
		p.updateNetworkTotal(result, totalHosts)
	} else {
		p.totalHostsMu.RLock()
		currentTotal := p.totalHosts
		p.totalHostsMu.RUnlock()

		if currentTotal == 0 {
			p.totalHostsMu.Lock()
			if p.totalHosts == 0 { // Double-check after acquiring write lock
				p.totalHosts = totalHosts
			}
			p.totalHostsMu.Unlock()
		}
	}
}

func (*BaseProcessor) hasMetadata(result *models.Result) bool {
	return result.Target.Metadata != nil
}

func (*BaseProcessor) getTotalHostsFromMetadata(result *models.Result) (int, bool) {
	totalHosts, ok := result.Target.Metadata["total_hosts"].(int)

	return totalHosts, ok
}

func (p *BaseProcessor) shouldUpdateNetworkTotal(result *models.Result) bool {
	networkName, hasNetwork := result.Target.Metadata["network"].(string)
	if !hasNetwork {
		return false
	}

	p.processedNetworksMu.RLock()
	processed := p.processedNetworks[networkName]
	p.processedNetworksMu.RUnlock()

	return !processed
}

func (p *BaseProcessor) updateNetworkTotal(result *models.Result, totalHosts int) {
	networkName := result.Target.Metadata["network"].(string) // Safe due to prior check

	p.processedNetworksMu.Lock()
	p.processedNetworks[networkName] = true
	p.processedNetworksMu.Unlock()

	p.totalHostsMu.Lock()
	p.totalHosts = totalHosts
	p.totalHostsMu.Unlock()
}

func (p *BaseProcessor) getOrCreateHost(shard *ProcessorShard, hostAddr string, now time.Time) *models.HostResult {
	host, exists := shard.hostMap[hostAddr]
	if !exists {
		host = p.hostResultPool.Get().(*models.HostResult)

		// Reset/initialize the host result
		host.Host = hostAddr
		host.Available = false
		
		// If we are reusing an object from the pool that was cleaned up,
		// its slices/maps will be nil. We need to re-initialize them.
		if host.PortResults == nil {
			host.PortResults = make([]*models.PortResult, 0, expectedPortsPerHost)
		} else {
			host.PortResults = host.PortResults[:0] // Clear slice but keep capacity
		}

		if host.PortMap == nil {
			host.PortMap = make(map[int]*models.PortResult, expectedPortsPerHost)
		} else {
			for k := range host.PortMap {
				delete(host.PortMap, k)
			}
		}

		host.ICMPStatus = nil
		host.ResponseTime = 0

		firstSeen := now
		if seen, ok := shard.firstSeenTimes[hostAddr]; ok {
			firstSeen = seen
		} else {
			shard.firstSeenTimes[hostAddr] = firstSeen
		}

		host.FirstSeen = firstSeen
		host.LastSeen = now

		shard.hostMap[hostAddr] = host
	}

	return host
}

// GetPortCounts aggregates port counts across all shards
func (p *BaseProcessor) GetPortCounts() map[int]int {
	aggregatedCounts := make(map[int]int)

	for i := 0; i < p.shardCount; i++ {
		shard := p.shards[i]
		shard.mu.RLock()

		for port, count := range shard.portCounts {
			aggregatedCounts[port] += count
		}

		shard.mu.RUnlock()
	}

	return aggregatedCounts
}

func (p *BaseProcessor) GetHostMap() map[string]*models.HostResult {
	aggregatedHosts := make(map[string]*models.HostResult)

	for i := 0; i < p.shardCount; i++ {
		shard := p.shards[i]
		shard.mu.RLock()

		for host, result := range shard.hostMap {
			aggregatedHosts[host] = result
		}

		shard.mu.RUnlock()
	}

	return aggregatedHosts
}

func (p *BaseProcessor) GetHostCount() int {
	totalHosts := 0

	for i := 0; i < p.shardCount; i++ {
		shard := p.shards[i]

		shard.mu.RLock()
		totalHosts += len(shard.hostMap)
		shard.mu.RUnlock()
	}

	return totalHosts
}

func (p *BaseProcessor) GetFirstSeenTimes() map[string]time.Time {
	aggregatedTimes := make(map[string]time.Time)

	for i := 0; i < p.shardCount; i++ {
		shard := p.shards[i]

		shard.mu.RLock()

		for host, time := range shard.firstSeenTimes {
			aggregatedTimes[host] = time
		}

		shard.mu.RUnlock()
	}

	return aggregatedTimes
}

func (p *BaseProcessor) GetLatestSweepTime() time.Time {
	var latest time.Time

	for i := 0; i < p.shardCount; i++ {
		shard := p.shards[i]
		shard.mu.RLock()

		if shard.lastSweepTime.After(latest) {
			latest = shard.lastSweepTime
		}

		shard.mu.RUnlock()
	}

	return latest
}

// shardStreamResult holds aggregated results from a single shard
type shardStreamResult struct {
	portCounts     map[int]int
	availableHosts int
	icmpHosts      int
	totalHosts     int
	lastSweep      time.Time
}

// processShardForSummary processes a single shard and sends host results to the channel
func (p *BaseProcessor) processShardForSummary(
	ctx context.Context,
	shardIndex int,
	hostCh chan<- models.HostResult,
) (shardStreamResult, bool) {
	shard := p.shards[shardIndex]

	shard.mu.RLock()
	defer shard.mu.RUnlock()

	result := shardStreamResult{
		portCounts: make(map[int]int),
		lastSweep:  shard.lastSweepTime,
	}

	// Aggregate port counts
	for port, count := range shard.portCounts {
		result.portCounts[port] = count
	}

	// Stream host data and count
	for _, host := range shard.hostMap {
		select {
		case hostCh <- *host:
			if host.Available {
				result.availableHosts++
			}

			if host.ICMPStatus != nil && host.ICMPStatus.Available {
				result.icmpHosts++
			}

			result.totalHosts++
		case <-ctx.Done():
			return result, false
		}
	}

	return result, true
}

// aggregateShardResults combines results from all shards into a single summary
func (*BaseProcessor) aggregateShardResults(results []shardStreamResult) (
	aggregatedPortCounts map[int]int, totalAvailableHosts int, totalIcmpHosts int, totalHostCount int, latestSweep time.Time,
) {
	aggregatedPortCounts = make(map[int]int)

	for _, result := range results {
		// Aggregate port counts
		for port, count := range result.portCounts {
			aggregatedPortCounts[port] += count
		}

		// Aggregate counters
		totalAvailableHosts += result.availableHosts
		totalIcmpHosts += result.icmpHosts
		totalHostCount += result.totalHosts

		// Find latest sweep time
		if result.lastSweep.After(latestSweep) {
			latestSweep = result.lastSweep
		}
	}

	return aggregatedPortCounts, totalAvailableHosts, totalIcmpHosts, totalHostCount, latestSweep
}

// GetSummaryStream provides a streaming interface for large-scale summaries
// to avoid building large slices in memory. Sends HostResult objects to the channel.
func (p *BaseProcessor) GetSummaryStream(ctx context.Context, hostCh chan<- models.HostResult) (*models.SweepSummary, error) {
	defer close(hostCh)

	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
	}

	results := make([]shardStreamResult, p.shardCount)

	var wg sync.WaitGroup

	// Process each shard in parallel, streaming hosts as we go
	for i := 0; i < p.shardCount; i++ {
		wg.Add(1)

		go func(shardIndex int) {
			defer wg.Done()

			result, ok := p.processShardForSummary(ctx, shardIndex, hostCh)
			if ok {
				results[shardIndex] = result
			}
		}(i)
	}

	wg.Wait()

	// Aggregate results from all shards
	aggregatedPortCounts, totalAvailableHosts, totalIcmpHosts, totalHostCount, latestSweep :=
		p.aggregateShardResults(results)

	// Convert aggregated port counts to slice
	ports := make([]models.PortCount, 0, len(aggregatedPortCounts))
	for port, count := range aggregatedPortCounts {
		ports = append(ports, models.PortCount{
			Port:      port,
			Available: count,
		})
	}

	if latestSweep.IsZero() {
		latestSweep = time.Now()
	}

	// Get global total hosts count
	p.totalHostsMu.RLock()
	actualTotalHosts := p.totalHosts
	p.totalHostsMu.RUnlock()

	if actualTotalHosts == 0 {
		actualTotalHosts = totalHostCount
	}

	log.Printf("Streaming summary stats - Total hosts: %d, Available: %d, ICMP responding: %d",
		totalHostCount, totalAvailableHosts, totalIcmpHosts)

	// Return summary without the hosts slice to save memory
	return &models.SweepSummary{
		TotalHosts:     actualTotalHosts,
		AvailableHosts: totalAvailableHosts,
		LastSweep:      latestSweep.Unix(),
		Ports:          ports,
		Hosts:          nil, // Hosts are streamed via channel
	}, nil
}
