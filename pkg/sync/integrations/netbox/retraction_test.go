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

package netbox

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

func TestNetboxIntegration_RetractionsWithSubmitter(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create mocks
	mockSubmitter := NewMockResultSubmitter(ctrl)
	ctx := context.Background()

	// Existing device states from ServiceRadar (includes both devices)
	existingDeviceStates := []DeviceState{
		{
			DeviceID:    "test-partition:192.168.1.1",
			IP:          "192.168.1.1",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"integration_id": "1",
			},
		},
		{
			DeviceID:    "test-partition:192.168.1.2",
			IP:          "192.168.1.2",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"integration_id": "2",
			},
		},
	}

	// Current events from NetBox API (device 1 is missing)
	currentEvents := []*models.DeviceUpdate{
		{
			AgentID:     "test-agent",
			PollerID:    "test-poller",
			Partition:   "test-partition",
			DeviceID:    "test-partition:192.168.1.2",
			Source:      models.DiscoverySourceNetbox,
			IP:          "192.168.1.2",
			Hostname:    stringPtr("Device 2"),
			Timestamp:   time.Now(),
			IsAvailable: true,
			Confidence:  models.GetSourceConfidence(models.DiscoverySourceNetbox),
			Metadata: map[string]string{
				"integration_type": "netbox",
				"integration_id":   "2",
			},
		},
	}

	// Setup the integration
	integration := &NetboxIntegration{
		Config: &models.SourceConfig{
			AgentID:     "test-agent",
			PollerID:    "test-poller",
			Partition:   "test-partition",
			Endpoint:    "https://netbox.example.com",
			Credentials: map[string]string{"api_token": "test-token"},
		},
		ResultSubmitter: mockSubmitter,
		Logger:          logger.NewTestLogger(),
	}

	// Mock the result submitter to capture retraction events
	mockSubmitter.EXPECT().
		SubmitBatchSweepResults(ctx, gomock.Any()).
		DoAndReturn(func(_ context.Context, results []*models.DeviceUpdate) error {
			require.Len(t, results, 1)
			result := results[0]

			// Verify retraction event structure
			assert.Equal(t, "test-partition:192.168.1.1", result.DeviceID)
			assert.Equal(t, models.DiscoverySourceNetbox, result.Source)
			assert.Equal(t, "192.168.1.1", result.IP)
			assert.False(t, result.IsAvailable)
			assert.Equal(t, "true", result.Metadata["_deleted"])
			assert.Equal(t, "test-agent", result.AgentID)
			assert.Equal(t, "test-poller", result.PollerID)
			assert.Equal(t, "test-partition", result.Partition)

			return nil
		})

	// Generate retraction events
	retractionEvents := integration.generateRetractionEvents(currentEvents, existingDeviceStates)

	// Verify we get the expected retraction event
	require.Len(t, retractionEvents, 1)

	// Test submission
	if len(retractionEvents) > 0 && integration.ResultSubmitter != nil {
		err := integration.ResultSubmitter.SubmitBatchSweepResults(ctx, retractionEvents)
		require.NoError(t, err)
	}
}

