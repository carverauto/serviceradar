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

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

// TestDeviceAvailabilityLogic tests the core business logic:
// "If any ping or TCP scan on ANY of the IP addresses succeeds, the device should be marked as available"
func TestDeviceAvailabilityLogic(t *testing.T) {
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

	t.Run("single IP available - device should be available", func(t *testing.T) {
		results := []*models.Result{
			{
				Target:    models.Target{Host: "192.168.1.1", Mode: models.ModeICMP},
				Available: true,
			},
		}

		deviceUpdate := &models.DeviceUpdate{
			Metadata: make(map[string]string),
		}

		sweeper.addAggregatedScanResults(deviceUpdate, results)

		assert.True(t, deviceUpdate.IsAvailable, "Device should be available when any IP is reachable")
		assert.Equal(t, "100.0", deviceUpdate.Metadata["scan_availability_percent"])
		assert.Equal(t, "1", deviceUpdate.Metadata["scan_available_count"])
		assert.Equal(t, "0", deviceUpdate.Metadata["scan_unavailable_count"])
	})

	t.Run("single IP unavailable - device should be unavailable", func(t *testing.T) {
		results := []*models.Result{
			{
				Target:    models.Target{Host: "192.168.1.1", Mode: models.ModeICMP},
				Available: false,
			},
		}

		deviceUpdate := &models.DeviceUpdate{
			Metadata: make(map[string]string),
		}

		sweeper.addAggregatedScanResults(deviceUpdate, results)

		assert.False(t, deviceUpdate.IsAvailable, "Device should be unavailable when no IPs are reachable")
		assert.Equal(t, "0.0", deviceUpdate.Metadata["scan_availability_percent"])
		assert.Equal(t, "0", deviceUpdate.Metadata["scan_available_count"])
		assert.Equal(t, "1", deviceUpdate.Metadata["scan_unavailable_count"])
	})

	t.Run("multiple IPs - ANY available makes device available", func(t *testing.T) {
		// Test the core requirement: if ANY IP responds, device is available
		testCases := []struct {
			name     string
			results  []*models.Result
			expected bool
			reason   string
		}{
			{
				name: "first IP available, others unavailable",
				results: []*models.Result{
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeICMP}, Available: true},
					{Target: models.Target{Host: "192.168.1.2", Mode: models.ModeICMP}, Available: false},
					{Target: models.Target{Host: "192.168.1.3", Mode: models.ModeICMP}, Available: false},
				},
				expected: true,
				reason:   "First IP responds",
			},
			{
				name: "middle IP available, others unavailable",
				results: []*models.Result{
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeICMP}, Available: false},
					{Target: models.Target{Host: "192.168.1.2", Mode: models.ModeICMP}, Available: true},
					{Target: models.Target{Host: "192.168.1.3", Mode: models.ModeICMP}, Available: false},
				},
				expected: true,
				reason:   "Middle IP responds",
			},
			{
				name: "last IP available, others unavailable",
				results: []*models.Result{
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeICMP}, Available: false},
					{Target: models.Target{Host: "192.168.1.2", Mode: models.ModeICMP}, Available: false},
					{Target: models.Target{Host: "192.168.1.3", Mode: models.ModeICMP}, Available: true},
				},
				expected: true,
				reason:   "Last IP responds",
			},
			{
				name: "all IPs unavailable",
				results: []*models.Result{
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeICMP}, Available: false},
					{Target: models.Target{Host: "192.168.1.2", Mode: models.ModeICMP}, Available: false},
					{Target: models.Target{Host: "192.168.1.3", Mode: models.ModeICMP}, Available: false},
				},
				expected: false,
				reason:   "No IPs respond",
			},
			{
				name: "multiple IPs available",
				results: []*models.Result{
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeICMP}, Available: true},
					{Target: models.Target{Host: "192.168.1.2", Mode: models.ModeICMP}, Available: true},
					{Target: models.Target{Host: "192.168.1.3", Mode: models.ModeICMP}, Available: false},
				},
				expected: true,
				reason:   "Multiple IPs respond",
			},
		}

		for _, tc := range testCases {
			t.Run(tc.name, func(t *testing.T) {
				deviceUpdate := &models.DeviceUpdate{
					Metadata: make(map[string]string),
				}

				sweeper.addAggregatedScanResults(deviceUpdate, tc.results)

				assert.Equal(t, tc.expected, deviceUpdate.IsAvailable,
					"Device availability should be %v when %s", tc.expected, tc.reason)
			})
		}
	})

	t.Run("mixed protocols - ANY protocol success makes device available", func(t *testing.T) {
		testCases := []struct {
			name     string
			results  []*models.Result
			expected bool
			reason   string
		}{
			{
				name: "ICMP succeeds, TCP fails",
				results: []*models.Result{
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeICMP}, Available: true},
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeTCP, Port: 80}, Available: false},
				},
				expected: true,
				reason:   "ICMP ping succeeds",
			},
			{
				name: "ICMP fails, TCP succeeds",
				results: []*models.Result{
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeICMP}, Available: false},
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeTCP, Port: 80}, Available: true},
				},
				expected: true,
				reason:   "TCP port scan succeeds",
			},
			{
				name: "both protocols fail",
				results: []*models.Result{
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeICMP}, Available: false},
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeTCP, Port: 80}, Available: false},
				},
				expected: false,
				reason:   "all protocols fail",
			},
			{
				name: "multiple ports - any success makes available",
				results: []*models.Result{
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeICMP}, Available: false},
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeTCP, Port: 22}, Available: false},
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeTCP, Port: 80}, Available: true},
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeTCP, Port: 443}, Available: false},
				},
				expected: true,
				reason:   "port 80 responds",
			},
		}

		for _, tc := range testCases {
			t.Run(tc.name, func(t *testing.T) {
				deviceUpdate := &models.DeviceUpdate{
					Metadata: make(map[string]string),
				}

				sweeper.addAggregatedScanResults(deviceUpdate, tc.results)

				assert.Equal(t, tc.expected, deviceUpdate.IsAvailable,
					"Device availability should be %v when %s", tc.expected, tc.reason)
			})
		}
	})

	t.Run("complex multi-IP multi-protocol scenarios", func(t *testing.T) {
		testCases := []struct {
			name     string
			results  []*models.Result
			expected bool
			reason   string
		}{
			{
				name: "IP1 fails everything, IP2 ICMP succeeds",
				results: []*models.Result{
					// IP1: All protocols fail
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeICMP}, Available: false},
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeTCP, Port: 80}, Available: false},
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeTCP, Port: 443}, Available: false},
					// IP2: ICMP succeeds
					{Target: models.Target{Host: "192.168.1.2", Mode: models.ModeICMP}, Available: true},
					{Target: models.Target{Host: "192.168.1.2", Mode: models.ModeTCP, Port: 80}, Available: false},
				},
				expected: true,
				reason:   "IP2 ICMP succeeds",
			},
			{
				name: "IP1 fails everything, IP2 fails everything, IP3 TCP succeeds",
				results: []*models.Result{
					// IP1: All fail
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeICMP}, Available: false},
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeTCP, Port: 80}, Available: false},
					// IP2: All fail
					{Target: models.Target{Host: "192.168.1.2", Mode: models.ModeICMP}, Available: false},
					{Target: models.Target{Host: "192.168.1.2", Mode: models.ModeTCP, Port: 80}, Available: false},
					// IP3: TCP succeeds
					{Target: models.Target{Host: "10.0.0.1", Mode: models.ModeICMP}, Available: false},
					{Target: models.Target{Host: "10.0.0.1", Mode: models.ModeTCP, Port: 22}, Available: true},
				},
				expected: true,
				reason:   "IP3 SSH port responds",
			},
			{
				name: "all IPs and all protocols fail",
				results: []*models.Result{
					// IP1: All fail
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeICMP}, Available: false},
					{Target: models.Target{Host: "192.168.1.1", Mode: models.ModeTCP, Port: 80}, Available: false},
					// IP2: All fail
					{Target: models.Target{Host: "192.168.1.2", Mode: models.ModeICMP}, Available: false},
					{Target: models.Target{Host: "192.168.1.2", Mode: models.ModeTCP, Port: 80}, Available: false},
					// IP3: All fail
					{Target: models.Target{Host: "10.0.0.1", Mode: models.ModeICMP}, Available: false},
					{Target: models.Target{Host: "10.0.0.1", Mode: models.ModeTCP, Port: 22}, Available: false},
				},
				expected: false,
				reason:   "all IPs and protocols fail",
			},
		}

		for _, tc := range testCases {
			t.Run(tc.name, func(t *testing.T) {
				deviceUpdate := &models.DeviceUpdate{
					Metadata: make(map[string]string),
				}

				sweeper.addAggregatedScanResults(deviceUpdate, tc.results)

				assert.Equal(t, tc.expected, deviceUpdate.IsAvailable,
					"Device availability should be %v when %s", tc.expected, tc.reason)
			})
		}
	})
}

