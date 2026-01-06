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

package sync

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// TestArmisNetBoxStreamResults tests that both Armis and NetBox data is properly chunked for streaming.
func TestArmisNetBoxStreamResults(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Mock dependencies
	// Create test config with both Armis and NetBox sources
	config := &Config{
		AgentID:           "test-agent",
		GatewayID:          "test-gateway",
		DiscoveryInterval: models.Duration(30 * time.Second),
		UpdateInterval:    models.Duration(60 * time.Second),
		Sources: map[string]*models.SourceConfig{
			"armis": {
				Type:     "armis",
				AgentID:  "test-agent",
				GatewayID: "test-gateway",
			},
			"netbox": {
				Type:     "netbox",
				AgentID:  "test-agent",
				GatewayID: "test-gateway",
			},
		},
	}

	// Create mock integrations that return test data
	mockArmisIntegration := NewMockIntegration(ctrl)
	mockNetBoxIntegration := NewMockIntegration(ctrl)

	// Create service with mocked integrations
	service := &SimpleSyncService{
		config: *config,
		sources: map[string]Integration{
			"armis":  mockArmisIntegration,
			"netbox": mockNetBoxIntegration,
		},
		resultsStore: &StreamingResultsStore{},
		logger:       logger.NewTestLogger(),
	}

	// Set up test data
	armisDevices := []*models.DeviceUpdate{
		{
			DeviceID:    "test:192.168.1.1",
			AgentID:     "test-agent",
			GatewayID:    "test-gateway",
			Source:      models.DiscoverySourceArmis,
			IP:          "192.168.1.1",
			IsAvailable: true,
			Timestamp:   time.Now(),
			Metadata: map[string]string{
				"integration_type": "armis",
				"integration_id":   "1001",
			},
		},
		{
			DeviceID:    "test:192.168.1.2",
			AgentID:     "test-agent",
			GatewayID:    "test-gateway",
			Source:      models.DiscoverySourceArmis,
			IP:          "192.168.1.2",
			IsAvailable: true,
			Timestamp:   time.Now(),
			Metadata: map[string]string{
				"integration_type": "armis",
				"integration_id":   "1002",
			},
		},
	}

	netboxDevices := []*models.DeviceUpdate{
		{
			DeviceID:    "test:10.0.0.1",
			AgentID:     "test-agent",
			GatewayID:    "test-gateway",
			Source:      models.DiscoverySourceNetbox,
			IP:          "10.0.0.1",
			IsAvailable: false, // NetBox doesn't set this to true
			Timestamp:   time.Now(),
			Metadata: map[string]string{
				"integration_type": "netbox",
				"integration_id":   "2001",
			},
		},
		{
			DeviceID:    "test:10.0.0.2",
			AgentID:     "test-agent",
			GatewayID:    "test-gateway",
			Source:      models.DiscoverySourceNetbox,
			IP:          "10.0.0.2",
			IsAvailable: false, // NetBox doesn't set this to true
			Timestamp:   time.Now(),
			Metadata: map[string]string{
				"integration_type": "netbox",
				"integration_id":   "2002",
			},
		},
	}

	allDeviceUpdates := map[string][]*models.DeviceUpdate{
		"armis":  armisDevices,
		"netbox": netboxDevices,
	}
	allDevices := service.collectDeviceUpdates(allDeviceUpdates)
	chunks, err := service.buildResultsChunks(allDevices, "seq-1")
	require.NoError(t, err)
	require.Len(t, chunks, 1, "Expected 1 chunk")
	chunk := chunks[0]

	// Unmarshal the chunk data
	var receivedDevices []*models.DeviceUpdate

	err = json.Unmarshal(chunk.Data, &receivedDevices)
	require.NoError(t, err)

	// Should have all 4 devices (2 from Armis, 2 from NetBox)
	assert.Len(t, receivedDevices, 4, "Should have all devices from both sources")

	// Count devices by source
	armisCount := 0
	netboxCount := 0

	for _, device := range receivedDevices {
		switch device.Source {
		case models.DiscoverySourceArmis:
			armisCount++

			assert.True(t, device.IsAvailable, "Armis devices should have IsAvailable=true")
			assert.Equal(t, "armis", device.Metadata["integration_type"])
		case models.DiscoverySourceNetbox:
			netboxCount++

			assert.False(t, device.IsAvailable, "NetBox devices should have IsAvailable=false")
			assert.Equal(t, "netbox", device.Metadata["integration_type"])
		case models.DiscoverySourceSNMP:
			// Not expected in this test
		case models.DiscoverySourceMapper:
			// Not expected in this test
		case models.DiscoverySourceIntegration:
			// Not expected in this test
		case models.DiscoverySourceNetFlow:
			// Not expected in this test
		case models.DiscoverySourceManual:
			// Not expected in this test
		case models.DiscoverySourceSweep:
			// Not expected in this test
		case models.DiscoverySourceSighting:
			// Not expected in this test
		case models.DiscoverySourceSelfReported:
			// Not expected in this test
		case models.DiscoverySourceSysmon:
			// Not expected in this test
		case models.DiscoverySourceServiceRadar:
			// Not expected in this test
		}
	}

	assert.Equal(t, 2, armisCount, "Should have 2 Armis devices")
	assert.Equal(t, 2, netboxCount, "Should have 2 NetBox devices")
}
