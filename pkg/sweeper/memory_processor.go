// Package sweeper pkg/sweeper/memory_processor.go
package sweeper

import (
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

	// Update last sweep time
	if result.LastSeen.After(p.lastSweepTime) {
		p.lastSweepTime = result.LastSeen
	}

	// Update port counts
	if result.Available && result.Target.Mode == models.ModeTCP {
		p.portCounts[result.Target.Port]++
	}

	// Update host information
	host, exists := p.hostMap[result.Target.Host]
	if !exists {
		p.totalHosts++
		host = &models.HostResult{
			Host:        result.Target.Host,
			FirstSeen:   result.FirstSeen,
			LastSeen:    result.LastSeen,
			Available:   false,
			PortResults: make([]*models.PortResult, 0),
		}

		p.hostMap[result.Target.Host] = host
	}

	if result.Available {
		host.Available = true
	}

	if result.Target.Mode == models.ModeTCP {
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

// Reset clears the internal state of the InMemoryProcessor.
func (p *InMemoryProcessor) Reset() {
	p.mu.Lock()
	defer p.mu.Unlock()

	p.hostMap = make(map[string]*models.HostResult)
	p.portCounts = make(map[int]int)
	p.totalHosts = 0
	p.lastSweepTime = time.Time{}
}
