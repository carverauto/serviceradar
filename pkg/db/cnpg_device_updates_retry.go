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
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// PostgreSQL SQLSTATE codes for transient errors that should be retried.
const (
	sqlstateDeadlockDetected    = "40P01" // Deadlock detected
	sqlstateSerializationFailed = "40001" // Serialization failure
	sqlstateInternalError       = "XX000" // Internal error (used by AGE for lock contention)
	sqlstateStatementTimeout    = "57014" // Statement timeout
)

// Default configuration for device updates retry logic.
const (
	defaultCNPGMaxRetryAttempts   = 3
	defaultCNPGDeadlockBackoffMs  = 500
	defaultCNPGBaseBackoffMs      = 150
	cnpgMaxRetryAttemptsEnv       = "CNPG_MAX_RETRY_ATTEMPTS"
	cnpgDeadlockBackoffMsEnv      = "CNPG_DEADLOCK_BACKOFF_MS"
)

// classifyCNPGError checks if an error is a transient PostgreSQL error that can be retried.
// Returns the SQLSTATE code and a boolean indicating if it's transient.
func classifyCNPGError(err error) (string, bool) {
	if err == nil {
		return "", false
	}

	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		switch pgErr.Code {
		case sqlstateDeadlockDetected, sqlstateSerializationFailed,
			sqlstateInternalError, sqlstateStatementTimeout:
			return pgErr.Code, true
		}
		return pgErr.Code, false
	}

	// Fallback to string matching for wrapped errors
	msg := strings.ToLower(err.Error())
	switch {
	case strings.Contains(msg, "40p01"), strings.Contains(msg, "deadlock detected"):
		return sqlstateDeadlockDetected, true
	case strings.Contains(msg, "40001"), strings.Contains(msg, "could not serialize access"):
		return sqlstateSerializationFailed, true
	case strings.Contains(msg, "xx000"), strings.Contains(msg, "internal error"):
		return sqlstateInternalError, true
	case strings.Contains(msg, "57014"), strings.Contains(msg, "statement timeout"):
		return sqlstateStatementTimeout, true
	default:
		return "", false
	}
}

// cnpgBackoffDelay calculates the backoff duration for a retry attempt.
// Uses exponential backoff with randomized jitter to break lock acquisition synchronization.
func cnpgBackoffDelay(attempt int, sqlstate string) time.Duration {
	if attempt < 1 {
		attempt = 1
	}

	// Use longer base backoff for deadlocks and serialization failures
	var baseBackoff time.Duration
	switch sqlstate {
	case sqlstateDeadlockDetected, sqlstateSerializationFailed:
		baseBackoff = time.Duration(getCNPGDeadlockBackoffMs()) * time.Millisecond
	default:
		baseBackoff = time.Duration(defaultCNPGBaseBackoffMs) * time.Millisecond
	}

	// Exponential backoff: base * 2^(attempt-1)
	backoff := baseBackoff * time.Duration(1<<(attempt-1))

	// Add randomized jitter (0-100% of base) to avoid lockstep retries.
	jitterMax := int64(baseBackoff)
	jitterNanos := time.Now().UnixNano() % jitterMax
	return backoff + time.Duration(jitterNanos)
}

// sendCNPGWithRetry sends a batch with automatic retry for transient errors.
// This should be used for device-related batch operations that may encounter deadlocks.
func (db *DB) sendCNPGWithRetry(ctx context.Context, batch *pgx.Batch, name string) error {
	maxAttempts := getCNPGMaxRetryAttempts()
	var lastErr error

	for attempt := 1; attempt <= maxAttempts; attempt++ {
		if ctx.Err() != nil {
			return ctx.Err()
		}

		err := db.sendCNPGBatch(ctx, batch, name)
		if err == nil {
			if attempt > 1 {
				// Record successful retry
				recordCNPGRetrySuccess(name)
			}
			return nil
		}

		lastErr = err
		code, transient := classifyCNPGError(err)

		// Record error-type-specific metrics
		switch code {
		case sqlstateDeadlockDetected:
			recordCNPGDeadlock(name)
		case sqlstateSerializationFailed:
			recordCNPGSerializationFailure(name)
		}

		if transient && attempt < maxAttempts {
			recordCNPGRetry(name)
			delay := cnpgBackoffDelay(attempt, code)
			db.logger.Warn().
				Err(err).
				Str("sqlstate", code).
				Str("batch_name", name).
				Int("attempt", attempt).
				Int("max_attempts", maxAttempts).
				Dur("backoff", delay).
				Msg("cnpg transient error, retrying")
			time.Sleep(delay)
			continue
		}

		// Non-transient error or max attempts reached
		db.logger.Error().
			Err(err).
			Str("sqlstate", code).
			Str("batch_name", name).
			Int("attempt", attempt).
			Int("max_attempts", maxAttempts).
			Msg("cnpg batch failed")
		return err
	}

	return lastErr
}

// sendCNPGBatch is the low-level batch sender without retry logic.
func (db *DB) sendCNPGBatch(ctx context.Context, batch *pgx.Batch, name string) (err error) {
	br := db.conn().SendBatch(ctx, batch)
	defer func() {
		if closeErr := br.Close(); closeErr != nil && err == nil {
			err = fmt.Errorf("cnpg %s batch close: %w", name, closeErr)
		}
	}()

	for i := 0; i < batch.Len(); i++ {
		if _, err = br.Exec(); err != nil {
			return fmt.Errorf("cnpg %s insert (command %d): %w", name, i, err)
		}
	}

	return nil
}

// getCNPGMaxRetryAttempts returns the configured max retry attempts.
func getCNPGMaxRetryAttempts() int {
	val := strings.TrimSpace(os.Getenv(cnpgMaxRetryAttemptsEnv))
	if val == "" {
		return defaultCNPGMaxRetryAttempts
	}
	parsed, err := strconv.Atoi(val)
	if err != nil || parsed <= 0 {
		return defaultCNPGMaxRetryAttempts
	}
	return parsed
}

// getCNPGDeadlockBackoffMs returns the configured deadlock backoff in milliseconds.
func getCNPGDeadlockBackoffMs() int {
	val := strings.TrimSpace(os.Getenv(cnpgDeadlockBackoffMsEnv))
	if val == "" {
		return defaultCNPGDeadlockBackoffMs
	}
	parsed, err := strconv.Atoi(val)
	if err != nil || parsed <= 0 {
		return defaultCNPGDeadlockBackoffMs
	}
	return parsed
}
