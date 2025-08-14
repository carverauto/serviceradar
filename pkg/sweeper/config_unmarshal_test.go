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

package sweeper

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestUnmarshalConfig_NewSweepConfigFormat tests that the agent can properly unmarshal
// the new SweepConfig format written by the sync service with device targets
func TestUnmarshalConfig_NewSweepConfigFormat(t *testing.T) {
	// This represents JSON that would be written by the sync service after optimization
	// (networks converted to device targets)
	syncServiceJSON := `{
		"networks": [],
		"device_targets": [
			{
				"network": "192.168.1.1/32",
				"sweep_modes": ["icmp", "tcp"],
				"query_label": "armis_corporate",
				"source": "armis",
				"metadata": {
					"armis_device_id": "123",
					"converted_from_network": "true"
				}
			},
			{
				"network": "10.0.0.0/24",
				"sweep_modes": ["icmp"],
				"query_label": "armis_guest",
				"source": "armis",
				"metadata": {
					"armis_device_id": "456"
				}
			}
		],
		"ports": [22, 80, 443],
		"sweep_modes": ["icmp", "tcp"],
		"interval": "5m",
		"concurrency": 10,
		"timeout": "30s",
		"icmp_count": 3
	}`

	var temp unmarshalConfig
	err := json.Unmarshal([]byte(syncServiceJSON), &temp)
	require.NoError(t, err, "Should be able to unmarshal sync service JSON")

	// Verify device targets were parsed correctly
	require.Len(t, temp.DeviceTargets, 2, "Should have 2 device targets")

	// Check first device target
	assert.Equal(t, "192.168.1.1/32", temp.DeviceTargets[0].Network)
	assert.Equal(t, []models.SweepMode{models.ModeICMP, models.ModeTCP}, temp.DeviceTargets[0].SweepModes)
	assert.Equal(t, "armis_corporate", temp.DeviceTargets[0].QueryLabel)
	assert.Equal(t, "armis", temp.DeviceTargets[0].Source)
	assert.Equal(t, "123", temp.DeviceTargets[0].Metadata["armis_device_id"])
	assert.Equal(t, "true", temp.DeviceTargets[0].Metadata["converted_from_network"])

	// Check second device target
	assert.Equal(t, "10.0.0.0/24", temp.DeviceTargets[1].Network)
	assert.Equal(t, []models.SweepMode{models.ModeICMP}, temp.DeviceTargets[1].SweepModes)
	assert.Equal(t, "armis_guest", temp.DeviceTargets[1].QueryLabel)
	assert.Equal(t, "armis", temp.DeviceTargets[1].Source)
	assert.Equal(t, "456", temp.DeviceTargets[1].Metadata["armis_device_id"])

	// Verify other fields
	assert.Empty(t, temp.Networks, "Networks should be empty (converted to device targets)")
	assert.Equal(t, []int{22, 80, 443}, temp.Ports)
	assert.Equal(t, []models.SweepMode{models.ModeICMP, models.ModeTCP}, []models.SweepMode(temp.SweepModes))
	assert.Equal(t, 5*time.Minute, time.Duration(temp.Interval))
	assert.Equal(t, 10, temp.Concurrency)
	assert.Equal(t, 30*time.Second, time.Duration(temp.Timeout))
	assert.Equal(t, 3, temp.ICMPCount)
}

// TestUnmarshalConfig_LegacyFormat tests backward compatibility with legacy Config format
func TestUnmarshalConfig_LegacyFormat(t *testing.T) {
	legacyJSON := `{
		"networks": ["192.168.1.0/24", "10.0.0.0/8"],
		"ports": [22, 80, 443],
		"sweep_modes": ["icmp", "tcp"],
		"interval": "5m",
		"concurrency": 10,
		"timeout": "30s",
		"icmp_count": 3,
		"icmp_settings": {
			"rate_limit": 100,
			"timeout": "5s",
			"max_batch": 50
		},
		"tcp_settings": {
			"concurrency": 20,
			"timeout": "10s",
			"max_batch": 100
		},
		"high_perf_icmp": true,
		"icmp_rate_limit": 200
	}`

	var temp unmarshalConfig
	err := json.Unmarshal([]byte(legacyJSON), &temp)
	require.NoError(t, err, "Should be able to unmarshal legacy JSON")

	// Verify legacy fields
	assert.Equal(t, []string{"192.168.1.0/24", "10.0.0.0/8"}, temp.Networks)
	assert.Equal(t, []int{22, 80, 443}, temp.Ports)
	assert.Equal(t, []models.SweepMode{models.ModeICMP, models.ModeTCP}, []models.SweepMode(temp.SweepModes))
	assert.Empty(t, temp.DeviceTargets, "DeviceTargets should be empty for legacy format")

	// Verify settings
	assert.Equal(t, 100, temp.ICMPSettings.RateLimit)
	assert.Equal(t, 5*time.Second, time.Duration(temp.ICMPSettings.Timeout))
	assert.Equal(t, 50, temp.ICMPSettings.MaxBatch)

	assert.Equal(t, 20, temp.TCPSettings.Concurrency)
	assert.Equal(t, 10*time.Second, time.Duration(temp.TCPSettings.Timeout))
	assert.Equal(t, 100, temp.TCPSettings.MaxBatch)

	assert.True(t, temp.EnableHighPerformanceICMP)
	assert.Equal(t, 200, temp.ICMPRateLimit)
}

// TestSweepModeSlice_StringFormat tests that sweep modes can be unmarshaled from strings
func TestSweepModeSlice_StringFormat(t *testing.T) {
	jsonWithStrings := `["icmp", "tcp"]`

	var sweepModes sweepModeSlice
	err := json.Unmarshal([]byte(jsonWithStrings), &sweepModes)
	require.NoError(t, err)

	expected := []models.SweepMode{models.ModeICMP, models.ModeTCP}
	assert.Equal(t, expected, []models.SweepMode(sweepModes))
}

// TestSweepModeSlice_TypedFormat tests that sweep modes can be unmarshaled from typed values
func TestSweepModeSlice_TypedFormat(t *testing.T) {
	jsonWithTypes := `["icmp", "tcp"]`

	var sweepModes sweepModeSlice
	err := json.Unmarshal([]byte(jsonWithTypes), &sweepModes)
	require.NoError(t, err)

	expected := []models.SweepMode{models.ModeICMP, models.ModeTCP}
	assert.Equal(t, expected, []models.SweepMode(sweepModes))
}

// TestDurationWrapper tests duration parsing
func TestDurationWrapper(t *testing.T) {
	testCases := []struct {
		name     string
		input    string
		expected time.Duration
	}{
		{"5 minutes", `"5m"`, 5 * time.Minute},
		{"30 seconds", `"30s"`, 30 * time.Second},
		{"1 hour", `"1h"`, 1 * time.Hour},
		{"empty string", `""`, 0},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			var d durationWrapper
			err := json.Unmarshal([]byte(tc.input), &d)
			require.NoError(t, err)
			assert.Equal(t, tc.expected, time.Duration(d))
		})
	}
}
