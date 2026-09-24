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

// Package edgerecord holds the trusted helpers for the producer-neutral edge
// record plane: RFC 9562 UUIDv7 identity, the immutable semantic-envelope
// digest, and fail-closed validation of EdgeRecordV1 / EdgeDeliveryFrameV1. The
// UUIDv7 and digest helpers are carried forward unchanged from the earlier
// edgeframe work; the validation and digest cover the v2 EdgeRecordV1 contract.
package edgerecord

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"math"
	"time"
)

// ErrInvalidUUIDv7 reports that a value is not a structurally valid RFC 9562
// UUIDv7 (wrong length, version, or variant).
var ErrInvalidUUIDv7 = errors.New("edgerecord: value is not a valid RFC 9562 UUIDv7")

// ErrInvalidUUID reports that a value is not a structurally valid canonical RFC
// 9562 UUID of any version (used where identity-time is NOT normative, so a v4
// scheduler/runtime id is legitimate; strict UUIDv7 is reserved for event/trace
// ids whose embedded timestamp is load-bearing).
var ErrInvalidUUID = errors.New("edgerecord: value is not a valid canonical UUID")

// ValidateCanonicalUUID returns nil when b is a 16-byte non-nil canonical UUID
// with a defined version (1-8) and the RFC variant-10 bits. It does NOT require
// version 7.
func ValidateCanonicalUUID(b []byte) error {
	if len(b) != 16 {
		return ErrInvalidUUID
	}
	if v := b[6] >> 4; v < 1 || v > 8 {
		return ErrInvalidUUID
	}
	if b[8]&0xC0 != 0x80 {
		return ErrInvalidUUID
	}
	allZero := true
	for _, x := range b {
		if x != 0 {
			allZero = false
			break
		}
	}
	if allZero {
		return ErrInvalidUUID
	}
	return nil
}

// clock is overridable in tests; production uses the wall clock.
//
//nolint:gochecknoglobals // overridable clock for tests
var clock = time.Now

// NewUUIDv7 returns a fresh 16-byte RFC 9562 UUIDv7: a 48-bit big-endian
// Unix-millisecond timestamp, the version 7 nibble, the variant-10 bits, and
// random remaining bits.
func NewUUIDv7() ([]byte, error) {
	return newUUIDv7At(clock())
}

func newUUIDv7At(now time.Time) ([]byte, error) {
	out := make([]byte, 16)
	if _, err := rand.Read(out[6:]); err != nil {
		return nil, err
	}

	ms := uint64(now.UnixMilli())
	var tsb [8]byte
	binary.BigEndian.PutUint64(tsb[:], ms<<16)
	copy(out[0:6], tsb[0:6])

	out[6] = (out[6] & 0x0F) | 0x70 // version 7
	out[8] = (out[8] & 0x3F) | 0x80 // variant 10
	return out, nil
}

// ValidateUUIDv7 returns nil when b is a structurally valid UUIDv7.
func ValidateUUIDv7(b []byte) error {
	if len(b) != 16 {
		return ErrInvalidUUIDv7
	}
	if b[6]&0xF0 != 0x70 {
		return ErrInvalidUUIDv7
	}
	if b[8]&0xC0 != 0x80 {
		return ErrInvalidUUIDv7
	}
	return nil
}

// ErrUUIDv7TimeRange reports that a structurally valid UUIDv7 carries a
// millisecond timestamp that cannot be expressed as Unix NANOSECONDS in an
// int64. This is reachable from valid input, not a corruption signal: RFC 9562
// gives the timestamp 48 bits (up to 281474976710655 ms), while int64 nanos top
// out near 9223372036854 ms -- so roughly 97% of the encodable range overflows.
var ErrUUIDv7TimeRange = errors.New("edgerecord: UUIDv7 timestamp is out of int64 nanosecond range")

// maxUUIDv7Millis is the largest millisecond timestamp convertible to int64
// nanoseconds without overflow.
const maxUUIDv7Millis = math.MaxInt64 / nanosPerMilli

const nanosPerMilli = 1_000_000

// UUIDv7Nanos extracts a UUIDv7's embedded timestamp as Unix NANOSECONDS, with
// the millisecond-to-nanosecond conversion CHECKED.
//
// Every site that compares a UUIDv7 identity time against a signed window MUST
// use this rather than multiplying UUIDv7Millis itself. An unchecked `ms * 1e6`
// wraps: a far-future identity becomes a small or negative nanosecond value that
// can land INSIDE the window it should have been refused by, turning an identity
// forgery into an accepted record. The conversion is one helper precisely so a
// call site cannot silently opt out of the check.
func UUIDv7Nanos(b []byte) (int64, error) {
	ms, err := UUIDv7Millis(b)
	if err != nil {
		return 0, err
	}
	// ms is decoded from 48 unsigned bits, so it is never negative; only the
	// upper bound is reachable.
	if ms > maxUUIDv7Millis {
		return 0, ErrUUIDv7TimeRange
	}
	return ms * nanosPerMilli, nil
}

// UUIDv7Millis extracts the embedded 48-bit Unix-millisecond timestamp. It does
// not validate the version/variant; call ValidateUUIDv7 first for untrusted
// input. Callers comparing against a time window MUST use UUIDv7Nanos instead.
func UUIDv7Millis(b []byte) (int64, error) {
	if len(b) != 16 {
		return 0, ErrInvalidUUIDv7
	}
	var tsb [8]byte
	copy(tsb[0:6], b[0:6])
	return int64(binary.BigEndian.Uint64(tsb[:]) >> 16), nil
}
