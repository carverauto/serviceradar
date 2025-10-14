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

	startOnce sync.Once

	ctxMu  sync.RWMutex
	ctx    context.Context
	cancel context.CancelFunc

	mu      sync.RWMutex
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

func (s *bufferedSampler) start(parent context.Context) {
	s.ensureContext(parent)

	s.startOnce.Do(func() {
		go s.loop()
	})
}

func (s *bufferedSampler) loop() {
	ticker := time.NewTicker(s.interval)
	defer ticker.Stop()

	for range ticker.C {
		ctx := s.context()
		select {
		case <-ctx.Done():
			return
		default:
		}
		s.collectOnce()
	}
}

func (s *bufferedSampler) collectOnce() {
	if s.collect == nil {
		return
	}

	parent := s.context()
	ctx, cancel := context.WithTimeout(parent, s.timeout)
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

func (s *bufferedSampler) ensureContext(parent context.Context) {
	s.ctxMu.Lock()
	defer s.ctxMu.Unlock()

	if s.ctx != nil {
		return
	}

	if parent == nil {
		parent = context.Background()
	}

	s.ctx, s.cancel = context.WithCancel(parent)
}

func (s *bufferedSampler) context() context.Context {
	s.ctxMu.RLock()
	ctx := s.ctx
	s.ctxMu.RUnlock()

	if ctx == nil {
		s.ensureContext(nil)
		s.ctxMu.RLock()
		ctx = s.ctx
		s.ctxMu.RUnlock()
	}

	return ctx
}
