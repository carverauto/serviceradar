/*-
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

package metrics

import (
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// ChannelBuffer is a channel-based buffer implementation.
type ChannelBuffer struct {
	points chan metricPoint
	size   int
}

// NewChannelBuffer creates a new ChannelBuffer with the specified size.
func NewChannelBuffer(size int) MetricStore {
	return &ChannelBuffer{
		points: make(chan metricPoint, size),
		size:   size,
	}
}

// Add adds a new metric point to the buffer.
func (b *ChannelBuffer) Add(timestamp time.Time, responseTime int64, serviceName string) {
	point := metricPoint{
		timestamp:    timestamp.UnixNano(),
		responseTime: responseTime,
		serviceName:  serviceName,
	}

	select {
	case b.points <- point: // Add the point if there's space
	default:
		// Drop the oldest point if the buffer is full
		<-b.points
		b.points <- point
	}
}

// GetPoints retrieves all metric points from the buffer.
func (b *ChannelBuffer) GetPoints() []models.MetricPoint {
	points := make([]models.MetricPoint, 0, b.size)

	for len(b.points) > 0 {
		p := <-b.points
		points = append(points, models.MetricPoint{
			Timestamp:    time.Unix(0, p.timestamp),
			ResponseTime: p.responseTime,
			ServiceName:  strings.TrimSpace(p.serviceName),
		})
	}

	return points
}

// BenchmarkRingBuffer benchmarks the RingBuffer implementation.
func BenchmarkRingBuffer(b *testing.B) {
	buffer := NewBuffer(1000)
	now := time.Now()

	b.Run("Add", func(b *testing.B) {
		b.ResetTimer()

		for i := 0; i < b.N; i++ {
			buffer.Add(now, int64(i), "test-service")
		}
	})

	b.Run("GetPoints", func(b *testing.B) {
		for i := 0; i < 1000; i++ {
			buffer.Add(now, int64(i), "test-service")
		}

		b.ResetTimer()

		for i := 0; i < b.N; i++ {
			_ = buffer.GetPoints()
		}
	})
}

// BenchmarkLockFreeRingBuffer benchmarks the LockFreeRingBuffer implementation.
func BenchmarkLockFreeRingBuffer(b *testing.B) {
	buffer := NewLockFreeBuffer(1000)
	now := time.Now()

	b.Run("Add", func(b *testing.B) {
		b.ResetTimer()

		for i := 0; i < b.N; i++ {
			buffer.Add(now, int64(i), "test-service")
		}
	})

	b.Run("GetPoints", func(b *testing.B) {
		for i := 0; i < 1000; i++ {
			buffer.Add(now, int64(i), "test-service")
		}

		b.ResetTimer()

		for i := 0; i < b.N; i++ {
			_ = buffer.GetPoints()
		}
	})
}

// BenchmarkChannelBuffer benchmarks the ChannelBuffer implementation.
func BenchmarkChannelBuffer(b *testing.B) {
	buffer := NewChannelBuffer(1000)
	now := time.Now()

	b.Run("Add", func(b *testing.B) {
		b.ResetTimer()

		for i := 0; i < b.N; i++ {
			buffer.Add(now, int64(i), "test-service")
		}
	})

	b.Run("GetPoints", func(b *testing.B) {
		for i := 0; i < 1000; i++ {
			buffer.Add(now, int64(i), "test-service")
		}

		b.ResetTimer()

		for i := 0; i < b.N; i++ {
			_ = buffer.GetPoints()
		}
	})
}

// BenchmarkImplementations compares the performance of all implementations.
func BenchmarkImplementations(b *testing.B) {
	implementations := []struct {
		name    string
		factory func(int) MetricStore
	}{
		{"RingBuffer", NewBuffer},
		{"LockFreeRingBuffer", NewLockFreeBuffer},
		{"ChannelBuffer", NewChannelBuffer},
	}

	for _, impl := range implementations {
		b.Run(impl.name, func(b *testing.B) {
			buffer := impl.factory(1000)
			now := time.Now()

			b.Run("Add", func(b *testing.B) {
				b.ResetTimer()

				for i := 0; i < b.N; i++ {
					buffer.Add(now, int64(i), "test-service")
				}
			})

			b.Run("GetPoints", func(b *testing.B) {
				for i := 0; i < 1000; i++ {
					buffer.Add(now, int64(i), "test-service")
				}

				b.ResetTimer()

				for i := 0; i < b.N; i++ {
					_ = buffer.GetPoints()
				}
			})
		})
	}
}

func (b *ChannelBuffer) GetLastPoint() *models.MetricPoint {
	points := b.GetPoints()
	if len(points) == 0 {
		return nil
	}

	lastPoint := points[len(points)-1]

	return &lastPoint
}
