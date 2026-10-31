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

import (
	"testing"
	"time"
)

func TestUnresolvedHealthUsesOldestUUIDv7AndBodyBytes(t *testing.T) {
	now := time.UnixMilli(1_700_000_000_000)
	older := now.Add(-90 * time.Second)
	newer := now.Add(-10 * time.Second)

	bytes, age, reportAge := UnresolvedHealth([]Record{
		{EventID: uuidV7At(uint64(newer.UnixMilli())), Body: []byte("ab")},
		{EventID: uuidV7At(uint64(older.UnixMilli())), Body: []byte("cdef")},
		{EventID: []byte{1, 2, 3}, Body: []byte("z")},
	}, now)

	if bytes != 7 {
		t.Fatalf("bytes = %d, want 7", bytes)
	}
	if !reportAge {
		t.Fatal("reportAge = false, want true")
	}
	if age != 90*time.Second {
		t.Fatalf("age = %s, want 90s", age)
	}
}

func TestUnresolvedHealthEmptySpoolReportsZeroAge(t *testing.T) {
	bytes, age, reportAge := UnresolvedHealth(nil, time.UnixMilli(1_700_000_000_000))
	if bytes != 0 || age != 0 || !reportAge {
		t.Fatalf("empty health = (%d, %s, %v)", bytes, age, reportAge)
	}
}

func TestUnresolvedHealthOmitsAgeWhenNoVersion7(t *testing.T) {
	id := uuidV7At(1_700_000_000_000)
	id[6] = 0x40
	bytes, age, reportAge := UnresolvedHealth([]Record{{EventID: id, Body: []byte("body")}}, time.UnixMilli(1_700_000_090_000))
	if bytes != 4 || age != 0 || reportAge {
		t.Fatalf("non-v7 health = (%d, %s, %v)", bytes, age, reportAge)
	}
}

func TestUnresolvedHealthClampsAFutureEventToZero(t *testing.T) {
	now := time.UnixMilli(1_700_000_000_000)
	future := now.Add(30 * time.Second)
	_, age, reportAge := UnresolvedHealth([]Record{{EventID: uuidV7At(uint64(future.UnixMilli())), Body: []byte("x")}}, now)
	if !reportAge || age != 0 {
		t.Fatalf("future health age = %s report=%v", age, reportAge)
	}
}

func uuidV7At(ms uint64) []byte {
	id := make([]byte, 16)
	id[0] = byte(ms >> 40)
	id[1] = byte(ms >> 32)
	id[2] = byte(ms >> 24)
	id[3] = byte(ms >> 16)
	id[4] = byte(ms >> 8)
	id[5] = byte(ms)
	id[6] = 0x70
	id[8] = 0x80
	return id
}
