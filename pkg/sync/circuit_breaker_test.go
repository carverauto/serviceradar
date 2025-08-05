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
	"errors"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCircuitBreaker_BasicFunctionality(t *testing.T) {
	config := CircuitBreakerConfig{
		FailureThreshold: 2,
		SuccessThreshold: 1,
		Timeout:          100 * time.Millisecond,
		ResetTimeout:     200 * time.Millisecond,
	}

	log := logger.NewTestLogger()
	cb := NewCircuitBreaker("test", config, log)

	// Initially closed and working
	assert.Equal(t, StateClosed, cb.GetState())

	// Successful calls should keep it closed
	err := cb.Execute(context.Background(), func() error { return nil })
	require.NoError(t, err)
	assert.Equal(t, StateClosed, cb.GetState())

	// First failure
	err = cb.Execute(context.Background(), func() error { return errors.New("test error") })
	require.Error(t, err)
	assert.Equal(t, StateClosed, cb.GetState())

	// Second failure should open the circuit
	err = cb.Execute(context.Background(), func() error { return errors.New("test error") })
	require.Error(t, err)
	assert.Equal(t, StateOpen, cb.GetState())

	// Subsequent calls should be rejected
	err = cb.Execute(context.Background(), func() error { return nil })
	require.Error(t, err)
	assert.Contains(t, err.Error(), "circuit breaker test is open")

	// Wait for timeout to transition to half-open
	time.Sleep(150 * time.Millisecond)

	// Should allow one call in half-open state
	err = cb.Execute(context.Background(), func() error { return nil })
	require.NoError(t, err)
	assert.Equal(t, StateClosed, cb.GetState()) // Should close after successful call
}

func TestCircuitBreaker_GetMetrics(t *testing.T) {
	config := DefaultCircuitBreakerConfig()
	log := logger.NewTestLogger()
	cb := NewCircuitBreaker("test-metrics", config, log)

	metrics := cb.GetMetrics()
	require.NotNil(t, metrics)

	assert.Equal(t, "test-metrics", metrics["name"])
	assert.Equal(t, "closed", metrics["state"])
	assert.Equal(t, 0, metrics["failure_count"])
	assert.Equal(t, 0, metrics["success_count"])
}

func TestDefaultCircuitBreakerConfig(t *testing.T) {
	config := DefaultCircuitBreakerConfig()

	assert.Equal(t, 5, config.FailureThreshold)
	assert.Equal(t, 2, config.SuccessThreshold)
	assert.Equal(t, 30*time.Second, config.Timeout)
	assert.Equal(t, 60*time.Second, config.ResetTimeout)
}

func TestCircuitBreakerState_String(t *testing.T) {
	assert.Equal(t, "closed", StateClosed.String())
	assert.Equal(t, "open", StateOpen.String())
	assert.Equal(t, "half-open", StateHalfOpen.String())
}
