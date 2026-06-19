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

package addon

import (
	"context"
	cryptorand "crypto/rand"
	"encoding/binary"
	"math/rand"
	"sync"
	"time"
)

var (
	streamReconnectJitterMu sync.Mutex
	streamReconnectJitter   = rand.New(rand.NewSource(streamReconnectJitterSeed()))
)

func nextStreamReconnectDelay(attempt int, initial, maxDelay time.Duration) time.Duration {
	return jitterStreamReconnectDelay(streamReconnectBaseDelay(attempt, initial, maxDelay))
}

func streamReconnectBaseDelay(attempt int, initial, maxDelay time.Duration) time.Duration {
	if initial <= 0 {
		initial = defaultRestartBackoffInitial
	}
	if maxDelay <= 0 {
		maxDelay = defaultRestartBackoffMax
	}
	if maxDelay < initial {
		maxDelay = initial
	}

	delay := initial
	for i := 0; i < attempt; i++ {
		if delay >= maxDelay/2 {
			return maxDelay
		}
		delay *= 2
	}
	if delay > maxDelay {
		return maxDelay
	}
	return delay
}

func jitterStreamReconnectDelay(delay time.Duration) time.Duration {
	return jitterStreamReconnectDelayWithRand(delay, streamReconnectJitterInt63n)
}

func jitterStreamReconnectDelayWithRand(delay time.Duration, nextInt63n func(int64) int64) time.Duration {
	if delay <= time.Nanosecond {
		return delay
	}

	minDelay := delay / 2
	span := delay - minDelay
	if span <= 0 {
		return delay
	}

	return minDelay + time.Duration(nextInt63n(int64(span)+1))
}

func streamReconnectJitterInt63n(n int64) int64 {
	if n <= 0 {
		return 0
	}

	streamReconnectJitterMu.Lock()
	defer streamReconnectJitterMu.Unlock()

	return streamReconnectJitter.Int63n(n)
}

func streamReconnectJitterSeed() int64 {
	var seed [8]byte
	if _, err := cryptorand.Read(seed[:]); err == nil {
		return int64(binary.LittleEndian.Uint64(seed[:]))
	}

	return time.Now().UnixNano()
}

func waitStreamReconnect(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()

	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}
