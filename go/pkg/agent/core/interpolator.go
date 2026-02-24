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
	"time"
)

// TimeValue represents a timestamped numeric value for interpolation.
type TimeValue struct {
	Timestamp int64
	Value     float64
}

// Interpolate aligns a series of raw data points to a fixed time grid.
//
// raw: Input points, sorted by timestamp (oldest first).
// step: The desired time interval (e.g., 1s).
// alignTo: The timestamp to align the grid to (usually start of minute or epoch).
// maxGap: Maximum time gap allowed between points before interpolation stops (creates a gap).
//
// Returns a slice of aligned TimeValues.
func Interpolate(raw []TimeValue, step time.Duration, maxGap time.Duration) []TimeValue {
	if len(raw) < 2 {
		return nil
	}

	stepNs := step.Nanoseconds()
	var result []TimeValue

	// Determine start and end times for the grid
	firstTs := raw[0].Timestamp
	lastTs := raw[len(raw)-1].Timestamp

	// Round up first timestamp to the next step boundary
	// startGrid = ceil(firstTs / step) * step
	remainder := firstTs % stepNs
	startGrid := firstTs
	if remainder != 0 {
		startGrid = firstTs + (stepNs - remainder)
	}

	currentGrid := startGrid
	rawIdx := 0

	for currentGrid <= lastTs {
		// Find the surrounding raw points (prev, next) such that prev.Ts <= currentGrid <= next.Ts
		// Advance rawIdx until raw[rawIdx+1].Timestamp >= currentGrid
		for rawIdx < len(raw)-1 && raw[rawIdx+1].Timestamp < currentGrid {
			rawIdx++
		}

		if rawIdx >= len(raw)-1 {
			break
		}

		prev := raw[rawIdx]
		next := raw[rawIdx+1]

		// Check for gaps
		if time.Duration(next.Timestamp-prev.Timestamp) > maxGap {
			// Gap detected, skip this grid point
			currentGrid += stepNs
			continue
		}

		// Linear Interpolation
		// V = V0 + (V1 - V0) * (T - T0) / (T1 - T0)
		tDiff := next.Timestamp - prev.Timestamp
		if tDiff == 0 {
			// Should not happen with unique timestamps, but handle safety
			currentGrid += stepNs
			continue
		}

		ratio := float64(currentGrid-prev.Timestamp) / float64(tDiff)
		val := prev.Value + (next.Value-prev.Value)*ratio

		result = append(result, TimeValue{
			Timestamp: currentGrid,
			Value:     val,
		})

		currentGrid += stepNs
	}

	return result
}
