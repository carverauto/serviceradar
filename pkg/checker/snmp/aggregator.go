// Package snmp pkg/checker/snmp/aggregator.go
package snmp

import (
	"fmt"
	"sync"
	"time"
)

type Aggregator struct {
	dataPoints map[string][]DataPoint
	mu         sync.RWMutex
	interval   time.Duration
}

func NewAggregator(interval time.Duration) *Aggregator {
	return &Aggregator{
		dataPoints: make(map[string][]DataPoint),
		interval:   interval,
	}
}

func (a *Aggregator) AddPoint(point DataPoint) {
	a.mu.Lock()
	defer a.mu.Unlock()

	points := a.dataPoints[point.OIDName]
	points = append(points, point)

	// Keep only points within the interval
	cutoff := time.Now().Add(-a.interval)
	for i, p := range points {
		if p.Timestamp.After(cutoff) {
			points = points[i:]
			break
		}
	}

	a.dataPoints[point.OIDName] = points
}

func (a *Aggregator) GetAggregatedData(oidName string, interval Interval) (*DataPoint, error) {
	a.mu.RLock()
	defer a.mu.RUnlock()

	points := a.dataPoints[oidName]
	if len(points) == 0 {
		return nil, fmt.Errorf("no data points for OID %s", oidName)
	}

	// Calculate based on interval
	var result DataPoint
	result.OIDName = oidName
	result.Timestamp = points[len(points)-1].Timestamp

	// Calculate average value
	var sum float64
	for _, p := range points {
		switch v := p.Value.(type) {
		case float64:
			sum += v
		case uint64:
			sum += float64(v)
		}
	}
	result.Value = sum / float64(len(points))

	return &result, nil
}
