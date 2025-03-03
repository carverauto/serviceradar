/*-
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

// Package snmp pkg/checker/snmp/aggregator.go

package snmp

import (
	"fmt"
	"sync"
	"time"
)

const (
	oneDay               = 24 * time.Hour
	defaultDataPointSize = 100
)

// TimeSeriesData holds time-series data points for an OID.
type TimeSeriesData struct {
	points  []DataPoint
	maxSize int
	mu      sync.RWMutex
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
	AggregateAvg AggregateType = iota
	AggregateMin
	AggregateMax
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
			points:  make([]DataPoint, 0, defaultDataPointSize),
			maxSize: a.maxSize,
		}
		a.data[point.OIDName] = series
	}

	series.addPoint(point)
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
	points := series.getPointsInRange(timeRange)
	if len(points) == 0 {
		return nil, fmt.Errorf("%w: %s", errNoDataPointsInterval, oidName)
	}

	// Aggregate the points
	return a.aggregatePoints(points, AggregateAvg)
}

// Reset implements Aggregator interface.
func (a *SNMPAggregator) Reset() {
	a.mu.Lock()
	defer a.mu.Unlock()

	// Clear all data
	for _, series := range a.data {
		series.mu.Lock()
		series.points = series.points[:0]
		series.mu.Unlock()
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

func (ts *TimeSeriesData) addPoint(point *DataPoint) {
	ts.mu.Lock()
	defer ts.mu.Unlock()

	// Add new point
	ts.points = append(ts.points, *point)

	// Remove oldest points if we exceed maxSize
	if len(ts.points) > ts.maxSize {
		ts.points = ts.points[len(ts.points)-ts.maxSize:]
	}
}

// getPointsInRange returns all points within the given duration.
func (ts *TimeSeriesData) getPointsInRange(duration time.Duration) []DataPoint {
	ts.mu.RLock()
	defer ts.mu.RUnlock()

	cutoff := time.Now().Add(-duration)

	var result []DataPoint

	// Find first point within range using binary search
	idx := ts.findFirstPointAfter(cutoff)
	if idx >= 0 {
		result = make([]DataPoint, len(ts.points)-idx)

		copy(result, ts.points[idx:])
	}

	return result
}

// findFirstPointAfter returns the index of the first point after the given time.
func (ts *TimeSeriesData) findFirstPointAfter(t time.Time) int {
	left, right := 0, len(ts.points)

	// Binary search
	for left < right {
		mid := (left + right) / 2
		if ts.points[mid].Timestamp.Before(t) {
			left = mid + 1
		} else {
			right = mid
		}
	}

	if left == len(ts.points) {
		return -1
	}

	return left
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
