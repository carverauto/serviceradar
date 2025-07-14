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

package armis

import (
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestChangeDetection(t *testing.T) {
	tests := []struct {
		name           string
		initialDevices []Device
		updatedDevices []Device
		expectChange   bool
		description    string
	}{
		{
			name:           "First fetch should always trigger change",
			initialDevices: nil,
			updatedDevices: []Device{
				{ID: 1, IPAddress: "192.168.1.10", Name: "device1"},
			},
			expectChange: true,
			description:  "First fetch with empty hash should trigger change",
		},
		{
			name: "Identical devices should not trigger change",
			initialDevices: []Device{
				{ID: 1, IPAddress: "192.168.1.10", Name: "device1", LastSeen: time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)},
				{ID: 2, IPAddress: "192.168.1.20", Name: "device2", LastSeen: time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)},
			},
			updatedDevices: []Device{
				{ID: 1, IPAddress: "192.168.1.10", Name: "device1", LastSeen: time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)},
				{ID: 2, IPAddress: "192.168.1.20", Name: "device2", LastSeen: time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)},
			},
			expectChange: false,
			description:  "Identical devices should not trigger change",
		},
		{
			name: "Different device count should trigger change",
			initialDevices: []Device{
				{ID: 1, IPAddress: "192.168.1.10", Name: "device1"},
			},
			updatedDevices: []Device{
				{ID: 1, IPAddress: "192.168.1.10", Name: "device1"},
				{ID: 2, IPAddress: "192.168.1.20", Name: "device2"},
			},
			expectChange: true,
			description:  "Adding a device should trigger change",
		},
		{
			name: "Changed IP address should trigger change",
			initialDevices: []Device{
				{ID: 1, IPAddress: "192.168.1.10", Name: "device1"},
			},
			updatedDevices: []Device{
				{ID: 1, IPAddress: "192.168.1.11", Name: "device1"}, // IP changed
			},
			expectChange: true,
			description:  "IP address change should trigger change",
		},
		{
			name: "Changed name should trigger change",
			initialDevices: []Device{
				{ID: 1, IPAddress: "192.168.1.10", Name: "device1"},
			},
			updatedDevices: []Device{
				{ID: 1, IPAddress: "192.168.1.10", Name: "device1-updated"}, // Name changed
			},
			expectChange: true,
			description:  "Name change should trigger change",
		},
		{
			name: "Changed LastSeen should trigger change",
			initialDevices: []Device{
				{ID: 1, IPAddress: "192.168.1.10", Name: "device1", LastSeen: time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)},
			},
			updatedDevices: []Device{
				{ID: 1, IPAddress: "192.168.1.10", Name: "device1", LastSeen: time.Date(2025, 1, 2, 0, 0, 0, 0, time.UTC)}, // LastSeen changed
			},
			expectChange: true,
			description:  "LastSeen change should trigger change",
		},
		{
			name: "Changed tags should trigger change",
			initialDevices: []Device{
				{ID: 1, IPAddress: "192.168.1.10", Name: "device1", Tags: []string{"tag1"}},
			},
			updatedDevices: []Device{
				{ID: 1, IPAddress: "192.168.1.10", Name: "device1", Tags: []string{"tag1", "tag2"}}, // Tags changed
			},
			expectChange: true,
			description:  "Tags change should trigger change",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Create Armis integration instance
			integration := &ArmisIntegration{
				Config: &models.SourceConfig{
					AgentID:   "test-agent",
					PollerID:  "test-poller",
					Partition: "test",
				},
			}

			// Simulate first fetch if we have initial devices
			if tt.initialDevices != nil {
				// First call to set baseline
				results1 := integration.convertToSweepResults(tt.initialDevices)
				// First call should always return results
				assert.NotEmpty(t, results1, "First call should return sweep results")
			}

			// Now test the updated devices
			results2 := integration.convertToSweepResults(tt.updatedDevices)

			if tt.expectChange {
				assert.NotEmpty(t, results2, "Should return sweep results when changes detected: %s", tt.description)
			} else {
				assert.Empty(t, results2, "Should return empty results when no changes detected: %s", tt.description)
			}
		})
	}
}

