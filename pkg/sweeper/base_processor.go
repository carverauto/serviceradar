package sweeper

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

const (
	startingBufferSize = 16
	portCountDivisor   = 4
)

type BaseProcessor struct {
	mu             sync.RWMutex
	hostMap        map[string]*models.HostResult
	portCounts     map[int]int
	lastSweepTime  time.Time
	firstSeenTimes map[string]time.Time
	totalHosts     int
	hostResultPool *sync.Pool
	portResultPool *sync.Pool
	portCount      int // Number of ports being scanned
	config         *models.Config
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
	p.mu.Lock()
	if newPortCount != p.portCount {
		p.portCount = newPortCount
		p.config = config
		p.hostResultPool = newPool
	}
	p.mu.Unlock()

	// Clean up after releasing the lock
	if newPortCount != p.portCount {
		log.Printf("Cleaning up existing results")
		p.cleanup()
	}
}

func (p *BaseProcessor) cleanup() {
	p.mu.Lock()
	defer p.mu.Unlock()

	log.Printf("Starting cleanup")

	// Get all hosts to clean up
	hostsToClean := make([]*models.HostResult, 0, len(p.hostMap))
	for _, host := range p.hostMap {
		hostsToClean = append(hostsToClean, host)
	}

	// Reset maps first
	p.hostMap = make(map[string]*models.HostResult)
	p.portCounts = make(map[int]int)
	p.firstSeenTimes = make(map[string]time.Time)
	p.totalHosts = 0
	p.lastSweepTime = time.Time{}

	// Clean up hosts outside the lock
	p.mu.Unlock()

	for _, host := range hostsToClean {
		// Clean up port results
		for _, pr := range host.PortResults {
			// Reset and return port result to pool
			pr.Port = 0
			pr.Available = false
			pr.RespTime = 0
			pr.Service = ""
			p.portResultPool.Put(pr)
		}

		// Reset and return host result to pool
		host.Host = ""
		host.PortResults = host.PortResults[:0]
		host.ICMPStatus = nil
		host.ResponseTime = 0
		p.hostResultPool.Put(host)
	}

	p.mu.Lock() // Re-acquire lock before returning (due to defer)

	log.Printf("Cleanup complete")
}

func (p *BaseProcessor) Process(result *models.Result) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	// Log entry point of each result for debugging
	log.Printf("Processing result for host %s mode %s (available: %v)",
		result.Target.Host, result.Target.Mode, result.Available)

	p.updateLastSweepTime()
	p.updateTotalHosts(result)

	host := p.getOrCreateHost(result.Target.Host, time.Now())
	host.LastSeen = time.Now()

	switch result.Target.Mode {
	case models.ModeICMP:
		// Log before ICMP processing
		log.Printf("Processing ICMP result for %s (available: %v, response time: %v)",
			result.Target.Host, result.Available, result.RespTime)

		p.processICMPResult(host, result)

	case models.ModeTCP:
		p.processTCPResult(host, result)
	}

	return nil
}

func (p *BaseProcessor) processICMPResult(host *models.HostResult, result *models.Result) {
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

	// Log after processing
	log.Printf("Updated ICMP status for %s: available=%v, roundtrip=%v",
		host.Host, host.ICMPStatus.Available, host.ICMPStatus.RoundTrip)
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

	log.Printf("Summary stats - Total hosts: %d, Available: %d, ICMP responding: %d",
		len(p.hostMap), availableHosts, icmpHosts)

	actualTotalHosts := len(p.hostMap)
	if actualTotalHosts == 0 {
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

func (p *BaseProcessor) updateTotalHosts(result *models.Result) {
	if result.Target.Metadata != nil {
		if totalHosts, ok := result.Target.Metadata["total_hosts"].(int); ok {
			p.totalHosts = totalHosts
		}
	}
}

func (p *BaseProcessor) processTCPResult(host *models.HostResult, result *models.Result) {
	if result.Available {
		host.Available = true
		p.updatePortStatus(host, result)
	}
}

func (p *BaseProcessor) updatePortStatus(host *models.HostResult, result *models.Result) {
	var found bool

	for _, port := range host.PortResults {
		if port.Port == result.Target.Port {
			port.Available = true
			port.RespTime = result.RespTime
			found = true

			break
		}
	}

	if !found {
		portResult := p.portResultPool.Get().(*models.PortResult)
		portResult.Port = result.Target.Port
		portResult.Available = true
		portResult.RespTime = result.RespTime

		host.PortResults = append(host.PortResults, portResult)
		p.portCounts[result.Target.Port]++
	}
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

		hosts = append(hosts, *host)
	}

	actualTotalHosts := len(p.hostMap)
	if actualTotalHosts == 0 {
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
