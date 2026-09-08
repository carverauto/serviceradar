//go:build linux
// +build linux

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
	"context"
	"sync/atomic"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

// tryReleaseMapping safely releases a src port mapping if it still belongs to key k.
func (s *SYNScanner) tryReleaseMapping(sp uint16, k string) {
	// Determine whether to release by checking mappings while holding lock
	s.mu.Lock()

	shouldRelease := false

	if s.portTargetMap != nil {
		if cur, ok := s.portTargetMap[sp]; ok && cur == k {
			delete(s.portTargetMap, sp)
			delete(s.portDeadline, sp) // Clean up deadline entry

			shouldRelease = true

			// Also remove from reverse index
			if ports, exists := s.targetPorts[k]; exists {
				// Remove sp from the slice
				for i, p := range ports {
					if p == sp {
						s.targetPorts[k] = append(ports[:i], ports[i+1:]...)

						// If slice is now empty, delete the entry to avoid memory leaks
						if len(s.targetPorts[k]) == 0 {
							delete(s.targetPorts, k)
						}

						break
					}
				}
			}
		}
	}

	s.mu.Unlock()

	// Release synchronously outside the lock to avoid goroutine-per-release overhead
	if shouldRelease {
		s.portAlloc.Release(sp)
		atomic.AddUint64(&s.stats.PortsReleased, 1)
	}
}

func (s *SYNScanner) hasFinalResult(targetKey string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	r, ok := s.results[targetKey]

	return ok && (r.Available || r.Error != nil)
}

// SetResultCallback sets a callback function that will be called immediately when a result becomes available
func (s *SYNScanner) SetResultCallback(callback func(models.Result)) {
	// Allow changing user callback at any time without touching the internal one.
	s.userCallback.Store(callback)
}

// emitResult stores the result and, if definitive, calls the callback *after* releasing s.mu.
// Callers MUST NOT hold s.mu when invoking this function.
func (s *SYNScanner) emitResult(targetKey string, result models.Result) {
	var cb func(models.Result)

	s.mu.Lock()

	if s.results == nil {
		s.results = make(map[string]models.Result)
	}

	s.results[targetKey] = result
	if s.resultCallback != nil && (result.Available || result.Error != nil) {
		cb = s.resultCallback
	}

	s.mu.Unlock()

	if cb != nil {
		cb(result)
	}
}

// startReaper begins the coarse port cleanup sweeper that replaces per-port timers
func (s *SYNScanner) startReaper() {
	if s.reaperCancel != nil {
		return // already running
	}

	// Calculate dynamic reaper interval based on scan timeout
	// Use min(50ms, scanTimeout/10) with bounds [5ms, 100ms]
	interval := s.timeout / 10
	if interval > 50*time.Millisecond {
		interval = 50 * time.Millisecond
	}

	if interval < 5*time.Millisecond {
		interval = 5 * time.Millisecond
	}

	if interval > 100*time.Millisecond {
		interval = 100 * time.Millisecond
	}

	s.logger.Debug().Dur("interval", interval).Dur("timeout", s.timeout).
		Msg("Starting reaper with dynamic interval")

	ctx, cancel := context.WithCancel(context.Background())
	s.reaperCancel = cancel
	s.reaperWG.Add(1)

	go func() {
		defer s.reaperWG.Done()

		ticker := time.NewTicker(interval)
		defer ticker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				now := time.Now()

				// Gather candidates outside the lock
				type pair struct {
					sp  uint16
					key string
				}

				var victims []pair

				s.mu.Lock()

				for sp, dl := range s.portDeadline {
					if now.After(dl) {
						key := s.portTargetMap[sp]
						victims = append(victims, pair{sp, key})

						delete(s.portDeadline, sp)
					}
				}

				s.mu.Unlock()

				// Release expired mappings
				for _, v := range victims {
					s.tryReleaseMapping(v.sp, v.key)
				}
			}
		}
	}()
}
