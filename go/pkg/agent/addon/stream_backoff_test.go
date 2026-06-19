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
	"testing"
	"time"
)

func TestStreamReconnectBaseDelayCapsExponentialBackoff(t *testing.T) {
	t.Parallel()

	initial := 100 * time.Millisecond
	maxDelay := 2 * time.Second

	tests := []struct {
		name    string
		attempt int
		want    time.Duration
	}{
		{name: "first", attempt: 0, want: 100 * time.Millisecond},
		{name: "second", attempt: 1, want: 200 * time.Millisecond},
		{name: "third", attempt: 2, want: 400 * time.Millisecond},
		{name: "fourth", attempt: 3, want: 800 * time.Millisecond},
		{name: "fifth", attempt: 4, want: 1600 * time.Millisecond},
		{name: "capped", attempt: 5, want: 2 * time.Second},
		{name: "still capped", attempt: 64, want: 2 * time.Second},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			if got := streamReconnectBaseDelay(tt.attempt, initial, maxDelay); got != tt.want {
				t.Fatalf("streamReconnectBaseDelay() = %s, want %s", got, tt.want)
			}
		})
	}
}

func TestStreamReconnectBaseDelayNormalizesInvalidDurations(t *testing.T) {
	t.Parallel()

	if got := streamReconnectBaseDelay(0, time.Second, time.Millisecond); got != time.Second {
		t.Fatalf("streamReconnectBaseDelay() = %s, want %s", got, time.Second)
	}

	if got := streamReconnectBaseDelay(0, 0, 0); got != defaultRestartBackoffInitial {
		t.Fatalf("streamReconnectBaseDelay() = %s, want default initial %s", got, defaultRestartBackoffInitial)
	}
}

func TestJitterStreamReconnectDelayBounds(t *testing.T) {
	t.Parallel()

	delay := time.Second

	min := jitterStreamReconnectDelayWithRand(delay, func(int64) int64 {
		return 0
	})
	if min != delay/2 {
		t.Fatalf("minimum jittered delay = %s, want %s", min, delay/2)
	}

	max := jitterStreamReconnectDelayWithRand(delay, func(n int64) int64 {
		return n - 1
	})
	if max != delay {
		t.Fatalf("maximum jittered delay = %s, want %s", max, delay)
	}
}

func TestNextStreamReconnectDelayAppliesJitterWithinBaseWindow(t *testing.T) {
	t.Parallel()

	initial := 100 * time.Millisecond
	maxDelay := 2 * time.Second

	for attempt := 0; attempt < 8; attempt++ {
		base := streamReconnectBaseDelay(attempt, initial, maxDelay)
		min := base / 2

		for i := 0; i < 32; i++ {
			got := nextStreamReconnectDelay(attempt, initial, maxDelay)
			if got < min || got > base {
				t.Fatalf("nextStreamReconnectDelay(%d) = %s, want between %s and %s", attempt, got, min, base)
			}
		}
	}
}
