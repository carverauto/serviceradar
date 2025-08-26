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
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/logger"
)

const (
	testSource = "test-source"
)

func TestInMemoryMetrics_DiscoveryMetrics(t *testing.T) {
	log := logger.NewTestLogger()
	metrics := NewInMemoryMetrics(log)

	source := testSource
	deviceCount := 10
	duration := 100 * time.Millisecond
	var testErr = errors.New("test error")

	// Record attempt
	metrics.RecordDiscoveryAttempt(source)

	// Record success
	metrics.RecordDiscoverySuccess(source, deviceCount, duration)

	// Record failure
	metrics.RecordDiscoveryFailure(source, testErr, duration)

	// Get metrics
	data := metrics.GetMetrics()
	require.NotNil(t, data)

	discovery, ok := data["discovery"].(map[string]interface{})
	require.True(t, ok)

	attempts, ok := discovery["attempts"].(map[string]int)
	require.True(t, ok)
	assert.Equal(t, 1, attempts[source])

	successes, ok := discovery["successes"].(map[string]int)
	require.True(t, ok)
	assert.Equal(t, 1, successes[source])

	failures, ok := discovery["failures"].(map[string]int)
	require.True(t, ok)
	assert.Equal(t, 1, failures[source])

	devices, ok := discovery["devices_by_source"].(map[string]int)
	require.True(t, ok)
	assert.Equal(t, deviceCount, devices[source])
}

func TestInMemoryMetrics_ReconciliationMetrics(t *testing.T) {
	log := logger.NewTestLogger()
	metrics := NewInMemoryMetrics(log)

	source := testSource
	updateCount := 5
	duration := 200 * time.Millisecond
	var testErr = errors.New("reconciliation error")

	// Record attempt and success
	metrics.RecordReconciliationAttempt(source)
	metrics.RecordReconciliationSuccess(source, updateCount, duration)

	// Record another attempt and failure
	metrics.RecordReconciliationAttempt(source)
	metrics.RecordReconciliationFailure(source, testErr, duration)

	// Get metrics
	data := metrics.GetMetrics()
	require.NotNil(t, data)

	reconciliation, ok := data["reconciliation"].(map[string]interface{})
	require.True(t, ok)

	attempts, ok := reconciliation["attempts"].(map[string]int)
	require.True(t, ok)
	assert.Equal(t, 2, attempts[source])

	successes, ok := reconciliation["successes"].(map[string]int)
	require.True(t, ok)
	assert.Equal(t, 1, successes[source])

	failures, ok := reconciliation["failures"].(map[string]int)
	require.True(t, ok)
	assert.Equal(t, 1, failures[source])

	updates, ok := reconciliation["updates"].(map[string]int)
	require.True(t, ok)
	assert.Equal(t, updateCount, updates[source])
}

func TestInMemoryMetrics_APIMetrics(t *testing.T) {
	log := logger.NewTestLogger()
	metrics := NewInMemoryMetrics(log)

	integration := "armis"
	endpoint := "/api/v1/search"
	duration := 50 * time.Millisecond
	statusCode := 500

	// Record API call, success, and failure
	metrics.RecordAPICall(integration, endpoint)
	metrics.RecordAPISuccess(integration, endpoint, duration)
	metrics.RecordAPIFailure(integration, endpoint, statusCode, duration)

	// Get metrics
	data := metrics.GetMetrics()
	require.NotNil(t, data)

	api, ok := data["api"].(map[string]interface{})
	require.True(t, ok)

	key := integration + ":" + endpoint

	calls, ok := api["calls"].(map[string]int)
	require.True(t, ok)
	assert.Equal(t, 1, calls[key])

	successes, ok := api["successes"].(map[string]int)
	require.True(t, ok)
	assert.Equal(t, 1, successes[key])

	failures, ok := api["failures"].(map[string]int)
	require.True(t, ok)
	assert.Equal(t, 1, failures[key])
}

func TestInMemoryMetrics_CircuitBreakerMetrics(t *testing.T) {
	log := logger.NewTestLogger()
	metrics := NewInMemoryMetrics(log)

	name := "test-breaker"
	oldState := StateClosed
	newState := StateOpen

	metrics.RecordCircuitBreakerStateChange(name, oldState, newState)

	// Get metrics
	data := metrics.GetMetrics()
	require.NotNil(t, data)

	circuitBreakers, ok := data["circuit_breakers"].(map[string]string)
	require.True(t, ok)
	assert.Equal(t, "open", circuitBreakers[name])
}

func TestInMemoryMetrics_ServiceMetrics(t *testing.T) {
	log := logger.NewTestLogger()
	metrics := NewInMemoryMetrics(log)

	activeIntegrations := 3
	totalDevices := 150

	metrics.RecordActiveIntegrations(activeIntegrations)
	metrics.RecordTotalDevicesDiscovered(totalDevices)

	// Get metrics
	data := metrics.GetMetrics()
	require.NotNil(t, data)

	service, ok := data["service"].(map[string]interface{})
	require.True(t, ok)

	assert.Equal(t, activeIntegrations, service["active_integrations"])
	assert.Equal(t, totalDevices, service["total_devices_discovered"])
	assert.NotNil(t, service["last_updated"])
}

func TestNoOpMetrics(t *testing.T) {
	metrics := &NoOpMetrics{}

	// Should not panic
	metrics.RecordDiscoveryAttempt("test")
	metrics.RecordDiscoverySuccess("test", 10, time.Second)
	testErr2 := errors.New("test")
	metrics.RecordDiscoveryFailure("test", testErr2, time.Second)
	metrics.RecordReconciliationAttempt("test")
	metrics.RecordReconciliationSuccess("test", 5, time.Second)
	testErr3 := errors.New("test")
	metrics.RecordReconciliationFailure("test", testErr3, time.Second)
	metrics.RecordAPICall("test", "endpoint")
	metrics.RecordAPISuccess("test", "endpoint", time.Second)
	metrics.RecordAPIFailure("test", "endpoint", 500, time.Second)
	metrics.RecordCircuitBreakerStateChange("test", StateClosed, StateOpen)
	metrics.RecordActiveIntegrations(1)
	metrics.RecordTotalDevicesDiscovered(100)

	data := metrics.GetMetrics()
	assert.Empty(t, data)
}
