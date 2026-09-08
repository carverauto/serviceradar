//go:build linux
// +build linux

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

package scan

import (
	"runtime"
	"sync"
	"sync/atomic"
	"time"
)

type rateLimiter interface {
	AllowN(n int) int
}

// tokenBucket is a tiny limiter (tokens/sec with a burst).
type tokenBucket struct {
	rate  float64 // tokens per second
	burst float64 // max tokens
	mu    sync.Mutex
	toks  float64
	last  time.Time
}

func newTokenBucket(pps, burst int) *tokenBucket {
	if pps <= 0 {
		return nil
	}

	if burst <= 0 {
		burst = pps
	}

	return &tokenBucket{
		rate:  float64(pps),
		burst: float64(burst),
		toks:  float64(burst),
		last:  time.Now(),
	}
}

// AllowN returns how many tokens can be spent immediately (<= n).
func (tb *tokenBucket) AllowN(n int) int {
	tb.mu.Lock()
	defer tb.mu.Unlock()

	now := time.Now()

	dt := now.Sub(tb.last).Seconds()

	if dt > 0 {
		tb.toks += dt * tb.rate
		if tb.toks > tb.burst {
			tb.toks = tb.burst
		}

		tb.last = now
	}

	if tb.toks < 1 {
		return 0
	}

	want := float64(n)

	if tb.toks < want {
		n = int(tb.toks)
	}

	tb.toks -= float64(n)

	return n
}

// shardedTokenBucket reduces lock contention by distributing the total rate
// across several independent token buckets. Each AllowN selects a shard
// using a fast pseudo-random counter to spread callers across shards.
type shardedTokenBucket struct {
	shards   int
	buckets  []*tokenBucket
	disabled bool
	ctr      uint64 // atomically incremented to spread calls
}

func newShardedTokenBucket(shards, pps, burst int) *shardedTokenBucket {
	if pps <= 0 {
		return &shardedTokenBucket{shards: 1, disabled: true}
	}

	if shards <= 1 {
		return &shardedTokenBucket{shards: 1, buckets: []*tokenBucket{newTokenBucket(pps, burst)}}
	}

	if burst <= 0 {
		burst = pps
	}

	// Divide rate and burst roughly evenly across shards
	perRate := pps / shards
	rateRemainder := pps % shards
	perBurst := burst / shards
	burstRemainder := burst % shards

	b := make([]*tokenBucket, shards)
	for i := 0; i < shards; i++ {
		r := perRate
		if i < rateRemainder {
			r++
		}

		bs := perBurst
		if i < burstRemainder {
			bs++
		}

		if r <= 0 {
			r = 1
		}

		if bs <= 0 {
			bs = r
		}

		b[i] = newTokenBucket(r, bs)
	}

	return &shardedTokenBucket{shards: shards, buckets: b}
}

func (s *shardedTokenBucket) AllowN(n int) int {
	if s == nil || s.disabled {
		return n
	}

	// Round-robin across shards by incrementing a counter.
	idx := int(atomic.AddUint64(&s.ctr, 1))
	if len(s.buckets) > 0 {
		idx %= len(s.buckets)
	} else {
		return n
	}

	if s.buckets[idx] == nil {
		return n
	}

	return s.buckets[idx].AllowN(n)
}

// SetRateLimit installs a global rate limit (packets/sec) with a burst.
// Pass pps<=0 to disable. If burst<=0, burst defaults to pps.
// Safe to call anytime, including during active scans.
func (s *SYNScanner) SetRateLimit(pps, burst int) {
	if pps <= 0 {
		s.rl.Store(rateLimiter(newShardedTokenBucket(1, 0, 0)))
		return
	}

	// Determine shard count to reduce lock contention at high concurrency.
	// Scale with scanner concurrency and CPU count, clamp to sensible bounds.
	// Using a power-of-two-ish upper bound keeps modulo cheap.
	shards := runtime.GOMAXPROCS(0)
	if s.concurrency > 0 && s.concurrency < shards {
		shards = s.concurrency
	}

	if shards < minShardCount {
		shards = minShardCount
	}

	if shards > maxShardCount {
		shards = maxShardCount
	}

	// Always store a non-nil rateLimiter to keep atomic.Value type stable and avoid nil checks.
	limiter := rateLimiter(newShardedTokenBucket(shards, pps, burst))
	s.rl.Store(limiter)
}

// allowN applies the limiter if present; otherwise returns n.
func (s *SYNScanner) allowN(n int) int {
	if v := s.rl.Load(); v != nil {
		if lim, ok := v.(rateLimiter); ok && lim != nil {
			return lim.AllowN(n)
		}
	}

	return n
}
