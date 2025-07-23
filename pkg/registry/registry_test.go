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

package registry

import (
	"context"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestDeviceRegistry_ProcessBatchSweepResults(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)

	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB)

	tests := []struct {
		name        string
		sightings   []*models.SweepResult
		description string
		validate    func(t *testing.T, publishedResults []*models.SweepResult)
	}{
		{
			name:        "Simple device with complete data",
			description: "Device with all required fields should be passed through without modification",
			sightings: []*models.SweepResult{
				{
					IP:              "216.17.46.98",
					DeviceID:        "default:216.17.46.98",
					Partition:       "default",
					DiscoverySource: "mapper",
					Hostname:        stringPtr("tonka01"),
					Timestamp:       time.Now(),
					Available:       true,
					Metadata: map[string]string{
						"alternate_ips":   `["192.168.10.1"]`,
						"controller_name": "Tonka",
						"source":          "unifi-api",
						"unifi_device_id": "39b54c6a-1598-3904-aa0c-96d9727f4d74",
					},
				},
			},
			validate: func(t *testing.T, publishedResults []*models.SweepResult) {
				t.Helper()
				assert.Len(t, publishedResults, 1, "Should publish exactly one result")
				result := publishedResults[0]
				assert.Equal(t, "default:216.17.46.98", result.DeviceID)
				assert.Equal(t, "216.17.46.98", result.IP)
				assert.Equal(t, "default", result.Partition)
				assert.Equal(t, "mapper", result.DiscoverySource)
				assert.Equal(t, "tonka01", *result.Hostname)
				assert.True(t, result.Available)
				assert.Equal(t, `["192.168.10.1"]`, result.Metadata["alternate_ips"])
			},
		},
		{
			name:        "Device with empty DeviceID gets normalized",
			description: "Device without DeviceID should get one generated from IP",
			sightings: []*models.SweepResult{
				{
					IP:              "192.168.1.100",
					DeviceID:        "", // Empty DeviceID
					Partition:       "default",
					DiscoverySource: "sweep",
					Hostname:        stringPtr("test-device"),
					Timestamp:       time.Now(),
					Available:       true,
					Metadata:        map[string]string{},
				},
			},
			validate: func(t *testing.T, publishedResults []*models.SweepResult) {
				t.Helper()
				assert.Len(t, publishedResults, 1, "Should publish exactly one result")
				result := publishedResults[0]
				assert.Equal(t, "default:192.168.1.100", result.DeviceID, "Should generate DeviceID from IP")
				assert.Equal(t, "192.168.1.100", result.IP)
				assert.Equal(t, "default", result.Partition)
			},
		},
		{
			name:        "Device with empty Partition gets normalized",
			description: "Device without Partition should get default partition",
			sightings: []*models.SweepResult{
				{
					IP:              "192.168.10.5",
					DeviceID:        "default:192.168.10.5",
					Partition:       "", // Empty Partition
					DiscoverySource: "mapper",
					Hostname:        stringPtr("multi-ip-device"),
					Timestamp:       time.Now(),
					Available:       true,
					Metadata: map[string]string{
						"alternate_ips": `["192.168.10.1", "192.168.10.3", "192.168.10.8"]`,
					},
				},
			},
			validate: func(t *testing.T, publishedResults []*models.SweepResult) {
				t.Helper()
				assert.Len(t, publishedResults, 1, "Should publish exactly one result")
				result := publishedResults[0]
				assert.Equal(t, "default", result.Partition, "Should extract partition from DeviceID")
				assert.Equal(t, "default:192.168.10.5", result.DeviceID)
			},
		},
		{
			name:        "Multiple devices in batch",
			description: "Multiple devices should all be processed and published",
			sightings: []*models.SweepResult{
				{
					IP:              "192.168.1.1",
					DeviceID:        "default:192.168.1.1",
					Partition:       "default",
					DiscoverySource: "snmp",
					Hostname:        stringPtr("device1"),
					Timestamp:       time.Now(),
					Available:       true,
					Metadata:        map[string]string{"type": "router"},
				},
				{
					IP:              "192.168.1.2",
					DeviceID:        "default:192.168.1.2",
					Partition:       "default",
					DiscoverySource: "sweep",
					Hostname:        stringPtr("device2"),
					Timestamp:       time.Now(),
					Available:       false,
					Metadata:        map[string]string{"type": "switch"},
				},
			},
			validate: func(t *testing.T, publishedResults []*models.SweepResult) {
				t.Helper()

				assert.Len(t, publishedResults, 2, "Should publish both results")

				// Check first device
				result1 := publishedResults[0]
				assert.Equal(t, "default:192.168.1.1", result1.DeviceID)
				assert.Equal(t, "192.168.1.1", result1.IP)
				assert.Equal(t, "device1", *result1.Hostname)
				assert.True(t, result1.Available)
				assert.Equal(t, "router", result1.Metadata["type"])

				// Check second device
				result2 := publishedResults[1]
				assert.Equal(t, "default:192.168.1.2", result2.DeviceID)
				assert.Equal(t, "192.168.1.2", result2.IP)
				assert.Equal(t, "device2", *result2.Hostname)
				assert.False(t, result2.Available)
				assert.Equal(t, "switch", result2.Metadata["type"])
			},
		},
		{
			name:        "Empty batch",
			description: "Empty batch should not cause any database calls",
			sightings:   []*models.SweepResult{},
			validate: func(t *testing.T, _ []*models.SweepResult) {
				t.Helper()

				// This test should not reach the validation function
				// since no PublishBatchSweepResults call should be made
				t.Error("Empty batch should not trigger database call")
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if len(tt.sightings) == 0 {
				// For empty batches, no database call should be made
				// Execute the test
				err := registry.ProcessBatchSweepResults(ctx, tt.sightings)
				require.NoError(t, err, "ProcessBatchSweepResults should handle empty batches")
			} else {
				// Mock: Expect PublishBatchSweepResults to be called
				mockDB.EXPECT().PublishBatchSweepResults(
					gomock.Any(),
					gomock.AssignableToTypeOf([]*models.SweepResult{}),
				).DoAndReturn(func(_ context.Context, results []*models.SweepResult) error {
					// Validate the results that would be published
					tt.validate(t, results)
					return nil
				})

				// Execute the test
				err := registry.ProcessBatchSweepResults(ctx, tt.sightings)
				require.NoError(t, err, "ProcessBatchSweepResults should not return error")
			}

			t.Logf("✅ Test passed: %s", tt.description)
		})
	}
}

