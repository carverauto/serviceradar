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
	"sync/atomic"
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
	// metricKey is the series' key in a drained metric set, built once when
	// the series is created so that a drain allocates nothing per series.
	metricKey string
	// queued is set while the series is on its aggregator's pending list.
	queued atomic.Bool
}

// SNMPAggregator implements the Aggregator interface.
//
// A drain visits only the series written since the previous drain: a write
// queues its series on the pending list, and a drain takes that list. Visiting
// every series instead made a drain's cost follow the number of series the
// target has ever had, not the points it moves.
type SNMPAggregator struct {
	targetName string
	interval   time.Duration
	data       map[string]*TimeSeriesData // map[oidName]*TimeSeriesData
	mu         sync.RWMutex
	maxSize    int

	pendingMu sync.Mutex
	pending   []*TimeSeriesData // series written since the last drain took the list

	drainMu  sync.Mutex
	draining []*TimeSeriesData // the list the last drain took, reused as the next pending list
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

// NewAggregator creates a new SNMPAggregator for the series of one target.
func NewAggregator(targetName string, interval time.Duration, maxDataPoints int) Aggregator {
	if interval < minInterval {
		interval = minInterval
	}

	if maxDataPoints <= 0 {
		maxDataPoints = defaultDataPointSize
	}

	return &SNMPAggregator{
		targetName: targetName,
		interval:   interval,
		data:       make(map[string]*TimeSeriesData),
		maxSize:    maxDataPoints,
	}
}

// AddPoint implements Aggregator interface. Only creating a new series takes
// the aggregator's write lock; an existing series is written under its own
// buffer lock, so adds and a concurrent Drain do not wait on each other.
func (a *SNMPAggregator) AddPoint(point *DataPoint) {
	a.mu.RLock()
	series, exists := a.data[point.OIDName]
	a.mu.RUnlock()

	if !exists {
		a.mu.Lock()
		series, exists = a.data[point.OIDName]
		if !exists {
			series = &TimeSeriesData{
				buffer:    core.NewRingBuffer[DataPoint](a.maxSize),
				metricKey: metricKey(a.targetName, point.OIDName),
			}
			a.data[point.OIDName] = series
		}
		a.mu.Unlock()
	}

	series.buffer.Write(*point)

	// The flag is set after the write, and a drain clears it before draining
	// the buffer, so a point is either drained by a drain that already holds
	// the series or queues the series for the next one.
	if !series.queued.Load() && series.queued.CompareAndSwap(false, true) {
		a.pendingMu.Lock()
		a.pending = append(a.pending, series)
		a.pendingMu.Unlock()
	}
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

// DrainInto implements Aggregator interface.
func (a *SNMPAggregator) DrainInto(dst map[string][]DataPoint) {
	a.drainMu.Lock()
	defer a.drainMu.Unlock()

	a.pendingMu.Lock()
	written := a.pending
	a.pending = a.draining[:0]
	a.pendingMu.Unlock()

	for _, series := range written {
		series.queued.Store(false)

		if points := series.buffer.Drain(); len(points) > 0 {
			dst[series.metricKey] = points
		}
	}

	a.draining = written
}

// Reset implements Aggregator interface.
func (a *SNMPAggregator) Reset() {
	a.mu.RLock()
	defer a.mu.RUnlock()

	// Discard buffered points in place: AddPoint writes a series' buffer
	// without the aggregator lock, so the buffer itself is never replaced.
	for _, series := range a.data {
		series.buffer.Drain()
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
