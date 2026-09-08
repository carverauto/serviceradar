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

package banner_grab

import (
	"context"
	"sync"
	"time"
)

type hostLimiter struct {
	maxPerHost int
	minGap     time.Duration
	mu         sync.Mutex
	hosts      map[string]*hostState
}

type hostState struct {
	sem       chan struct{}
	mu        sync.Mutex
	lastStart time.Time
}

func newHostLimiter(maxPerHost int, minGap time.Duration) *hostLimiter {
	if maxPerHost <= 0 {
		maxPerHost = 1
	}

	return &hostLimiter{
		maxPerHost: maxPerHost,
		minGap:     minGap,
		hosts:      make(map[string]*hostState),
	}
}

func (l *hostLimiter) acquire(ctx context.Context, host string) (func(), error) {
	state := l.stateFor(host)

	select {
	case state.sem <- struct{}{}:
	case <-ctx.Done():
		return nil, ctx.Err()
	}

	if err := l.waitForHostGap(ctx, state); err != nil {
		<-state.sem
		return nil, err
	}

	return func() {
		<-state.sem
	}, nil
}

func (l *hostLimiter) stateFor(host string) *hostState {
	l.mu.Lock()
	defer l.mu.Unlock()

	state := l.hosts[host]
	if state == nil {
		state = &hostState{sem: make(chan struct{}, l.maxPerHost)}
		l.hosts[host] = state
	}

	return state
}

func (l *hostLimiter) waitForHostGap(ctx context.Context, state *hostState) error {
	if l.minGap <= 0 {
		return nil
	}

	state.mu.Lock()
	now := time.Now()
	startAt := now
	if !state.lastStart.IsZero() {
		startAt = state.lastStart.Add(l.minGap)
	}
	if startAt.Before(now) {
		startAt = now
	}
	state.lastStart = startAt
	delay := time.Until(startAt)
	if delay <= 0 {
		state.mu.Unlock()

		return nil
	}
	state.mu.Unlock()

	timer := time.NewTimer(delay)
	defer timer.Stop()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

type probeRateLimiter struct {
	interval time.Duration
	mu       sync.Mutex
	next     time.Time
}

func newProbeRateLimiter(ratePerSecond int) *probeRateLimiter {
	if ratePerSecond <= 0 {
		return nil
	}

	return &probeRateLimiter{interval: time.Second / time.Duration(ratePerSecond)}
}

func (l *probeRateLimiter) wait(ctx context.Context) error {
	if l == nil || l.interval <= 0 {
		return nil
	}

	l.mu.Lock()
	now := time.Now()
	if l.next.Before(now) {
		l.next = now
	}

	delay := time.Until(l.next)
	l.next = l.next.Add(l.interval)
	l.mu.Unlock()

	if delay <= 0 {
		return nil
	}

	timer := time.NewTimer(delay)
	defer timer.Stop()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
