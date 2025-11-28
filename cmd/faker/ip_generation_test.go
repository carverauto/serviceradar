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

package main

import (
	"fmt"
	"testing"
)

func TestGenerateSingleIP_UniqueFor50kDevices(t *testing.T) {
	numDevices := 50000
	if testing.Short() {
		numDevices = 5000
	}
	seen := make(map[string]int, numDevices)

	for i := 0; i < numDevices; i++ {
		ip := generateSingleIP(i)
		if prevIndex, exists := seen[ip]; exists {
			t.Errorf("IP collision: %s generated for device index %d and %d", ip, prevIndex, i)
		}
		seen[ip] = i
	}

	if len(seen) != numDevices {
		t.Errorf("Expected %d unique IPs, got %d", numDevices, len(seen))
	}
}

func TestGenerateSingleIP_UniqueWithOffsets(t *testing.T) {
	// Generating the same index twice should always return the same IP.
	const index = 42

	ip1 := generateSingleIP(index)
	ip2 := generateSingleIP(index)

	if ip1 != ip2 {
		t.Fatalf("expected deterministic IP generation for index %d, got %s and %s", index, ip1, ip2)
	}
}

func TestGenerateSingleIP_ValidFormat(t *testing.T) {
	testCases := []int{0, 100, 1000, 10000, 49999}

	for _, idx := range testCases {
		ip := generateSingleIP(idx)

		// Basic validation - should have 4 octets
		var o1, o2, o3, o4 int
		n, err := fmt.Sscanf(ip, "%d.%d.%d.%d", &o1, &o2, &o3, &o4)
		if err != nil || n != 4 {
			t.Errorf("Invalid IP format for index %d: %s", idx, ip)
			continue
		}

		// Each octet should be in valid range
		for _, octet := range []int{o1, o2, o3, o4} {
			if octet < 0 || octet > 255 {
				t.Errorf("Invalid octet value in IP %s for index %d", ip, idx)
			}
		}

		// Last octet should not be 0 or 255 (network/broadcast)
		if o4 == 0 || o4 == 255 {
			t.Errorf("Last octet is network/broadcast address in IP %s for index %d", ip, idx)
		}
	}
}