func TestHashCalculation(t *testing.T) {
	integration := &ArmisIntegration{}

	devices1 := []Device{
		{ID: 1, IPAddress: "192.168.1.10", Name: "device1", LastSeen: time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)},
		{ID: 2, IPAddress: "192.168.1.20", Name: "device2", LastSeen: time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)},
	}

	devices2 := []Device{
		{ID: 1, IPAddress: "192.168.1.10", Name: "device1", LastSeen: time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)},
		{ID: 2, IPAddress: "192.168.1.20", Name: "device2", LastSeen: time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)},
	}

	devices3 := []Device{
		{ID: 1, IPAddress: "192.168.1.10", Name: "device1", LastSeen: time.Date(2025, 1, 2, 0, 0, 0, 0, time.UTC)}, // Different LastSeen
		{ID: 2, IPAddress: "192.168.1.20", Name: "device2", LastSeen: time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)},
	}

	hash1 := integration.calculateDevicesHash(devices1)
	hash2 := integration.calculateDevicesHash(devices2)
	hash3 := integration.calculateDevicesHash(devices3)

	// Same devices should produce same hash
	assert.Equal(t, hash1, hash2, "Identical devices should produce same hash")

	// Different devices should produce different hash
	assert.NotEqual(t, hash1, hash3, "Different devices should produce different hash")

	// Hashes should be non-empty
	assert.NotEmpty(t, hash1, "Hash should not be empty")
	assert.NotEmpty(t, hash3, "Hash should not be empty")
}

func TestSweepResultGeneration(t *testing.T) {
	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			AgentID:   "test-agent",
			PollerID:  "test-poller",
			Partition: "test",
		},
	}

	devices := []Device{
		{
			ID:         1,
			IPAddress:  "192.168.1.10",
			MacAddress: "aa:bb:cc:dd:ee:ff",
			Name:       "test-device",
			Tags:       []string{"critical", "server"},
			FirstSeen:  time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC),
		},
	}

	// First call should generate sweep results
	results := integration.convertToSweepResults(devices)

	require.Len(t, results, 1, "Should generate one sweep result")

	result := results[0]
	assert.Equal(t, "test-agent", result.AgentID)
	assert.Equal(t, "test-poller", result.PollerID)
	assert.Equal(t, "test", result.Partition)
	assert.Equal(t, "armis", result.DiscoverySource)
	assert.Equal(t, "192.168.1.10", result.IP)
	assert.Equal(t, "aa:bb:cc:dd:ee:ff", *result.MAC)
	assert.Equal(t, "test-device", *result.Hostname)
	assert.True(t, result.Available)

	// Check metadata
	assert.Equal(t, "1", result.Metadata["armis_device_id"])
	assert.Equal(t, "critical,server", result.Metadata["tag"])

	// Second call with same devices should not generate results
	results2 := integration.convertToSweepResults(devices)
	assert.Empty(t, results2, "Second call with unchanged devices should return empty results")
}

func TestPerformanceNoChangeScenario(t *testing.T) {
	integration := &ArmisIntegration{
		Config: &models.SourceConfig{
			AgentID:   "test-agent",
			PollerID:  "test-poller",
			Partition: "test",
		},
	}

	// Create a large number of devices to simulate real-world scenario
	devices := make([]Device, 2874) // Same count as the production issue
	for i := 0; i < 2874; i++ {
		devices[i] = Device{
			ID:         i + 1,
			IPAddress:  fmt.Sprintf("192.168.%d.%d", (i/254)+1, (i%254)+1),
			MacAddress: fmt.Sprintf("aa:bb:cc:dd:%02x:%02x", i/256, i%256),
			Name:       fmt.Sprintf("device-%d", i+1),
			LastSeen:   time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC),
		}
	}

	// First call should generate all sweep results
	start := time.Now()
	results1 := integration.convertToSweepResults(devices)
	duration1 := time.Since(start)

	assert.Len(t, results1, 2874, "First call should generate all sweep results")
	t.Logf("First call (with changes) took: %v", duration1)

	// Second call with same devices should be very fast and return no results
	start = time.Now()
	results2 := integration.convertToSweepResults(devices)
	duration2 := time.Since(start)

	assert.Empty(t, results2, "Second call should return no results")
	// Performance improvement should be measurable, but allow for some variance
	assert.Less(t, duration2, duration1*2, "Second call should not be significantly slower")
	t.Logf("Second call (no changes) took: %v", duration2)

	if duration1 > 0 && duration2 > 0 {
		improvement := float64(duration1) / float64(duration2)
		t.Logf("Performance improvement factor: %.2fx", improvement)
	}
}
