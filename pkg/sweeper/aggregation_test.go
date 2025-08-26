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
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// Test helper function to create a test sweeper with mocks
func createTestSweeper(t *testing.T) (*NetworkSweeper, *MockStore, *MockResultProcessor, *MockDeviceRegistryService, *gomock.Controller) {
	t.Helper()
	ctrl := gomock.NewController(t)

	// Create test sweeper with mocks
	mockStore := NewMockStore(ctrl)
	mockProcessor := NewMockResultProcessor(ctrl)
	mockDeviceRegistry := NewMockDeviceRegistryService(ctrl)

	config := &models.Config{
		Networks:    []string{"192.168.1.0/24"},
		Ports:       []int{80, 443},
		SweepModes:  []models.SweepMode{models.ModeICMP, models.ModeTCP},
		Interval:    time.Minute,
		Concurrency: 10,
		Timeout:     time.Second * 30,
		AgentID:     "test-agent",
		PollerID:    "test-poller",
		Partition:   "test-partition",
	}

	sweeper := &NetworkSweeper{
		config:         config,
		store:          mockStore,
		processor:      mockProcessor,
		deviceRegistry: mockDeviceRegistry,
		logger:         logger.NewTestLogger(),
		deviceResults:  make(map[string]*DeviceResultAggregator),
	}

	return sweeper, mockStore, mockProcessor, mockDeviceRegistry, ctrl
}

