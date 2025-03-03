/*
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
