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
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Stop gracefully stops the scanner
func (s *SYNScanner) Stop() error {
	// Grab and clear the cancel func WITHOUT holding the lock while we wait
	var cancel context.CancelFunc

	s.mu.Lock()
	cancel = s.cancel
	s.cancel = nil
	s.mu.Unlock()

	if cancel != nil {
		cancel()
	}

	// IMPORTANT: wait for the listener (and thus all ring readers) to exit
	// Do NOT hold s.mu here (processEthernetFrame uses it).
	s.readersWG.Wait()

	// Now it is safe to unmap/close the ring and socket resources.
	s.mu.Lock()
	s.retryCh = nil // prevent accidental future sends

	toRelease := make([]uint16, 0, len(s.portTargetMap))

	for src := range s.portTargetMap {
		toRelease = append(toRelease, src)
	}

	// keep non-nil to avoid panics
	s.portTargetMap = make(map[uint16]string)
	s.targetPorts = make(map[string][]uint16)
	s.portDeadline = make(map[uint16]time.Time) // clear deadline map
	s.targetIP = nil                            // drop memory faster (re-init on next Scan())
	s.results = nil                             // drop memory faster (re-init on next Scan())

	s.mu.Unlock()

	// Stop the reaper if it's running
	if s.reaperCancel != nil {
		s.reaperCancel()
		s.reaperWG.Wait()
		s.reaperCancel = nil
	}

	for _, src := range toRelease {
		s.portAlloc.Release(src)
		atomic.AddUint64(&s.stats.PortsReleased, 1)
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	var err error

	for _, r := range s.rings {
		if r.mem != nil {
			if e := unix.Munmap(r.mem); e != nil && err == nil {
				err = e
			}

			r.mem = nil
		}

		if r.fd != 0 {
			if e := unix.Close(r.fd); e != nil && err == nil {
				err = e
			}

			r.fd = 0
		}
	}

	s.rings = nil

	if s.sendSocket != 0 {
		if e := syscall.Close(s.sendSocket); e != nil && err == nil {
			err = e
		}

		s.sendSocket = 0
	}

	if s.sendSocket6 != 0 {
		if e := syscall.Close(s.sendSocket6); e != nil && err == nil {
			err = e
		}

		s.sendSocket6 = 0
	}

	return err
}
