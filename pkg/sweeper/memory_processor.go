package sweeper

import (
	"context"
	"log"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

// InMemoryProcessor implements ResultProcessor with in-memory state.
type InMemoryProcessor struct {
	*BaseProcessor
	firstSeenTimes map[string]time.Time
}

func NewInMemoryProcessor() ResultProcessor {
	baseProcessor := NewBaseProcessor()
	baseProcessor.Locker = baseProcessor // InMemoryProcessor uses its own mutex

	return &InMemoryProcessor{
		BaseProcessor: baseProcessor,
	}
}

func (p *InMemoryProcessor) RLock() {
	p.mu.RLock()
}

func (p *InMemoryProcessor) RUnlock() {
	p.mu.RUnlock()
}

// Process updates the internal state of the InMemoryProcessor.
func (p *InMemoryProcessor) Process(result *models.Result) error {
	// Handle total hosts from metadata if available
	if result.Target.Metadata != nil {
		if totalHosts, ok := result.Target.Metadata["total_hosts"].(int); ok {
			p.totalHosts = totalHosts
		}
	}
	p.mu.Lock()
	defer p.mu.Unlock()

	log.Printf("Processing result: Host=%s, Port=%d, Mode=%s, Available=%v, Response Time=%v",
		result.Target.Host, result.Target.Port, result.Target.Mode, result.Available, result.RespTime)

	// Always update last sweep time to current time
	p.lastSweepTime = time.Now()

	// Early return if not a TCP scan or not available
	if result.Target.Mode != models.ModeTCP {
		return nil
	}

	// Update total hosts count (this should happen for every unique host)
	if _, exists := p.hostMap[result.Target.Host]; !exists {
		p.totalHosts++
	}

	// Update host information
	host, exists := p.hostMap[result.Target.Host]
	if !exists {
		host = &models.HostResult{
			Host:        result.Target.Host,
			FirstSeen:   result.FirstSeen,
			LastSeen:    result.LastSeen,
			Available:   false,
			PortResults: make([]*models.PortResult, 0),
		}
		p.hostMap[result.Target.Host] = host
	}

	// Update availability based on TCP scan results
	if result.Available {
		host.Available = true
		p.portCounts[result.Target.Port]++

		// Append port result for TCP mode
		portResult := &models.PortResult{
			Port:      result.Target.Port,
			Available: result.Available,
			RespTime:  result.RespTime,
		}
		host.PortResults = append(host.PortResults, portResult)
	}

	// Update timestamps
	if result.FirstSeen.Before(host.FirstSeen) {
		host.FirstSeen = result.FirstSeen
	}

	if result.LastSeen.After(host.LastSeen) {
		host.LastSeen = result.LastSeen
	}

	return nil
}

func (p *InMemoryProcessor) GetSummary(ctx context.Context) (*models.SweepSummary, error) {
	p.mu.RLock()
	defer p.mu.RUnlock()

	// Count available hosts
	availableHosts := 0
	offlineHosts := make([]models.HostResult, 0)
	onlineHosts := make([]models.HostResult, 0)

	for _, host := range p.hostMap {
		if host.Available {
			availableHosts++
			onlineHosts = append(onlineHosts, *host)
		} else {
			offlineHosts = append(offlineHosts, *host)
		}
	}

	// Sort port counts
	ports := make([]models.PortCount, 0, len(p.portCounts))
	for port, count := range p.portCounts {
		ports = append(ports, models.PortCount{
			Port:      port,
			Available: count,
		})
	}

	// Combine online and offline hosts, with offline hosts at the end
	allHosts := append(onlineHosts, offlineHosts...)

	// Calculate total possible hosts from the CIDR ranges in the scan
	actualTotalHosts := len(p.hostMap)
	if actualTotalHosts == 0 {
		actualTotalHosts = p.totalHosts
	}

	return &models.SweepSummary{
		TotalHosts:     actualTotalHosts,
		AvailableHosts: availableHosts,
		LastSweep:      p.lastSweepTime.Unix(),
		Ports:          ports,
		Hosts:          allHosts,
	}, nil
}

// Reset clears the internal state of the InMemoryProcessor.
func (p *InMemoryProcessor) Reset() {
	p.mu.Lock()
	defer p.mu.Unlock()

	p.hostMap = make(map[string]*models.HostResult)
	p.portCounts = make(map[int]int)
	p.totalHosts = 0
	p.lastSweepTime = time.Time{}
}
