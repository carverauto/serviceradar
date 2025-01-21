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
// In pkg/sweeper/memory_processor.go

func (p *InMemoryProcessor) Process(result *models.Result) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	now := time.Now()
	// Always update the last sweep time, but only if it would be moving forward
	if now.After(p.lastSweepTime) {
		p.lastSweepTime = now
	}

	log.Printf("Processing result with lastSweepTime: %v", p.lastSweepTime.Format(time.RFC3339))

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
	} else {
		// Always update LastSeen for existing hosts
		host.LastSeen = now
	}

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

	// Add debug logging
	log.Printf("Host %s - FirstSeen: %v, LastSeen: %v, LastSweep: %v",
		host.Host,
		host.FirstSeen.Format(time.RFC3339),
		host.LastSeen.Format(time.RFC3339),
		p.lastSweepTime.Format(time.RFC3339))

	return nil
}

// In pkg/sweeper/memory_processor.go

func (p *InMemoryProcessor) GetSummary(ctx context.Context) (*models.SweepSummary, error) {
	p.mu.RLock()
	defer p.mu.RUnlock()

	// Check for context cancellation
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
	}

	// Count available hosts and prepare host list
	availableHosts := 0
	onlineHosts := make([]models.HostResult, 0, len(p.hostMap))
	offlineHosts := make([]models.HostResult, 0, len(p.hostMap))

	for _, host := range p.hostMap {
		if host.Available {
			availableHosts++

			onlineHosts = append(onlineHosts, *host)
		} else {
			offlineHosts = append(offlineHosts, *host)
		}
	}

	// Calculate capacity needed for all hosts
	totalCap := len(onlineHosts) + len(offlineHosts)
	allHosts := make([]models.HostResult, 0, totalCap)

	// Append online hosts first
	allHosts = append(allHosts, onlineHosts...)
	// Then append offline hosts
	allHosts = append(allHosts, offlineHosts...)

	// Prepare port counts
	ports := make([]models.PortCount, 0, len(p.portCounts))
	for port, count := range p.portCounts {
		ports = append(ports, models.PortCount{
			Port:      port,
			Available: count,
		})
	}

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
