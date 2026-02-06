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

package mdns

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func TestNewEntryIsNotDuplicate(t *testing.T) {
	t.Parallel()
	cache := NewDedupCache(300, 1000)
	assert.True(t, cache.CheckAndInsert("mydevice.local", []byte{192, 168, 1, 1}))
}

func TestDuplicateWithinTTL(t *testing.T) {
	t.Parallel()
	cache := NewDedupCache(300, 1000)
	assert.True(t, cache.CheckAndInsert("mydevice.local", []byte{192, 168, 1, 1}))
	assert.False(t, cache.CheckAndInsert("mydevice.local", []byte{192, 168, 1, 1}))
}

func TestDifferentHostnameNotDuplicate(t *testing.T) {
	t.Parallel()
	cache := NewDedupCache(300, 1000)
	assert.True(t, cache.CheckAndInsert("device-a.local", []byte{192, 168, 1, 1}))
	assert.True(t, cache.CheckAndInsert("device-b.local", []byte{192, 168, 1, 1}))
}

func TestDifferentAddrNotDuplicate(t *testing.T) {
	t.Parallel()
	cache := NewDedupCache(300, 1000)
	assert.True(t, cache.CheckAndInsert("mydevice.local", []byte{192, 168, 1, 1}))
	assert.True(t, cache.CheckAndInsert("mydevice.local", []byte{192, 168, 1, 2}))
}

func TestPTRRecordsDedupWithEmptyAddr(t *testing.T) {
	t.Parallel()
	cache := NewDedupCache(300, 1000)
	assert.True(t, cache.CheckAndInsert("mydevice.local", []byte{}))
	assert.False(t, cache.CheckAndInsert("mydevice.local", []byte{}))
}

func TestTTLExpiry(t *testing.T) {
	t.Parallel()

	cache := NewDedupCache(1, 1000) // 1 second TTL
	now := time.Now()
	cache.nowFunc = func() time.Time { return now }

	assert.True(t, cache.CheckAndInsert("mydevice.local", []byte{192, 168, 1, 1}))
	assert.False(t, cache.CheckAndInsert("mydevice.local", []byte{192, 168, 1, 1}))

	// Advance time past TTL
	cache.nowFunc = func() time.Time { return now.Add(1100 * time.Millisecond) }

	// After TTL expires, should be treated as new
	assert.True(t, cache.CheckAndInsert("mydevice.local", []byte{192, 168, 1, 1}))
}

func TestCleanupRemovesExpired(t *testing.T) {
	t.Parallel()

	cache := NewDedupCache(1, 1000)
	now := time.Now()
	cache.nowFunc = func() time.Time { return now }

	cache.CheckAndInsert("device-a.local", []byte{10, 0, 0, 1})
	cache.CheckAndInsert("device-b.local", []byte{10, 0, 0, 2})
	assert.Equal(t, 2, cache.Len())

	// Advance time past TTL
	cache.nowFunc = func() time.Time { return now.Add(1100 * time.Millisecond) }

	removed := cache.Cleanup()
	assert.Equal(t, 2, removed)
	assert.Equal(t, 0, cache.Len())
}

func TestCapacityEviction(t *testing.T) {
	t.Parallel()

	cache := NewDedupCache(300, 2) // max 2 entries
	now := time.Now()
	cache.nowFunc = func() time.Time { return now }

	cache.CheckAndInsert("device-a.local", []byte{10, 0, 0, 1})

	// Advance time slightly so device-a is older
	cache.nowFunc = func() time.Time { return now.Add(10 * time.Millisecond) }

	cache.CheckAndInsert("device-b.local", []byte{10, 0, 0, 2})
	assert.Equal(t, 2, cache.Len())

	// Advance again
	cache.nowFunc = func() time.Time { return now.Add(20 * time.Millisecond) }

	// Adding a third entry should evict the oldest (device-a)
	cache.CheckAndInsert("device-c.local", []byte{10, 0, 0, 3})
	assert.Equal(t, 2, cache.Len())

	// device-a was evicted, so inserting it again should succeed
	assert.True(t, cache.CheckAndInsert("device-a.local", []byte{10, 0, 0, 1}))
}

func TestReinsertSameKeyAtCapacityNoEviction(t *testing.T) {
	t.Parallel()

	cache := NewDedupCache(1, 2)
	now := time.Now()
	cache.nowFunc = func() time.Time { return now }

	cache.CheckAndInsert("device-a.local", []byte{10, 0, 0, 1})
	cache.CheckAndInsert("device-b.local", []byte{10, 0, 0, 2})
	assert.Equal(t, 2, cache.Len())

	// Advance past TTL
	cache.nowFunc = func() time.Time { return now.Add(1100 * time.Millisecond) }

	// TTL expired, re-inserting device-a should succeed without evicting device-b
	assert.True(t, cache.CheckAndInsert("device-a.local", []byte{10, 0, 0, 1}))
	assert.Equal(t, 2, cache.Len())
}

func TestNilResolvedAddr(t *testing.T) {
	t.Parallel()
	cache := NewDedupCache(300, 1000)
	assert.True(t, cache.CheckAndInsert("mydevice.local", nil))
	assert.False(t, cache.CheckAndInsert("mydevice.local", nil))
}
