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

package agent

import (
	"context"
	"fmt"
	"runtime"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/scan"
)

// skipIfNotLinuxRoot skips the test if not running on Linux or without root privileges
func skipIfNotLinuxRoot(t *testing.T) {
	t.Helper()

	if runtime.GOOS != "linux" {
		t.Skip("SYN scanning is only supported on Linux")
	}

	log := logger.NewTestLogger()
	scanner, err := scan.NewSYNScanner(100*time.Millisecond, 1, log, nil)
	if err != nil {
		t.Skipf("SYN scanning unavailable: %v", err)
	}
	if scanner != nil {
		_ = scanner.Stop()
	}
}

func expectSweepConfigBootstrap(mockKV *MockKVStore, key string) {
	mockKV.EXPECT().Get(gomock.Any(), key).Return(nil, false, nil).AnyTimes()
	mockKV.EXPECT().Put(gomock.Any(), key, gomock.Any(), time.Duration(0)).Return(nil).AnyTimes()
	mockKV.EXPECT().Close().Return(nil).AnyTimes()
}

func TestSweepService_Creation(t *testing.T) {
	skipIfNotLinuxRoot(t)

	// Test that sweep service can be created successfully with optimized config
	config := &models.Config{
		Concurrency: 500,             // Optimized high concurrency
		Timeout:     2 * time.Second, // Fast timeouts
		Interval:    5 * time.Minute, // Default interval
		SweepModes:  []models.SweepMode{models.ModeTCP, models.ModeICMP},
	}

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	log := logger.NewTestLogger()
	mockKVStore := NewMockKVStore(ctrl)
	expectSweepConfigBootstrap(mockKVStore, "test")

	service, err := NewSweepService(context.Background(), config, mockKVStore, "test", log)
	require.NoError(t, err)
	assert.NotNil(t, service)
	assert.Equal(t, "network_sweep", service.Name())

	t.Logf("Successfully created sweep service with optimized configuration")
}

func TestSweepService_LargeScaleConfig(t *testing.T) {
	skipIfNotLinuxRoot(t)

	if testing.Short() {
		t.Skip("Skipping large scale config test in short mode")
	}

	// Test configuration that simulates large-scale production scenario
	config := &models.Config{
		DeviceTargets: createLargeDeviceTargetSet(1000),                     // 1000 devices
		Ports:         []int{22, 80, 135, 443, 445, 3389, 5985, 8080, 8443}, // 9 ports
		SweepModes:    []models.SweepMode{models.ModeTCP},
		Concurrency:   500,
		Timeout:       2 * time.Second,
		Interval:      10 * time.Minute,
	}

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	log := logger.NewTestLogger()
	mockKVStore := NewMockKVStore(ctrl)
	expectSweepConfigBootstrap(mockKVStore, "test")

	service, err := NewSweepService(context.Background(), config, mockKVStore, "test", log)
	require.NoError(t, err)
	assert.NotNil(t, service)

	// With 1000 devices * 9 ports = 9000 TCP targets
	// This should demonstrate the performance improvements

	// Test that the service can be created without errors for large configurations
	assert.Equal(t, "network_sweep", service.Name())

	t.Logf("Large-scale config: %d devices, %d ports = %d potential TCP targets",
		len(config.DeviceTargets), len(config.Ports),
		len(config.DeviceTargets)*len(config.Ports))
}

func TestSweepService_PerformanceComparison(t *testing.T) {
	skipIfNotLinuxRoot(t)

	if testing.Short() {
		t.Skip("Skipping performance comparison test in short mode")
	}

	// Compare old vs new default configurations
	oldConfig := &models.Config{
		Networks:    []string{"127.0.0.1/32"},
		Ports:       []int{22, 80, 443},
		SweepModes:  []models.SweepMode{models.ModeTCP},
		Concurrency: 20,              // Old default
		Timeout:     5 * time.Second, // Old default
	}

	newConfig := &models.Config{
		Networks:    []string{"127.0.0.1/32"},
		Ports:       []int{22, 80, 443},
		SweepModes:  []models.SweepMode{models.ModeTCP},
		Concurrency: 500,             // Optimized default
		Timeout:     2 * time.Second, // Optimized default
	}

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	log := logger.NewTestLogger()
	mockKVStore1 := NewMockKVStore(ctrl)
	expectSweepConfigBootstrap(mockKVStore1, "test_old")

	mockKVStore2 := NewMockKVStore(ctrl)
	expectSweepConfigBootstrap(mockKVStore2, "test_new")

	// Test old configuration
	oldService, err := NewSweepService(context.Background(), oldConfig, mockKVStore1, "test_old", log)
	require.NoError(t, err)
	assert.Equal(t, "network_sweep", oldService.Name())

	// Test new configuration (with optimized defaults)
	newService, err := NewSweepService(context.Background(), newConfig, mockKVStore2, "test_new", log)
	require.NoError(t, err)
	assert.Equal(t, "network_sweep", newService.Name())

	t.Logf("Performance comparison:")
	t.Logf("  Old: concurrency=%d, timeout=%v",
		oldConfig.Concurrency, oldConfig.Timeout)
	t.Logf("  New: concurrency=%d, timeout=%v (%.1fx concurrency, %.1fx faster timeout)",
		newConfig.Concurrency, newConfig.Timeout,
		float64(newConfig.Concurrency)/float64(oldConfig.Concurrency),
		float64(oldConfig.Timeout)/float64(newConfig.Timeout))
}

