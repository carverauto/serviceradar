package metrics

import (
	"sync"
	"sync/atomic"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

// metricPoint represents a single metric data point.
type metricPoint struct {
	timestamp    int64
	responseTime int64
	serviceName  string
}

// LockFreeRingBuffer is a lock-free ring buffer implementation.
type LockFreeRingBuffer struct {
	points []metricPoint
	pos    int64 // Atomic position counter
	size   int64
	pool   sync.Pool
}

// NewBuffer creates a new MetricStore (e.g., RingBuffer or LockFreeRingBuffer).
func NewBuffer(size int) MetricStore {
	return NewLockFreeBuffer(size) // Use LockFreeRingBuffer by default
}

// NewLockFreeBuffer creates a new LockFreeRingBuffer with the specified size.
func NewLockFreeBuffer(size int) MetricStore {
	return &LockFreeRingBuffer{
		points: make([]metricPoint, size),
		size:   int64(size),
		pool: sync.Pool{
			New: func() interface{} {
				return &models.MetricPoint{}
			},
		},
	}
}

// Add adds a new metric point to the buffer.
func (b *LockFreeRingBuffer) Add(timestamp time.Time, responseTime int64, serviceName string) {
	// Atomically increment the position and get the index
	pos := atomic.AddInt64(&b.pos, 1) - 1
	idx := pos % b.size

	// Write the metric point
	b.points[idx] = metricPoint{
		timestamp:    timestamp.UnixNano(),
		responseTime: responseTime,
		serviceName:  serviceName,
	}
}

// GetPoints retrieves all metric points from the buffer.
func (b *LockFreeRingBuffer) GetPoints() []models.MetricPoint {
	// Load the current position atomically
	pos := atomic.LoadInt64(&b.pos)

	points := make([]models.MetricPoint, b.size)

	for i := int64(0); i < b.size; i++ {
		// Calculate the index for the current point
		idx := (pos - i - 1 + b.size) % b.size
		p := b.points[idx]

		// Get a MetricPoint from the pool
		mp := b.pool.Get().(*models.MetricPoint)
		mp.Timestamp = time.Unix(0, p.timestamp)
		mp.ResponseTime = p.responseTime
		mp.ServiceName = p.serviceName

		points[i] = *mp

		// Return the MetricPoint to the pool
		b.pool.Put(mp)
	}

	return points
}
