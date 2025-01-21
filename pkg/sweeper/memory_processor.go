package sweeper

import (
	"context"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

// InMemoryProcessor implements ResultProcessor with in-memory state.
type InMemoryProcessor struct {
	*BaseProcessor
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
	p.mu.Lock()
	defer p.mu.Unlock()

	now := time.Now()
	// Always update the last sweep time, but only if it would be moving forward
	if now.After(p.lastSweepTime) {
		p.lastSweepTime = now
	}

	// Handle total hosts from metadata if available
	if result.Target.Metadata != nil {
		if totalHosts, ok := result.Target.Metadata["total_hosts"].(int); ok {
			p.totalHosts = totalHosts
		}
	}

	// Early return if not a TCP scan
	if result.Target.Mode != models.ModeTCP {
		return nil
	}

	// Update host information
	host, exists := p.hostMap[result.Target.Host]
	if !exists {
		// Check/update first seen time
		firstSeen, hasFirstSeen := p.firstSeenTimes[result.Target.Host]
		if !hasFirstSeen {
			firstSeen = now

			p.firstSeenTimes[result.Target.Host] = firstSeen
		}

		host = &models.HostResult{
			Host:        result.Target.Host,
			FirstSeen:   firstSeen,
			LastSeen:    now,
			Available:   false,
			PortResults: make([]*models.PortResult, 0),
		}

		p.hostMap[result.Target.Host] = host
	}

	// Always update LastSeen for existing hosts
	host.LastSeen = now

	if result.Available {
		host.Available = true
		p.portCounts[result.Target.Port]++

		portResult := &models.PortResult{
			Port:      result.Target.Port,
			Available: true,
			RespTime:  result.RespTime,
		}

		host.PortResults = append(host.PortResults, portResult)
	}

	return nil
}

// GetSummary returns the current summary of all processed results.
func (p *InMemoryProcessor) GetSummary(ctx context.Context) (*models.SweepSummary, error) {
	p.mu.RLock()
	defer p.mu.RUnlock()

	// Check for context cancellation
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
	}

	// If lastSweepTime is zero, use current time
	lastSweep := p.lastSweepTime
	if lastSweep.IsZero() {
		lastSweep = time.Now()
	}

	availableHosts := 0
	ports := make([]models.PortCount, 0, len(p.portCounts))

	for port, count := range p.portCounts {
		ports = append(ports, models.PortCount{
			Port:      port,
			Available: count,
		})
	}

	hosts := make([]models.HostResult, 0, len(p.hostMap))

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

// Reset clears the internal state of the InMemoryProcessor.
func (p *InMemoryProcessor) Reset() {
	p.mu.Lock()
	defer p.mu.Unlock()

	p.hostMap = make(map[string]*models.HostResult)
	p.portCounts = make(map[int]int)
	p.totalHosts = 0
	p.lastSweepTime = time.Time{}
}
