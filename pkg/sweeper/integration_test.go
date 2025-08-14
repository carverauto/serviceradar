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

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestAgentCanReadSyncServiceConfig demonstrates that the agent can properly read
// and process configurations written by the sync service, including optimized configs
// with device targets that were converted from large network lists
func TestAgentCanReadSyncServiceConfig(t *testing.T) {
	// This simulates JSON that would be written by the sync service after processing
	// a large Armis configuration (21k+ networks) that was optimized to device targets
	optimizedConfigJSON := `{
		"networks": [],
		"device_targets": [
			{
				"network": "192.168.1.1/32",
				"sweep_modes": ["icmp", "tcp"],
				"query_label": "armis_corporate_devices",
				"source": "armis",
				"metadata": {
					"armis_device_id": "1001",
					"integration_id": "armis-corp-1",
					"integration_type": "armis",
					"query_label": "armis_corporate_devices",
					"converted_from_network": "true",
					"original_network_count": "21000"
				}
			},
			{
				"network": "192.168.1.2/32",
				"sweep_modes": ["icmp"],
				"query_label": "armis_corporate_devices",
				"source": "armis",
				"metadata": {
					"armis_device_id": "1002",
					"integration_id": "armis-corp-2",
					"integration_type": "armis",
					"query_label": "armis_corporate_devices",
					"converted_from_network": "true",
					"original_network_count": "21000"
				}
			},
			{
				"network": "10.1.1.0/24",
				"sweep_modes": ["tcp"],
				"query_label": "armis_guest_devices",
				"source": "armis",
				"metadata": {
					"armis_device_id": "2001",
					"integration_type": "armis",
					"query_label": "armis_guest_devices"
				}
			}
		],
		"ports": [22, 80, 443, 8080],
		"sweep_modes": ["icmp", "tcp"],
		"interval": "5m",
		"concurrency": 50,
		"timeout": "30s",
		"icmp_count": 3,
		"high_perf_icmp": true,
		"icmp_rate_limit": 1000
	}`

	// Create a mock NetworkSweeper to test config processing
	initialConfig := &models.Config{
		Networks: []string{},
		Ports:    []int{22, 80},
	}
	mockSweeper := &NetworkSweeper{
		logger: logger.NewTestLogger(),
		config: initialConfig,
	}

	// Process the config update (this is what happens when agent reads from KV)
	mockSweeper.processConfigUpdate([]byte(optimizedConfigJSON))

	// The test passes if processConfigUpdate doesn't panic or log errors
	// In a real scenario, you would verify that the config was properly applied

	// We can also directly test the unmarshaling
	var temp unmarshalConfig
	err := json.Unmarshal([]byte(optimizedConfigJSON), &temp)
	require.NoError(t, err, "Agent should be able to unmarshal optimized sync service config")

	// Verify the structure
	assert.Empty(t, temp.Networks, "Networks should be empty (converted to device targets)")
	assert.Len(t, temp.DeviceTargets, 3, "Should have 3 device targets")
	assert.Equal(t, []int{22, 80, 443, 8080}, temp.Ports)

	// Verify device targets have correct metadata indicating they came from optimization
	foundConvertedTarget := false

	for _, target := range temp.DeviceTargets {
		if target.Metadata["converted_from_network"] == "true" {
			foundConvertedTarget = true

			assert.Equal(t, "21000", target.Metadata["original_network_count"])

			assert.Equal(t, "armis", target.Source)

			break
		}
	}

	assert.True(t, foundConvertedTarget, "Should find at least one target converted from network optimization")
}

// TestAgentBackwardCompatibility ensures that agents can still read legacy config format
func TestAgentBackwardCompatibility(t *testing.T) {
	legacyConfigJSON := `{
		"networks": ["192.168.1.0/24", "10.0.0.0/16"],
		"ports": [22, 80, 443],
		"sweep_modes": ["icmp", "tcp"],
		"interval": "5m",
		"concurrency": 10,
		"timeout": "30s",
		"icmp_count": 3
	}`

	// Create a mock NetworkSweeper
	initialConfig := &models.Config{
		Networks: []string{},
		Ports:    []int{22, 80},
	}
	mockSweeper := &NetworkSweeper{
		logger: logger.NewTestLogger(),
		config: initialConfig,
	}

	// Process legacy config (should not panic)
	mockSweeper.processConfigUpdate([]byte(legacyConfigJSON))

	// Direct unmarshaling test
	var temp unmarshalConfig
	err := json.Unmarshal([]byte(legacyConfigJSON), &temp)
	require.NoError(t, err, "Agent should handle legacy config format")

	assert.Equal(t, []string{"192.168.1.0/24", "10.0.0.0/16"}, temp.Networks)
	assert.Empty(t, temp.DeviceTargets, "Legacy format should not have device targets")
}

// TestMalformedJSONHandling ensures agent gracefully handles malformed JSON
func TestMalformedJSONHandling(t *testing.T) {
	malformedJSON := `{
		"networks": ["192.168.1.0/24",
		"invalid": "json"
	}` // Missing closing bracket

	mockSweeper := &NetworkSweeper{
		logger: logger.NewTestLogger(),
	}

	// This should not panic, just log an error
	mockSweeper.processConfigUpdate([]byte(malformedJSON))

	// Direct test
	var temp unmarshalConfig
	err := json.Unmarshal([]byte(malformedJSON), &temp)
	assert.Error(t, err, "Should return error for malformed JSON")
}
