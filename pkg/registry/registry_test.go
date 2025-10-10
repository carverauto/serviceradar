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

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

func allowCanonicalizationQueries(mockDB *db.MockService) {
	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()
}

func TestDeviceRegistry_ProcessBatchDeviceUpdates(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)

	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger)

	tests := []struct {
		name        string
		updates     []*models.DeviceUpdate
		description string
		validate    func(t *testing.T, publishedUpdates []*models.DeviceUpdate)
	}{
		{
			name:        "Simple device with complete data",
			description: "Device with all required fields should be passed through without modification",
			updates: []*models.DeviceUpdate{
				{
					IP:          "216.17.46.98",
					DeviceID:    "default:216.17.46.98",
					Partition:   "default",
					Source:      models.DiscoverySourceSNMP, // mapper -> SNMP
					Hostname:    stringPtr("tonka01"),
					Timestamp:   time.Now(),
					IsAvailable: true,
					Confidence:  models.GetSourceConfidence(models.DiscoverySourceSNMP),
					Metadata: map[string]string{
						"alternate_ips":   `["192.168.10.1"]`,
						"controller_name": "Tonka",
						"source":          "unifi-api",
						"unifi_device_id": "39b54c6a-1598-3904-aa0c-96d9727f4d74",
					},
				},
			},
			validate: func(t *testing.T, publishedUpdates []*models.DeviceUpdate) {
				t.Helper()
				assert.Len(t, publishedUpdates, 1, "Should publish exactly one update")
				result := publishedUpdates[0]
				assert.Equal(t, "default:216.17.46.98", result.DeviceID)
				assert.Equal(t, "216.17.46.98", result.IP)
				assert.Equal(t, "default", result.Partition)
				assert.Equal(t, models.DiscoverySourceSNMP, result.Source)
				assert.Equal(t, "tonka01", *result.Hostname)
				assert.True(t, result.IsAvailable)
				assert.Equal(t, `["192.168.10.1"]`, result.Metadata["alternate_ips"])
			},
		},
		{
			name:        "Device with empty DeviceID gets normalized",
			description: "Device without DeviceID should get one generated from IP",
			updates: []*models.DeviceUpdate{
				{
					IP:          "192.168.1.100",
					DeviceID:    "", // Empty DeviceID
					Partition:   "default",
					Source:      models.DiscoverySourceMapper,
					Hostname:    stringPtr("test-device"),
					Timestamp:   time.Now(),
					IsAvailable: true,
					Confidence:  models.GetSourceConfidence(models.DiscoverySourceMapper),
					Metadata:    map[string]string{},
				},
			},
			validate: func(t *testing.T, publishedUpdates []*models.DeviceUpdate) {
				t.Helper()
				assert.Len(t, publishedUpdates, 1, "Should publish exactly one update")
				result := publishedUpdates[0]
				assert.Equal(t, "default:192.168.1.100", result.DeviceID, "Should generate DeviceID from IP")
				assert.Equal(t, "192.168.1.100", result.IP)
				assert.Equal(t, "default", result.Partition)
			},
		},
		{
			name:        "Device with empty Partition gets normalized",
			description: "Device without Partition should get default partition",
			updates: []*models.DeviceUpdate{
				{
					IP:          "192.168.10.5",
					DeviceID:    "default:192.168.10.5",
					Partition:   "", // Empty Partition
					Source:      models.DiscoverySourceSNMP,
					Hostname:    stringPtr("multi-ip-device"),
					Timestamp:   time.Now(),
					IsAvailable: true,
					Confidence:  models.GetSourceConfidence(models.DiscoverySourceSNMP),
					Metadata: map[string]string{
						"alternate_ips": `["192.168.10.1", "192.168.10.3", "192.168.10.8"]`,
					},
				},
			},
			validate: func(t *testing.T, publishedUpdates []*models.DeviceUpdate) {
				t.Helper()
				assert.Len(t, publishedUpdates, 1, "Should publish exactly one update")
				result := publishedUpdates[0]
				assert.Equal(t, "default", result.Partition, "Should extract partition from DeviceID")
				assert.Equal(t, "default:192.168.10.5", result.DeviceID)
			},
		},
		{
			name:        "Multiple devices in batch",
			description: "Multiple devices should all be processed and published",
			updates: []*models.DeviceUpdate{
				{
					IP:          "192.168.1.1",
					DeviceID:    "default:192.168.1.1",
					Partition:   "default",
					Source:      models.DiscoverySourceSNMP,
					Hostname:    stringPtr("device1"),
					Timestamp:   time.Now(),
					IsAvailable: true,
					Confidence:  models.GetSourceConfidence(models.DiscoverySourceSNMP),
					Metadata:    map[string]string{"type": "router"},
				},
				{
					IP:          "192.168.1.2",
					DeviceID:    "default:192.168.1.2",
					Partition:   "default",
					Source:      models.DiscoverySourceMapper,
					Hostname:    stringPtr("device2"),
					Timestamp:   time.Now(),
					IsAvailable: false,
					Confidence:  models.GetSourceConfidence(models.DiscoverySourceMapper),
					Metadata:    map[string]string{"type": "switch"},
				},
			},
			validate: func(t *testing.T, publishedUpdates []*models.DeviceUpdate) {
				t.Helper()

				assert.Len(t, publishedUpdates, 2, "Should publish both updates")

				// Check first device
				result1 := publishedUpdates[0]
				assert.Equal(t, "default:192.168.1.1", result1.DeviceID)
				assert.Equal(t, "192.168.1.1", result1.IP)
				assert.Equal(t, "device1", *result1.Hostname)
				assert.True(t, result1.IsAvailable)
				assert.Equal(t, "router", result1.Metadata["type"])

				// Check second device
				result2 := publishedUpdates[1]
				assert.Equal(t, "default:192.168.1.2", result2.DeviceID)
				assert.Equal(t, "192.168.1.2", result2.IP)
				assert.Equal(t, "device2", *result2.Hostname)
				assert.False(t, result2.IsAvailable)
				assert.Equal(t, "switch", result2.Metadata["type"])
			},
		},
		{
			name:        "Empty batch",
			description: "Empty batch should not cause any database calls",
			updates:     []*models.DeviceUpdate{},
			validate: func(t *testing.T, _ []*models.DeviceUpdate) {
				t.Helper()

				// This test should not reach the validation function
				// since no ProcessBatchDeviceUpdates call should be made
				t.Error("Empty batch should not trigger database call")
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if len(tt.updates) == 0 {
				// For empty batches, no database call should be made
				// Execute the test
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
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger)

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
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger)

	tests := []struct {
		name        string
		input       *models.DeviceUpdate
		description string
		validate    func(t *testing.T, normalized *models.DeviceUpdate)
	}{
		{
			name:        "DeviceID and Partition both empty",
			description: "Should generate both DeviceID and Partition from IP",
			input: &models.DeviceUpdate{
				IP:          "192.168.1.100",
				DeviceID:    "",
				Partition:   "",
				Source:      models.DiscoverySourceMapper,
				Timestamp:   time.Now(),
				IsAvailable: true,
				Confidence:  models.GetSourceConfidence(models.DiscoverySourceMapper),
			},
			validate: func(t *testing.T, normalized *models.DeviceUpdate) {
				t.Helper()

				assert.Equal(t, "default:192.168.1.100", normalized.DeviceID)
				assert.Equal(t, "default", normalized.Partition)
			},
		},
		{
			name:        "Partition empty but DeviceID has valid format",
			description: "Should extract partition from DeviceID",
			input: &models.DeviceUpdate{
				IP:          "192.168.1.101",
				DeviceID:    "custom:192.168.1.101",
				Partition:   "",
				Source:      models.DiscoverySourceMapper,
				Timestamp:   time.Now(),
				IsAvailable: true,
				Confidence:  models.GetSourceConfidence(models.DiscoverySourceMapper),
			},
			validate: func(t *testing.T, normalized *models.DeviceUpdate) {
				t.Helper()

				assert.Equal(t, "custom:192.168.1.101", normalized.DeviceID)
				assert.Equal(t, "custom", normalized.Partition)
			},
		},
		{
			name:        "DeviceID malformed without colon",
			description: "Should fix malformed DeviceID and set default partition",
			input: &models.DeviceUpdate{
				IP:          "192.168.1.102",
				DeviceID:    "malformed-device-id",
				Partition:   "",
				Source:      models.DiscoverySourceMapper,
				Timestamp:   time.Now(),
				IsAvailable: true,
				Confidence:  models.GetSourceConfidence(models.DiscoverySourceMapper),
			},
			validate: func(t *testing.T, normalized *models.DeviceUpdate) {
				t.Helper()

				assert.Equal(t, "default:192.168.1.102", normalized.DeviceID)
				assert.Equal(t, "default", normalized.Partition)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Mock: Expect PublishBatchDeviceUpdates to be called
			mockDB.EXPECT().PublishBatchDeviceUpdates(
				gomock.Any(),
				gomock.AssignableToTypeOf([]*models.DeviceUpdate{}),
			).DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
				assert.Len(t, updates, 1, "Should publish exactly one update")
				tt.validate(t, updates[0])

				return nil
			})

			// Execute the test
			err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{tt.input})
			require.NoError(t, err, "ProcessBatchDeviceUpdates should not return error")

			t.Logf("✅ Test passed: %s", tt.description)
		})
	}
}

