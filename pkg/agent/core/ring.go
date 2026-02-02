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

// RingBuffer is a fixed-size circular buffer for time-series data.
// It supports concurrent writes and a "Drain" operation that returns
// all values since the last drain.
type RingBuffer struct {
	mu     sync.RWMutex
	values []float64
	times  []int64
	head   int // index where the next write will occur
	tail   int // index of the oldest unread value
	size   int // total capacity
	count  int // number of unread items
}

// NewRingBuffer creates a new RingBuffer with the given capacity.
func NewRingBuffer(capacity int) *RingBuffer {
	return &RingBuffer{
		values: make([]float64, capacity),
		times:  make([]int64, capacity),
		size:   capacity,
	}
}

// Write adds a new data point to the buffer.
// If the buffer is full, it overwrites the oldest unread value
// and advances the tail pointer.
func (r *RingBuffer) Write(t int64, v float64) {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.values[r.head] = v
	r.times[r.head] = t

	r.head = (r.head + 1) % r.size

	if r.count < r.size {
		r.count++
	} else {
		// Overwriting oldest unread value
		r.tail = (r.tail + 1) % r.size
	}
}

// Drain returns all unread data points and marks them as read.
func (r *RingBuffer) Drain() ([]int64, []float64) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.count == 0 {
		return nil, nil
	}

	times := make([]int64, r.count)
	values := make([]float64, r.count)

	for i := 0; i < r.count; i++ {
		idx := (r.tail + i) % r.size
		times[i] = r.times[idx]
		values[i] = r.values[idx]
	}

	r.tail = r.head
	r.count = 0

	return times, values
}

// Capacity returns the total capacity of the buffer.
func (r *RingBuffer) Capacity() int {
	return r.size
}

// Count returns the number of unread data points currently in the buffer.
func (r *RingBuffer) Count() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.count
}