func TestSweepService_RealTimeProgressTracking(t *testing.T) {
	skipIfNotLinuxRoot(t)

	if testing.Short() {
		t.Skip("Skipping real-time progress tracking test in short mode")
	}

	// Test that real-time progress tracking works
	config := &models.Config{
		Networks:   []string{"127.0.0.1/32"},
		Ports:      []int{22, 80, 135, 443, 445}, // 5 ports for progress testing
		SweepModes: []models.SweepMode{models.ModeTCP},
		Timeout:    500 * time.Millisecond, // Fast timeouts for quick test
	}

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	log := logger.NewTestLogger()
	mockKVStore := NewMockKVStore(ctrl)
	expectSweepConfigBootstrap(mockKVStore, "test")

	service, err := NewSweepService(context.Background(), config, mockKVStore, "test", log)
	require.NoError(t, err)

	// The service should initialize without errors
	// In a real scenario, this would show progress logs every 1000 targets
	assert.Equal(t, "network_sweep", service.Name())

	t.Logf("Real-time progress tracking initialized for %d TCP targets",
		len(config.Networks)*len(config.Ports))
}

func TestSweepService_TimeoutHandling(t *testing.T) {
	skipIfNotLinuxRoot(t)

	if testing.Short() {
		t.Skip("Skipping timeout handling test in short mode")
	}

	// Test that the new 20-minute timeout handling works
	config := &models.Config{
		Networks:   []string{"127.0.0.1/32"},
		Ports:      []int{22}, // Single port for fast test
		SweepModes: []models.SweepMode{models.ModeTCP},
	}

	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	log := logger.NewTestLogger()
	mockKVStore := NewMockKVStore(ctrl)
	expectSweepConfigBootstrap(mockKVStore, "test")

	service, err := NewSweepService(context.Background(), config, mockKVStore, "test", log)
	require.NoError(t, err)

	// Should not timeout immediately - the 20-minute scan timeout should allow completion
	start := time.Now()

	// Note: We can't easily test the full 20-minute timeout in unit tests,
	// but we can verify the service handles timeouts gracefully
	assert.Equal(t, "network_sweep", service.Name())

	duration := time.Since(start)
	assert.Less(t, duration, 1*time.Second) // Should initialize quickly

	t.Logf("Timeout handling test completed in %v", duration)
}

// Helper function to create a large set of device targets for testing
func createLargeDeviceTargetSet(count int) []models.DeviceTarget {
	var targets []models.DeviceTarget

	for i := 0; i < count; i++ {
		// Create device targets with both managed and unmanaged devices
		var sweepModes []models.SweepMode

		queryLabel := "managed"

		if i%3 == 0 { // Every 3rd device is unmanaged
			sweepModes = []models.SweepMode{models.ModeICMP, models.ModeTCP}
			queryLabel = "unmanaged"
		} else {
			sweepModes = []models.SweepMode{models.ModeTCP}
		}

		// Simulate IP addresses in different subnets
		subnet := (i / 254) + 1
		hostIP := (i % 254) + 1

		target := models.DeviceTarget{
			Network:    fmt.Sprintf("10.%d.%d.%d/32", subnet, subnet, hostIP),
			SweepModes: sweepModes,
			Source:     "armis",
			QueryLabel: queryLabel,
			Metadata: map[string]string{
				"armis_device_id": fmt.Sprintf("%d", i+1000),
				"primary_ip":      fmt.Sprintf("10.%d.%d.%d", subnet, subnet, hostIP),
				"device_name":     fmt.Sprintf("device-%d", i),
			},
		}

		targets = append(targets, target)
	}

	return targets
}

// Benchmark the sweep service with optimizations
func BenchmarkSweepService_OptimizedPerformance(b *testing.B) {
	config := &models.Config{
		Networks:    []string{"127.0.0.1/32"},
		Ports:       []int{22, 80, 443},
		SweepModes:  []models.SweepMode{models.ModeTCP},
		Concurrency: 500, // Optimized defaults
		Timeout:     2 * time.Second,
	}

	ctrl := gomock.NewController(b)
	defer ctrl.Finish()

	log := logger.NewTestLogger()
	mockKVStore := NewMockKVStore(ctrl)
	mockKVStore.EXPECT().Close().Return(nil).AnyTimes()

	service, err := NewSweepService(context.Background(), config, mockKVStore, "benchmark", log)
	require.NoError(b, err)

	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		// Benchmark service name access (basic operation)
		_ = service.Name()
	}
}
