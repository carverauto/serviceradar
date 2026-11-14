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

// RingBuffer is a bounded circular buffer for data.
// It supports concurrent writes and a "Drain" operation that returns
// all values since the last drain.
//
// Capacity is an upper bound, not an allocation: the backing slice grows as
// values arrive and is handed to the caller on Drain, so a buffer that is
// drained regularly holds only the values written since the last drain. Once
// capacity unread values are held, each write overwrites the oldest one.
type RingBuffer[T any] struct {
	mu     sync.RWMutex
	values []T
	head   int // index where the next write will occur once values is full
	tail   int // index of the oldest unread value
	size   int // maximum number of unread values
	count  int // number of unread items
}

// NewRingBuffer creates a new RingBuffer that holds at most capacity unread values.
func NewRingBuffer[T any](capacity int) *RingBuffer[T] {
	if capacity <= 0 {
		return &RingBuffer[T]{}
	}

	return &RingBuffer[T]{size: capacity}
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

	// Until the bound is reached the buffer is a plain slice: tail stays 0 and
	// every value is unread, so a write is an append.
	if len(r.values) < r.size {
		r.values = append(r.values, v)
		r.count++
		r.head = len(r.values) % r.size

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

// Drain returns all unread data points and marks them as read. The buffer
// gives up its backing slice, so drained values are not retained.
func (r *RingBuffer[T]) Drain() []T {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.size == 0 || r.count == 0 {
		return nil
	}

	var data []T
	if r.tail == 0 && r.count == len(r.values) {
		// Unread values are already in order: hand the slice over as is.
		data = r.values
	} else {
		data = make([]T, r.count)
		for i := 0; i < r.count; i++ {
			data[i] = r.values[(r.tail+i)%len(r.values)]
		}
	}

	r.values = nil
	r.head = 0
	r.tail = 0
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
		data[i] = r.values[(r.tail+i)%len(r.values)]
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

	n := len(r.values)

	// The newest item sits just before head; head is n % size while the buffer
	// is still growing, which is 0 only once it is full.
	startIdx := (r.head - 1 + n) % n

	for i := 0; i < r.count; i++ {
		idx := (startIdx - i + n) % n
		if !fn(r.values[idx]) {
			return
		}
	}
}

// Capacity returns the maximum number of unread values the buffer holds.
func (r *RingBuffer[T]) Capacity() int {
	return r.size
}

// Count returns the number of unread data points currently in the buffer.
func (r *RingBuffer[T]) Count() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.count
}