// TestEndToEndAvailabilityFlow tests the complete flow from target generation to device update
func TestEndToEndAvailabilityFlow(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockStore := NewMockStore(ctrl)
	mockProcessor := NewMockResultProcessor(ctrl)
	mockDeviceRegistry := NewMockDeviceRegistryService(ctrl)

	config := &models.Config{
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
		Ports:     []int{80, 443},
		Interval:  time.Minute,
		AgentID:   "test-agent",
		PollerID:  "test-poller",
		Partition: "default",
	}

	sweeper := &NetworkSweeper{
		config:         config,
		store:          mockStore,
		processor:      mockProcessor,
		deviceRegistry: mockDeviceRegistry,
		logger:         logger.NewTestLogger(),
		deviceResults:  make(map[string]*DeviceResultAggregator),
	}

	t.Run("end-to-end: only last IP responds - device available", func(t *testing.T) {
		// Generate targets and prepare aggregators
		targets, err := sweeper.generateTargets()
		require.NoError(t, err)
		require.NotEmpty(t, targets)

		sweeper.prepareDeviceAggregators(targets)

		// Simulate scan results where only the last IP (10.0.0.1) responds to ICMP
		deviceMeta := map[string]interface{}{"armis_device_id": "123"}
		mockResults := []*models.Result{
			// IP1: All fail
			{
				Target:    models.Target{Host: "192.168.1.1", Mode: models.ModeICMP, Metadata: deviceMeta},
				Available: false,
			},
			{
				Target:    models.Target{Host: "192.168.1.1", Mode: models.ModeTCP, Port: 80, Metadata: deviceMeta},
				Available: false,
			},
			{
				Target:    models.Target{Host: "192.168.1.1", Mode: models.ModeTCP, Port: 443, Metadata: deviceMeta},
				Available: false,
			},
			// IP2: All fail
			{
				Target:    models.Target{Host: "192.168.1.2", Mode: models.ModeICMP, Metadata: deviceMeta},
				Available: false,
			},
			{
				Target:    models.Target{Host: "192.168.1.2", Mode: models.ModeTCP, Port: 80, Metadata: deviceMeta},
				Available: false,
			},
			{
				Target:    models.Target{Host: "192.168.1.2", Mode: models.ModeTCP, Port: 443, Metadata: deviceMeta},
				Available: false,
			},
			// IP3: Only ICMP succeeds
			{
				Target:    models.Target{Host: "10.0.0.1", Mode: models.ModeICMP, Metadata: deviceMeta},
				Available: true,
			},
			{
				Target:    models.Target{Host: "10.0.0.1", Mode: models.ModeTCP, Port: 80, Metadata: deviceMeta},
				Available: false,
			},
			{
				Target:    models.Target{Host: "10.0.0.1", Mode: models.ModeTCP, Port: 443, Metadata: deviceMeta},
				Available: false,
			},
		}

		// Set up expectations for regular result processing
		for _, result := range mockResults {
			mockProcessor.EXPECT().Process(result).Return(nil)
			mockStore.EXPECT().SaveResult(gomock.Any(), result).Return(nil)
		}

		// Set up device registry expectation - device should be available because 10.0.0.1 responds
		mockDeviceRegistry.EXPECT().
			UpdateDevice(gomock.Any(), gomock.Any()).
			DoAndReturn(func(_ context.Context, update *models.DeviceUpdate) error {
				// Verify the device is marked as available
				assert.True(t, update.IsAvailable, "Device should be available when any IP responds")

				// The system lists each IP multiple times (once per scan type)
				// With 3 IPs × 3 scan types (ICMP + 2 TCP ports) = 9 entries each
				expectedAllIPs := "192.168.1.1,192.168.1.1,192.168.1.1,192.168.1.2,192.168.1.2," +
					"192.168.1.2,10.0.0.1,10.0.0.1,10.0.0.1"
				expectedUnavailableIPs := "192.168.1.1,192.168.1.1,192.168.1.1,192.168.1.2," +
					"192.168.1.2,192.168.1.2,10.0.0.1,10.0.0.1"

				assert.Equal(t, expectedAllIPs, update.Metadata["scan_all_ips"])
				assert.Equal(t, "10.0.0.1", update.Metadata["scan_available_ips"])
				assert.Equal(t, expectedUnavailableIPs, update.Metadata["scan_unavailable_ips"])

				// Should show ~11% availability (1 success out of 9 total scans)
				assert.Equal(t, "11.1", update.Metadata["scan_availability_percent"])

				return nil
			})

		// Process results through the normal flow
		for _, result := range mockResults {
			err := sweeper.processResult(context.Background(), result)
			require.NoError(t, err)
		}

		// Finalize aggregators to trigger device update
		sweeper.finalizeDeviceAggregators(context.Background())
	})

	t.Run("end-to-end: no IPs respond - device unavailable", func(t *testing.T) {
		// Reset aggregators
		sweeper.deviceResults = make(map[string]*DeviceResultAggregator)

		// Generate targets and prepare aggregators
		targets, err := sweeper.generateTargets()
		require.NoError(t, err)

		sweeper.prepareDeviceAggregators(targets)

		// Simulate scan results where NO IPs respond to anything
		deviceMeta2 := map[string]interface{}{"armis_device_id": "123"}
		mockResults := []*models.Result{
			// IP1: All fail
			{
				Target:    models.Target{Host: "192.168.1.1", Mode: models.ModeICMP, Metadata: deviceMeta2},
				Available: false,
			},
			{
				Target:    models.Target{Host: "192.168.1.1", Mode: models.ModeTCP, Port: 80, Metadata: deviceMeta2},
				Available: false,
			},
			{
				Target:    models.Target{Host: "192.168.1.1", Mode: models.ModeTCP, Port: 443, Metadata: deviceMeta2},
				Available: false,
			},
			// IP2: All fail
			{
				Target:    models.Target{Host: "192.168.1.2", Mode: models.ModeICMP, Metadata: deviceMeta2},
				Available: false,
			},
			{
				Target:    models.Target{Host: "192.168.1.2", Mode: models.ModeTCP, Port: 80, Metadata: deviceMeta2},
				Available: false,
			},
			{
				Target:    models.Target{Host: "192.168.1.2", Mode: models.ModeTCP, Port: 443, Metadata: deviceMeta2},
				Available: false,
			},
			// IP3: All fail
			{
				Target:    models.Target{Host: "10.0.0.1", Mode: models.ModeICMP, Metadata: deviceMeta2},
				Available: false,
			},
			{
				Target:    models.Target{Host: "10.0.0.1", Mode: models.ModeTCP, Port: 80, Metadata: deviceMeta2},
				Available: false,
			},
			{
				Target:    models.Target{Host: "10.0.0.1", Mode: models.ModeTCP, Port: 443, Metadata: deviceMeta2},
				Available: false,
			},
		}

		// Set up expectations for regular result processing
		for _, result := range mockResults {
			mockProcessor.EXPECT().Process(result).Return(nil)
			mockStore.EXPECT().SaveResult(gomock.Any(), result).Return(nil)
		}

		// Set up device registry expectation - device should be unavailable
		mockDeviceRegistry.EXPECT().
			UpdateDevice(gomock.Any(), gomock.Any()).
			DoAndReturn(func(_ context.Context, update *models.DeviceUpdate) error {
				// Verify the device is marked as unavailable
				assert.False(t, update.IsAvailable, "Device should be unavailable when no IPs respond")

				// The system lists each IP multiple times (once per scan type)
				// With 3 IPs × 3 scan types (ICMP + 2 TCP ports) = 9 entries each
				expectedAllIPs2 := "192.168.1.1,192.168.1.1,192.168.1.1,192.168.1.2,192.168.1.2," +
					"192.168.1.2,10.0.0.1,10.0.0.1,10.0.0.1"

				assert.Equal(t, expectedAllIPs2, update.Metadata["scan_all_ips"])
				assert.Equal(t, "", update.Metadata["scan_available_ips"])
				assert.Equal(t, expectedAllIPs2, update.Metadata["scan_unavailable_ips"])
				assert.Equal(t, "0.0", update.Metadata["scan_availability_percent"])

				return nil
			})

		// Process results through the normal flow
		for _, result := range mockResults {
			err := sweeper.processResult(context.Background(), result)
			require.NoError(t, err)
		}

		// Finalize aggregators to trigger device update
		sweeper.finalizeDeviceAggregators(context.Background())
	})
}

