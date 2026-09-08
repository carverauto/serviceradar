//go:build linux
// +build linux

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

package scan

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

// readLocalPortRange reads the system's ephemeral port range from /proc
func readLocalPortRange() (uint16, uint16, error) {
	b, err := os.ReadFile("/proc/sys/net/ipv4/ip_local_port_range")
	if err != nil {
		return 0, 0, err
	}

	var lo, hi uint16

	if _, err := fmt.Sscanf(strings.TrimSpace(string(b)), "%d %d", &lo, &hi); err != nil {
		return 0, 0, fmt.Errorf("failed to parse ip_local_port_range: %w", err)
	}

	return lo, hi, nil
}

// readReservedPorts reads the reserved ports from /proc
func readReservedPorts() map[uint16]struct{} {
	ports := map[uint16]struct{}{}

	b, err := os.ReadFile("/proc/sys/net/ipv4/ip_local_reserved_ports")
	if err != nil || len(b) == 0 {
		return ports // return empty map if file doesn't exist or is empty
	}

	// Parse comma-separated list of ports and ranges
	for _, tok := range strings.Split(strings.TrimSpace(string(b)), ",") {
		tok = strings.TrimSpace(tok)
		if tok == "" {
			continue
		}

		if strings.Contains(tok, "-") {
			// Handle range like "32768-61000"
			var a, z int

			if _, err := fmt.Sscanf(tok, "%d-%d", &a, &z); err == nil {
				for p := a; p <= z && p <= 65535; p++ {
					ports[uint16(p)] = struct{}{}
				}
			}
		} else {
			// Handle single port
			if v, err := strconv.Atoi(tok); err == nil && v >= 0 && v <= 65535 {
				ports[uint16(v)] = struct{}{}
			}
		}
	}

	return ports
}

// checkPortRangeDensity calculates the reserved port density for a given range
// and logs appropriate messages.
func checkPortRangeDensity(scanStart, scanEnd uint16, reserved map[uint16]struct{}, log logger.Logger) {
	rangeSize := int(scanEnd - scanStart + 1)
	samples := rangeSize / portDensitySampleDiv // 5%

	if samples < 100 {
		samples = rangeSize // sample all if small
	}

	if samples < 1 {
		samples = 1
	}

	reservedCount := 0

	for i := 0; i < samples; i++ {
		p := scanStart + uint16((i*rangeSize)/samples)
		if p > scanEnd {
			break
		}

		if _, ok := reserved[p]; ok {
			reservedCount++
		}
	}

	reservedDensity := float64(reservedCount) / float64(samples)

	if reservedDensity >= reservedDensityLimit {
		log.Info().Uint16("start", scanStart).Uint16("end", scanEnd).
			Float64("reservedDensity", reservedDensity).
			Msg("Using mostly-reserved port range for scanning")
	} else {
		log.Warn().Uint16("start", scanStart).Uint16("end", scanEnd).
			Float64("reservedDensity", reservedDensity).
			Msg("Scanner port range not reserved densely; consider ip_local_reserved_ports")
	}
}

// findSafeScannerPortRange finds a safe port range for scanning that doesn't
// conflict with the system's ephemeral ports or other local applications.
// Returns the start and end of the range. Always succeeds using fallback if needed.
func findSafeScannerPortRange(log logger.Logger) (uint16, uint16) {
	// Default fallback range (what we were using before)
	const (
		fallbackStart = 32768
		fallbackEnd   = 61000
	)

	// Try to read system ephemeral range
	sysStart, sysEnd, err := readLocalPortRange()
	if err != nil {
		log.Warn().Err(err).Msg("Failed to read system ephemeral port range, using fallback")
		log.Warn().Uint16("start", fallbackStart).Uint16("end", fallbackEnd).
			Msg("WARNING: Using default range that may conflict with local applications!")

		return fallbackStart, fallbackEnd
	}

	log.Info().Uint16("sysStart", sysStart).Uint16("sysEnd", sysEnd).
		Msg("System ephemeral port range detected")

	// Read reserved ports
	reserved := readReservedPorts()

	// Strategy: Find a range that doesn't overlap with system ephemeral range
	// Prefer ranges that are marked as reserved (to prevent other apps from using them)

	// Option 1: Use ports below the system range (if there's enough space)
	if sysStart > highPortThreshold {
		// We can use 10000-19999 or similar
		scanStart := uint16(lowPortFallback)
		scanEnd := sysStart - 1

		if scanEnd-scanStart >= minPortRange { // Need at least 5000 ports
			checkPortRangeDensity(scanStart, scanEnd, reserved, log)
			return scanStart, scanEnd
		}
	}

	// Option 2: Use ports above the system range (if there's enough space)
	if sysEnd < highPortUpperBound {
		scanStart := sysEnd + 1
		scanEnd := uint16(safePortUpperBound) // Leave some ports at the top

		if scanEnd-scanStart >= minPortRange { // Need at least 5000 ports
			checkPortRangeDensity(scanStart, scanEnd, reserved, log)
			return scanStart, scanEnd
		}
	}

	// Option 3: If we can't find a non-overlapping range, try to use reserved ports within the range
	// This is less ideal but better than nothing
	if lo, hi, ok := largestContiguous(reserved, portSearchStart, maxPortNumber); ok && hi-lo+1 >= minPortRange {
		log.Warn().Uint16("start", lo).Uint16("end", hi).
			Msg("Using largest contiguous reserved block for scanner ports")

		return lo, hi
	}

	// Last resort: Use the fallback range with a loud warning
	log.Error().Uint16("start", fallbackStart).Uint16("end", fallbackEnd).
		Msg("ERROR: Could not find safe port range! Using fallback that WILL conflict with local applications!")
	log.Error().Msg("RECOMMENDATION: Reserve ports via 'echo 32768-61000 > /proc/sys/net/ipv4/ip_local_reserved_ports'")

	return fallbackStart, fallbackEnd
}

// largestContiguous finds the largest contiguous block of reserved ports in the range [lo, hi]
func largestContiguous(res map[uint16]struct{}, lo, hi uint16) (uint16, uint16, bool) {
	var bestLo, bestHi uint16

	found, inRun := false, false

	var curLo, curHi uint16

	for pi := int(lo); pi <= int(hi); pi++ {
		p := uint16(pi)
		if _, ok := res[p]; ok {
			if !inRun {
				curLo = p
				inRun = true
			}

			curHi = p
		} else if inRun {
			if !found || int(curHi-curLo) > int(bestHi-bestLo) {
				bestLo, bestHi, found = curLo, curHi, true
			}

			inRun = false
		}
	}

	if inRun && (!found || int(curHi-curLo) > int(bestHi-bestLo)) {
		bestLo, bestHi, found = curLo, curHi, true
	}

	if found {
		return bestLo, bestHi, true
	}

	return 0, 0, false
}
