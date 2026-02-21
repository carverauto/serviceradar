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

package core

import (
	"sync"
)

// RingBuffer is a fixed-size circular buffer for data.
// It supports concurrent writes and a "Drain" operation that returns
// all values since the last drain.
type RingBuffer[T any] struct {
	mu     sync.RWMutex
	values []T
	head   int // index where the next write will occur
	tail   int // index of the oldest unread value
	size   int // total capacity
	count  int // number of unread items
}

// NewRingBuffer creates a new RingBuffer with the given capacity.
func NewRingBuffer[T any](capacity int) *RingBuffer[T] {
	if capacity <= 0 {
		return &RingBuffer[T]{}
	}

	return &RingBuffer[T]{
		values: make([]T, capacity),
		size:   capacity,
	}
}

// Write adds a new data point to the buffer.
// If the buffer is full, it overwrites the oldest unread value
// and advances the tail pointer.
func (r *RingBuffer[T]) Write(v T) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.size == 0 {
		return
	}

	r.values[r.head] = v

	r.head = (r.head + 1) % r.size

	if r.count < r.size {
		r.count++
	} else {
		// Overwriting oldest unread value
		r.tail = (r.tail + 1) % r.size
	}
}

// Drain returns all unread data points and marks them as read.
func (r *RingBuffer[T]) Drain() []T {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.size == 0 || r.count == 0 {
		return nil
	}

	data := make([]T, r.count)

	for i := 0; i < r.count; i++ {
		idx := (r.tail + i) % r.size
		data[i] = r.values[idx]
	}

	r.tail = r.head
	r.count = 0

	return data
}

// Snapshot returns all unread data points without marking them as read.
func (r *RingBuffer[T]) Snapshot() []T {
	r.mu.RLock()
	defer r.mu.RUnlock()

	if r.size == 0 || r.count == 0 {
		return nil
	}

	data := make([]T, r.count)

	for i := 0; i < r.count; i++ {
		idx := (r.tail + i) % r.size
		data[i] = r.values[idx]
	}

	return data
}

// WalkReverse iterates over the buffer from newest to oldest.
// The callback function 'fn' is called for each item.
// If 'fn' returns false, iteration stops.
func (r *RingBuffer[T]) WalkReverse(fn func(T) bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	if r.size == 0 || r.count == 0 {
		return
	}

	// Calculate the index of the newest item
	// head points to the *next* write slot, so newest is head - 1
	startIdx := (r.head - 1 + r.size) % r.size

	for i := 0; i < r.count; i++ {
		idx := (startIdx - i + r.size) % r.size
		if !fn(r.values[idx]) {
			return
		}
	}
}

// Capacity returns the total capacity of the buffer.
func (r *RingBuffer[T]) Capacity() int {
	return r.size
}

// Count returns the number of unread data points currently in the buffer.
func (r *RingBuffer[T]) Count() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.count
}
