package sweeper

import (
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

// DefaultProcessor implements ResultProcessor with in-memory state.
type DefaultProcessor struct {
	mu            sync.RWMutex
	hostMap       map[string]*models.HostResult
	portCounts    map[int]int
	lastSweepTime time.Time
	totalHosts    int
}

func NewDefaultProcessor() *DefaultProcessor {
	return &DefaultProcessor{
		hostMap:    make(map[string]*models.HostResult),
		portCounts: make(map[int]int),
	}
}

func (p *DefaultProcessor) Process(result *models.Result) error {
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

		if result.Target.Mode == models.ModeTCP {
			port := &models.PortResult{
				Port:      result.Target.Port,
				Available: true,
				RespTime:  result.RespTime,
			}
			host.PortResults = append(host.PortResults, port)
		}
	}

	return nil
}

func (p *DefaultProcessor) GetSummary() (*models.SweepSummary, error) {
	p.mu.RLock()
	defer p.mu.RUnlock()

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

	p.hostMap = make(map[string]*models.HostResult)
	p.portCounts = make(map[int]int)
	p.totalHosts = 0
	p.lastSweepTime = time.Time{}
}
