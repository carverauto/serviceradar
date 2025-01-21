// Package sweeper pkg/sweeper/result_processor.go
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

	if err := p.updateTimestamps(result); err != nil {
		return err
	}

	if err := p.updateMetadata(result); err != nil {
		return err
	}

	// Early return if not a TCP scan
	if result.Target.Mode != models.ModeTCP {
		return nil
	}

	return p.processTCPResult(result)
}

func (p *DefaultProcessor) updateTimestamps(_ *models.Result) error {
	now := time.Now()
	if now.After(p.lastSweepTime) {
		p.lastSweepTime = now
	}
	log.Printf("Processing result with lastSweepTime: %v", p.lastSweepTime.Format(time.RFC3339))
	return nil
}

func (p *DefaultProcessor) updateMetadata(result *models.Result) error {
	if result.Target.Metadata == nil {
		return nil
	}

	if totalHosts, ok := result.Target.Metadata["total_hosts"].(int); ok {
		p.totalHosts = totalHosts
	}
	return nil
}

func (p *DefaultProcessor) processTCPResult(result *models.Result) error {
	host, err := p.getOrCreateHost(result)
	if err != nil {
		return err
	}

	if result.Available {
		host.Available = true
		p.portCounts[result.Target.Port]++
		p.updatePortResults(host, result)
	}

	return nil
}

func (p *DefaultProcessor) getOrCreateHost(result *models.Result) (*models.HostResult, error) {
	now := time.Now()
	host, exists := p.hostMap[result.Target.Host]

	if !exists {
		firstSeen := p.getFirstSeenTime(result.Target.Host, now)
		host = &models.HostResult{
			Host:        result.Target.Host,
			FirstSeen:   firstSeen,
			LastSeen:    now,
			Available:   false,
			PortResults: make([]*models.PortResult, 0),
		}
		p.hostMap[result.Target.Host] = host
	}

	host.LastSeen = now
	return host, nil
}

func (p *DefaultProcessor) getFirstSeenTime(host string, now time.Time) time.Time {
	if firstSeen, ok := p.firstSeenTimes[host]; ok {
		return firstSeen
	}

	p.firstSeenTimes[host] = now
	return now
}

func (p *DefaultProcessor) updatePortResults(host *models.HostResult, result *models.Result) {
	portResult := p.findPortResult(host, result.Target.Port)
	if portResult == nil {
		host.PortResults = append(host.PortResults, &models.PortResult{
			Port:      result.Target.Port,
			Available: true,
			RespTime:  result.RespTime,
		})
	} else {
		portResult.Available = true
		portResult.RespTime = result.RespTime
	}
}

func (p *DefaultProcessor) findPortResult(host *models.HostResult, port int) *models.PortResult {
	for _, pr := range host.PortResults {
		if pr.Port == port {
			return pr
		}
	}
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
