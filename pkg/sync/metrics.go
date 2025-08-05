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
	"net/http"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
)

// Metrics defines the interface for collecting sync service metrics
type Metrics interface {
	// Integration metrics
	RecordDiscoveryAttempt(source string)
	RecordDiscoverySuccess(source string, deviceCount int, duration time.Duration)
	RecordDiscoveryFailure(source string, err error, duration time.Duration)
	RecordReconciliationAttempt(source string)
	RecordReconciliationSuccess(source string, updateCount int, duration time.Duration)
	RecordReconciliationFailure(source string, err error, duration time.Duration)

	// API metrics
	RecordAPICall(integration, endpoint string)
	RecordAPISuccess(integration, endpoint string, duration time.Duration)
	RecordAPIFailure(integration, endpoint string, statusCode int, duration time.Duration)

	// Circuit breaker metrics
	RecordCircuitBreakerStateChange(name string, oldState, newState CircuitBreakerState)

	// General service metrics
	RecordActiveIntegrations(count int)
	RecordTotalDevicesDiscovered(count int)

	// Export metrics for monitoring systems
	GetMetrics() map[string]interface{}
}

// NoOpMetrics provides a no-op implementation of the Metrics interface
type NoOpMetrics struct{}

func (n *NoOpMetrics) RecordDiscoveryAttempt(source string) {}
func (n *NoOpMetrics) RecordDiscoverySuccess(source string, deviceCount int, duration time.Duration) {
}
func (n *NoOpMetrics) RecordDiscoveryFailure(source string, err error, duration time.Duration) {}
func (n *NoOpMetrics) RecordReconciliationAttempt(source string)                               {}
func (n *NoOpMetrics) RecordReconciliationSuccess(source string, updateCount int, duration time.Duration) {
}
func (n *NoOpMetrics) RecordReconciliationFailure(source string, err error, duration time.Duration) {}
func (n *NoOpMetrics) RecordAPICall(integration, endpoint string)                                   {}
func (n *NoOpMetrics) RecordAPISuccess(integration, endpoint string, duration time.Duration)        {}
func (n *NoOpMetrics) RecordAPIFailure(integration, endpoint string, statusCode int, duration time.Duration) {
}
func (n *NoOpMetrics) RecordCircuitBreakerStateChange(name string, oldState, newState CircuitBreakerState) {
}
func (n *NoOpMetrics) RecordActiveIntegrations(count int)     {}
func (n *NoOpMetrics) RecordTotalDevicesDiscovered(count int) {}
func (n *NoOpMetrics) GetMetrics() map[string]interface{}     { return map[string]interface{}{} }

// InMemoryMetrics provides an in-memory implementation of the Metrics interface
type InMemoryMetrics struct {
	mu     sync.RWMutex
	logger logger.Logger

	// Discovery metrics
	discoveryAttempts map[string]int
	discoverySuccess  map[string]int
	discoveryFailures map[string]int
	discoveryDuration map[string]time.Duration
	devicesDiscovered map[string]int

	// Reconciliation metrics
	reconciliationAttempts map[string]int
	reconciliationSuccess  map[string]int
	reconciliationFailures map[string]int
	reconciliationDuration map[string]time.Duration
	reconciliationUpdates  map[string]int

	// API metrics
	apiCalls    map[string]int
	apiSuccess  map[string]int
	apiFailures map[string]int
	apiDuration map[string]time.Duration

	// Circuit breaker metrics
	circuitBreakerStates map[string]string

	// General metrics
	activeIntegrations     int
	totalDevicesDiscovered int
	lastUpdated            time.Time
}

// NewInMemoryMetrics creates a new in-memory metrics collector
func NewInMemoryMetrics(log logger.Logger) *InMemoryMetrics {
	return &InMemoryMetrics{
		logger:                 log,
		discoveryAttempts:      make(map[string]int),
		discoverySuccess:       make(map[string]int),
		discoveryFailures:      make(map[string]int),
		discoveryDuration:      make(map[string]time.Duration),
		devicesDiscovered:      make(map[string]int),
		reconciliationAttempts: make(map[string]int),
		reconciliationSuccess:  make(map[string]int),
		reconciliationFailures: make(map[string]int),
		reconciliationDuration: make(map[string]time.Duration),
		reconciliationUpdates:  make(map[string]int),
		apiCalls:               make(map[string]int),
		apiSuccess:             make(map[string]int),
		apiFailures:            make(map[string]int),
		apiDuration:            make(map[string]time.Duration),
		circuitBreakerStates:   make(map[string]string),
		lastUpdated:            time.Now(),
	}
}

func (m *InMemoryMetrics) RecordDiscoveryAttempt(source string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.discoveryAttempts[source]++
	m.lastUpdated = time.Now()
}

func (m *InMemoryMetrics) RecordDiscoverySuccess(source string, deviceCount int, duration time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.discoverySuccess[source]++
	m.discoveryDuration[source] = duration
	m.devicesDiscovered[source] = deviceCount
	m.lastUpdated = time.Now()

	m.logger.Info().
		Str("source", source).
		Int("device_count", deviceCount).
		Dur("duration", duration).
		Msg("Discovery completed successfully")
}