// TestTCPOnlyArmisScenarios tests TCP-only queries for Armis integration to verify
// that successful TCP scans mark devices as available without requiring ICMP.
// This validates production networks where ICMP might be allowed but TCP should be blocked.
func TestTCPOnlyArmisScenarios(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockStore := NewMockStore(ctrl)
	mockProcessor := NewMockResultProcessor(ctrl)
	mockDeviceRegistry := NewMockDeviceRegistryService(ctrl)

	// Create a TCP-only configuration for Armis devices
	config := &models.Config{
		DeviceTargets: []models.DeviceTarget{
			{
				Network:    "192.168.1.100/32",                 // Single IP for focused testing
				SweepModes: []models.SweepMode{models.ModeTCP}, // TCP ONLY - no ICMP
				QueryLabel: "armis_tcp_only_devices",
				Source:     "armis",
				Metadata: map[string]string{
					"armis_device_id": "tcp-test-device-456",
					"all_ips":         "192.168.1.100,10.1.1.100", // Multiple IPs for this device
					"primary_ip":      "192.168.1.100",
					"agent_id":        "tcp-test-agent",
					"poller_id":       "tcp-test-poller",
					"partition":       "tcp-test-partition",
				},
			},
		},
		Ports:     []int{22, 80, 443}, // Common ports for TCP scanning
		Interval:  time.Minute,
		AgentID:   "tcp-test-agent",
		PollerID:  "tcp-test-poller",
		Partition: "tcp-test-partition",
	}

	sweeper := &NetworkSweeper{
		config:         config,
		store:          mockStore,
		processor:      mockProcessor,
		deviceRegistry: mockDeviceRegistry,
		logger:         logger.NewTestLogger(),
		deviceResults:  make(map[string]*DeviceResultAggregator),
	}

	t.Run("TCP-only: single port success marks device available", func(t *testing.T) {
		// Generate targets and prepare aggregators
		targets, err := sweeper.generateTargets()
		require.NoError(t, err)
		require.NotEmpty(t, targets)

		sweeper.prepareDeviceAggregators(targets)

		// Simulate TCP scan results where only port 22 on IP1 succeeds
		deviceMeta := map[string]interface{}{"armis_device_id": "tcp-test-device-456"}
		mockResults := []*models.Result{
			// IP1: Port 22 succeeds, others fail
			{
				Target:    models.Target{Host: "192.168.1.100", Mode: models.ModeTCP, Port: 22, Metadata: deviceMeta},
				Available: true, // SSH port is open
			},
			{
				Target:    models.Target{Host: "192.168.1.100", Mode: models.ModeTCP, Port: 80, Metadata: deviceMeta},
				Available: false, // HTTP port closed
			},
			{
				Target:    models.Target{Host: "192.168.1.100", Mode: models.ModeTCP, Port: 443, Metadata: deviceMeta},
				Available: false, // HTTPS port closed
			},
			// IP2: All TCP ports fail
			{
				Target:    models.Target{Host: "10.1.1.100", Mode: models.ModeTCP, Port: 22, Metadata: deviceMeta},
				Available: false,
			},
			{
				Target:    models.Target{Host: "10.1.1.100", Mode: models.ModeTCP, Port: 80, Metadata: deviceMeta},
				Available: false,
			},
			{
				Target:    models.Target{Host: "10.1.1.100", Mode: models.ModeTCP, Port: 443, Metadata: deviceMeta},
				Available: false,
			},
		}

		// Set up expectations for regular result processing
		for _, result := range mockResults {
			mockProcessor.EXPECT().Process(result).Return(nil)
			mockStore.EXPECT().SaveResult(gomock.Any(), result).Return(nil)
		}

		// Set up device registry expectation - device should be available due to TCP success
		mockDeviceRegistry.EXPECT().
			UpdateDevice(gomock.Any(), gomock.Any()).
			DoAndReturn(func(_ context.Context, update *models.DeviceUpdate) error {
				// CRITICAL: Device should be available despite no ICMP checks
				assert.True(t, update.IsAvailable,
					"Device should be available with TCP-only scan when any TCP port succeeds")

				// Verify metadata shows TCP success
				assert.Equal(t, "192.168.1.100", update.Metadata["scan_available_ips"])
				assert.Contains(t, update.Metadata["scan_unavailable_ips"], "10.1.1.100")

				// Should show ~16.7% availability (1 success out of 6 total TCP scans)
				assert.Equal(t, "16.7", update.Metadata["scan_availability_percent"])
				assert.Equal(t, "1", update.Metadata["scan_available_count"])
				assert.Equal(t, "5", update.Metadata["scan_unavailable_count"])

				return nil
			})

		// Process results through the normal flow
		for _, result := range mockResults {
			err := sweeper.processResult(context.Background(), result)
			require.NoError(t, err)
		}

		// Finalize aggregators to trigger device update
		sweeper.finalizeDeviceAggregators(context.Background())
	})

	t.Run("TCP-only: all TCP ports fail - device unavailable", func(t *testing.T) {
		// Reset aggregators for clean test
		sweeper.deviceResults = make(map[string]*DeviceResultAggregator)

		// Generate targets and prepare aggregators
		targets, err := sweeper.generateTargets()
		require.NoError(t, err)

		sweeper.prepareDeviceAggregators(targets)

		// Simulate TCP scan results where ALL TCP ports fail on all IPs
		deviceMeta := map[string]interface{}{"armis_device_id": "tcp-test-device-456"}
		mockResults := []*models.Result{
			// IP1: All TCP ports fail
			{
				Target:    models.Target{Host: "192.168.1.100", Mode: models.ModeTCP, Port: 22, Metadata: deviceMeta},
				Available: false,
			},
			{
				Target:    models.Target{Host: "192.168.1.100", Mode: models.ModeTCP, Port: 80, Metadata: deviceMeta},
				Available: false,
			},
			{
				Target:    models.Target{Host: "192.168.1.100", Mode: models.ModeTCP, Port: 443, Metadata: deviceMeta},
				Available: false,
			},
			// IP2: All TCP ports fail
			{
				Target:    models.Target{Host: "10.1.1.100", Mode: models.ModeTCP, Port: 22, Metadata: deviceMeta},
				Available: false,
			},
			{
				Target:    models.Target{Host: "10.1.1.100", Mode: models.ModeTCP, Port: 80, Metadata: deviceMeta},
				Available: false,
			},
			{
				Target:    models.Target{Host: "10.1.1.100", Mode: models.ModeTCP, Port: 443, Metadata: deviceMeta},
				Available: false,
			},
		}

		// Set up expectations for regular result processing
		for _, result := range mockResults {
			mockProcessor.EXPECT().Process(result).Return(nil)
			mockStore.EXPECT().SaveResult(gomock.Any(), result).Return(nil)
		}

		// Set up device registry expectation - device should be unavailable
		mockDeviceRegistry.EXPECT().
			UpdateDevice(gomock.Any(), gomock.Any()).
			DoAndReturn(func(_ context.Context, update *models.DeviceUpdate) error {
				// Device should be unavailable when all TCP ports fail
				assert.False(t, update.IsAvailable,
					"Device should be unavailable in TCP-only scan when all TCP ports fail")

				// Verify metadata shows no available IPs
				assert.Equal(t, "", update.Metadata["scan_available_ips"])
				assert.Equal(t, "0.0", update.Metadata["scan_availability_percent"])
				assert.Equal(t, "0", update.Metadata["scan_available_count"])
				assert.Equal(t, "6", update.Metadata["scan_unavailable_count"])

				return nil
			})

		// Process results through the normal flow
		for _, result := range mockResults {
			err := sweeper.processResult(context.Background(), result)
			require.NoError(t, err)
		}

		// Finalize aggregators to trigger device update
		sweeper.finalizeDeviceAggregators(context.Background())
	})

	t.Run("TCP-only: mixed IP results - any TCP success makes available", func(t *testing.T) {
		// Reset aggregators for clean test
		sweeper.deviceResults = make(map[string]*DeviceResultAggregator)

		// Generate targets and prepare aggregators
		targets, err := sweeper.generateTargets()
		require.NoError(t, err)

		sweeper.prepareDeviceAggregators(targets)

		// Simulate scenario where IP1 has all TCP ports closed but IP2 has one open
		deviceMeta := map[string]interface{}{"armis_device_id": "tcp-test-device-456"}
		mockResults := []*models.Result{
			// IP1: All TCP ports fail (device might be blocking TCP as expected)
			{
				Target:    models.Target{Host: "192.168.1.100", Mode: models.ModeTCP, Port: 22, Metadata: deviceMeta},
				Available: false,
			},
			{
				Target:    models.Target{Host: "192.168.1.100", Mode: models.ModeTCP, Port: 80, Metadata: deviceMeta},
				Available: false,
			},
			{
				Target:    models.Target{Host: "192.168.1.100", Mode: models.ModeTCP, Port: 443, Metadata: deviceMeta},
				Available: false,
			},
			// IP2: HTTPS port is open (compliance violation - should be blocked)
			{
				Target:    models.Target{Host: "10.1.1.100", Mode: models.ModeTCP, Port: 22, Metadata: deviceMeta},
				Available: false,
			},
			{
				Target:    models.Target{Host: "10.1.1.100", Mode: models.ModeTCP, Port: 80, Metadata: deviceMeta},
				Available: false,
			},
			{
				Target:    models.Target{Host: "10.1.1.100", Mode: models.ModeTCP, Port: 443, Metadata: deviceMeta},
				Available: true, // Non-compliant: HTTPS should be blocked but isn't
			},
		}

		// Set up expectations for regular result processing
		for _, result := range mockResults {
			mockProcessor.EXPECT().Process(result).Return(nil)
			mockStore.EXPECT().SaveResult(gomock.Any(), result).Return(nil)
		}

		// Set up device registry expectation - device should be available and flagged as non-compliant
		mockDeviceRegistry.EXPECT().
			UpdateDevice(gomock.Any(), gomock.Any()).
			DoAndReturn(func(_ context.Context, update *models.DeviceUpdate) error {
				// CRITICAL: Device is reachable via TCP (non-compliant)
				assert.True(t, update.IsAvailable,
					"Device should be marked available when any TCP port succeeds, indicating non-compliance")

				// Verify the specific IP that has open TCP port is identified
				assert.Equal(t, "10.1.1.100", update.Metadata["scan_available_ips"])
				assert.Contains(t, update.Metadata["scan_unavailable_ips"], "192.168.1.100")

				// Should show ~16.7% availability (1 success out of 6 total TCP scans)
				assert.Equal(t, "16.7", update.Metadata["scan_availability_percent"])
				assert.Equal(t, "1", update.Metadata["scan_available_count"])
				assert.Equal(t, "5", update.Metadata["scan_unavailable_count"])

				return nil
			})

		// Process results through the normal flow
		for _, result := range mockResults {
			err := sweeper.processResult(context.Background(), result)
			require.NoError(t, err)
		}

		// Finalize aggregators to trigger device update
		sweeper.finalizeDeviceAggregators(context.Background())
	})
}
