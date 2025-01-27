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
}

func NewBaseProcessor() *BaseProcessor {
	return &BaseProcessor{
		hostMap:        make(map[string]*models.HostResult),
		portCounts:     make(map[int]int),
		firstSeenTimes: make(map[string]time.Time),
	}
}

func (p *BaseProcessor) Process(result *models.Result) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	now := time.Now()
	if now.After(p.lastSweepTime) {
		p.lastSweepTime = now
	}

	if result.Target.Metadata != nil {
		if totalHosts, ok := result.Target.Metadata["total_hosts"].(int); ok {
			p.totalHosts = totalHosts
		}
	}

	host := p.getOrCreateHost(result.Target.Host, now)
	host.LastSeen = now

	if !result.Available {
		if result.Target.Mode == models.ModeICMP {
			if host.ICMPStatus == nil {
				host.ICMPStatus = &models.ICMPStatus{}
			}
			host.ICMPStatus.PacketLoss = 100
		}
		return nil
	}

	host.Available = true

	if result.Target.Mode == models.ModeICMP {
		if host.ICMPStatus == nil {
			host.ICMPStatus = &models.ICMPStatus{}
		}
		host.ICMPStatus.PacketLoss = 0
		host.ICMPStatus.RoundTrip = result.RespTime
		return nil
	}

	if result.Target.Mode == models.ModeTCP {
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
			host.PortResults = append(host.PortResults, &models.PortResult{
				Port:      result.Target.Port,
				Available: true,
				RespTime:  result.RespTime,
			})
			p.portCounts[result.Target.Port]++
		}
	}

	return nil
}

func (p *BaseProcessor) getOrCreateHost(hostAddr string, now time.Time) *models.HostResult {
	host, exists := p.hostMap[hostAddr]
	if !exists {
		firstSeen := now
		if seen, ok := p.firstSeenTimes[hostAddr]; ok {
			firstSeen = seen
		} else {
			p.firstSeenTimes[hostAddr] = firstSeen
		}

		host = &models.HostResult{
			Host:        hostAddr,
			FirstSeen:   firstSeen,
			LastSeen:    now,
			Available:   false,
			PortResults: make([]*models.PortResult, 0),
		}
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
