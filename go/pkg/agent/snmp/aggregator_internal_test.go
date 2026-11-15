/*
 * Copyright 2026 Carver Automation Corporation.
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

package snmp

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestSNMPAggregator_DrainInto(t *testing.T) {
	agg := NewAggregator("router-a", time.Minute, 10)

	// Add some points
	p1 := &DataPoint{OIDName: "ifInOctets", Value: 100.0, Timestamp: time.Now()}
	p2 := &DataPoint{OIDName: "ifInOctets", Value: 200.0, Timestamp: time.Now().Add(time.Second)}
	p3 := &DataPoint{OIDName: "ifOutOctets", Value: 50.0, Timestamp: time.Now()}

	agg.AddPoint(p1)
	agg.AddPoint(p2)
	agg.AddPoint(p3)

	// Drain
	drained := make(map[string][]DataPoint)
	agg.DrainInto(drained)

	assert.Len(t, drained, 2)
	assert.Len(t, drained["router-a|ifInOctets"], 2)
	assert.Len(t, drained["router-a|ifOutOctets"], 1)

	assert.InDelta(t, 100.0, drained["router-a|ifInOctets"][0].Value, 0.001)
	assert.InDelta(t, 200.0, drained["router-a|ifInOctets"][1].Value, 0.001)

	// Drain again should be empty
	drained2 := make(map[string][]DataPoint)
	agg.DrainInto(drained2)
	assert.Empty(t, drained2)
}

// A drain takes only the series written since the previous one, so a point
// written while a drain runs must land in that drain or queue its series for
// the next: no point is lost or drained twice.
func TestSNMPAggregator_DrainIntoConcurrentWritesDrainEveryPointOnce(t *testing.T) {
	const (
		writers         = 8
		seriesPerWriter = 25
		pointsPerSeries = 200
	)

	agg := NewAggregator("router-a", time.Minute, pointsPerSeries)

	var wg sync.WaitGroup
	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for p := 0; p < pointsPerSeries; p++ {
				for s := 0; s < seriesPerWriter; s++ {
					agg.AddPoint(&DataPoint{OIDName: fmt.Sprintf("w%d-s%d", w, s), Value: p, Timestamp: time.Now()})
				}
			}
		}(w)
	}

	writersDone := make(chan struct{})
	go func() {
		wg.Wait()
		close(writersDone)
	}()

	seen := make(map[string][]int)
	drainOnce := func() {
		drained := make(map[string][]DataPoint)
		agg.DrainInto(drained)
		for key, points := range drained {
			for _, point := range points {
				seen[key] = append(seen[key], point.Value.(int))
			}
		}
	}

	for running := true; running; {
		select {
		case <-writersDone:
			running = false
		default:
		}
		drainOnce()
	}
	drainOnce()

	require.Len(t, seen, writers*seriesPerWriter)
	for key, values := range seen {
		require.Len(t, values, pointsPerSeries, key)
		for i, v := range values {
			require.Equal(t, i, v, "%s: points out of order or repeated", key)
		}
	}
}

func TestSNMPAggregator_GetAggregatedData(t *testing.T) {
	agg := NewAggregator("router-a", time.Minute, 10)

	// Add points spanning more than a minute
	now := time.Now()
	agg.AddPoint(&DataPoint{OIDName: "cpu", Value: 10.0, Timestamp: now.Add(-2 * time.Minute)})
	agg.AddPoint(&DataPoint{OIDName: "cpu", Value: 20.0, Timestamp: now.Add(-30 * time.Second)})
	agg.AddPoint(&DataPoint{OIDName: "cpu", Value: 40.0, Timestamp: now})

	// Get aggregation for last minute
	avg, err := agg.GetAggregatedData("cpu", Minute)
	require.NoError(t, err)
	// Should be average of 20 and 40 = 30
	assert.InDelta(t, 30.0, avg.Value, 0.001)
}
