//go:build darwin

package cpufreq

import (
	"context"
	"sync"
	"time"
)

type bufferEntry struct {
	snapshot  *Snapshot
	collected time.Time
}

type samplerCollector func(context.Context) (*Snapshot, error)

type bufferedSampler struct {
	interval  time.Duration
	retention time.Duration
	timeout   time.Duration
	collect   samplerCollector

	once sync.Once
	mu   sync.RWMutex

	entries []bufferEntry
	next    int
	count   int
}

func newBufferedSampler(interval, retention, timeout time.Duration, collect samplerCollector) *bufferedSampler {
	if interval <= 0 {
		interval = time.Second
	}
	if timeout <= 0 {
		timeout = interval
	}
	if retention < interval {
		retention = interval * 5
	}

	capacity := int(retention/interval) + 1
	if capacity < 1 {
		capacity = 1
	}

	return &bufferedSampler{
		interval:  interval,
		retention: retention,
		timeout:   timeout,
		collect:   collect,
		entries:   make([]bufferEntry, capacity),
	}
}

func (s *bufferedSampler) start() {
	s.once.Do(func() {
		go s.loop()
	})
}

func (s *bufferedSampler) loop() {
	ticker := time.NewTicker(s.interval)
	defer ticker.Stop()

	s.collectOnce()

	for range ticker.C {
		s.collectOnce()
	}
}

func (s *bufferedSampler) collectOnce() {
	if s.collect == nil {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), s.timeout)
	defer cancel()

	snapshot, err := s.collect(ctx)
	if err != nil {
		return
	}

	s.record(snapshot, time.Now())
}

func (s *bufferedSampler) record(snapshot *Snapshot, collected time.Time) {
	if snapshot == nil {
		return
	}

	snapCopy := snapshotClone(snapshot)

	s.mu.Lock()
	defer s.mu.Unlock()

	if len(s.entries) == 0 {
		return
	}

	s.entries[s.next] = bufferEntry{
		snapshot:  snapCopy,
		collected: collected,
	}
	s.next = (s.next + 1) % len(s.entries)
	if s.count < len(s.entries) {
		s.count++
	}
}

func (s *bufferedSampler) latest() (*Snapshot, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.count == 0 {
		return nil, false
	}

	idx := s.next - 1
	if idx < 0 {
		idx = len(s.entries) - 1
	}

	entry := s.entries[idx]
	if entry.snapshot == nil {
		return nil, false
	}

	if time.Since(entry.collected) > s.retention {
		return nil, false
	}

	return snapshotClone(entry.snapshot), true
}
