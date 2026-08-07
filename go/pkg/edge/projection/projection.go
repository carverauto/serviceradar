/*
 * Copyright 2026 Carver Automation Corporation.
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

// Package projection is the EventWriter-side projection core (tasks 5.x, 1.5):
// the pure functions that turn a decoded observation/trace batch into the
// database facts the consumer will write idempotently.
//
//   - CanonicalMicros canonicalizes nanoseconds to PostgreSQL microseconds for
//     PROJECTION-DOMAIN STORAGE AND ORDERING COORDINATES ONLY (task 1.5-c). It is
//     never applied before a contract hash or a contract-identity comparison:
//     payload_sha256 covers the exact carried bytes and semantic_envelope_sha256
//     covers a transcript committing the RAW nanosecond values.
//   - SweepRows / MtrRows are the single source of truth for the projected row
//     count -- every synchronous row a batch produces, including per-check
//     port_errors and MTR summary/hop rows. The agent's projected_row_count and
//     the consumer's actual insert count MUST use the same rule so admission and
//     write cost agree.
//   - RowKey derives a stable per-row idempotency key from the frame's immutable
//     semantic digest and the row ordinal, so re-projecting a redelivered frame
//     upserts the same rows instead of duplicating them.
package projection

import (
	"crypto/sha256"
	"encoding/binary"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// MicrosPerNano is the PostgreSQL microsecond resolution (1 us == 1000 ns).
const nanosPerMicro = 1000

// CanonicalMicros names the microsecond bucket CONTAINING the instant, which is the
// invariant `u*1000 <= ns < (u+1)*1000` (mathematical, in widened arithmetic -- near the
// extremes of int64 both bounds overflow the type).
//
// FLOOR, NOT TRUNCATION TOWARD ZERO, and the reason is that invariant rather than
// monotonicity: both are monotonic, so monotonicity cannot distinguish them. Truncation
// satisfies the invariant only for non-negative inputs -- -1500ns truncates to -1us, whose
// bucket [-1000, 0) does not contain -1500 -- so a coordinate built from it names a bucket
// its own instant is not in.
//
// IT FORMS NO UNREPRESENTABLE POSITIVE MAGNITUDE. The previous implementation negated the
// operand to reuse a positive-domain division, which fails across [MinInt64, MinInt64+999]
// for two distinct reasons: at exactly MinInt64 the negation itself wraps, and for
// MinInt64+1..+999 the negation is representable but the +999 bias wraps. Either way the
// result came back POSITIVE -- a sign flip, not a rounding error -- so an ordering
// coordinate built on it sorted the earliest instants as the latest. Adjusting the quotient
// after a direct signed division never forms that intermediate.
func CanonicalMicros(unixNanos int64) int64 {
	q := unixNanos / nanosPerMicro
	if unixNanos%nanosPerMicro != 0 && unixNanos < 0 {
		q--
	}

	return q
}

// SweepHostRows returns the number of synchronous database rows one host
// observation projects: one reachability row, one per open port, one per port
// error, and one MTR-summary row when present.
func SweepHostRows(h *edgev1.SweepHostObservationV1) int {
	rows := 1
	rows += len(h.GetOpenPorts())
	rows += len(h.GetPortErrors())
	if h.GetMtr() != nil {
		rows++
	}
	return rows
}

// SweepRows returns the total projected rows for a sweep observation batch.
func SweepRows(b *edgev1.SweepObservationBatchV1) int {
	total := 0
	for _, h := range b.GetHosts() {
		total += SweepHostRows(h)
	}
	return total
}

// MtrTraceRows returns the projected rows for one MTR trace: one trace row plus
// one row per hop.
func MtrTraceRows(t *edgev1.MtrTraceEventV1) int {
	return 1 + len(t.GetHops())
}

// MtrRows returns the total projected rows for an MTR trace batch.
func MtrRows(b *edgev1.MtrTraceBatchV1) int {
	total := 0
	for _, tr := range b.GetTraces() {
		total += MtrTraceRows(tr)
	}
	return total
}

// RowKey derives a stable idempotency key for the row at ordinal within a frame
// whose immutable semantic digest is semanticDigest. Re-projecting the same
// durable frame yields identical keys, so a redelivery upserts rather than
// duplicating. Distinct frames (distinct digests) and distinct ordinals yield
// distinct keys.
func RowKey(semanticDigest []byte, ordinal int) []byte {
	h := sha256.New()
	var num [8]byte
	binary.BigEndian.PutUint64(num[:], uint64(len(semanticDigest)))
	_, _ = h.Write(num[:])
	_, _ = h.Write(semanticDigest)
	binary.BigEndian.PutUint64(num[:], uint64(ordinal))
	_, _ = h.Write(num[:])
	return h.Sum(nil)
}