// Helper function
func stringPtr(s string) *string {
	return &s
}

func TestDeviceRegistry_ProcessBatchDeviceUpdates_CanonicalizesDuplicatesWithinBatch(t *testing.T) {
	ctx := context.Background()

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger)

	primaryID := "default:10.0.0.1"
	updates := []*models.DeviceUpdate{
		{
			IP:          "10.0.0.1",
			DeviceID:    primaryID,
			Partition:   "default",
			Source:      models.DiscoverySourceArmis,
			Timestamp:   time.Now(),
			IsAvailable: true,
			Metadata: map[string]string{
				"armis_device_id": "armis-123",
			},
		},
		{
			IP:          "10.0.0.2",
			DeviceID:    "default:10.0.0.2",
			Partition:   "default",
			Source:      models.DiscoverySourceArmis,
			Timestamp:   time.Now(),
			IsAvailable: true,
			Metadata: map[string]string{
				"armis_device_id": "armis-123",
			},
		},
	}

	var published []*models.DeviceUpdate
	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, batch []*models.DeviceUpdate) error {
			published = append([]*models.DeviceUpdate(nil), batch...)
			return nil
		})

	err := registry.ProcessBatchDeviceUpdates(ctx, updates)
	require.NoError(t, err)
	require.Len(t, published, 3, "expected two canonical updates plus tombstone")

	first := published[0]
	second := published[1]
	tombstone := published[2]

	assert.Equal(t, primaryID, first.DeviceID)
	assert.Equal(t, "10.0.0.1", first.IP)

	assert.Equal(t, primaryID, second.DeviceID, "duplicate should re-use canonical id from batch")
	assert.Equal(t, "10.0.0.2", second.IP)
	assert.Contains(t, second.Metadata, "alt_ip:10.0.0.2")
	assert.Equal(t, "armis-123", second.Metadata["armis_device_id"])

	require.Contains(t, tombstone.Metadata, "_merged_into")
	assert.Equal(t, primaryID, tombstone.Metadata["_merged_into"])
	assert.Equal(t, "default:10.0.0.2", tombstone.DeviceID)
}

