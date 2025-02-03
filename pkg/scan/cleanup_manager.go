package scan

import (
	"sync"
	"time"
)

type cleanupManager struct {
	ticker  *time.Ticker
	done    chan struct{}
	cleanup func()
	wg      sync.WaitGroup
}

func newCleanupManager(interval time.Duration, cleanup func()) *cleanupManager {
	return &cleanupManager{
		ticker:  time.NewTicker(interval),
		done:    make(chan struct{}),
		cleanup: cleanup,
	}
}

func (m *cleanupManager) start() {
	m.wg.Add(1)
	go func() {
		defer m.wg.Done()
		defer m.ticker.Stop()

		for {
			select {
			case <-m.done:
				return
			case <-m.ticker.C:
				m.cleanup()
			}
		}
	}()
}

func (m *cleanupManager) stop() {
	close(m.done)
	m.wg.Wait()
}
