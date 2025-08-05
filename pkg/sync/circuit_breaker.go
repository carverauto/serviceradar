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
	"context"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
)

// CircuitBreakerState represents the current state of the circuit breaker
type CircuitBreakerState int

const (
	// StateClosed - Circuit is closed, requests are allowed
	StateClosed CircuitBreakerState = iota
	// StateOpen - Circuit is open, requests are rejected
	StateOpen
	// StateHalfOpen - Circuit is testing if the service has recovered
	StateHalfOpen
)

// CircuitBreakerConfig holds configuration for the circuit breaker
type CircuitBreakerConfig struct {
	// FailureThreshold is the number of failures before opening the circuit
	FailureThreshold int
	// SuccessThreshold is the number of successes needed to close the circuit from half-open
	SuccessThreshold int
	// Timeout is how long to wait before transitioning from open to half-open
	Timeout time.Duration
	// ResetTimeout is how long to wait before resetting failure counts in closed state
	ResetTimeout time.Duration
}

// DefaultCircuitBreakerConfig returns a sensible default configuration
func DefaultCircuitBreakerConfig() CircuitBreakerConfig {
	return CircuitBreakerConfig{
		FailureThreshold: 5,
		SuccessThreshold: 2,
		Timeout:          30 * time.Second,
		ResetTimeout:     60 * time.Second,
	}
}

// CircuitBreaker implements a circuit breaker pattern for HTTP clients
type CircuitBreaker struct {
	config        CircuitBreakerConfig
	state         CircuitBreakerState
	failureCount  int
	successCount  int
	lastFailTime  time.Time
	lastResetTime time.Time
	mu            sync.RWMutex
	logger        logger.Logger
	name          string // Name for logging/identification
}

// NewCircuitBreaker creates a new circuit breaker with the given configuration
func NewCircuitBreaker(name string, config CircuitBreakerConfig, log logger.Logger) *CircuitBreaker {
	return &CircuitBreaker{
		config:        config,
		state:         StateClosed,
		lastResetTime: time.Now(),
		logger:        log,
		name:          name,
	}
}

// Execute executes a function call through the circuit breaker
func (cb *CircuitBreaker) Execute(ctx context.Context, fn func() error) error {
	if !cb.allowRequest() {
		return fmt.Errorf("circuit breaker %s is open", cb.name)
	}

	err := fn()
	cb.recordResult(err)
	return err
}

// allowRequest checks if a request should be allowed based on circuit breaker state
func (cb *CircuitBreaker) allowRequest() bool {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	now := time.Now()

	switch cb.state {
	case StateClosed:
		// Reset failure count if enough time has passed
		if now.Sub(cb.lastResetTime) >= cb.config.ResetTimeout {
			cb.failureCount = 0
			cb.lastResetTime = now
		}
		return true

	case StateOpen:
		// Transition to half-open if timeout has passed
		if now.Sub(cb.lastFailTime) >= cb.config.Timeout {
			cb.state = StateHalfOpen
			cb.successCount = 0
			cb.logger.Info().
				Str("circuit_breaker", cb.name).
				Msg("Circuit breaker transitioning to half-open")
			return true
		}
		return false

	case StateHalfOpen:
		return true

	default:
		return false
	}
}

// recordResult records the result of a request and updates circuit breaker state
func (cb *CircuitBreaker) recordResult(err error) {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	if err != nil {
		cb.onFailure()
	} else {
		cb.onSuccess()
	}
}

// onFailure handles a failed request
func (cb *CircuitBreaker) onFailure() {
	cb.failureCount++
	cb.lastFailTime = time.Now()

	switch cb.state {
	case StateClosed:
		if cb.failureCount >= cb.config.FailureThreshold {
			cb.state = StateOpen
			cb.logger.Warn().
				Str("circuit_breaker", cb.name).
				Int("failure_count", cb.failureCount).
				Msg("Circuit breaker opened due to failures")
		}

	case StateHalfOpen:
		cb.state = StateOpen
		cb.logger.Warn().
			Str("circuit_breaker", cb.name).
			Msg("Circuit breaker reopened after failed attempt in half-open state")
	}
}

// onSuccess handles a successful request
func (cb *CircuitBreaker) onSuccess() {
	switch cb.state {
	case StateHalfOpen:
		cb.successCount++
		if cb.successCount >= cb.config.SuccessThreshold {
			cb.state = StateClosed
			cb.failureCount = 0
			cb.lastResetTime = time.Now()
			cb.logger.Info().
				Str("circuit_breaker", cb.name).
				Msg("Circuit breaker closed after successful recovery")
		}

	case StateClosed:
		// Reset failure count on success
		cb.failureCount = 0
		cb.lastResetTime = time.Now()
	}
}

// GetState returns the current state of the circuit breaker
func (cb *CircuitBreaker) GetState() CircuitBreakerState {
	cb.mu.RLock()
	defer cb.mu.RUnlock()
	return cb.state
}

// GetMetrics returns current metrics for monitoring
func (cb *CircuitBreaker) GetMetrics() map[string]interface{} {
	cb.mu.RLock()
	defer cb.mu.RUnlock()

	return map[string]interface{}{
		"name":          cb.name,
		"state":         cb.state.String(),
		"failure_count": cb.failureCount,
		"success_count": cb.successCount,
		"last_failure":  cb.lastFailTime,
		"last_reset":    cb.lastResetTime,
	}
}

// String returns a string representation of the circuit breaker state
func (s CircuitBreakerState) String() string {
	switch s {
	case StateClosed:
		return "closed"
	case StateOpen:
		return "open"
	case StateHalfOpen:
		return "half-open"
	default:
		return "unknown"
	}
}

// CircuitBreakerHTTPClient wraps an HTTP client with circuit breaker functionality
type CircuitBreakerHTTPClient struct {
	client         HTTPClient
	circuitBreaker *CircuitBreaker
}

// NewCircuitBreakerHTTPClient creates a new HTTP client wrapper with circuit breaker
func NewCircuitBreakerHTTPClient(client HTTPClient, name string, config CircuitBreakerConfig, log logger.Logger) *CircuitBreakerHTTPClient {
	return &CircuitBreakerHTTPClient{
		client:         client,
		circuitBreaker: NewCircuitBreaker(name, config, log),
	}
}

// Do executes an HTTP request through the circuit breaker
func (c *CircuitBreakerHTTPClient) Do(req *http.Request) (*http.Response, error) {
	var resp *http.Response
	var err error

	execErr := c.circuitBreaker.Execute(req.Context(), func() error {
		resp, err = c.client.Do(req)

		// Consider HTTP 5xx errors and network errors as failures
		if err != nil {
			return err
		}

		if resp.StatusCode >= 500 {
			return fmt.Errorf("server error: %d", resp.StatusCode)
		}

		return nil
	})

	if execErr != nil {
		return nil, execErr
	}

	return resp, err
}

// GetCircuitBreaker returns the underlying circuit breaker for metrics/monitoring
func (c *CircuitBreakerHTTPClient) GetCircuitBreaker() *CircuitBreaker {
	return c.circuitBreaker
}
