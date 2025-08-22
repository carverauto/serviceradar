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
	"runtime"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestNetworkSweeper_OptimizedTCPScannerSelection(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("SYN scanning is only supported on Linux")
	}

	tests := []struct {
		name           string
		runAsRoot      bool
		expectSYN      bool
		expectFallback bool
	}{
		{
			name:           "non-root user should use TCP scanner",
			runAsRoot:      false,
			expectSYN:      false,
			expectFallback: true,
		},
		// Note: We can't easily test root scenario in unit tests
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			config := &models.Config{
				Networks:    []string{"127.0.0.1/32"},
				Ports:       []int{22, 80, 443},
				SweepModes:  []models.SweepMode{models.ModeTCP},
				Concurrency: 100,
				Timeout:     2 * time.Second,
			}

			log := logger.NewTestLogger()
			ctrl := gomock.NewController(t)
			mockStore := NewMockStore(ctrl)
			mockProcessor := NewMockResultProcessor(ctrl)

			defer ctrl.Finish()
			mockKVStore := NewMockKVStore(ctrl)

			sweeper, err := NewNetworkSweeper(config, mockStore, mockProcessor, mockKVStore, nil, "test", log)

			if tt.expectFallback {
				// Should succeed with TCP fallback
				require.NoError(t, err)
				assert.NotNil(t, sweeper)

				// Verify it's using a scanner (can't easily determine which type without exposing internals)
				assert.NotNil(t, sweeper.tcpScanner)
			} else {
				// Would succeed with SYN scanner if running as root
				require.NoError(t, err)
				assert.NotNil(t, sweeper)
			}
		})
	}
}

func TestNetworkSweeper_HighConcurrencyConfig(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("SYN scanning is only supported on Linux")
	}

	config := &models.Config{
		Networks:    []string{"192.168.1.0/29"},                           // Small network, 6 hosts
		Ports:       []int{22, 80, 135, 443, 445, 3389, 5985, 8080, 8443}, // 9 ports like production
		SweepModes:  []models.SweepMode{models.ModeTCP},
		Concurrency: 500, // High concurrency
		Timeout:     2 * time.Second,
		Interval:    1 * time.Minute,
	}

	log := logger.NewTestLogger()
	ctrl := gomock.NewController(t)

	defer ctrl.Finish()
	mockStore := NewMockStore(ctrl)
	mockProcessor := NewMockResultProcessor(ctrl)
	mockKVStore := NewMockKVStore(ctrl)

	// Mock the processor to capture results
	mockStore.EXPECT().SaveResult(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
	mockProcessor.EXPECT().Process(gomock.Any()).Return(nil).AnyTimes()
	mockProcessor.EXPECT().GetSummary(gomock.Any()).Return(&models.SweepSummary{}, nil).AnyTimes()

	sweeper, err := NewNetworkSweeper(config, mockStore, mockProcessor, mockKVStore, nil, "test", log)
	require.NoError(t, err)
	assert.NotNil(t, sweeper)

	// Generate targets and verify high concurrency handling
	targets, err := sweeper.generateTargets()
	require.NoError(t, err)

	// Should generate targets for TCP scanning
	// 6 hosts * 9 ports = 54 TCP targets
	expectedTCPTargets := 54
	tcpTargetCount := 0

	for _, target := range targets {
		if target.Mode == models.ModeTCP {
			tcpTargetCount++
		}
	}

	assert.Equal(t, expectedTCPTargets, tcpTargetCount)

	t.Logf("Generated %d TCP targets with high concurrency config", tcpTargetCount)
}

func TestNetworkSweeper_DeviceTargetsWithTCPOptimization(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("SYN scanning is only supported on Linux")
	}

	config := &models.Config{
		DeviceTargets: []models.DeviceTarget{
			{
				Network:    "10.1.1.1/32",
				SweepModes: []models.SweepMode{models.ModeTCP},
				Source:     "armis",
				QueryLabel: "managed",
				Metadata: map[string]string{
					"armis_device_id": "123",
					"primary_ip":      "10.1.1.1",
				},
			},
			{
				Network:    "10.1.1.2/32",
				SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
				Source:     "armis",
				QueryLabel: "unmanaged",
				Metadata: map[string]string{
					"armis_device_id": "456",
					"primary_ip":      "10.1.1.2",
				},
			},
		},
		Ports:       []int{22, 80, 443},
		Concurrency: 500,
		Timeout:     1 * time.Second,
	}

	log := logger.NewTestLogger()
	ctrl := gomock.NewController(t)

	defer ctrl.Finish()
	mockStore := NewMockStore(ctrl)
	mockProcessor := NewMockResultProcessor(ctrl)
	mockKVStore := NewMockKVStore(ctrl)

	sweeper, err := NewNetworkSweeper(config, mockStore, mockProcessor, mockKVStore, nil, "test", log)
	require.NoError(t, err)

	targets, err := sweeper.generateTargets()
	require.NoError(t, err)

	// Count targets by mode and device
	tcpTargets := 0
	icmpTargets := 0
	deviceIPs := make(map[string]bool)

	for _, target := range targets {
		deviceIPs[target.Host] = true

		if target.Mode == models.ModeTCP {
			tcpTargets++
		} else if target.Mode == models.ModeICMP {
			icmpTargets++
		}

		// Verify metadata is preserved
		assert.Contains(t, target.Metadata, "armis_device_id")
		assert.Contains(t, target.Metadata, "source")
	}

	// First device: 1 IP * 3 ports = 3 TCP targets
	// Second device: 1 ICMP + (1 IP * 3 ports) = 1 ICMP + 3 TCP targets
	assert.Equal(t, 6, tcpTargets)  // 3 + 3
	assert.Equal(t, 1, icmpTargets) // 0 + 1
	assert.Len(t, deviceIPs, 2)     // 2 unique IPs

	t.Logf("Device targets: %d TCP, %d ICMP across %d devices",
		tcpTargets, icmpTargets, len(deviceIPs))
}

