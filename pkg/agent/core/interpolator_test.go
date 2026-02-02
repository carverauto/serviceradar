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

package core

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func TestInterpolate(t *testing.T) {
	// Setup raw points: 0s, 2s, 4s (values 0, 20, 40)
	// We want to interpolate to 1s grid: 0s, 1s, 2s, 3s, 4s
	baseTime := time.Date(2025, 1, 1, 12, 0, 0, 0, time.UTC)
	raw := []TimeValue{
		{Timestamp: baseTime.UnixNano(), Value: 0},
		{Timestamp: baseTime.Add(2 * time.Second).UnixNano(), Value: 20},
		{Timestamp: baseTime.Add(4 * time.Second).UnixNano(), Value: 40},
	}

	step := 1 * time.Second
	maxGap := 5 * time.Second

	aligned := Interpolate(raw, step, maxGap)

	assert.Len(t, aligned, 5)

	// T=0s (exact match) -> Value 0
	assert.Equal(t, baseTime.UnixNano(), aligned[0].Timestamp)
	assert.InDelta(t, 0.0, aligned[0].Value, 0.001)

	// T=1s (midpoint of 0s and 2s) -> Value 10
	assert.Equal(t, baseTime.Add(1*time.Second).UnixNano(), aligned[1].Timestamp)
	assert.InDelta(t, 10.0, aligned[1].Value, 0.001)

	// T=2s (exact match with raw point) -> Value 20
	assert.Equal(t, baseTime.Add(2*time.Second).UnixNano(), aligned[2].Timestamp)
	assert.InDelta(t, 20.0, aligned[2].Value, 0.001)

	// T=3s (midpoint of 2s and 4s) -> Value 30
	assert.Equal(t, baseTime.Add(3*time.Second).UnixNano(), aligned[3].Timestamp)
	assert.InDelta(t, 30.0, aligned[3].Value, 0.001)

	// T=4s (exact match) -> Value 40
	assert.Equal(t, baseTime.Add(4*time.Second).UnixNano(), aligned[4].Timestamp)
	assert.InDelta(t, 40.0, aligned[4].Value, 0.001)
}

func TestInterpolate_GapDetection(t *testing.T) {
	// Setup raw points with a large gap: 0s, 10s (values 0, 100)
	// Max gap is 5s. Should produce no points between them.
	baseTime := time.Date(2025, 1, 1, 12, 0, 0, 0, time.UTC)
	raw := []TimeValue{
		{Timestamp: baseTime.UnixNano(), Value: 0},
		{Timestamp: baseTime.Add(10 * time.Second).UnixNano(), Value: 100},
	}

	step := 1 * time.Second
	maxGap := 5 * time.Second

	aligned := Interpolate(raw, step, maxGap)

	// Should be empty (or contain only start/end if they align perfectly?)
	// 0s aligns. 10s aligns.
	// But the logic checks gap between *raw* points.
	// next.Ts - prev.Ts = 10s > 5s.
	// So it skips grid points between them.
	// BUT, does it skip grid points that *coincide* with the raw points?
	// The loop: for currentGrid <= lastTs.
	// inside: find prev/next such that prev <= currentGrid <= next.
	// if next-prev > maxGap -> skip.
	// So yes, if the gap surrounding the grid point is too large, it skips.
	// 0s: prev=0, next=10 (gap 10). Skip.
	// 10s: prev=0, next=10 (gap 10). Skip.
	assert.Empty(t, aligned)
}

func TestInterpolate_Jitter(t *testing.T) {
	// Raw points slightly off: 0.1s, 1.1s, 2.1s
	// Target grid: 1s, 2s
	baseTime := time.Date(2025, 1, 1, 12, 0, 0, 0, time.UTC)
	raw := []TimeValue{
		{Timestamp: baseTime.Add(100 * time.Millisecond).UnixNano(), Value: 1},
		{Timestamp: baseTime.Add(1100 * time.Millisecond).UnixNano(), Value: 11},
		{Timestamp: baseTime.Add(2100 * time.Millisecond).UnixNano(), Value: 21},
	}

	step := 1 * time.Second
	maxGap := 5 * time.Second

	aligned := Interpolate(raw, step, maxGap)

	assert.Len(t, aligned, 2)

	// T=1s (between 0.1 and 1.1)
	// 0.1->1.1 = 1s diff.
	// 1.0 is 0.9s from 0.1. Ratio 0.9.
	// Val = 1 + 10*0.9 = 10.
	assert.Equal(t, baseTime.Add(1*time.Second).UnixNano(), aligned[0].Timestamp)
	assert.InDelta(t, 10.0, aligned[0].Value, 0.001)

	// T=2s (between 1.1s and 2.1s)
	// 1.1->2.1 = 1s diff.
	// 2.0 is 0.9s from 1.1. Ratio 0.9.
	// Val = 11 + 10*0.9 = 20.
	assert.Equal(t, baseTime.Add(2*time.Second).UnixNano(), aligned[1].Timestamp)
	assert.InDelta(t, 20.0, aligned[1].Value, 0.001)
}