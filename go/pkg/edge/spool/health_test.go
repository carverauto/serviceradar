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

// healthSpool opens a fresh spool holding one record per body, in order, with
// the given event ids.
func healthSpool(t *testing.T, ids [][]byte, bodies []string) *Spool {
	t.Helper()
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	for i := range ids {
		if _, err := s.Append(ids[i], []byte(bodies[i])); err != nil {
			t.Fatalf("append %d: %v", i+1, err)
		}
	}
	return s
}

func TestUnresolvedHealthUsesOldestUUIDv7AndBodyBytes(t *testing.T) {
	now := time.UnixMilli(1_700_000_000_000)
	older := now.Add(-90 * time.Second)
	newer := now.Add(-10 * time.Second)
	notV7 := uuidV7At(uint64(now.UnixMilli()))
	notV7[6] = 0x40

	s := healthSpool(t,
		[][]byte{uuidV7At(uint64(newer.UnixMilli())), uuidV7At(uint64(older.UnixMilli())), notV7},
		[]string{"ab", "cdef", "z"})
	bytes, age, reportAge, err := s.UnresolvedHealth(now)
	if err != nil {
		t.Fatal(err)
	}
	if bytes != 7 {
		t.Fatalf("bytes = %d, want 7", bytes)
	}
	if !reportAge {
		t.Fatal("reportAge = false, want true")
	}
	if age != 90*time.Second {
		t.Fatalf("age = %s, want 90s", age)
	}

	// Resolved records leave the backlog.
	if err := s.Resolve(2); err != nil {
		t.Fatal(err)
	}
	bytes, age, reportAge, err = s.UnresolvedHealth(now)
	if err != nil || bytes != 1 || age != 0 || reportAge {
		t.Fatalf("after resolving two records health = (%d, %s, %v, %v), want (1, 0s, false, nil)", bytes, age, reportAge, err)
	}
}

func TestUnresolvedHealthEmptySpoolReportsZeroAge(t *testing.T) {
	s := healthSpool(t, nil, nil)
	bytes, age, reportAge, err := s.UnresolvedHealth(time.UnixMilli(1_700_000_000_000))
	if err != nil || bytes != 0 || age != 0 || !reportAge {
		t.Fatalf("empty health = (%d, %s, %v, %v)", bytes, age, reportAge, err)
	}
}

func TestUnresolvedHealthOmitsAgeWhenNoVersion7(t *testing.T) {
	id := uuidV7At(1_700_000_000_000)
	id[6] = 0x40
	s := healthSpool(t, [][]byte{id}, []string{"body"})
	bytes, age, reportAge, err := s.UnresolvedHealth(time.UnixMilli(1_700_000_090_000))
	if err != nil || bytes != 4 || age != 0 || reportAge {
		t.Fatalf("non-v7 health = (%d, %s, %v, %v)", bytes, age, reportAge, err)
	}
}

func TestUnresolvedHealthClampsAFutureEventToZero(t *testing.T) {
	now := time.UnixMilli(1_700_000_000_000)
	future := now.Add(30 * time.Second)
	s := healthSpool(t, [][]byte{uuidV7At(uint64(future.UnixMilli()))}, []string{"x"})
	_, age, reportAge, err := s.UnresolvedHealth(now)
	if err != nil || !reportAge || age != 0 {
		t.Fatalf("future health age = %s report=%v err=%v", age, reportAge, err)
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