func (m *InMemoryMetrics) RecordDiscoveryFailure(source string, err error, duration time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.discoveryFailures[source]++
	m.discoveryDuration[source] = duration
	m.lastUpdated = time.Now()

	m.logger.Error().
		Str("source", source).
		Err(err).
		Dur("duration", duration).
		Msg("Discovery failed")
}

func (m *InMemoryMetrics) RecordReconciliationAttempt(source string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.reconciliationAttempts[source]++
	m.lastUpdated = time.Now()
}

func (m *InMemoryMetrics) RecordReconciliationSuccess(source string, updateCount int, duration time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.reconciliationSuccess[source]++
	m.reconciliationDuration[source] = duration
	m.reconciliationUpdates[source] = updateCount
	m.lastUpdated = time.Now()

	m.logger.Info().
		Str("source", source).
		Int("update_count", updateCount).
		Dur("duration", duration).
		Msg("Reconciliation completed successfully")
}

func (m *InMemoryMetrics) RecordReconciliationFailure(source string, err error, duration time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.reconciliationFailures[source]++
	m.reconciliationDuration[source] = duration
	m.lastUpdated = time.Now()

	m.logger.Error().
		Str("source", source).
		Err(err).
		Dur("duration", duration).
		Msg("Reconciliation failed")
}

func (m *InMemoryMetrics) RecordAPICall(integration, endpoint string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := integration + ":" + endpoint
	m.apiCalls[key]++
	m.lastUpdated = time.Now()
}

func (m *InMemoryMetrics) RecordAPISuccess(integration, endpoint string, duration time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := integration + ":" + endpoint
	m.apiSuccess[key]++
	m.apiDuration[key] = duration
	m.lastUpdated = time.Now()
}

func (m *InMemoryMetrics) RecordAPIFailure(integration, endpoint string, statusCode int, duration time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := integration + ":" + endpoint
	m.apiFailures[key]++
	m.apiDuration[key] = duration
	m.lastUpdated = time.Now()

	m.logger.Warn().
		Str("integration", integration).
		Str("endpoint", endpoint).
		Int("status_code", statusCode).
		Dur("duration", duration).
		Msg("API call failed")
}

func (m *InMemoryMetrics) RecordCircuitBreakerStateChange(name string, oldState, newState CircuitBreakerState) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.circuitBreakerStates[name] = newState.String()
	m.lastUpdated = time.Now()

	m.logger.Info().
		Str("circuit_breaker", name).
		Str("old_state", oldState.String()).
		Str("new_state", newState.String()).
		Msg("Circuit breaker state changed")
}

func (m *InMemoryMetrics) RecordActiveIntegrations(count int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.activeIntegrations = count
	m.lastUpdated = time.Now()
}

func (m *InMemoryMetrics) RecordTotalDevicesDiscovered(count int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.totalDevicesDiscovered = count
	m.lastUpdated = time.Now()
}

func (m *InMemoryMetrics) GetMetrics() map[string]interface{} {
	m.mu.RLock()
	defer m.mu.RUnlock()

	return map[string]interface{}{
		"discovery": map[string]interface{}{
			"attempts":          m.discoveryAttempts,
			"successes":         m.discoverySuccess,
			"failures":          m.discoveryFailures,
			"durations":         m.discoveryDuration,
			"devices_by_source": m.devicesDiscovered,
		},
		"reconciliation": map[string]interface{}{
			"attempts":  m.reconciliationAttempts,
			"successes": m.reconciliationSuccess,
			"failures":  m.reconciliationFailures,
			"durations": m.reconciliationDuration,
			"updates":   m.reconciliationUpdates,
		},
		"api": map[string]interface{}{
			"calls":     m.apiCalls,
			"successes": m.apiSuccess,
			"failures":  m.apiFailures,
			"durations": m.apiDuration,
		},
		"circuit_breakers": m.circuitBreakerStates,
		"service": map[string]interface{}{
			"active_integrations":      m.activeIntegrations,
			"total_devices_discovered": m.totalDevicesDiscovered,
			"last_updated":             m.lastUpdated,
		},
	}
}

// MetricsHTTPClient wraps an HTTP client to collect API metrics
type MetricsHTTPClient struct {
	client      HTTPClient
	metrics     Metrics
	integration string
}

// NewMetricsHTTPClient creates a new HTTP client wrapper that collects metrics
func NewMetricsHTTPClient(client HTTPClient, integration string, metrics Metrics) *MetricsHTTPClient {
	return &MetricsHTTPClient{
		client:      client,
		metrics:     metrics,
		integration: integration,
	}
}

// Do executes an HTTP request and records metrics
func (m *MetricsHTTPClient) Do(req *http.Request) (*http.Response, error) {
	endpoint := req.URL.Path
	if endpoint == "" {
		endpoint = req.URL.String()
	}

	start := time.Now()
	m.metrics.RecordAPICall(m.integration, endpoint)

	resp, err := m.client.Do(req)
	duration := time.Since(start)

	if err != nil {
		m.metrics.RecordAPIFailure(m.integration, endpoint, 0, duration)
		return resp, err
	}

	if resp.StatusCode >= 400 {
		m.metrics.RecordAPIFailure(m.integration, endpoint, resp.StatusCode, duration)
	} else {
		m.metrics.RecordAPISuccess(m.integration, endpoint, duration)
	}

	return resp, err
}