func TestExtractDeviceID(t *testing.T) {
	sweeper, _, _, _, ctrl := createTestSweeper(t) //nolint:dogsled // test helper returns many values
	defer ctrl.Finish()

	tests := []struct {
		name     string
		target   models.Target
		expected string
	}{
		{
			name: "armis device ID",
			target: models.Target{
				Host: "192.168.1.1",
				Metadata: map[string]interface{}{
					"armis_device_id": "12345",
					"integration_id":  "67890",
				},
			},
			expected: "armis:12345",
		},
		{
			name: "integration ID fallback",
			target: models.Target{
				Host: "192.168.1.2",
				Metadata: map[string]interface{}{
					"integration_id": "67890",
				},
			},
			expected: "integration:67890",
		},
		{
			name: "no device ID",
			target: models.Target{
				Host:     "192.168.1.3",
				Metadata: map[string]interface{}{},
			},
			expected: "",
		},
		{
			name: "nil metadata",
			target: models.Target{
				Host:     "192.168.1.4",
				Metadata: nil,
			},
			expected: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := sweeper.extractDeviceID(tt.target)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestPrepareDeviceAggregators(t *testing.T) {
	sweeper, _, _, _, ctrl := createTestSweeper(t) //nolint:dogsled // test helper returns many values
	defer ctrl.Finish()

	targets := []models.Target{
		// Device with multiple IPs (should create aggregator)
		{
			Host: "192.168.1.1",
			Mode: models.ModeICMP,
			Metadata: map[string]interface{}{
				"armis_device_id": "123",
				"all_ips":         "192.168.1.1,192.168.1.2,192.168.1.3",
				"agent_id":        "test-agent",
				"poller_id":       "test-poller",
				"partition":       "test-partition",
			},
		},
		{
			Host: "192.168.1.2",
			Mode: models.ModeICMP,
			Metadata: map[string]interface{}{
				"armis_device_id": "123",
				"all_ips":         "192.168.1.1,192.168.1.2,192.168.1.3",
				"agent_id":        "test-agent",
				"poller_id":       "test-poller",
				"partition":       "test-partition",
			},
		},
		{
			Host: "192.168.1.3",
			Mode: models.ModeTCP,
			Port: 80,
			Metadata: map[string]interface{}{
				"armis_device_id": "123",
				"all_ips":         "192.168.1.1,192.168.1.2,192.168.1.3",
				"agent_id":        "test-agent",
				"poller_id":       "test-poller",
				"partition":       "test-partition",
			},
		},
		// Single IP device (should not create aggregator)
		{
			Host: "192.168.1.10",
			Mode: models.ModeICMP,
			Metadata: map[string]interface{}{
				"armis_device_id": "456",
				"all_ips":         "192.168.1.10",
				"agent_id":        "test-agent",
				"poller_id":       "test-poller",
				"partition":       "test-partition",
			},
		},
	}

	sweeper.prepareDeviceAggregators(targets)

	// Should have created aggregator for device 123 (3 targets)
	assert.Contains(t, sweeper.deviceResults, "armis:123")
	aggregator := sweeper.deviceResults["armis:123"]
	assert.Equal(t, "armis:123", aggregator.DeviceID)
	assert.Equal(t, []string{"192.168.1.1", "192.168.1.2", "192.168.1.3"}, aggregator.ExpectedIPs)
	assert.Equal(t, "test-agent", aggregator.AgentID)
	assert.Equal(t, "test-poller", aggregator.PollerID)
	assert.Equal(t, "test-partition", aggregator.Partition)

	// Should not have created aggregator for device 456 (1 target)
	assert.NotContains(t, sweeper.deviceResults, "armis:456")
}

func TestShouldAggregateResult(t *testing.T) {
	sweeper, _, _, _, ctrl := createTestSweeper(t) //nolint:dogsled // test helper returns many values
	defer ctrl.Finish()

	// Set up aggregator for device 123
	sweeper.deviceResults["armis:123"] = &DeviceResultAggregator{
		DeviceID: "armis:123",
	}

	tests := []struct {
		name     string
		result   *models.Result
		expected bool
	}{
		{
			name: "should aggregate - device has aggregator",
			result: &models.Result{
				Target: models.Target{
					Host: "192.168.1.1",
					Metadata: map[string]interface{}{
						"armis_device_id": "123",
					},
				},
			},
			expected: true,
		},
		{
			name: "should not aggregate - no aggregator",
			result: &models.Result{
				Target: models.Target{
					Host: "192.168.1.10",
					Metadata: map[string]interface{}{
						"armis_device_id": "456",
					},
				},
			},
			expected: false,
		},
		{
			name: "should not aggregate - no device ID",
			result: &models.Result{
				Target: models.Target{
					Host:     "192.168.1.20",
					Metadata: map[string]interface{}{},
				},
			},
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := sweeper.shouldAggregateResult(tt.result)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestAddResultToAggregator(t *testing.T) {
	sweeper, _, _, _, ctrl := createTestSweeper(t) //nolint:dogsled // test helper returns many values
	defer ctrl.Finish()

	// Set up aggregator
	aggregator := &DeviceResultAggregator{
		DeviceID: "armis:123",
		Results:  []*models.Result{},
	}
	sweeper.deviceResults["armis:123"] = aggregator

	result := &models.Result{
		Target: models.Target{
			Host: "192.168.1.1",
			Mode: models.ModeICMP,
			Metadata: map[string]interface{}{
				"armis_device_id": "123",
			},
		},
		Available:  true,
		LastSeen:   time.Now(),
		RespTime:   time.Millisecond * 50,
		PacketLoss: 0.0,
	}

	sweeper.addResultToAggregator(result)

	assert.Len(t, aggregator.Results, 1)
	assert.Equal(t, result, aggregator.Results[0])
}

func TestAddAggregatedScanResults(t *testing.T) {
	sweeper, _, _, _, ctrl := createTestSweeper(t) //nolint:dogsled // test helper returns many values
	defer ctrl.Finish()

	results := []*models.Result{
		{
			Target: models.Target{
				Host: "192.168.1.1",
				Mode: models.ModeICMP,
			},
			Available:  true,
			RespTime:   time.Millisecond * 50,
			PacketLoss: 0.0,
		},
		{
			Target: models.Target{
				Host: "192.168.1.2",
				Mode: models.ModeICMP,
			},
			Available:  false,
			RespTime:   0,
			PacketLoss: 100.0,
		},
		{
			Target: models.Target{
				Host: "192.168.1.3",
				Mode: models.ModeTCP,
				Port: 80,
			},
			Available:  true,
			RespTime:   time.Millisecond * 25,
			PacketLoss: 0.0,
		},
	}

	deviceUpdate := &models.DeviceUpdate{
		Metadata: make(map[string]string),
	}

	sweeper.addAggregatedScanResults(deviceUpdate, results)

	// Check aggregated metadata
	assert.Equal(t, "192.168.1.1,192.168.1.2,192.168.1.3", deviceUpdate.Metadata["scan_all_ips"])
	assert.Equal(t, "192.168.1.1,192.168.1.3", deviceUpdate.Metadata["scan_available_ips"])
	assert.Equal(t, "192.168.1.2", deviceUpdate.Metadata["scan_unavailable_ips"])
	assert.Equal(t, "3", deviceUpdate.Metadata["scan_result_count"])
	assert.Equal(t, "2", deviceUpdate.Metadata["scan_available_count"])
	assert.Equal(t, "1", deviceUpdate.Metadata["scan_unavailable_count"])
	assert.Equal(t, "66.7", deviceUpdate.Metadata["scan_availability_percent"])

	// Check detailed results
	assert.Contains(t, deviceUpdate.Metadata["scan_icmp_results"], "192.168.1.1:icmp:available=true")
	assert.Contains(t, deviceUpdate.Metadata["scan_icmp_results"], "192.168.1.2:icmp:available=false")
	assert.Contains(t, deviceUpdate.Metadata["scan_tcp_results"], "192.168.1.3:tcp:available=true")

	// Device should be available if any IP is available
	assert.True(t, deviceUpdate.IsAvailable)
}

func TestProcessAggregatedResults(t *testing.T) {
	sweeper, _, _, mockDeviceRegistry, ctrl := createTestSweeper(t)
	defer ctrl.Finish()

	aggregator := &DeviceResultAggregator{
		DeviceID:  "armis:123",
		AgentID:   "test-agent",
		PollerID:  "test-poller",
		Partition: "test-partition",
		Metadata: map[string]interface{}{
			"armis_device_id": "123",
			"device_name":     "Test Device",
		},
		Results: []*models.Result{
			{
				Target: models.Target{
					Host: "192.168.1.1",
					Mode: models.ModeICMP,
				},
				Available:  true,
				LastSeen:   time.Now(),
				RespTime:   time.Millisecond * 50,
				PacketLoss: 0.0,
			},
			{
				Target: models.Target{
					Host: "192.168.1.2",
					Mode: models.ModeICMP,
				},
				Available:  false,
				LastSeen:   time.Now(),
				RespTime:   0,
				PacketLoss: 100.0,
			},
		},
	}

	mockDeviceRegistry.EXPECT().
		UpdateDevice(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, update *models.DeviceUpdate) error {
			// Verify the device update contains aggregated scan results
			assert.Equal(t, "test-partition:192.168.1.1", update.DeviceID)
			assert.Equal(t, "192.168.1.1", update.IP)
			assert.True(t, update.IsAvailable) // Device available because first IP is available
			assert.Equal(t, models.DiscoverySourceSweep, update.Source)

			// Check aggregated metadata
			assert.Equal(t, "192.168.1.1,192.168.1.2", update.Metadata["scan_all_ips"])
			assert.Equal(t, "192.168.1.1", update.Metadata["scan_available_ips"])
			assert.Equal(t, "192.168.1.2", update.Metadata["scan_unavailable_ips"])
			assert.Equal(t, "50.0", update.Metadata["scan_availability_percent"])

			return nil
		})

	sweeper.processAggregatedResults(context.Background(), aggregator)
}

func TestMultiIPScanFlow(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create test sweeper with mocks
	mockStore := NewMockStore(ctrl)
	mockProcessor := NewMockResultProcessor(ctrl)
	mockDeviceRegistry := NewMockDeviceRegistryService(ctrl)

	config := &models.Config{
		Networks: []string{},
		DeviceTargets: []models.DeviceTarget{
			{
				Network:    "192.168.1.1/32",
				SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
				QueryLabel: "test_devices",
				Source:     "armis",
				Metadata: map[string]string{
					"armis_device_id": "123",
					"all_ips":         "192.168.1.1,192.168.1.2,10.0.0.1",
					"primary_ip":      "192.168.1.1",
					"agent_id":        "test-agent",
					"poller_id":       "test-poller",
					"partition":       "default",
				},
			},
		},
		Ports:       []int{80, 443},
		SweepModes:  []models.SweepMode{models.ModeICMP, models.ModeTCP},
		Interval:    time.Minute,
		Concurrency: 10,
		Timeout:     time.Second * 30,
		AgentID:     "test-agent",
		PollerID:    "test-poller",
		Partition:   "default",
	}

	sweeper := &NetworkSweeper{
		config:         config,
		store:          mockStore,
		processor:      mockProcessor,
		deviceRegistry: mockDeviceRegistry,
		logger:         logger.NewTestLogger(),
		deviceResults:  make(map[string]*DeviceResultAggregator),
	}

	t.Run("generateTargetsForDeviceTarget with multiple IPs", func(t *testing.T) {
		deviceTarget := &models.DeviceTarget{
			Network:    "192.168.1.1/32",
			SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
			QueryLabel: "test_devices",
			Source:     "armis",
			Metadata: map[string]string{
				"armis_device_id": "123",
				"all_ips":         "192.168.1.1,192.168.1.2,10.0.0.1",
				"primary_ip":      "192.168.1.1",
			},
		}

		targets, hostCount := sweeper.generateTargetsForDeviceTarget(deviceTarget)

		// Should generate targets for all 3 IPs with both ICMP and TCP modes
		// 3 ICMP targets (1 per IP) + 6 TCP targets (3 IPs × 2 ports)
		expectedTargetCount := 3 + (3 * len(config.Ports))
		assert.Len(t, targets, expectedTargetCount)
		assert.Equal(t, 3, hostCount)

		// Verify target generation
		ipsFound := make(map[string]bool)
		modesFound := make(map[models.SweepMode]int)

		for _, target := range targets {
			ipsFound[target.Host] = true
			modesFound[target.Mode]++

			// All targets should have the device metadata
			assert.Equal(t, "123", target.Metadata["armis_device_id"])
			assert.Equal(t, "192.168.1.1,192.168.1.2,10.0.0.1", target.Metadata["all_ips"])
		}

		// Verify all IPs are covered
		assert.True(t, ipsFound["192.168.1.1"])
		assert.True(t, ipsFound["192.168.1.2"])
		assert.True(t, ipsFound["10.0.0.1"])

		// Verify mode distribution (3 ICMP + 6 TCP targets for 2 ports)
		assert.Equal(t, 3, modesFound[models.ModeICMP])
		assert.Equal(t, 6, modesFound[models.ModeTCP])
	})

	t.Run("full aggregation flow", func(t *testing.T) {
		// Generate targets for our device with multiple IPs
		targets, err := sweeper.generateTargets()
		require.NoError(t, err)
		require.NotEmpty(t, targets)

		// Prepare aggregators
		sweeper.prepareDeviceAggregators(targets)

		// Verify aggregator was created
		assert.Contains(t, sweeper.deviceResults, "armis:123")
		aggregator := sweeper.deviceResults["armis:123"]
		assert.Len(t, aggregator.ExpectedIPs, 9) // 3 IPs × 3 targets each (1 ICMP + 2 TCP ports)

		// Simulate scan results - need to match what the actual system generates
		// For 3 IPs with ICMP and TCP modes, we get multiple results per IP
		mockResults := []*models.Result{
			// IP 1 - ICMP and TCP results
			{
				Target: models.Target{
					Host: "192.168.1.1",
					Mode: models.ModeICMP,
					Metadata: map[string]interface{}{
						"armis_device_id": "123",
					},
				},
				Available:  true,
				LastSeen:   time.Now(),
				RespTime:   time.Millisecond * 25,
				PacketLoss: 0.0,
			},
			{
				Target: models.Target{
					Host: "192.168.1.1",
					Mode: models.ModeTCP,
					Port: 80,
					Metadata: map[string]interface{}{
						"armis_device_id": "123",
					},
				},
				Available:  true,
				LastSeen:   time.Now(),
				RespTime:   time.Millisecond * 15,
				PacketLoss: 0.0,
			},
			// IP 2 - ICMP and TCP results
			{
				Target: models.Target{
					Host: "192.168.1.2",
					Mode: models.ModeICMP,
					Metadata: map[string]interface{}{
						"armis_device_id": "123",
					},
				},
				Available:  false,
				LastSeen:   time.Now(),
				RespTime:   0,
				PacketLoss: 100.0,
			},
			{
				Target: models.Target{
					Host: "192.168.1.2",
					Mode: models.ModeTCP,
					Port: 80,
					Metadata: map[string]interface{}{
						"armis_device_id": "123",
					},
				},
				Available:  false,
				LastSeen:   time.Now(),
				RespTime:   0,
				PacketLoss: 100.0,
			},
			// IP 3 - ICMP and TCP results
			{
				Target: models.Target{
					Host: "10.0.0.1",
					Mode: models.ModeICMP,
					Metadata: map[string]interface{}{
						"armis_device_id": "123",
					},
				},
				Available:  true,
				LastSeen:   time.Now(),
				RespTime:   time.Millisecond * 30,
				PacketLoss: 0.0,
			},
			{
				Target: models.Target{
					Host: "10.0.0.1",
					Mode: models.ModeTCP,
					Port: 80,
					Metadata: map[string]interface{}{
						"armis_device_id": "123",
					},
				},
				Available:  true,
				LastSeen:   time.Now(),
				RespTime:   time.Millisecond * 10,
				PacketLoss: 0.0,
			},
		}

		// Set up processor expectations for basic result processing
		for _, result := range mockResults {
			mockProcessor.EXPECT().Process(result).Return(nil)
			mockStore.EXPECT().SaveResult(gomock.Any(), result).Return(nil)
		}

		// Verify the shouldAggregateResult logic works
		for _, result := range mockResults {
			assert.True(t, sweeper.shouldAggregateResult(result))
		}

		// Set up device registry expectation for aggregated result
		mockDeviceRegistry.EXPECT().
			UpdateDevice(gomock.Any(), gomock.Any()).
			DoAndReturn(func(_ context.Context, update *models.DeviceUpdate) error {
				// Verify aggregated metadata - the implementation lists each result's IP
				// So with 6 results, we get each IP listed twice (once for ICMP, once for TCP)
				assert.Equal(t, "192.168.1.1,192.168.1.1,192.168.1.2,192.168.1.2,10.0.0.1,10.0.0.1", update.Metadata["scan_all_ips"])
				assert.Equal(t, "192.168.1.1,192.168.1.1,10.0.0.1,10.0.0.1", update.Metadata["scan_available_ips"])
				assert.Equal(t, "192.168.1.2,192.168.1.2", update.Metadata["scan_unavailable_ips"])
				assert.Equal(t, "66.7", update.Metadata["scan_availability_percent"]) // 4 available out of 6 = 66.7%
				assert.Equal(t, "6", update.Metadata["scan_result_count"])
				assert.Equal(t, "4", update.Metadata["scan_available_count"])
				assert.Equal(t, "2", update.Metadata["scan_unavailable_count"])

				// Device should be available since some IPs are available
				assert.True(t, update.IsAvailable)
				assert.Equal(t, "192.168.1.1", update.IP) // Primary IP should be first available

				return nil
			})

		// Process results through the normal flow
		for _, result := range mockResults {
			err := sweeper.processResult(context.Background(), result)
			require.NoError(t, err)
		}

		// Finalize aggregators
		sweeper.finalizeDeviceAggregators(context.Background())
	})
}

func TestEdgeCases(t *testing.T) {
	config := &models.Config{
		AgentID:   "test-agent",
		PollerID:  "test-poller",
		Partition: "test-partition",
	}

	sweeper := &NetworkSweeper{
		config:        config,
		logger:        logger.NewTestLogger(),
		deviceResults: make(map[string]*DeviceResultAggregator),
	}

	t.Run("aggregator with no results", func(_ *testing.T) {
		aggregator := &DeviceResultAggregator{
			DeviceID: "armis:empty",
			Results:  []*models.Result{},
		}

		// Should handle empty results gracefully
		sweeper.processAggregatedResults(context.Background(), aggregator)
	})

	t.Run("all IPs unavailable", func(t *testing.T) {
		results := []*models.Result{
			{
				Target: models.Target{
					Host: "192.168.1.1",
					Mode: models.ModeICMP,
				},
				Available:  false,
				PacketLoss: 100.0,
			},
			{
				Target: models.Target{
					Host: "192.168.1.2",
					Mode: models.ModeICMP,
				},
				Available:  false,
				PacketLoss: 100.0,
			},
		}

		deviceUpdate := &models.DeviceUpdate{
			Metadata: make(map[string]string),
		}

		sweeper.addAggregatedScanResults(deviceUpdate, results)

		assert.Empty(t, deviceUpdate.Metadata["scan_available_ips"])
		assert.Equal(t, "192.168.1.1,192.168.1.2", deviceUpdate.Metadata["scan_unavailable_ips"])
		assert.Equal(t, "0.0", deviceUpdate.Metadata["scan_availability_percent"])
		assert.False(t, deviceUpdate.IsAvailable)
	})

	t.Run("mixed protocol results", func(t *testing.T) {
		results := []*models.Result{
			{
				Target: models.Target{
					Host: "192.168.1.1",
					Mode: models.ModeICMP,
				},
				Available:  true,
				RespTime:   time.Millisecond * 10,
				PacketLoss: 0.0,
			},
			{
				Target: models.Target{
					Host: "192.168.1.1",
					Mode: models.ModeTCP,
					Port: 80,
				},
				Available:  true,
				RespTime:   time.Millisecond * 5,
				PacketLoss: 0.0,
			},
			{
				Target: models.Target{
					Host: "192.168.1.1",
					Mode: models.ModeTCP,
					Port: 443,
				},
				Available:  false,
				RespTime:   0,
				PacketLoss: 100.0,
			},
		}

		deviceUpdate := &models.DeviceUpdate{
			Metadata: make(map[string]string),
		}

		sweeper.addAggregatedScanResults(deviceUpdate, results)

		// Should have separate ICMP and TCP results
		assert.Contains(t, deviceUpdate.Metadata["scan_icmp_results"], "192.168.1.1:icmp:available=true")
		assert.Contains(t, deviceUpdate.Metadata["scan_tcp_results"], "192.168.1.1:tcp:available=true")
		assert.Contains(t, deviceUpdate.Metadata["scan_tcp_results"], "192.168.1.1:tcp:available=false")

		// Overall should show as available (2 out of 3 succeed)
		assert.True(t, deviceUpdate.IsAvailable)
	})
}