func TestNetboxIntegration_NoRetractionEvents(t *testing.T) {
	// Existing device states from ServiceRadar
	existingDeviceStates := []DeviceState{
		{
			DeviceID:    "test-partition:192.168.1.1",
			IP:          "192.168.1.1",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"integration_id": "1",
			},
		},
		{
			DeviceID:    "test-partition:192.168.1.2",
			IP:          "192.168.1.2",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"integration_id": "2",
			},
		},
	}

	// Current events from NetBox API (all devices still present)
	currentEvents := []*models.DeviceUpdate{
		{
			AgentID:     "test-agent",
			PollerID:    "test-poller",
			Partition:   "test-partition",
			DeviceID:    "test-partition:192.168.1.1",
			Source:      models.DiscoverySourceNetbox,
			IP:          "192.168.1.1",
			Hostname:    stringPtr("Device 1"),
			Timestamp:   time.Now(),
			IsAvailable: true,
			Confidence:  models.GetSourceConfidence(models.DiscoverySourceNetbox),
			Metadata: map[string]string{
				"integration_type": "netbox",
				"integration_id":   "1",
			},
		},
		{
			AgentID:     "test-agent",
			PollerID:    "test-poller",
			Partition:   "test-partition",
			DeviceID:    "test-partition:192.168.1.2",
			Source:      models.DiscoverySourceNetbox,
			IP:          "192.168.1.2",
			Hostname:    stringPtr("Device 2"),
			Timestamp:   time.Now(),
			IsAvailable: true,
			Confidence:  models.GetSourceConfidence(models.DiscoverySourceNetbox),
			Metadata: map[string]string{
				"integration_type": "netbox",
				"integration_id":   "2",
			},
		},
	}

	// Setup the integration
	integration := &NetboxIntegration{
		Config: &models.SourceConfig{
			AgentID:     "test-agent",
			PollerID:    "test-poller",
			Partition:   "test-partition",
			Endpoint:    "https://netbox.example.com",
			Credentials: map[string]string{"api_token": "test-token"},
		},
	}

	// Generate retraction events (should be empty)
	retractionEvents := integration.generateRetractionEvents(currentEvents, existingDeviceStates)

	// Verify no retraction events are generated
	assert.Empty(t, retractionEvents)
}

func TestNetboxIntegration_ResultSubmitterError(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create mocks
	mockSubmitter := NewMockResultSubmitter(ctrl)
	ctx := context.Background()

	// Existing device states from ServiceRadar
	existingDeviceStates := []DeviceState{
		{
			DeviceID:    "test-partition:192.168.1.1",
			IP:          "192.168.1.1",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"integration_id": "1",
			},
		},
	}

	// Current events from NetBox API (device 1 is missing)
	currentEvents := []*models.DeviceUpdate{}

	// Setup the integration
	integration := &NetboxIntegration{
		Config: &models.SourceConfig{
			AgentID:     "test-agent",
			PollerID:    "test-poller",
			Partition:   "test-partition",
			Endpoint:    "https://netbox.example.com",
			Credentials: map[string]string{"api_token": "test-token"},
		},
		ResultSubmitter: mockSubmitter,
		Logger:          logger.NewTestLogger(),
	}

	// Mock the result submitter to return an error
	expectedError := assert.AnError
	mockSubmitter.EXPECT().
		SubmitBatchSweepResults(ctx, gomock.Any()).
		Return(expectedError)

	// Generate retraction events
	retractionEvents := integration.generateRetractionEvents(currentEvents, existingDeviceStates)
	require.Len(t, retractionEvents, 1)

	// Test that error is properly propagated
	if len(retractionEvents) > 0 && integration.ResultSubmitter != nil {
		err := integration.ResultSubmitter.SubmitBatchSweepResults(ctx, retractionEvents)
		require.Error(t, err)
		assert.Equal(t, expectedError, err)
	}
}

func TestNetboxIntegration_NoResultSubmitter(t *testing.T) {
	// Test case where ResultSubmitter is nil - should log warning but not fail
	existingDeviceStates := []DeviceState{
		{
			DeviceID:    "test-partition:192.168.1.1",
			IP:          "192.168.1.1",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"integration_id": "1",
			},
		},
	}

	// Current events from NetBox API (device 1 is missing)
	currentEvents := []*models.DeviceUpdate{}

	// Setup the integration WITHOUT ResultSubmitter
	integration := &NetboxIntegration{
		Config: &models.SourceConfig{
			AgentID:     "test-agent",
			PollerID:    "test-poller",
			Partition:   "test-partition",
			Endpoint:    "https://netbox.example.com",
			Credentials: map[string]string{"api_token": "test-token"},
		},
		ResultSubmitter: nil, // No result submitter configured
		Logger:          logger.NewTestLogger(),
	}

	// Generate retraction events
	retractionEvents := integration.generateRetractionEvents(currentEvents, existingDeviceStates)

	// Should generate retraction events
	require.Len(t, retractionEvents, 1)

	// But submitting should be skipped without error when ResultSubmitter is nil
	if len(retractionEvents) > 0 && integration.ResultSubmitter != nil {
		// This block should not execute
		t.Fatal("ResultSubmitter should be nil")
	}
}