func TestNetworkSweeper_TimeoutOptimization(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("SYN scanning is only supported on Linux")
	}
	if testing.Short() {
		t.Skip("Skipping timeout optimization test in short mode")
	}

	// Test that scan timeout is properly increased for large-scale scanning
	config := &models.Config{
		Networks:   []string{"127.0.0.1/32"},
		Ports:      []int{22},
		SweepModes: []models.SweepMode{models.ModeTCP},
		Timeout:    500 * time.Millisecond, // Fast individual timeouts
	}

	log := logger.NewTestLogger()
	ctrl := gomock.NewController(t)

	defer ctrl.Finish()
	mockStore := NewMockStore(ctrl)
	mockProcessor := NewMockResultProcessor(ctrl)
	mockKVStore := NewMockKVStore(ctrl)

	sweeper, err := NewNetworkSweeper(config, mockStore, mockProcessor, mockKVStore, nil, "test", log)
	require.NoError(t, err)

	// Verify the sweep uses the optimized scan timeout (20 minutes)
	// This is internal to runSweep, but we can test that it doesn't timeout immediately
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	// Mock processor to avoid nil pointer
	mockStore.EXPECT().SaveResult(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
	mockProcessor.EXPECT().Process(gomock.Any()).Return(nil).AnyTimes()
	mockProcessor.EXPECT().GetSummary(gomock.Any()).Return(&models.SweepSummary{}, nil).AnyTimes()

	// This should complete quickly since we're only scanning one host
	start := time.Now()
	err = sweeper.runSweep(ctx)
	duration := time.Since(start)

	// Should complete fast, not hit the 20-minute timeout
	require.NoError(t, err)
	assert.Less(t, duration, 2*time.Second)

	t.Logf("Single host sweep completed in %v", duration)
}

func TestNetworkSweeper_ProgressLogging(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("SYN scanning is only supported on Linux")
	}
	if testing.Short() {
		t.Skip("Skipping progress logging test in short mode")
	}

	// Test that progress logging works with optimized scanning
	config := &models.Config{
		Networks:    []string{"127.0.0.1/32"},
		Ports:       []int{22, 80, 135, 443, 445}, // 5 ports to ensure progress logging
		SweepModes:  []models.SweepMode{models.ModeTCP},
		Timeout:     100 * time.Millisecond, // Fast timeouts
		Concurrency: 10,
	}

	log := logger.NewTestLogger()
	ctrl := gomock.NewController(t)

	defer ctrl.Finish()
	mockStore := NewMockStore(ctrl)
	mockProcessor := NewMockResultProcessor(ctrl)
	mockKVStore := NewMockKVStore(ctrl)

	// Mock processor to capture all results
	var processedResults []*models.Result

	mockStore.EXPECT().SaveResult(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
	mockProcessor.EXPECT().Process(gomock.Any()).DoAndReturn(func(result *models.Result) error {
		processedResults = append(processedResults, result)
		return nil
	}).AnyTimes()
	mockProcessor.EXPECT().GetSummary(gomock.Any()).Return(&models.SweepSummary{}, nil).AnyTimes()

	sweeper, err := NewNetworkSweeper(config, mockStore, mockProcessor, mockKVStore, nil, "test", log)
	require.NoError(t, err)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	err = sweeper.runSweep(ctx)
	require.NoError(t, err)

	// Should have processed 5 TCP results (1 host * 5 ports)
	assert.Len(t, processedResults, 5)

	// Verify all results are for TCP mode
	for _, result := range processedResults {
		assert.Equal(t, models.ModeTCP, result.Target.Mode)
		assert.Equal(t, "127.0.0.1", result.Target.Host)
		assert.Contains(t, []int{22, 80, 135, 443, 445}, result.Target.Port)
	}

	t.Logf("Processed %d TCP scan results with progress logging", len(processedResults))
}

// Benchmark the sweeper with optimized TCP scanning
func BenchmarkNetworkSweeper_OptimizedTCPScan(b *testing.B) {
	if testing.Short() {
		b.Skip("Skipping benchmark in short mode")
	}

	config := &models.Config{
		Networks:    []string{"127.0.0.1/32"},
		Ports:       []int{22, 80, 135, 443, 445, 3389, 5985, 8080, 8443},
		SweepModes:  []models.SweepMode{models.ModeTCP},
		Timeout:     500 * time.Millisecond,
		Concurrency: 500,
	}

	log := logger.NewTestLogger()
	ctrl := gomock.NewController(b)

	defer ctrl.Finish()
	mockStore := NewMockStore(ctrl)
	mockProcessor := NewMockResultProcessor(ctrl)
	mockKVStore := NewMockKVStore(ctrl)

	mockStore.EXPECT().SaveResult(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
	mockProcessor.EXPECT().Process(gomock.Any()).Return(nil).AnyTimes()
	mockProcessor.EXPECT().GetSummary(gomock.Any()).Return(&models.SweepSummary{}, nil).AnyTimes()

	sweeper, err := NewNetworkSweeper(config, mockStore, mockProcessor, mockKVStore, nil, "test", log)
	require.NoError(b, err)

	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)

		err := sweeper.runSweep(ctx)
		require.NoError(b, err)

		cancel()
	}
}
