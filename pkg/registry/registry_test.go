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

func TestDeviceRegistry_Tonka01Scenario(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)

	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB)

	// Test the exact scenario from the logs
	tests := []struct {
		name          string
		sightings     []*models.SweepResult
		expectedCalls []expectedCall
		description   string
	}{
		{
			name:        "Tonka01 Private IP to Public IP Mapping",
			description: "Device with public IP should be mapped to existing private IP canonical device",
			sightings: []*models.SweepResult{
				{
					IP:              "216.17.46.98", // Public IP
					DeviceID:        "default:216.17.46.98",
					Partition:       "default",
					DiscoverySource: "mapper",
					Hostname:        stringPtr("tonka01"),
					Timestamp:       time.Now(),
					Available:       true,
					Metadata: map[string]string{
						"alternate_ips":   `["192.168.10.1"]`, // Has private IP as alternate
						"controller_name": "Tonka",
						"source":          "unifi-api",
						"unifi_device_id": "39b54c6a-1598-3904-aa0c-96d9727f4d74",
					},
				},
			},
			expectedCalls: []expectedCall{
				{
					method:  "GetUnifiedDevicesByIP",
					args:    []interface{}{gomock.Any(), "216.17.46.98"},
					returns: []interface{}{[]*models.UnifiedDevice{}, nil},
				},
				{
					method:  "GetUnifiedDevicesByIP",
					args:    []interface{}{gomock.Any(), "192.168.10.1"},
					returns: []interface{}{[]*models.UnifiedDevice{}, nil},
				},
				{
					method:  "PublishBatchSweepResults",
					args:    []interface{}{gomock.Any(), gomock.AssignableToTypeOf([]*models.SweepResult{})},
					returns: []interface{}{nil},
				},
			},
		},
		{
			name:        "No Mapping When No Alternate IPs",
			description: "Device without alternate IPs should use its own device ID",
			sightings: []*models.SweepResult{
				{
					IP:              "192.168.1.100",
					DeviceID:        "default:192.168.1.100",
					Partition:       "default",
					DiscoverySource: "sweep",
					Hostname:        stringPtr("test-device"),
					Timestamp:       time.Now(),
					Available:       true,
					Metadata:        map[string]string{},
				},
			},
			expectedCalls: []expectedCall{
				{
					method:  "GetUnifiedDevicesByIP",
					args:    []interface{}{gomock.Any(), "192.168.1.100"},
					returns: []interface{}{[]*models.UnifiedDevice{}, nil},
				},
				{
					method:  "PublishBatchSweepResults",
					args:    []interface{}{gomock.Any(), gomock.AssignableToTypeOf([]*models.SweepResult{})},
					returns: []interface{}{nil},
				},
			},
		},
		{
			name:        "Multiple Alternate IPs - Prefer Lowest",
			description: "When multiple private alternate IPs exist, prefer the lowest",
			sightings: []*models.SweepResult{
				{
					IP:              "192.168.10.5",
					DeviceID:        "default:192.168.10.5",
					Partition:       "default",
					DiscoverySource: "mapper",
					Hostname:        stringPtr("multi-ip-device"),
					Timestamp:       time.Now(),
					Available:       true,
					Metadata: map[string]string{
						"alternate_ips": `["192.168.10.1", "192.168.10.3", "192.168.10.8"]`,
					},
				},
			},
			expectedCalls: []expectedCall{
				{
					method:  "GetUnifiedDevicesByIP",
					args:    []interface{}{gomock.Any(), "192.168.10.5"},
					returns: []interface{}{[]*models.UnifiedDevice{}, nil},
				},
				{
					method:  "GetUnifiedDevicesByIP",
					args:    []interface{}{gomock.Any(), "192.168.10.1"},
					returns: []interface{}{[]*models.UnifiedDevice{}, nil},
				},
				{
					method:  "GetUnifiedDevicesByIP",
					args:    []interface{}{gomock.Any(), "192.168.10.3"},
					returns: []interface{}{[]*models.UnifiedDevice{}, nil},
				},
				{
					method:  "GetUnifiedDevicesByIP",
					args:    []interface{}{gomock.Any(), "192.168.10.8"},
					returns: []interface{}{[]*models.UnifiedDevice{}, nil},
				},
				{
					method:  "PublishBatchSweepResults",
					args:    []interface{}{gomock.Any(), gomock.AssignableToTypeOf([]*models.SweepResult{})},
					returns: []interface{}{nil},
				},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Set up expectations
			for _, expectedCall := range tt.expectedCalls {
				switch expectedCall.method {
				case "GetUnifiedDevicesByIP":
					mockDB.EXPECT().GetUnifiedDevicesByIP(
						expectedCall.args[0],
						expectedCall.args[1],
					).Return(expectedCall.returns[0], expectedCall.returns[1])
				case "PublishBatchSweepResults":
					mockDB.EXPECT().PublishBatchSweepResults(
						expectedCall.args[0],
						expectedCall.args[1],
					).Return(expectedCall.returns[0])
				}
			}

			// Execute the test
			err := registry.ProcessBatchSightings(ctx, tt.sightings)

			// Verify results
			require.NoError(t, err, "ProcessBatchSightings should not return error")

			t.Logf("✅ Test passed: %s", tt.description)
		})
	}
}

