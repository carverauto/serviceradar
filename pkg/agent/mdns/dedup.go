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
	"encoding/hex"
	"sync"
	"time"
)

// dedupKey is the cache key: (hostname, hex-encoded resolved_addr).
type dedupKey struct {
	hostname     string
	resolvedAddr string // hex-encoded bytes
}

type dedupEntry struct {
	insertedAt time.Time
}

// DedupCache provides duplicate suppression for mDNS records.
// Key: (hostname, hex(resolved_addr)). Entries expire after TTL.
// Thread-safe.
type DedupCache struct {
	mu         sync.Mutex
	entries    map[dedupKey]dedupEntry
	ttl        time.Duration
	maxEntries int
	// nowFunc allows overriding time in tests.
	nowFunc func() time.Time
}

// NewDedupCache creates a new dedup cache.
func NewDedupCache(ttlSecs int, maxEntries int) *DedupCache {
	return &DedupCache{
		entries:    make(map[dedupKey]dedupEntry),
		ttl:        time.Duration(ttlSecs) * time.Second,
		maxEntries: maxEntries,
		nowFunc:    time.Now,
	}
}

// CheckAndInsert returns true if the record should be published (not a duplicate).
// Returns false if the record is a duplicate within the TTL window.
func (d *DedupCache) CheckAndInsert(hostname string, resolvedAddr []byte) bool {
	key := dedupKey{
		hostname:     hostname,
		resolvedAddr: hex.EncodeToString(resolvedAddr),
	}

	now := d.nowFunc()

	d.mu.Lock()
	defer d.mu.Unlock()

	if entry, exists := d.entries[key]; exists {
		if now.Sub(entry.insertedAt) < d.ttl {
			return false // duplicate within TTL
		}
	}

	// Evict oldest entry if at capacity and this is a new key
	if len(d.entries) >= d.maxEntries {
		if _, exists := d.entries[key]; !exists {
			d.evictOldest()
		}
	}

	d.entries[key] = dedupEntry{insertedAt: now}
	return true
}

// Cleanup removes entries that have expired past the TTL.
// Returns the number of entries removed.
func (d *DedupCache) Cleanup() int {
	now := d.nowFunc()

	d.mu.Lock()
	defer d.mu.Unlock()

	before := len(d.entries)
	for k, entry := range d.entries {
		if now.Sub(entry.insertedAt) >= d.ttl {
			delete(d.entries, k)
		}
	}
	return before - len(d.entries)
}

// Len returns the current number of entries in the cache.
func (d *DedupCache) Len() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.entries)
}

// evictOldest removes the oldest entry from the cache. Must be called with lock held.
func (d *DedupCache) evictOldest() {
	var oldestKey dedupKey
	var oldestTime time.Time
	first := true

	for k, entry := range d.entries {
		if first || entry.insertedAt.Before(oldestTime) {
			oldestKey = k
			oldestTime = entry.insertedAt
			first = false
		}
	}

	if !first {
		delete(d.entries, oldestKey)
	}
}
