package sweeper

import (
	"context"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

type ProcessorLocker interface {
	RLock()
	RUnlock()
}

type BaseProcessor struct {
	mu             sync.RWMutex
	hostMap        map[string]*models.HostResult
	portCounts     map[int]int
	lastSweepTime  time.Time
	firstSeenTimes map[string]time.Time
	totalHosts     int
	hostResultPool sync.Pool
	portCount      int // Number of ports being scanned
	config         *models.Config
}

func NewBaseProcessor(config *models.Config) *BaseProcessor {
	portCount := len(config.Ports)
	if portCount == 0 {
		// Default to a reasonable size if no ports specified
		portCount = 100 // Increased default given typical usage
	}

	p := &BaseProcessor{
		hostMap:        make(map[string]*models.HostResult),
		portCounts:     make(map[int]int),
		firstSeenTimes: make(map[string]time.Time),
		portCount:      portCount,
		config:         config,
	}

	// Initialize the pool with capacity for all ports
	p.hostResultPool.New = func() interface{} {
		return &models.HostResult{
			// For 2300+ ports, we might want to start smaller and grow as needed
			// to avoid allocating max size for hosts with few open ports
			PortResults: make([]*models.PortResult, 0, portCount/4),
		}
	}

	return p
}

func (p *BaseProcessor) Process(result *models.Result) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	p.updateLastSweepTime(time.Now())
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

func (p *BaseProcessor) updateLastSweepTime(now time.Time) {
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

func (*BaseProcessor) processICMPResult(host *models.HostResult, result *models.Result) {
	if host.ICMPStatus == nil {
		host.ICMPStatus = &models.ICMPStatus{}
	}

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

func (p *BaseProcessor) processTCPResult(host *models.HostResult, result *models.Result) {
	if result.Available {
		host.Available = true

		// Grow capacity if needed, but only for hosts that actually have open ports
		if len(host.PortResults) == cap(host.PortResults) {
			// Double capacity until we reach portCount
			newCap := cap(host.PortResults) * 2
			if newCap > p.portCount {
				newCap = p.portCount
			}
			newResults := make([]*models.PortResult, len(host.PortResults), newCap)
			copy(newResults, host.PortResults)
			host.PortResults = newResults
		}

		p.updatePortStatus(host, result)
	}
}

// Cleanup releases all resources and returns objects to the pool.
func (p *BaseProcessor) cleanup() {
	p.mu.Lock()
	defer p.mu.Unlock()

	// Return all host results to the pool and clear maps
	for k, host := range p.hostMap {
		// Clear sensitive data
		host.Host = ""
		host.PortResults = host.PortResults[:0]
		host.ICMPStatus = nil

		// Return to pool
		p.hostResultPool.Put(host)
		delete(p.hostMap, k)
	}

	// Clear other maps and state
	p.portCounts = make(map[int]int)
	p.firstSeenTimes = make(map[string]time.Time)
	p.totalHosts = 0
	p.lastSweepTime = time.Time{}
}

func (p *BaseProcessor) updatePortStatus(host *models.HostResult, result *models.Result) {
	found := false

	for _, port := range host.PortResults {
		if port.Port == result.Target.Port {
			port.Available = true
			port.RespTime = result.RespTime
			found = true
			break
		}
	}

	if !found {
		portResult := &models.PortResult{
			Port:      result.Target.Port,
			Available: true,
			RespTime:  result.RespTime,
		}
		host.PortResults = append(host.PortResults, portResult)
		p.portCounts[result.Target.Port]++
	}
}

func (p *BaseProcessor) getOrCreateHost(hostAddr string, now time.Time) *models.HostResult {
	host, exists := p.hostMap[hostAddr]
	if !exists {
		// Get from pool or create new
		host = p.hostResultPool.Get().(*models.HostResult)

		// Reset the host result to initial state
		host.Host = hostAddr
		host.Available = false

		// Start with existing capacity, will grow if needed
		if cap(host.PortResults) < p.portCount {
			// Rare case: pool provided an object with insufficient capacity
			host.PortResults = make([]*models.PortResult, 0, p.portCount/4)
		} else {
			host.PortResults = host.PortResults[:0]
		}
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

func (p *BaseProcessor) UpdateConfig(config *models.Config) {
	p.mu.Lock()
	defer p.mu.Unlock()

	newPortCount := len(config.Ports)
	if newPortCount == 0 {
		newPortCount = 100
	}

	// Only update if port count changes significantly
	if newPortCount != p.portCount {
		p.portCount = newPortCount
		p.config = config

		// Create new pool with updated capacity
		p.hostResultPool = sync.Pool{
			New: func() interface{} {
				return &models.HostResult{
					// Start with 25% capacity, will grow if needed
					PortResults: make([]*models.PortResult, 0, newPortCount/4),
				}
			},
		}

		// Clean up existing results to use new pool
		p.cleanup()
	}
}