func TestNetboxIntegration_generateRetractionEvents(t *testing.T) {
	// Setup test data
	integration := &NetboxIntegration{
		Config: &models.SourceConfig{
			AgentID:   "test-agent",
			PollerID:  "test-poller",
			Partition: "test-partition",
		},
		Logger: logger.NewTestLogger(),
	}

	// Current events from NetBox API
	currentEvents := []*models.DeviceUpdate{
		{
			DeviceID:    "test-partition:192.168.1.2",
			IP:          "192.168.1.2",
			Source:      models.DiscoverySourceNetbox,
			AgentID:     "test-agent",
			PollerID:    "test-poller",
			Partition:   "test-partition",
			Timestamp:   time.Now(),
			IsAvailable: true,
			Confidence:  models.GetSourceConfidence(models.DiscoverySourceNetbox),
			Metadata: map[string]string{
				"integration_id": "2", // Device 2 is still present
			},
		},
		{
			DeviceID:    "test-partition:192.168.1.3",
			IP:          "192.168.1.3",
			Source:      models.DiscoverySourceNetbox,
			AgentID:     "test-agent",
			PollerID:    "test-poller",
			Partition:   "test-partition",
			Timestamp:   time.Now(),
			IsAvailable: true,
			Confidence:  models.GetSourceConfidence(models.DiscoverySourceNetbox),
			Metadata: map[string]string{
				"integration_id": "3", // Device 3 is still present
			},
		},
	}

	// Existing device states from ServiceRadar
	existingDeviceStates := []DeviceState{
		{
			DeviceID:    "test-partition:192.168.1.1",
			IP:          "192.168.1.1",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"integration_id": "1", // This device is missing from current events
			},
		},
		{
			DeviceID:    "test-partition:192.168.1.2",
			IP:          "192.168.1.2",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"integration_id": "2", // This device is still present
			},
		},
		{
			DeviceID:    "test-partition:192.168.1.4",
			IP:          "192.168.1.4",
			IsAvailable: true,
			Metadata: map[string]interface{}{
				"integration_id": "4", // This device is missing from current events
			},
		},
		{
			DeviceID:    "test-partition:192.168.1.5",
			IP:          "192.168.1.5",
			IsAvailable: true,
			Metadata:    map[string]interface{}{
				// Missing integration_id - should be skipped
			},
		},
	}

	// Execute
	retractionEvents := integration.generateRetractionEvents(currentEvents, existingDeviceStates)

	// Verify
	require.Len(t, retractionEvents, 2) // Only devices 1 and 4 should be retracted

	// Check first retraction event
	event1 := retractionEvents[0]
	assert.Equal(t, "test-partition:192.168.1.1", event1.DeviceID)
	assert.Equal(t, models.DiscoverySourceNetbox, event1.Source)
	assert.Equal(t, "192.168.1.1", event1.IP)
	assert.False(t, event1.IsAvailable)
	assert.Equal(t, "true", event1.Metadata["_deleted"])
	assert.Equal(t, "test-agent", event1.AgentID)
	assert.Equal(t, "test-poller", event1.PollerID)
	assert.Equal(t, "test-partition", event1.Partition)

	// Check second retraction event
	event2 := retractionEvents[1]
	assert.Equal(t, "test-partition:192.168.1.4", event2.DeviceID)
	assert.Equal(t, models.DiscoverySourceNetbox, event2.Source)
	assert.Equal(t, "192.168.1.4", event2.IP)
	assert.False(t, event2.IsAvailable)
	assert.Equal(t, "true", event2.Metadata["_deleted"])
	assert.Equal(t, "test-agent", event2.AgentID)
	assert.Equal(t, "test-poller", event2.PollerID)
	assert.Equal(t, "test-partition", event2.Partition)

	// Verify timestamps are recent
	assert.WithinDuration(t, time.Now(), event1.Timestamp, time.Second)
	assert.WithinDuration(t, time.Now(), event2.Timestamp, time.Second)
}

// Helper function to create string pointer
func stringPtr(s string) *string {
	return &s
}
