package metrics

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"log"
	"math"
	"math/big"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

const (
	metricPointSize = 32
)

type NodeMetrics struct {
	buffer MetricBuffer
	mu     sync.RWMutex // Fine-grained lock for this node
}

type MetricBuffer struct {
	buffer []byte
	pos    int
	size   int
	mu     sync.RWMutex
	pool   sync.Pool
}

func NewMetricBuffer(points int) *MetricBuffer {
	return &MetricBuffer{
		buffer: make([]byte, points*metricPointSize),
		size:   points,
		pool: sync.Pool{
			New: func() interface{} {
				return new(bytes.Buffer)
			},
		},
	}
}

func (b *MetricBuffer) Add(timestamp time.Time, responseTime int64, serviceName string) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	// Get a buffer from the pool
	buf := b.pool.Get().(*bytes.Buffer)
	defer b.pool.Put(buf)
	buf.Reset()

	// Write data to the buffer
	if err := binary.Write(buf, binary.LittleEndian, timestamp.UnixNano()); err != nil {
		log.Printf("Error writing timestamp to buffer: %v", err)
		return fmt.Errorf("failed to write timestamp: %w", err)
	}

	if err := binary.Write(buf, binary.LittleEndian, responseTime); err != nil {
		log.Printf("Error writing response time to buffer: %v", err)
		return fmt.Errorf("failed to write response time: %w", err)
	}

	if _, err := buf.WriteString(serviceName); err != nil {
		log.Printf("Error writing service name to buffer: %v", err)
		return fmt.Errorf("failed to write service name: %w", err)
	}

	// Copy buffer to the main buffer
	offset := b.pos * metricPointSize
	copy(b.buffer[offset:offset+metricPointSize], buf.Bytes())

	b.pos = (b.pos + 1) % b.size

	return nil
}

func (b *MetricBuffer) GetPoints() []models.MetricPoint {
	b.mu.RLock()
	defer b.mu.RUnlock()

	points := make([]models.MetricPoint, b.size)

	log.Printf("Retrieved %d metric points", len(points))

	for i := 0; i < b.size; i++ {
		pos := (b.pos - i - 1 + b.size) % b.size
		offset := pos * metricPointSize

		ts := binary.LittleEndian.Uint64(b.buffer[offset:])
		rt := binary.LittleEndian.Uint64(b.buffer[offset+8:])
		sn := string(bytes.TrimRight(b.buffer[offset+16:offset+32], "\x00"))

		// Safely handle uint64 to int64 conversion using math/big
		timestamp := safeUint64ToInt64(ts, sn, "timestamp")
		responseTime := safeUint64ToInt64(rt, sn, "response time")

		points[i] = models.MetricPoint{
			Timestamp:    time.Unix(0, timestamp),
			ResponseTime: responseTime,
			ServiceName:  sn,
		}
	}

	return points
}

// safeUint64ToInt64 safely converts a uint64 to int64 using math/big.
func safeUint64ToInt64(value uint64, serviceName, fieldName string) int64 {
	maxInt64 := big.NewInt(math.MaxInt64) // Maximum value for int64
	val := new(big.Int).SetUint64(value)  // Convert uint64 to big.Int

	// Check if the value exceeds math.MaxInt64
	if val.Cmp(maxInt64) > 0 {
		log.Printf("Warning: %s overflow for service '%s': %d (clamped to MaxInt64)", fieldName, serviceName, value)
		return math.MaxInt64
	}

	// If the value is within the valid range, convert it to int64
	return val.Int64()
}