func TestExtractAlternateIPs(t *testing.T) {
	tests := []struct {
		name     string
		metadata map[string]string
		expected []string
	}{
		{
			name: "Valid JSON Array",
			metadata: map[string]string{
				"alternate_ips": `["192.168.1.1", "10.0.0.1"]`,
			},
			expected: []string{"192.168.1.1", "10.0.0.1"},
		},
		{
			name: "Empty JSON Array",
			metadata: map[string]string{
				"alternate_ips": `[]`,
			},
			expected: []string{},
		},
		{
			name: "Comma Separated Fallback",
			metadata: map[string]string{
				"alternate_ips": "192.168.1.1,10.0.0.1",
			},
			expected: []string{"192.168.1.1", "10.0.0.1"},
		},
		{
			name:     "No Metadata",
			metadata: nil,
			expected: nil,
		},
		{
			name:     "No Alternate IPs Key",
			metadata: map[string]string{},
			expected: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := extractAlternateIPs(tt.metadata)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestIsPrivateIP(t *testing.T) {
	tests := []struct {
		ip       string
		expected bool
	}{
		{"192.168.1.1", true},
		{"10.0.0.1", true},
		{"172.16.0.1", true},
		{"172.31.255.255", true},
		{"216.17.46.98", false},
		{"8.8.8.8", false},
		{"203.0.113.1", false},
		{"127.0.0.1", false}, // localhost is not considered "private" in our business logic
	}

	for _, tt := range tests {
		t.Run(tt.ip, func(t *testing.T) {
			result := isPrivateIP(tt.ip)
			assert.Equal(t, tt.expected, result, "isPrivateIP(%s) should return %v", tt.ip, tt.expected)
		})
	}
}

func TestFarm01MultipleDiscoveryScenario(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)

	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB)

	// Test the farm01 scenario where device has multiple IPs from different discovery sources
	// 1. First sighting: SNMP discovers farm01 at 192.168.2.1
	// 2. Second sighting: Mapper discovers farm01 at 152.117.116.178 with alternate IPs including 192.168.2.1

	// First sighting from SNMP
	snmpSighting := &models.SweepResult{
		IP:              "192.168.2.1",
		DeviceID:        "default:192.168.2.1",
		Partition:       "default",
		DiscoverySource: "snmp",
		Hostname:        stringPtr("farm01"),
		Timestamp:       time.Now(),
		Available:       true,
		Metadata: map[string]string{
			"source": "snmp-target",
		},
	}

	// Mock: No existing devices yet
	mockDB.EXPECT().GetUnifiedDevicesByIP(
		gomock.Any(),
		"192.168.2.1",
	).Return([]*models.UnifiedDevice{}, nil)

	// Mock: Publish first sighting
	mockDB.EXPECT().PublishBatchSweepResults(
		gomock.Any(),
		gomock.Any(),
	).Return(nil)

	// Process first sighting
	err := registry.ProcessSighting(ctx, snmpSighting)
	require.NoError(t, err)

	// Now simulate the device exists in DB after first sighting
	existingFarm01 := &models.UnifiedDevice{
		DeviceID: "default:192.168.2.1",
		IP:       "192.168.2.1",
		Hostname: &models.DiscoveredField[string]{
			Value:  "farm01",
			Source: models.DiscoverySourceSNMP,
		},
		FirstSeen: time.Now().Add(-5 * time.Minute),
		LastSeen:  time.Now(),
	}

	// Second sighting from mapper with public IP
	mapperSighting := &models.SweepResult{
		IP:              "152.117.116.178",
		DeviceID:        "default:152.117.116.178",
		Partition:       "default",
		DiscoverySource: "mapper",
		Hostname:        stringPtr("farm01"),
		Timestamp:       time.Now(),
		Available:       true,
		Metadata: map[string]string{
			"alternate_ips": `["192.168.2.1", "192.168.1.1"]`,
			"device_type":   "network_device",
			"source":        "unifi-api",
		},
	}

	// Mock: When mapper sighting comes in, first check for devices with 152.117.116.178
	mockDB.EXPECT().GetUnifiedDevicesByIP(
		gomock.Any(),
		"152.117.116.178",
	).Return([]*models.UnifiedDevice{}, nil)

	// Mock: Then check for devices with the alternate IPs (192.168.2.1)
	mockDB.EXPECT().GetUnifiedDevicesByIP(
		gomock.Any(),
		"192.168.2.1",
	).Return([]*models.UnifiedDevice{existingFarm01}, nil)

	// Mock: Publish the correlated sighting
	mockDB.EXPECT().PublishBatchSweepResults(
		gomock.Any(),
		gomock.AssignableToTypeOf([]*models.SweepResult{}),
	).DoAndReturn(func(_ context.Context, sightings []*models.SweepResult) error {
		// Verify that the sighting was correlated to the existing device
		assert.Len(t, sightings, 1, "Should publish exactly one sighting")
		correctedSighting := sightings[0]

		assert.Equal(t, "default:192.168.2.1", correctedSighting.DeviceID, "Should use existing farm01 device ID")
		assert.Equal(t, "152.117.116.178", correctedSighting.IP, "Should keep mapper sighting IP")
		t.Logf("✅ Mapper sighting correctly correlated: IP %s mapped to existing device %s", correctedSighting.IP, correctedSighting.DeviceID)

		return nil
	})

	// Process second sighting
	err = registry.ProcessSighting(ctx, mapperSighting)
	require.NoError(t, err)

	// Test 3: Ensure untrusted sources don't correlate
	untrustedSighting := &models.SweepResult{
		IP:              "203.0.113.1", // Public IP
		DeviceID:        "default:203.0.113.1",
		Partition:       "default",
		DiscoverySource: "sweep",             // Untrusted source
		Hostname:        stringPtr("farm01"), // Same hostname
		Timestamp:       time.Now(),
		Available:       true,
		Metadata: map[string]string{
			"alternate_ips": `["192.168.2.1"]`, // Has farm01's IP as alternate
		},
	}

	// Mock: Check for devices with 203.0.113.1 (should return empty)
	mockDB.EXPECT().GetUnifiedDevicesByIP(
		gomock.Any(),
		"203.0.113.1",
	).Return([]*models.UnifiedDevice{}, nil)

	// Mock: Should NOT query alternate IPs because it's untrusted source

	// Mock: Publish as separate device
	mockDB.EXPECT().PublishBatchSweepResults(
		gomock.Any(),
		gomock.AssignableToTypeOf([]*models.SweepResult{}),
	).DoAndReturn(func(_ context.Context, sightings []*models.SweepResult) error {
		// Verify that untrusted sighting was NOT correlated
		assert.Len(t, sightings, 1, "Should publish exactly one sighting")
		sighting := sightings[0]

		assert.Equal(t, "default:203.0.113.1", sighting.DeviceID, "Untrusted source should not correlate")
		t.Logf("✅ Untrusted source correctly NOT correlated: kept device ID %s", sighting.DeviceID)

		return nil
	})

	// Process untrusted sighting
	err = registry.ProcessSighting(ctx, untrustedSighting)
	assert.NoError(t, err)
}

func TestU6MeshScenario(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)

	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB)

	// Test the actual U6 Mesh scenario from production logs
	// Device 192.168.1.80 should be correlated with existing U6 Mesh device at 192.168.1.204

	// Existing U6 Mesh device with alternate IPs
	existingU6Device := &models.UnifiedDevice{
		DeviceID: "default:192.168.1.204",
		IP:       "192.168.1.204",
		Metadata: &models.DiscoveredField[map[string]string]{
			Value: map[string]string{
				"alternate_ips": `["192.168.1.80", "192.168.1.1"]`,
				"hostname":      "U6 Mesh",
			},
			Source:      models.DiscoverySourceMapper,
			LastUpdated: time.Now(),
		},
		FirstSeen: time.Now().Add(-24 * time.Hour),
		LastSeen:  time.Now(),
	}

	// New sighting for 192.168.1.80 (should be correlated with U6 Mesh)
	sighting := &models.SweepResult{
		IP:              "192.168.1.80",
		DeviceID:        "default:192.168.1.80",
		Partition:       "default",
		DiscoverySource: "snmp",
		Hostname:        stringPtr("farm01"), // Wrong hostname from config
		Timestamp:       time.Now(),
		Available:       true,
		Metadata:        map[string]string{},
	}

	// Mock database calls
	// First call: Look for devices with IP 192.168.1.80 (should find U6 Mesh device)
	mockDB.EXPECT().GetUnifiedDevicesByIP(
		gomock.Any(),
		"192.168.1.80",
	).Return([]*models.UnifiedDevice{existingU6Device}, nil)

	// Third call: Publish the corrected sighting (should have device ID changed to U6 Mesh)
	mockDB.EXPECT().PublishBatchSweepResults(
		gomock.Any(),
		gomock.AssignableToTypeOf([]*models.SweepResult{}),
	).DoAndReturn(func(_ context.Context, sightings []*models.SweepResult) error {
		// Verify that the sighting was corrected to use the canonical device ID
		assert.Len(t, sightings, 1, "Should publish exactly one sighting")
		correctedSighting := sightings[0]

		assert.Equal(t, "default:192.168.1.204", correctedSighting.DeviceID, "Should use U6 Mesh device ID as canonical")
		assert.Equal(t, "192.168.1.80", correctedSighting.IP, "Should keep original sighting IP")
		t.Logf("✅ Sighting correctly correlated: IP %s mapped to canonical device %s", correctedSighting.IP, correctedSighting.DeviceID)

		return nil
	})

	// Execute the test
	err := registry.ProcessSighting(ctx, sighting)
	assert.NoError(t, err)
}

