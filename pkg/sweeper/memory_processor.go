// Package sweeper pkg/sweeper/memory_processor.go
package sweeper

import (
	"context"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

// InMemoryProcessor implements ResultProcessor with in-memory state.
type InMemoryProcessor struct {
	mu            sync.RWMutex
	hostMap       map[string]*models.HostResult
	portCounts    map[int]int
	lastSweepTime time.Time
	totalHosts    int
}

func (i *InMemoryProcessor) Process(result *models.Result) error {
	//TODO implement me
	panic("implement me")
}

func (i *InMemoryProcessor) GetSummary(ctx context.Context) (*models.SweepSummary, error) {
	//TODO implement me
	panic("implement me")
}

func (i *InMemoryProcessor) Reset() {
	//TODO implement me
	panic("implement me")
}

func NewInMemoryProcessor() ResultProcessor {
	return &InMemoryProcessor{
		hostMap:    make(map[string]*models.HostResult),
		portCounts: make(map[int]int),
	}
}
