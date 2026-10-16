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
	"fmt"
	"sync/atomic"
	"time"

	"golang.org/x/sys/unix"
)

// scanGateWaitLogThreshold is how long a scan may wait for the scan ahead of
// it before the wait is logged.
const scanGateWaitLogThreshold = time.Second

// acquire takes the gate, or returns the context's error if it ends first.
// An already cancelled context never takes the gate.
func (g *SYNScanGate) acquire(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}

	select {
	case g.slot <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (g *SYNScanGate) release() {
	<-g.slot
}

func (s *SYNScanner) waitForScanGate(ctx context.Context, gate *SYNScanGate) error {
	start := time.Now()

	if err := gate.acquire(ctx); err != nil {
		return err
	}

	if waited := time.Since(start); waited >= scanGateWaitLogThreshold {
		s.logger.Info().
			Dur("waited", waited).
			Msg("Raw SYN scan waited for another scan on this agent to finish")
	}

	return nil
}

func (s *SYNScanner) scanRunning() bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	return s.cancel != nil
}

// startCaptureLocked attaches the reply filter to every ring, then discards
// whatever the rings already hold and clears their kernel counters, so the
// scan about to start reads and counts only its own replies. The caller holds
// s.mu, which Stop also takes before it closes the rings.
func (s *SYNScanner) startCaptureLocked() error {
	if len(s.replyFilter) == 0 {
		return nil
	}

	for _, r := range s.rings {
		if r == nil || r.fd <= 0 {
			continue
		}

		if err := attachSocketFilter(r.fd, s.replyFilter); err != nil {
			// A ring left on the idle filter would report every target as
			// unreachable, so fail the scan rather than run it half deaf.
			s.stopCaptureLocked()

			return fmt.Errorf("attach reply filter to ring: %w", err)
		}
	}

	for _, r := range s.rings {
		if r == nil || r.fd <= 0 {
			continue
		}

		if released := r.releaseReadyBlocks(); released > 0 {
			s.logger.Debug().
				Int("ring_fd", r.fd).
				Int("blocks", released).
				Msg("Discarded ring blocks captured before this scan")
		}

		// Reading PACKET_STATISTICS resets the kernel's drop counter.
		_, _ = unix.GetsockoptTpacketStats(r.fd, unix.SOL_PACKET, unix.PACKET_STATISTICS)
	}

	return nil
}

// stopCaptureLocked puts every ring back on the idle filter. The caller holds
// s.mu.
func (s *SYNScanner) stopCaptureLocked() {
	for _, r := range s.rings {
		if r == nil || r.fd <= 0 {
			continue
		}

		if err := attachSocketFilter(r.fd, idleCaptureFilter()); err != nil {
			s.logger.Warn().
				Err(err).
				Int("ring_fd", r.fd).
				Msg("Failed to put ring back on the idle capture filter")
		}
	}
}

// releaseReadyBlocks hands every block the kernel has passed to user space
// back to it unread, starting at the reader cursor, and returns how many it
// released. No ring reader may be running.
func (r *ringBuf) releaseReadyBlocks() int {
	if r == nil || r.blockNr == 0 {
		return 0
	}

	cur := atomic.LoadUint32(&r.cursor) % r.blockNr
	released := 0

	for released < int(r.blockNr) {
		blk := r.block(cur)
		if blk == nil || len(blk) < int(h1_first_pkt_off+uint32Size) {
			break
		}

		if loadU32(blk)&tpStatusUser == 0 {
			break
		}

		storeU32(blk, h1_status_off, 0)

		cur = (cur + 1) % r.blockNr
		released++
	}

	atomic.StoreUint32(&r.cursor, cur)

	return released
}
