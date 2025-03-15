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
	"log"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	startingBufferSize = 16
	portCountDivisor   = 4
)

type BaseProcessor struct {
	mu                sync.RWMutex
	hostMap           map[string]*models.HostResult
	portCounts        map[int]int
	lastSweepTime     time.Time
	firstSeenTimes    map[string]time.Time
	totalHosts        int
	hostResultPool    *sync.Pool
	portResultPool    *sync.Pool
	portCount         int // Number of ports being scanned
	config            *models.Config
	processedNetworks map[string]bool // Track which networks we've already processed
}

func NewBaseProcessor(config *models.Config) *BaseProcessor {
	portCount := len(config.Ports)
	if portCount == 0 {
		portCount = 100
	}

	// Create pools before initializing the processor
	hostPool := &sync.Pool{
		New: func() interface{} {
			return &models.HostResult{
				PortResults: make([]*models.PortResult, 0, startingBufferSize),
			}
		},
	}

	portPool := &sync.Pool{
		New: func() interface{} {
			return &models.PortResult{}
		},
	}

	p := &BaseProcessor{
		hostMap:        make(map[string]*models.HostResult),
		portCounts:     make(map[int]int),
		firstSeenTimes: make(map[string]time.Time),
		portCount:      portCount,
		config:         config,
		hostResultPool: hostPool,
		portResultPool: portPool,
	}

	return p
}

func (p *BaseProcessor) UpdateConfig(config *models.Config) {
	// First update the configuration
	newPortCount := len(config.Ports)
	if newPortCount == 0 {
		newPortCount = 100
	}

	log.Printf("Updating port count from %d to %d", p.portCount, newPortCount)

	// Create new pool outside the lock
	newPool := &sync.Pool{
		New: func() interface{} {
			return &models.HostResult{
				// Start with 25% capacity, will grow if needed
				PortResults: make([]*models.PortResult, 0, newPortCount/portCountDivisor),
			}
		},
	}

	// Take lock only for the update
	oldPortCount := p.portCount

	p.mu.Lock()
	if newPortCount != p.portCount {
		p.portCount = newPortCount
		p.config = config
		p.hostResultPool = newPool
	}
	p.mu.Unlock()

	// Only cleanup if you actually want to flush out stale data.
	// In this case, we want to preserve existing hosts so we don’t call cleanup.
	if newPortCount != oldPortCount {
		log.Printf("Port count updated from %d to %d (preserving existing host data)", oldPortCount, newPortCount)
	}
}

func (p *BaseProcessor) cleanup() {
	p.mu.Lock()
	hostsToClean := make([]*models.HostResult, 0, len(p.hostMap))

	for _, host := range p.hostMap {
		hostsToClean = append(hostsToClean, host)
	}

	// Reset internal maps, including portCounts.
	p.hostMap = make(map[string]*models.HostResult)
	p.portCounts = make(map[int]int) // Explicitly reset the portCounts map
	p.firstSeenTimes = make(map[string]time.Time)
	p.totalHosts = 0
	p.lastSweepTime = time.Time{}

	p.mu.Unlock()

	// Perform cleanup outside.
	for _, host := range hostsToClean {
		for _, pr := range host.PortResults {
			pr.Port = 0
			pr.Available = false
			pr.RespTime = 0
			pr.Service = ""
			p.portResultPool.Put(pr)
		}

		host.Host = ""
		host.PortResults = host.PortResults[:0]
		host.ICMPStatus = nil
		host.ResponseTime = 0

		p.hostResultPool.Put(host)
	}

	log.Printf("Cleanup complete")
}

func (p *BaseProcessor) Process(result *models.Result) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	p.updateLastSweepTime()
	p.updateTotalHosts(result)

	host := p.getOrCreateHost(result.Target.Host, time.Now())
	host.LastSeen = time.Now()

	switch result.Target.Mode {
	case models.ModeICMP:
		p.processICMPResult(host, result)

	case models.ModeTCP:
		p.processTCPResult(host, result)
	}

	return nil
}

func (p *BaseProcessor) processTCPResult(host *models.HostResult, result *models.Result) {
	if result.Available {
		p.updatePortStatus(host, result)
	}
}

