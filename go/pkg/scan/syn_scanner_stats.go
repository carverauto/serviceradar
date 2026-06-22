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
	"unsafe"

	"golang.org/x/sys/unix"
)

// ScannerStats holds performance and diagnostic counters
type ScannerStats struct {
	// Packet statistics
	PacketsSent    uint64 // Total SYN packets sent
	PacketsRecv    uint64 // Total packets received (SYN-ACK, RST, etc.)
	PacketsDropped uint64 // Packets dropped by kernel (ring buffer full)

	// Ring buffer statistics
	RingBlocksProcessed uint64 // TPACKET_V3 blocks processed
	RingBlocksDropped   uint64 // TPACKET_V3 blocks lost due to buffer overruns (TP_STATUS_LOSING)

	// Retry statistics
	RetriesAttempted  uint64 // Number of retry packets actually sent
	RetriesSuccessful uint64 // Number of successful retries
	RetriesDropped    uint64 // Number of retry attempts dropped before send

	// Port allocation statistics
	PortsAllocated uint64 // Total port allocations
	PortsReleased  uint64 // Total port releases
	PortExhaustion uint64 // Number of times port allocator was exhausted

	// Rate limiting statistics
	RateLimitDeferrals  uint64 // Legacy aggregate of packet send deferrals
	RateLimitWaits      uint64 // Token-bucket wait events
	SourcePortWaits     uint64 // Source-port allocator wait events
	RateLimitWaitNanos  uint64 // Total token-bucket wait time in nanoseconds
	SourcePortWaitNanos uint64 // Total source-port wait time in nanoseconds

	// Timing statistics (in nanoseconds, for precision)
	LastStatsReset int64 // Timestamp of last stats reset (UnixNano)

	// TCP connect statistics
	DialsStarted       uint64 // Total full TCP connect dials started
	DialsSucceeded     uint64 // Total full TCP connect dials that established
	DialTimeouts       uint64 // Dial attempts that timed out
	DialResets         uint64 // Dial attempts refused or reset by remote endpoint
	DialResourceErrors uint64 // Dial attempts blocked by local fd/port/buffer pressure
	ActiveDials        uint64 // Current in-flight full TCP connect dials
	MaxActiveDials     uint64 // High-water mark of in-flight full TCP connect dials
	QueueDepth         uint64 // Latest observed scanner input queue depth
	MaxQueueDepth      uint64 // High-water mark of scanner input queue depth
}

// GetStats returns a snapshot of scanner performance statistics
// Safe to call concurrently during scans
func (s *SYNScanner) GetStats() ScannerStats {
	// Use atomic loads to ensure consistent snapshot
	return ScannerStats{
		PacketsSent:         atomic.LoadUint64(&s.stats.PacketsSent),
		PacketsRecv:         atomic.LoadUint64(&s.stats.PacketsRecv),
		PacketsDropped:      atomic.LoadUint64(&s.stats.PacketsDropped),
		RingBlocksProcessed: atomic.LoadUint64(&s.stats.RingBlocksProcessed),
		RingBlocksDropped:   atomic.LoadUint64(&s.stats.RingBlocksDropped),
		RetriesAttempted:    atomic.LoadUint64(&s.stats.RetriesAttempted),
		RetriesSuccessful:   atomic.LoadUint64(&s.stats.RetriesSuccessful),
		RetriesDropped:      atomic.LoadUint64(&s.stats.RetriesDropped),
		PortsAllocated:      atomic.LoadUint64(&s.stats.PortsAllocated),
		PortsReleased:       atomic.LoadUint64(&s.stats.PortsReleased),
		PortExhaustion:      atomic.LoadUint64(&s.stats.PortExhaustion),
		RateLimitDeferrals:  atomic.LoadUint64(&s.stats.RateLimitDeferrals),
		RateLimitWaits:      atomic.LoadUint64(&s.stats.RateLimitWaits),
		SourcePortWaits:     atomic.LoadUint64(&s.stats.SourcePortWaits),
		RateLimitWaitNanos:  atomic.LoadUint64(&s.stats.RateLimitWaitNanos),
		SourcePortWaitNanos: atomic.LoadUint64(&s.stats.SourcePortWaitNanos),
		LastStatsReset:      atomic.LoadInt64(&s.stats.LastStatsReset),
		DialsStarted:        atomic.LoadUint64(&s.stats.DialsStarted),
		DialsSucceeded:      atomic.LoadUint64(&s.stats.DialsSucceeded),
		DialTimeouts:        atomic.LoadUint64(&s.stats.DialTimeouts),
		DialResets:          atomic.LoadUint64(&s.stats.DialResets),
		DialResourceErrors:  atomic.LoadUint64(&s.stats.DialResourceErrors),
		ActiveDials:         atomic.LoadUint64(&s.stats.ActiveDials),
		MaxActiveDials:      atomic.LoadUint64(&s.stats.MaxActiveDials),
		QueueDepth:          atomic.LoadUint64(&s.stats.QueueDepth),
		MaxQueueDepth:       atomic.LoadUint64(&s.stats.MaxQueueDepth),
	}
}

