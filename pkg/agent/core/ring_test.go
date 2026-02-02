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
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestRingBuffer_WriteAndDrain(t *testing.T) {
	rb := NewRingBuffer(5)

	// Write 3 values
	rb.Write(100, 1.1)
	rb.Write(200, 2.2)
	rb.Write(300, 3.3)

	assert.Equal(t, 3, rb.Count())

	// Drain
	times, values := rb.Drain()
	assert.Equal(t, 3, len(times))
	assert.Equal(t, []int64{100, 200, 300}, times)
	assert.Equal(t, []float64{1.1, 2.2, 3.3}, values)
	assert.Equal(t, 0, rb.Count())
}

func TestRingBuffer_Overflow(t *testing.T) {
	rb := NewRingBuffer(3)

	// Write 5 values (overflows by 2)
	rb.Write(100, 1.1)
	rb.Write(200, 2.2)
	rb.Write(300, 3.3)
	rb.Write(400, 4.4)
	rb.Write(500, 5.5)

	assert.Equal(t, 3, rb.Count())

	// Should contain the last 3 values
	times, values := rb.Drain()
	assert.Equal(t, []int64{300, 400, 500}, times)
	assert.Equal(t, []float64{3.3, 4.4, 5.5}, values)
}

func TestRingBuffer_PartialDrainAndRefill(t *testing.T) {
	rb := NewRingBuffer(5)

	rb.Write(100, 1.1)
	rb.Write(200, 2.2)

	times, _ := rb.Drain()
	assert.Equal(t, 2, len(times))

	rb.Write(300, 3.3)
	rb.Write(400, 4.4)

	times, values := rb.Drain()
	assert.Equal(t, []int64{300, 400}, times)
	assert.Equal(t, []float64{3.3, 4.4}, values)
}

func TestRingBuffer_EmptyDrain(t *testing.T) {
	rb := NewRingBuffer(5)
	times, values := rb.Drain()
	assert.Nil(t, times)
	assert.Nil(t, values)
}
