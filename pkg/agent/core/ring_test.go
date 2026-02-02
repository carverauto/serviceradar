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
	rb := NewRingBuffer[float64](5)

	// Write 3 values
	rb.Write(1.1)
	rb.Write(2.2)
	rb.Write(3.3)

	assert.Equal(t, 3, rb.Count())

	// Drain
	values := rb.Drain()
	assert.Equal(t, 3, len(values))
	assert.Equal(t, []float64{1.1, 2.2, 3.3}, values)
	assert.Equal(t, 0, rb.Count())
}

func TestRingBuffer_Overflow(t *testing.T) {
	rb := NewRingBuffer[float64](3)

	// Write 5 values (overflows by 2)
	rb.Write(1.1)
	rb.Write(2.2)
	rb.Write(3.3)
	rb.Write(4.4)
	rb.Write(5.5)

	assert.Equal(t, 3, rb.Count())

	// Should contain the last 3 values
	values := rb.Drain()
	assert.Equal(t, []float64{3.3, 4.4, 5.5}, values)
}

func TestRingBuffer_PartialDrainAndRefill(t *testing.T) {
	rb := NewRingBuffer[float64](5)

	rb.Write(1.1)
	rb.Write(2.2)

	values := rb.Drain()
	assert.Equal(t, 2, len(values))

	rb.Write(3.3)
	rb.Write(4.4)

	values = rb.Drain()
	assert.Equal(t, []float64{3.3, 4.4}, values)
}

func TestRingBuffer_EmptyDrain(t *testing.T) {
	rb := NewRingBuffer[float64](5)
	values := rb.Drain()
	assert.Nil(t, values)
}