func (p *BaseProcessor) updatePortStatus(host *models.HostResult, result *models.Result) {
	found := false

	for i := range host.PortResults {
		if host.PortResults[i].Port == result.Target.Port {
			// Update existing port result
			host.PortResults[i].Available = result.Available
			host.PortResults[i].RespTime = result.RespTime
			found = true

			break
		}
	}

	if !found {
		// Create a new PortResult and add it to the host
		portResult := &models.PortResult{
			Port:      result.Target.Port,
			Available: result.Available,
			RespTime:  result.RespTime,
		}
		host.PortResults = append(host.PortResults, portResult)
		p.portCounts[result.Target.Port]++
	}
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

func (p *BaseProcessor) GetSummary(ctx context.Context) (*models.SweepSummary, error) {
	p.mu.RLock()
	defer p.mu.RUnlock()

	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
	}

	lastSweep := p.lastSweepTime
	if lastSweep.IsZero() {
		lastSweep = time.Now()
	}

	availableHosts := 0
	icmpHosts := 0 // Track ICMP-responding hosts
	ports := make([]models.PortCount, 0, len(p.portCounts))
	hosts := make([]models.HostResult, 0, len(p.hostMap))

	for port, count := range p.portCounts {
		ports = append(ports, models.PortCount{
			Port:      port,
			Available: count,
		})
	}

	for _, host := range p.hostMap {
		if host.Available {
			availableHosts++
		}
		// Count ICMP-responding hosts
		if host.ICMPStatus != nil && host.ICMPStatus.Available {
			icmpHosts++
		}

		hosts = append(hosts, *host)
	}

	log.Printf("Summary stats - Total hosts: %d, Available: %d, ICMP responding: %d, Actual total defined in config: %d",
		len(p.hostMap), availableHosts, icmpHosts, p.totalHosts)

	// Here's the important change - don't use the network size from config if we have actual data
	actualTotalHosts := p.totalHosts
	if len(p.hostMap) > 0 {
		// We have some processed hosts, but we want to report the real total from config
		actualTotalHosts = p.totalHosts
	}

	return &models.SweepSummary{
		TotalHosts:     actualTotalHosts,
		AvailableHosts: availableHosts,
		LastSweep:      lastSweep.Unix(),
		Ports:          ports,
		Hosts:          hosts,
	}, nil
}

func (p *BaseProcessor) updateLastSweepTime() {
	now := time.Now()
	if now.After(p.lastSweepTime) {
		p.lastSweepTime = now
	}
}

// updateTotalHosts updates the totalHosts value based on result metadata
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
	} else if p.totalHosts == 0 {
		p.totalHosts = totalHosts
	}
}

func (p *BaseProcessor) hasMetadata(result *models.Result) bool {
	return result.Target.Metadata != nil
}

func (p *BaseProcessor) getTotalHostsFromMetadata(result *models.Result) (int, bool) {
	totalHosts, ok := result.Target.Metadata["total_hosts"].(int)
	return totalHosts, ok
}

func (p *BaseProcessor) shouldUpdateNetworkTotal(result *models.Result) bool {
	networkName, hasNetwork := result.Target.Metadata["network"].(string)
	if !hasNetwork {
		return false
	}

	if p.processedNetworks == nil {
		p.processedNetworks = make(map[string]bool)
	}

	return !p.processedNetworks[networkName]
}

func (p *BaseProcessor) updateNetworkTotal(result *models.Result, totalHosts int) {
	networkName := result.Target.Metadata["network"].(string) // Safe due to prior check
	p.processedNetworks[networkName] = true
	p.totalHosts = totalHosts
}

func (p *BaseProcessor) getOrCreateHost(hostAddr string, now time.Time) *models.HostResult {
	host, exists := p.hostMap[hostAddr]
	if !exists {
		host = p.hostResultPool.Get().(*models.HostResult)

		// Reset/initialize the host result
		host.Host = hostAddr
		host.Available = false
		host.PortResults = host.PortResults[:0] // Clear slice but keep capacity
		host.ICMPStatus = nil
		host.ResponseTime = 0

		firstSeen := now
		if seen, ok := p.firstSeenTimes[hostAddr]; ok {
			firstSeen = seen
		} else {
			p.firstSeenTimes[hostAddr] = firstSeen
		}

		host.FirstSeen = firstSeen
		host.LastSeen = now

		p.hostMap[hostAddr] = host
	}

	return host
}
