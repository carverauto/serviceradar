package metrics

import (
	"strings"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

type metricPoint struct {
	timestamp    int64
	responseTime int64
	serviceName  string
}

type RingBuffer struct {
	points []metricPoint
	pos    int
	size   int
	mu     sync.RWMutex
}

func NewBuffer(size int) MetricStore {
	return &RingBuffer{
		points: make([]metricPoint, size),
		size:   size,
	}
}

func (b *RingBuffer) Add(timestamp time.Time, responseTime int64, serviceName string) {
	b.mu.Lock()
	defer b.mu.Unlock()

	b.points[b.pos] = metricPoint{
		timestamp:    timestamp.UnixNano(),
		responseTime: responseTime,
		serviceName:  serviceName,
	}

	b.pos = (b.pos + 1) % b.size
}

func (b *RingBuffer) GetPoints() []models.MetricPoint {
	b.mu.RLock()
	defer b.mu.RUnlock()

	points := make([]models.MetricPoint, b.size)
	pos := b.pos

	for i := 0; i < b.size; i++ {
		idx := (pos - i - 1 + b.size) % b.size
		p := b.points[idx]
		points[i] = models.MetricPoint{
			Timestamp:    time.Unix(0, p.timestamp),
			ResponseTime: p.responseTime,
			ServiceName:  strings.TrimSpace(p.serviceName),
		}
	}

	return points
}
