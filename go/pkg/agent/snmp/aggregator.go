/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Package snmp pkg/agent/snmp/aggregator.go
package snmp

import (
	"fmt"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/core"
)

const (
	oneDay               = 24 * time.Hour
	defaultDataPointSize = 100
)

// TimeSeriesData holds time-series data points for an OID.
type TimeSeriesData struct {
	buffer *core.RingBuffer[DataPoint]
}

// SNMPAggregator implements the Aggregator interface.
type SNMPAggregator struct {
	interval time.Duration
	data     map[string]*TimeSeriesData // map[oidName]*TimeSeriesData
	mu       sync.RWMutex
	maxSize  int
}

// AggregateType defines different types of aggregation.
type AggregateType int

const (
	// AggregateAvg calculates the average value
	AggregateAvg AggregateType = iota
	// AggregateMin finds the minimum value
	AggregateMin
	// AggregateMax finds the maximum value
	AggregateMax
	// AggregateSum calculates the sum of values
	AggregateSum
	AggregateCount
)

const (
	minInterval = 5 * time.Second
)

// NewAggregator creates a new SNMPAggregator.
func NewAggregator(interval time.Duration, maxDataPoints int) Aggregator {
	if interval < minInterval {
		interval = minInterval
	}

	if maxDataPoints <= 0 {
		maxDataPoints = defaultDataPointSize
	}

	return &SNMPAggregator{
		interval: interval,
		data:     make(map[string]*TimeSeriesData),
		maxSize:  maxDataPoints,
	}
}

// AddPoint implements Aggregator interface.
func (a *SNMPAggregator) AddPoint(point *DataPoint) {
	a.mu.Lock()
	defer a.mu.Unlock()

	// Get or create time series for this OID
	series, exists := a.data[point.OIDName]
	if !exists {
		series = &TimeSeriesData{
			buffer: core.NewRingBuffer[DataPoint](a.maxSize),
		}
		a.data[point.OIDName] = series
	}

	series.buffer.Write(*point)
}

// GetAggregatedData implements Aggregator interface.
func (a *SNMPAggregator) GetAggregatedData(oidName string, interval Interval) (*DataPoint, error) {
	a.mu.RLock()
	series, exists := a.data[oidName]
	a.mu.RUnlock()

	if !exists {
		return nil, fmt.Errorf("%w: %s", errNoDataFound, oidName)
	}

	// Get the time range for the interval
	timeRange := a.getTimeRange(interval)

	// Get points within the time range
	// Uses WalkReverse to efficiently find recent points without scanning the entire buffer.
	points := series.getPointsInRange(timeRange)
	if len(points) == 0 {
		return nil, fmt.Errorf("%w: %s", errNoDataPointsInterval, oidName)
	}

	// Aggregate the points
	return a.aggregatePoints(points, AggregateAvg)
}

// Drain implements Aggregator interface.
func (a *SNMPAggregator) Drain() map[string][]DataPoint {
	a.mu.RLock()
	defer a.mu.RUnlock()

	result := make(map[string][]DataPoint)
	for oidName, series := range a.data {
		points := series.buffer.Drain()
		if len(points) > 0 {
			result[oidName] = points
		}
	}
	return result
}

// Reset implements Aggregator interface.
func (a *SNMPAggregator) Reset() {
	a.mu.Lock()
	defer a.mu.Unlock()

	// Re-initialize buffers
	for _, series := range a.data {
		series.buffer = core.NewRingBuffer[DataPoint](a.maxSize)
	}
}

func (a *SNMPAggregator) getTimeRange(interval Interval) time.Duration {
	switch interval {
	case Minute:
		return time.Minute
	case Hour:
		return time.Hour
	case Day:
		return oneDay
	default:
		return a.interval
	}
}

func (a *SNMPAggregator) aggregatePoints(points []DataPoint, aggType AggregateType) (*DataPoint, error) {
	if len(points) == 0 {
		return nil, errNoPointsAggregate
	}

	var result DataPoint

	result.OIDName = points[0].OIDName
	result.Timestamp = points[len(points)-1].Timestamp // Use latest timestamp

	switch aggType {
	case AggregateAvg:
		result.Value = a.calculateAverage(points)
	case AggregateMin:
		result.Value = a.calculateMin(points)
	case AggregateMax:
		result.Value = a.calculateMax(points)
	case AggregateSum:
		result.Value = a.calculateSum(points)
	case AggregateCount:
		result.Value = len(points)
	default:
		return nil, fmt.Errorf("%w: %d", errUnsupportedAggregateType, aggType)
	}

	return &result, nil
}

// getPointsInRange returns all points within the given duration.
func (ts *TimeSeriesData) getPointsInRange(duration time.Duration) []DataPoint {
	cutoff := time.Now().Add(-duration)
	var result []DataPoint

	// Iterate backwards from newest to oldest
	ts.buffer.WalkReverse(func(p DataPoint) bool {
		// If the point is older than the cutoff, we can stop iterating
		// because the buffer is time-ordered.
		if p.Timestamp.Before(cutoff) {
			return false
		}
		// Prepend to maintain chronological order in result?
		// WalkReverse gives newest first. result will be [newest, ..., oldest]
		// Typically aggregations work fine with this, or we can reverse it.
		// Aggregate functions expect points.
		result = append(result, p)
		return true
	})

	// Reverse the result to be chronological [oldest, ..., newest]
	// if needed by aggregation functions (e.g. for trending).
	// calculateAverage/Min/Max/Sum don't care about order.
	// But it's safer to maintain expectation.
	for i, j := 0, len(result)-1; i < j; i, j = i+1, j-1 {
		result[i], result[j] = result[j], result[i]
	}

	return result
}

// Calculation helper methods

func (a *SNMPAggregator) calculateAverage(points []DataPoint) interface{} {
	switch v := points[0].Value.(type) {
	case int64, uint64, float64:
		sum := 0.0

		for _, p := range points {
			sum += a.toFloat64(p.Value)
		}

		return sum / float64(len(points))
	default:
		return v // For non-numeric types, return the latest value
	}
}

func (a *SNMPAggregator) calculateMin(points []DataPoint) interface{} {
	minPoints := a.toFloat64(points[0].Value)

	for _, p := range points[1:] {
		v := a.toFloat64(p.Value)

		if v < minPoints {
			minPoints = v
		}
	}

	return minPoints
}

func (a *SNMPAggregator) calculateMax(points []DataPoint) interface{} {
	pointsMax := a.toFloat64(points[0].Value)

	for _, p := range points[1:] {
		v := a.toFloat64(p.Value)
		if v > pointsMax {
			pointsMax = v
		}
	}

	return pointsMax
}

func (a *SNMPAggregator) calculateSum(points []DataPoint) interface{} {
	sum := 0.0

	for _, p := range points {
		sum += a.toFloat64(p.Value)
	}

	return sum
}

func (*SNMPAggregator) toFloat64(v interface{}) float64 {
	switch value := v.(type) {
	case int64:
		return float64(value)
	case uint64:
		return float64(value)
	case float64:
		return value
	case int:
		return float64(value)
	default:
		return 0.0
	}
}
