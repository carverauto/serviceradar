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

package edgeframe

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"time"
)

// UUIDv7 identifiers are used for every v1 semantic event ID, trace ID, and
// spool ID in the edge data plane. Their embedded millisecond timestamp selects
// the metadata-retirement partition, so the encoding must be a valid RFC 9562
// UUIDv7 (version nibble 7, variant 10) with a monotonic time field.

// ErrInvalidUUIDv7 reports that a value is not a structurally valid RFC 9562
// UUIDv7 (wrong length, version, or variant).
var ErrInvalidUUIDv7 = errors.New("edgeframe: value is not a valid RFC 9562 UUIDv7")

// clock is overridable in tests; production uses the wall clock.
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
	// 48-bit big-endian timestamp in bytes 0..5.
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

// UUIDv7Millis extracts the embedded 48-bit Unix-millisecond timestamp. It does
// not validate the version/variant; call ValidateUUIDv7 first when the input is
// untrusted.
func UUIDv7Millis(b []byte) (int64, error) {
	if len(b) != 16 {
		return 0, ErrInvalidUUIDv7
	}
	var tsb [8]byte
	copy(tsb[0:6], b[0:6])
	return int64(binary.BigEndian.Uint64(tsb[:]) >> 16), nil
}