func TestDeviceRegistry_ProcessBatchDeviceUpdates(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB)

	tests := []struct {
		name        string
		updates     []*models.DeviceUpdate
		description string
		validate    func(t *testing.T, publishedUpdates []*models.DeviceUpdate)
	}{
		{
			name:        "DeviceUpdate with complete data",
			description: "DeviceUpdate should be converted to SweepResult and published",
			updates: []*models.DeviceUpdate{
				{
					DeviceID:    "default:192.168.1.1",
					IP:          "192.168.1.1",
					Partition:   "default",
					Source:      models.DiscoverySourceSNMP,
					AgentID:     "agent1",
					PollerID:    "poller1",
					Timestamp:   time.Now(),
					IsAvailable: true,
					Hostname:    stringPtr("test-device"),
					MAC:         stringPtr("00:11:22:33:44:55"),
					Metadata: map[string]string{
						"vendor": "Cisco",
						"model":  "2960",
					},
					Confidence: 95,
				},
			},
			validate: func(t *testing.T, publishedUpdates []*models.DeviceUpdate) {
				t.Helper()
				assert.Len(t, publishedUpdates, 1, "Should publish exactly one update")
				update := publishedUpdates[0]
				assert.Equal(t, "default:192.168.1.1", update.DeviceID)
				assert.Equal(t, "192.168.1.1", update.IP)
				assert.Equal(t, "default", update.Partition)
				assert.Equal(t, models.DiscoverySourceSNMP, update.Source)
				assert.Equal(t, "agent1", update.AgentID)
				assert.Equal(t, "poller1", update.PollerID)
				assert.True(t, update.IsAvailable)
				assert.Equal(t, "test-device", *update.Hostname)
				assert.Equal(t, "00:11:22:33:44:55", *update.MAC)
				assert.Equal(t, "Cisco", update.Metadata["vendor"])
				assert.Equal(t, "2960", update.Metadata["model"])
			},
		},
		{
			name:        "DeviceUpdate with empty DeviceID gets normalized",
			description: "DeviceUpdate without DeviceID should get one generated",
			updates: []*models.DeviceUpdate{
				{
					DeviceID:    "", // Empty DeviceID
					IP:          "192.168.1.2",
					Partition:   "default",
					Source:      models.DiscoverySourceSweep,
					Timestamp:   time.Now(),
					IsAvailable: true,
					Hostname:    stringPtr("normalized-device"),
				},
			},
			validate: func(t *testing.T, publishedUpdates []*models.DeviceUpdate) {
				t.Helper()
				assert.Len(t, publishedUpdates, 1, "Should publish exactly one update")
				update := publishedUpdates[0]
				assert.Equal(t, "default:192.168.1.2", update.DeviceID, "Should generate DeviceID from IP")
				assert.Equal(t, "192.168.1.2", update.IP)
				assert.Equal(t, "default", update.Partition)
			},
		},
		{
			name:        "DeviceUpdate with nil hostname and MAC",
			description: "DeviceUpdate with nil hostname and MAC should be handled correctly",
			updates: []*models.DeviceUpdate{
				{
					DeviceID:    "default:192.168.1.3",
					IP:          "192.168.1.3",
					Partition:   "default",
					Source:      models.DiscoverySourceMapper,
					Timestamp:   time.Now(),
					IsAvailable: false,
					Hostname:    nil,
					MAC:         nil,
					Metadata:    map[string]string{},
				},
			},
			validate: func(t *testing.T, publishedUpdates []*models.DeviceUpdate) {
				t.Helper()
				assert.Len(t, publishedUpdates, 1, "Should publish exactly one update")
				update := publishedUpdates[0]
				assert.Equal(t, "default:192.168.1.3", update.DeviceID)
				assert.Nil(t, update.Hostname, "Should keep nil hostname as nil")
				assert.Nil(t, update.MAC, "Should keep nil MAC as nil")
				assert.False(t, update.IsAvailable)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if len(tt.updates) == 0 {
				// For empty batches, no database call should be made
				err := registry.ProcessBatchDeviceUpdates(ctx, tt.updates)
				require.NoError(t, err, "ProcessBatchDeviceUpdates should handle empty batches")
			} else {
				// Mock: Expect PublishBatchDeviceUpdates to be called
				mockDB.EXPECT().PublishBatchDeviceUpdates(
					gomock.Any(),
					gomock.AssignableToTypeOf([]*models.DeviceUpdate{}),
				).DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
					// Validate the updates that would be published
					tt.validate(t, updates)

					return nil
				})

				// Execute the test
				err := registry.ProcessBatchDeviceUpdates(ctx, tt.updates)
				require.NoError(t, err, "ProcessBatchDeviceUpdates should not return error")
			}

			t.Logf("✅ Test passed: %s", tt.description)
		})
	}
}

