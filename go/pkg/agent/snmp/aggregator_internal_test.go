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
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestSNMPAggregator_Drain(t *testing.T) {
	agg := NewAggregator(time.Minute, 10)

	// Add some points
	p1 := &DataPoint{OIDName: "ifInOctets", Value: 100.0, Timestamp: time.Now()}
	p2 := &DataPoint{OIDName: "ifInOctets", Value: 200.0, Timestamp: time.Now().Add(time.Second)}
	p3 := &DataPoint{OIDName: "ifOutOctets", Value: 50.0, Timestamp: time.Now()}

	agg.AddPoint(p1)
	agg.AddPoint(p2)
	agg.AddPoint(p3)

	// Drain
	drained := agg.Drain()

	assert.Len(t, drained, 2)
	assert.Len(t, drained["ifInOctets"], 2)
	assert.Len(t, drained["ifOutOctets"], 1)

	assert.InDelta(t, 100.0, drained["ifInOctets"][0].Value, 0.001)
	assert.InDelta(t, 200.0, drained["ifInOctets"][1].Value, 0.001)

	// Drain again should be empty
	drained2 := agg.Drain()
	assert.Empty(t, drained2)
}

func TestSNMPAggregator_GetAggregatedData(t *testing.T) {
	agg := NewAggregator(time.Minute, 10)

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
