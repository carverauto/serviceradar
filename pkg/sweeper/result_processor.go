package sweeper

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

type ProcessorLocker interface {
	RLock()
	RUnlock()
}

type DefaultProcessor struct {
	*BaseProcessor
}

func NewDefaultProcessor() *DefaultProcessor {
	return &DefaultProcessor{
		BaseProcessor: NewBaseProcessor(),
	}
}

type BaseProcessor struct {
	mu             sync.RWMutex
	hostMap        map[string]*models.HostResult
	portCounts     map[int]int
	lastSweepTime  time.Time
	firstSeenTimes map[string]time.Time
	totalHosts     int
	Locker         ProcessorLocker
}

func (p *BaseProcessor) RLock() {
	p.mu.RLock()
}

func (p *BaseProcessor) RUnlock() {
	p.mu.RUnlock()
}

func NewBaseProcessor() *BaseProcessor {
	return &BaseProcessor{
		hostMap:        make(map[string]*models.HostResult),
		portCounts:     make(map[int]int),
		firstSeenTimes: make(map[string]time.Time),
		Locker:         &sync.RWMutex{}, // Default locker
	}
}

func (p *DefaultProcessor) Process(result *models.Result) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	now := time.Now()
	p.lastSweepTime = now

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

	// Check/update first seen time
	if _, exists := p.firstSeenTimes[result.Target.Host]; !exists {
		p.firstSeenTimes[result.Target.Host] = now
	}

	// Update host information
	host, exists := p.hostMap[result.Target.Host]
	if !exists {
		host = &models.HostResult{
			Host:        result.Target.Host,
			FirstSeen:   p.firstSeenTimes[result.Target.Host],
			LastSeen:    now,
			Available:   false,
			PortResults: make([]*models.PortResult, 0),
		}
		p.hostMap[result.Target.Host] = host
	}

	if result.Available {
		host.Available = true
		p.portCounts[result.Target.Port]++

		if result.Target.Mode == models.ModeTCP {
			port := &models.PortResult{
				Port:      result.Target.Port,
				Available: true,
				RespTime:  result.RespTime,
			}
			host.PortResults = append(host.PortResults, port)
		}
	}

	// Update LastSeen but preserve FirstSeen
	host.LastSeen = now

	log.Printf("Processed result for host %s: available=%v mode=%s port=%d firstSeen=%v",
		result.Target.Host, result.Available, result.Target.Mode, result.Target.Port,
		p.firstSeenTimes[result.Target.Host])

	return nil
}

func (p *BaseProcessor) GetSummary(ctx context.Context) (*models.SweepSummary, error) {
	p.Locker.RLock()
	defer p.Locker.RUnlock()

	// Check for context cancellation
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
	}

	// Count available hosts and prepare host list
	availableHosts := 0
	hosts := make([]models.HostResult, 0, len(p.hostMap))

	for _, host := range p.hostMap {
		if host.Available {
			availableHosts++
		}

		hosts = append(hosts, *host)
	}

	// Prepare port counts
	ports := make([]models.PortCount, 0, len(p.portCounts))
	for port, count := range p.portCounts {
		ports = append(ports, models.PortCount{
			Port:      port,
			Available: count,
		})
	}

	return &models.SweepSummary{
		TotalHosts:     p.totalHosts,
		AvailableHosts: availableHosts,
		LastSweep:      p.lastSweepTime.Unix(),
		Ports:          ports,
		Hosts:          hosts,
	}, nil
}

func (p *DefaultProcessor) Reset() {
	p.mu.Lock()
	defer p.mu.Unlock()

	// Preserve firstSeenTimes
	firstSeenTimes := p.firstSeenTimes

	p.hostMap = make(map[string]*models.HostResult)
	p.portCounts = make(map[int]int)
	p.totalHosts = 0
	p.lastSweepTime = time.Time{}

	// Restore firstSeenTimes
	p.firstSeenTimes = firstSeenTimes
}
