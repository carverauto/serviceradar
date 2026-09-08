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
	"time"
)

func nextStreamReconnectDelay(attempt int, initial, maxDelay time.Duration) time.Duration {
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

func reconnectStreamLoop[T any](
	ctx context.Context,
	initial time.Duration,
	maxDelay time.Duration,
	open func(context.Context) (T, error),
	drain func(context.Context, T) bool,
	logOpenFailure func(error, time.Duration),
	logStreamClosed func(time.Duration),
) {
	attempt := 0
	resetAfter := streamReconnectResetDuration(initial, maxDelay)

	for ctx.Err() == nil {
		stream, err := open(ctx)
		if err != nil {
			delay := nextStreamReconnectDelay(attempt, initial, maxDelay)
			if logOpenFailure != nil {
				logOpenFailure(err, delay)
			}
			attempt++
			if !waitStreamReconnect(ctx, delay) {
				return
			}
			continue
		}

		startedAt := time.Now()
		madeProgress := drain(ctx, stream)
		if ctx.Err() != nil {
			return
		}
		if madeProgress || time.Since(startedAt) >= resetAfter {
			attempt = 0
		}

		delay := nextStreamReconnectDelay(attempt, initial, maxDelay)
		if logStreamClosed != nil {
			logStreamClosed(delay)
		}
		attempt++
		if !waitStreamReconnect(ctx, delay) {
			return
		}
	}
}

func streamReconnectResetDuration(initial, maxDelay time.Duration) time.Duration {
	if initial <= 0 {
		initial = defaultRestartBackoffInitial
	}
	if maxDelay <= 0 {
		maxDelay = defaultRestartBackoffMax
	}
	if maxDelay < initial {
		return initial
	}
	return maxDelay
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