func TestFindCanonicalDeviceIDSimple(t *testing.T) {
	ctx := context.Background()
	ctrl := gomock.NewController(t)

	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	registry := NewDeviceRegistry(mockDB)

	tests := []struct {
		name        string
		sighting    *models.SweepResult
		expected    string
		description string
	}{
		{
			name: "Higher IP with Lower Alternate",
			sighting: &models.SweepResult{
				IP:              "216.17.46.98",
				DeviceID:        "default:216.17.46.98",
				Partition:       "default",
				DiscoverySource: "mapper", // Trusted source
				Hostname:        stringPtr("tonka01"),
				Metadata: map[string]string{
					"alternate_ips": `["192.168.10.1"]`,
				},
			},
			expected:    "default:192.168.10.1",
			description: "Should prefer lowest IP address",
		},
		{
			name: "Private IP with Lower Private Alternate",
			sighting: &models.SweepResult{
				IP:              "192.168.10.5",
				DeviceID:        "default:192.168.10.5",
				Partition:       "default",
				DiscoverySource: "mapper", // Trusted source
				Hostname:        stringPtr("device"),
				Metadata: map[string]string{
					"alternate_ips": `["192.168.10.1", "192.168.10.8"]`,
				},
			},
			expected:    "default:192.168.10.1",
			description: "Should prefer lower IP address",
		},
		{
			name: "No Lower Alternate IPs",
			sighting: &models.SweepResult{
				IP:              "192.168.1.1",
				DeviceID:        "default:192.168.1.1",
				Partition:       "default",
				DiscoverySource: "mapper", // Trusted source
				Hostname:        nil,
				Metadata: map[string]string{
					"alternate_ips": `["192.168.1.2"]`,
				},
			},
			expected:    "",
			description: "Should return empty when current IP is already the lowest",
		},
		{
			name: "Untrusted Source",
			sighting: &models.SweepResult{
				IP:              "216.17.46.98",
				DeviceID:        "default:216.17.46.98",
				Partition:       "default",
				DiscoverySource: "sweep", // Untrusted source
				Hostname:        stringPtr("tonka01"),
				Metadata: map[string]string{
					"alternate_ips": `["192.168.10.1"]`,
				},
			},
			expected:    "",
			description: "Should not correlate for untrusted sources",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := registry.findCanonicalDeviceIDSimple(ctx, tt.sighting)
			require.NoError(t, err)
			assert.Equal(t, tt.expected, result, tt.description)
		})
	}
}

// Helper types and functions

type expectedCall struct {
	method  string
	args    []interface{}
	returns []interface{}
}

func stringPtr(s string) *string {
	return &s
}