func TestDeviceRegistry_ProcessDeviceUpdate(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB)

	// Test single device update (should call ProcessBatchDeviceUpdates internally)
	update := &models.DeviceUpdate{
		DeviceID:    "default:192.168.1.1",
		IP:          "192.168.1.1",
		Partition:   "default",
		Source:      models.DiscoverySourceSNMP,
		Timestamp:   time.Now(),
		IsAvailable: true,
		Hostname:    stringPtr("single-device"),
		Metadata:    map[string]string{"test": "value"},
	}

	// Mock: Expect PublishBatchDeviceUpdates to be called with single item
	mockDB.EXPECT().PublishBatchDeviceUpdates(
		gomock.Any(),
		gomock.AssignableToTypeOf([]*models.DeviceUpdate{}),
	).DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
		assert.Len(t, updates, 1, "Should publish exactly one update")
		update = updates[0]
		assert.Equal(t, "default:192.168.1.1", update.DeviceID)
		assert.Equal(t, "192.168.1.1", update.IP)
		assert.Equal(t, "single-device", *update.Hostname)
		assert.Equal(t, "value", update.Metadata["test"])

		return nil
	})

	// Execute the test
	err := registry.ProcessDeviceUpdate(ctx, update)
	require.NoError(t, err, "ProcessDeviceUpdate should not return error")
}

func TestDeviceRegistry_NormalizationBehavior(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB)

	tests := []struct {
		name        string
		input       *models.SweepResult
		description string
		validate    func(t *testing.T, normalized *models.SweepResult)
	}{
		{
			name:        "DeviceID and Partition both empty",
			description: "Should generate both DeviceID and Partition from IP",
			input: &models.SweepResult{
				IP:              "192.168.1.100",
				DeviceID:        "",
				Partition:       "",
				DiscoverySource: "sweep",
				Timestamp:       time.Now(),
				Available:       true,
			},
			validate: func(t *testing.T, normalized *models.SweepResult) {
				t.Helper()

				assert.Equal(t, "default:192.168.1.100", normalized.DeviceID)
				assert.Equal(t, "default", normalized.Partition)
			},
		},
		{
			name:        "Partition empty but DeviceID has valid format",
			description: "Should extract partition from DeviceID",
			input: &models.SweepResult{
				IP:              "192.168.1.101",
				DeviceID:        "custom:192.168.1.101",
				Partition:       "",
				DiscoverySource: "sweep",
				Timestamp:       time.Now(),
				Available:       true,
			},
			validate: func(t *testing.T, normalized *models.SweepResult) {
				t.Helper()

				assert.Equal(t, "custom:192.168.1.101", normalized.DeviceID)
				assert.Equal(t, "custom", normalized.Partition)
			},
		},
		{
			name:        "DeviceID malformed without colon",
			description: "Should keep malformed DeviceID but extract default partition",
			input: &models.SweepResult{
				IP:              "192.168.1.102",
				DeviceID:        "malformed-device-id",
				Partition:       "",
				DiscoverySource: "sweep",
				Timestamp:       time.Now(),
				Available:       true,
			},
			validate: func(t *testing.T, normalized *models.SweepResult) {
				t.Helper()

				assert.Equal(t, "malformed-device-id", normalized.DeviceID)
				assert.Equal(t, "default", normalized.Partition)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Mock: Expect PublishBatchSweepResults to be called
			mockDB.EXPECT().PublishBatchSweepResults(
				gomock.Any(),
				gomock.AssignableToTypeOf([]*models.SweepResult{}),
			).DoAndReturn(func(_ context.Context, results []*models.SweepResult) error {
				assert.Len(t, results, 1, "Should publish exactly one result")
				tt.validate(t, results[0])

				return nil
			})

			// Execute the test
			err := registry.ProcessBatchSweepResults(ctx, []*models.SweepResult{tt.input})
			require.NoError(t, err, "ProcessBatchSweepResults should not return error")

			t.Logf("✅ Test passed: %s", tt.description)
		})
	}
}

// Helper function
func stringPtr(s string) *string {
	return &s
}