// ResetStats clears all performance counters and updates the reset timestamp
func (s *SYNScanner) ResetStats() {
	atomic.StoreUint64(&s.stats.PacketsSent, 0)
	atomic.StoreUint64(&s.stats.PacketsRecv, 0)
	atomic.StoreUint64(&s.stats.PacketsDropped, 0)
	atomic.StoreUint64(&s.stats.RingBlocksProcessed, 0)
	atomic.StoreUint64(&s.stats.RingBlocksDropped, 0)
	atomic.StoreUint64(&s.stats.RetriesAttempted, 0)
	atomic.StoreUint64(&s.stats.RetriesSuccessful, 0)
	atomic.StoreUint64(&s.stats.RetriesDropped, 0)
	atomic.StoreUint64(&s.stats.PortsAllocated, 0)
	atomic.StoreUint64(&s.stats.PortsReleased, 0)
	atomic.StoreUint64(&s.stats.PortExhaustion, 0)
	atomic.StoreUint64(&s.stats.RateLimitDeferrals, 0)
	atomic.StoreUint64(&s.stats.RateLimitWaits, 0)
	atomic.StoreUint64(&s.stats.SourcePortWaits, 0)
	atomic.StoreUint64(&s.stats.RateLimitWaitNanos, 0)
	atomic.StoreUint64(&s.stats.SourcePortWaitNanos, 0)
	atomic.StoreUint64(&s.stats.DialsStarted, 0)
	atomic.StoreUint64(&s.stats.DialsSucceeded, 0)
	atomic.StoreUint64(&s.stats.DialTimeouts, 0)
	atomic.StoreUint64(&s.stats.DialResets, 0)
	atomic.StoreUint64(&s.stats.DialResourceErrors, 0)
	atomic.StoreUint64(&s.stats.ActiveDials, 0)
	atomic.StoreUint64(&s.stats.MaxActiveDials, 0)
	atomic.StoreUint64(&s.stats.QueueDepth, 0)
	atomic.StoreUint64(&s.stats.MaxQueueDepth, 0)
	atomic.StoreInt64(&s.stats.LastStatsReset, time.Now().UnixNano())
}

func (s *SYNScanner) recordRateLimitWait(d time.Duration) {
	atomic.AddUint64(&s.stats.RateLimitDeferrals, 1)
	atomic.AddUint64(&s.stats.RateLimitWaits, 1)
	atomic.AddUint64(&s.stats.RateLimitWaitNanos, uint64(d))
}

func (s *SYNScanner) recordSourcePortWait(d time.Duration) {
	atomic.AddUint64(&s.stats.RateLimitDeferrals, 1)
	atomic.AddUint64(&s.stats.SourcePortWaits, 1)
	atomic.AddUint64(&s.stats.SourcePortWaitNanos, uint64(d))
}

// sampleKernelStats samples PACKET_STATISTICS from all ring buffers to track kernel drops
func (s *SYNScanner) sampleKernelStats() {
	s.mu.Lock()
	rings := s.rings
	s.mu.Unlock()

	if rings == nil {
		return
	}

	for _, ring := range rings {
		if ring == nil {
			continue
		}

		var st unix.TpacketStats

		optlen := uint32(unsafe.Sizeof(st))

		// Use unix.Syscall with proper getsockopt call
		r1, _, errno := unix.Syscall6(unix.SYS_GETSOCKOPT,
			uintptr(ring.fd),
			uintptr(unix.SOL_PACKET),
			uintptr(unix.PACKET_STATISTICS),
			uintptr(unsafe.Pointer(&st)),
			uintptr(unsafe.Pointer(&optlen)),
			0)
		if errno == 0 && r1 == 0 {
			// PACKET_STATISTICS resets on read; just accumulate drops
			atomic.AddUint64(&s.stats.PacketsDropped, uint64(st.Drops))
		}
	}
}

// logTelemetry periodically logs scanner performance statistics
// to detect silent performance regressions
func (s *SYNScanner) logTelemetry(ctx context.Context) {
	ticker := time.NewTicker(telemetryLogInterval) // Log every 30s during active scans
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// Sample kernel drop stats from all ring buffers
			s.sampleKernelStats()

			stats := s.GetStats()

			// Only log if there's been activity
			if stats.PacketsSent > 0 || stats.PacketsRecv > 0 {
				// Compute RX drop rate (ring buffer drops vs total packets that could be received)
				rxDropRate := float64(0)
				rxDropDen := stats.PacketsRecv + stats.PacketsDropped

				if rxDropDen > 0 {
					rxDropRate = 100 * float64(stats.PacketsDropped) / float64(rxDropDen)
				}

				// Include limiter shard count for visibility
				rlShards := 1

				if v := s.rl.Load(); v != nil {
					switch lim := v.(type) {
					case *shardedTokenBucket:
						rlShards = lim.shards
					case *tokenBucket:
						rlShards = 1
					}
				}

				s.logger.Info().
					Uint64("packets_sent", stats.PacketsSent).
					Uint64("packets_recv", stats.PacketsRecv).
					Uint64("packets_dropped", stats.PacketsDropped).
					Float64("rx_drop_rate_percent", rxDropRate).
					Uint64("ring_blocks_processed", stats.RingBlocksProcessed).
					Uint64("ring_blocks_dropped", stats.RingBlocksDropped).
					Uint64("retries_attempted", stats.RetriesAttempted).
					Uint64("retries_successful", stats.RetriesSuccessful).
					Uint64("retries_dropped", stats.RetriesDropped).
					Uint64("ports_allocated", stats.PortsAllocated).
					Uint64("rate_limit_deferrals", stats.RateLimitDeferrals).
					Uint64("rate_limit_waits", stats.RateLimitWaits).
					Uint64("source_port_waits", stats.SourcePortWaits).
					Int("rl_shards", rlShards).
					Msg("SYN scanner telemetry")
			}
		}
	}
}

// u32ptr gets a pointer to a uint32 at a specific offset in a byte slice.
// mmap'd memory is shared; use atomics to enforce ordering with the kernel.
