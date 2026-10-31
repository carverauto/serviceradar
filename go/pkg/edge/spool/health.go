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

package spool

import "time"

// UnresolvedHealth summarizes records the sender has not yet resolved.
// Bytes is the sum of record bodies. The oldest age comes from UUIDv7 event
// ids: the first 48 bits are a Unix millisecond timestamp and the high nibble
// of byte 6 is version 7. reportAge is true when the spool is empty, and when
// at least one unresolved id is a version-7 timestamp. It is false when
// unresolved records exist and none of those ids carry that timestamp, so a
// caller does not publish a fresh age for an unknown clock.
func UnresolvedHealth(records []Record, now time.Time) (bytes uint64, oldest time.Duration, reportAge bool) {
	var oldestMs int64
	var found bool
	for _, rec := range records {
		bytes += uint64(len(rec.Body))
		ms, ok := uuidV7UnixMilli(rec.EventID)
		if !ok {
			continue
		}
		if !found || ms < oldestMs {
			oldestMs = ms
			found = true
		}
	}
	if len(records) == 0 {
		return 0, 0, true
	}
	if !found {
		return bytes, 0, false
	}
	age := now.Sub(time.UnixMilli(oldestMs))
	if age < 0 {
		age = 0
	}
	return bytes, age, true
}

func uuidV7UnixMilli(id []byte) (int64, bool) {
	if len(id) != 16 || id[6]>>4 != 0x7 {
		return 0, false
	}
	ms := int64(id[0])<<40 |
		int64(id[1])<<32 |
		int64(id[2])<<24 |
		int64(id[3])<<16 |
		int64(id[4])<<8 |
		int64(id[5])
	return ms, true
}
