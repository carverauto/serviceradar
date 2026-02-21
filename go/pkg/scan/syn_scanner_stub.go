//go:build !linux
// +build !linux

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
	"errors"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

var (
	// ErrSYNScanNotSupported is returned when SYN scanning is attempted on non-Linux platforms
	ErrSYNScanNotSupported = errors.New("SYN scanning is only supported on Linux")
)

// SYNScanner is a stub implementation for non-Linux platforms
type SYNScanner struct{}

// SYNScannerOptions contains optional configuration for the SYN scanner
type SYNScannerOptions struct {
	// SendBatchSize is the number of packets to send per sendmmsg call
	SendBatchSize int
	// RateLimit is the packets per second limit
	RateLimit int
	// RateLimitBurst is the burst size for rate limiting
	RateLimitBurst int
	// RouteDiscoveryHost is the target address for local IP discovery
	RouteDiscoveryHost string

	// Ring buffer tuning options (not used in stub but kept for API compatibility)
	RingBlockSize  uint32
	RingBlockCount uint32
	RingFrameSize  uint32

	// Interface selection (not used in stub but kept for API compatibility)
	Interface string

	// NAT/Firewall options (not used in stub but kept for API compatibility)
	SuppressRSTReply bool
	// GlobalRingMemoryMB is the total memory cap (in MB) for all ring buffers
	// (not used in stub but kept for API compatibility)
	GlobalRingMemoryMB int

	// Ring tuning (not used in stub but kept for API compatibility)
	RingReaders       int
	RingPollTimeoutMs int
}

var _ Scanner = (*SYNScanner)(nil)

// NewSYNScanner creates a new SYN scanner stub that returns an error on non-Linux platforms
func NewSYNScanner(_ time.Duration, _ int, _ logger.Logger, _ *SYNScannerOptions) (*SYNScanner, error) {
	return nil, fmt.Errorf("%w", ErrSYNScanNotSupported)
}

// Scan returns an error indicating SYN scanning is not supported on this platform
func (*SYNScanner) Scan(_ context.Context, _ []models.Target) (<-chan models.Result, error) {
	return nil, fmt.Errorf("%w", ErrSYNScanNotSupported)
}

// Stop returns an error indicating SYN scanning is not supported on this platform
func (*SYNScanner) Stop() error {
	return fmt.Errorf("%w", ErrSYNScanNotSupported)
}

// ScannerStats holds performance and diagnostic counters for the scanner.
// This is a stub implementation for non-Linux platforms with the same fields
// as the Linux version for API compatibility.
type ScannerStats struct {
	// Packet statistics
	PacketsSent    uint64 // Total SYN packets sent
	PacketsRecv    uint64 // Total packets received (SYN-ACK, RST, etc.)
	PacketsDropped uint64 // Packets dropped by kernel (ring buffer full)

	// Ring buffer statistics
	RingBlocksProcessed uint64 // TPACKET_V3 blocks processed
	RingBlocksDropped   uint64 // TPACKET_V3 blocks lost due to buffer overruns

	// Retry statistics
	RetriesAttempted  uint64 // Number of retry attempts made
	RetriesSuccessful uint64 // Number of successful retries

	// Port allocation statistics
	PortsAllocated uint64 // Total port allocations
	PortsReleased  uint64 // Total port releases
	PortExhaustion uint64 // Number of times port allocator was exhausted

	// Rate limiting statistics
	RateLimitDeferrals uint64 // Packet send operations deferred due to rate limiting
}

// GetStats returns empty stats on non-Linux platforms.
func (*SYNScanner) GetStats() ScannerStats {
	return ScannerStats{}
}
