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

package db

import (
	"fmt"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/stretchr/testify/assert"
)

// Static test errors for err113 compliance.
var (
	errTestDeadlock      = fmt.Errorf("ERROR: deadlock detected (SQLSTATE 40P01)")
	errTestSerialization = fmt.Errorf("could not serialize access due to concurrent update")
	errTestInternal      = fmt.Errorf("XX000: internal error occurred")
	errTestTimeout       = fmt.Errorf("statement timeout")
	errTestUnknown       = fmt.Errorf("some random database error")
)

func TestClassifyCNPGError_NilError(t *testing.T) {
	code, transient := classifyCNPGError(nil)
	assert.Empty(t, code)
	assert.False(t, transient)
}

func TestClassifyCNPGError_DeadlockPgError(t *testing.T) {
	pgErr := &pgconn.PgError{Code: "40P01"}
	code, transient := classifyCNPGError(pgErr)
	assert.Equal(t, sqlstateDeadlockDetected, code)
	assert.True(t, transient)
}

func TestClassifyCNPGError_SerializationFailurePgError(t *testing.T) {
	pgErr := &pgconn.PgError{Code: "40001"}
	code, transient := classifyCNPGError(pgErr)
	assert.Equal(t, sqlstateSerializationFailed, code)
	assert.True(t, transient)
}

func TestClassifyCNPGError_InternalErrorPgError(t *testing.T) {
	pgErr := &pgconn.PgError{Code: "XX000"}
	code, transient := classifyCNPGError(pgErr)
	assert.Equal(t, sqlstateInternalError, code)
	assert.True(t, transient)
}

func TestClassifyCNPGError_StatementTimeoutPgError(t *testing.T) {
	pgErr := &pgconn.PgError{Code: "57014"}
	code, transient := classifyCNPGError(pgErr)
	assert.Equal(t, sqlstateStatementTimeout, code)
	assert.True(t, transient)
}

func TestClassifyCNPGError_NonTransientPgError(t *testing.T) {
	pgErr := &pgconn.PgError{Code: "23505"} // unique_violation
	code, transient := classifyCNPGError(pgErr)
	assert.Equal(t, "23505", code)
	assert.False(t, transient)
}

func TestClassifyCNPGError_WrappedDeadlockError(t *testing.T) {
	code, transient := classifyCNPGError(errTestDeadlock)
	assert.Equal(t, sqlstateDeadlockDetected, code)
	assert.True(t, transient)
}

func TestClassifyCNPGError_WrappedSerializationError(t *testing.T) {
	code, transient := classifyCNPGError(errTestSerialization)
	assert.Equal(t, sqlstateSerializationFailed, code)
	assert.True(t, transient)
}

func TestClassifyCNPGError_WrappedInternalError(t *testing.T) {
	code, transient := classifyCNPGError(errTestInternal)
	assert.Equal(t, sqlstateInternalError, code)
	assert.True(t, transient)
}

func TestClassifyCNPGError_WrappedStatementTimeout(t *testing.T) {
	code, transient := classifyCNPGError(errTestTimeout)
	assert.Equal(t, sqlstateStatementTimeout, code)
	assert.True(t, transient)
}

func TestClassifyCNPGError_UnknownError(t *testing.T) {
	code, transient := classifyCNPGError(errTestUnknown)
	assert.Empty(t, code)
	assert.False(t, transient)
}

func TestCNPGBackoffDelay_DeadlockUsesLongerBackoff(t *testing.T) {
	// Test that deadlock errors use longer backoff than other errors
	deadlockDelay := cnpgBackoffDelay(1, sqlstateDeadlockDetected)
	regularDelay := cnpgBackoffDelay(1, sqlstateInternalError)

	// Deadlock backoff should be significantly longer
	// defaultCNPGDeadlockBackoffMs = 500, defaultCNPGBaseBackoffMs = 150
	// With jitter, deadlock should be >= 500ms, regular should be >= 150ms
	assert.GreaterOrEqual(t, deadlockDelay.Milliseconds(), int64(500))
	assert.GreaterOrEqual(t, regularDelay.Milliseconds(), int64(150))
	assert.Less(t, regularDelay.Milliseconds(), int64(500))
}

func TestCNPGBackoffDelay_ExponentialGrowth(t *testing.T) {
	// Test that backoff grows exponentially
	delay1 := cnpgBackoffDelay(1, sqlstateInternalError)
	delay2 := cnpgBackoffDelay(2, sqlstateInternalError)
	delay3 := cnpgBackoffDelay(3, sqlstateInternalError)

	// Each subsequent delay should be roughly double (accounting for jitter)
	// Delay 2 should be >= 2x base, Delay 3 should be >= 4x base
	baseMs := int64(defaultCNPGBaseBackoffMs)
	assert.GreaterOrEqual(t, delay1.Milliseconds(), baseMs)
	assert.GreaterOrEqual(t, delay2.Milliseconds(), baseMs*2)
	assert.GreaterOrEqual(t, delay3.Milliseconds(), baseMs*4)
}

func TestCNPGBackoffDelay_ZeroAttemptTreatedAsOne(t *testing.T) {
	// Test that attempt < 1 is treated as attempt = 1
	delay0 := cnpgBackoffDelay(0, sqlstateInternalError)
	delay1 := cnpgBackoffDelay(1, sqlstateInternalError)

	// Both should produce delays in the same range (base + jitter)
	baseMs := int64(defaultCNPGBaseBackoffMs)
	maxJitter := baseMs * 2 // jitter can add up to 100% of base

	assert.GreaterOrEqual(t, delay0.Milliseconds(), baseMs)
	assert.LessOrEqual(t, delay0.Milliseconds(), maxJitter)
	assert.GreaterOrEqual(t, delay1.Milliseconds(), baseMs)
	assert.LessOrEqual(t, delay1.Milliseconds(), maxJitter)
}

func TestCNPGBackoffDelay_IncludesJitter(t *testing.T) {
	// Run multiple times and verify we get different values (jitter is working)
	delays := make(map[int64]struct{})
	for i := 0; i < 10; i++ {
		delay := cnpgBackoffDelay(1, sqlstateDeadlockDetected)
		delays[delay.Nanoseconds()] = struct{}{}
		time.Sleep(time.Nanosecond) // Ensure different timestamps
	}

	// With jitter, we should see multiple unique delay values
	// This test may occasionally fail if all 10 happen to hit the same jitter
	// but that's extremely unlikely
	assert.Greater(t, len(delays), 1, "Expected jitter to produce varied delays")
}

func TestGetCNPGMaxRetryAttempts_Default(t *testing.T) {
	// Without env var, should return default
	attempts := getCNPGMaxRetryAttempts()
	assert.Equal(t, defaultCNPGMaxRetryAttempts, attempts)
}

func TestGetCNPGDeadlockBackoffMs_Default(t *testing.T) {
	// Without env var, should return default
	backoff := getCNPGDeadlockBackoffMs()
	assert.Equal(t, defaultCNPGDeadlockBackoffMs, backoff)
}
