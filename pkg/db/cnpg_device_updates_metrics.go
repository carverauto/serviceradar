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
	"sync/atomic"
)

// Metrics counters for CNPG device updates operations.
// These are exposed as atomic counters for thread-safe access.
//
//nolint:gochecknoglobals // metrics require package-level state
var (
	cnpgDeadlockTotal            int64
	cnpgSerializationFailureTotal int64
	cnpgRetryTotal               int64
	cnpgRetrySuccessTotal        int64
)

// recordCNPGDeadlock increments the deadlock counter for the given batch type.
func recordCNPGDeadlock(batchName string) {
	atomic.AddInt64(&cnpgDeadlockTotal, 1)
	// Future: emit OTel metric with batchName label
	_ = batchName
}

// recordCNPGSerializationFailure increments the serialization failure counter.
func recordCNPGSerializationFailure(batchName string) {
	atomic.AddInt64(&cnpgSerializationFailureTotal, 1)
	_ = batchName
}

// recordCNPGRetry increments the retry counter.
func recordCNPGRetry(batchName string) {
	atomic.AddInt64(&cnpgRetryTotal, 1)
	_ = batchName
}

// recordCNPGRetrySuccess increments the successful retry counter.
func recordCNPGRetrySuccess(batchName string) {
	atomic.AddInt64(&cnpgRetrySuccessTotal, 1)
	_ = batchName
}

// GetCNPGDeadlockTotal returns the current deadlock count.
func GetCNPGDeadlockTotal() int64 {
	return atomic.LoadInt64(&cnpgDeadlockTotal)
}

// GetCNPGSerializationFailureTotal returns the current serialization failure count.
func GetCNPGSerializationFailureTotal() int64 {
	return atomic.LoadInt64(&cnpgSerializationFailureTotal)
}

// GetCNPGRetryTotal returns the current retry count.
func GetCNPGRetryTotal() int64 {
	return atomic.LoadInt64(&cnpgRetryTotal)
}

// GetCNPGRetrySuccessTotal returns the current successful retry count.
func GetCNPGRetrySuccessTotal() int64 {
	return atomic.LoadInt64(&cnpgRetrySuccessTotal)
}