func TestLookupCanonicalPrefersMACOverIP(t *testing.T) {
	registry := &DeviceRegistry{logger: logger.NewTestLogger()}
	mac := "AA:BB:CC:DD:EE:FF"
	update := &models.DeviceUpdate{
		IP:  "10.0.0.10",
		MAC: &mac,
	}
	maps := &identityMaps{
		armis: map[string]string{},
		netbx: map[string]string{},
		mac:   map[string]string{mac: "default:canonical-mac"},
		ip:    map[string]string{"10.0.0.10": "default:canonical-ip"},
	}

	canonical, via := registry.lookupCanonicalFromMaps(update, maps)

	require.Equal(t, "default:canonical-mac", canonical)
	require.Equal(t, identitySourceMAC, via)
}

func TestLookupCanonicalFallsBackToIP(t *testing.T) {
	registry := &DeviceRegistry{logger: logger.NewTestLogger()}
	update := &models.DeviceUpdate{
		IP: "10.0.0.11",
	}
	maps := &identityMaps{
		armis: map[string]string{},
		netbx: map[string]string{},
		mac:   map[string]string{},
		ip:    map[string]string{"10.0.0.11": "default:canonical-ip"},
	}

	canonical, via := registry.lookupCanonicalFromMaps(update, maps)

	require.Equal(t, "default:canonical-ip", canonical)
	require.Equal(t, "ip", via)
}

func TestProcessBatchSkipsSweepWithoutIdentity(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	allowCanonicalizationQueries(mockDB)
	testLogger := logger.NewTestLogger()
	registry := NewDeviceRegistry(mockDB, testLogger)

	mockDB.EXPECT().
		PublishBatchDeviceUpdates(gomock.Any(), gomock.AssignableToTypeOf([]*models.DeviceUpdate{})).
		DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
			require.Empty(t, updates, "sweep without identity should be dropped")
			return nil
		})

	update := &models.DeviceUpdate{
		IP:          "10.1.1.1",
		DeviceID:    "default:10.1.1.1",
		Partition:   "default",
		Source:      models.DiscoverySourceSweep,
		Timestamp:   time.Now(),
		IsAvailable: false,
		Metadata: map[string]string{
			"icmp_available": "false",
		},
	}

	err := registry.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update})
	require.NoError(t, err)
}
