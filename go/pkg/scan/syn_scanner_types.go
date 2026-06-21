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
	"math/rand/v2"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"golang.org/x/sys/unix"
)

// SYNScanner performs SYN scanning (half-open scanning) for faster TCP port detection.
//
// For maximum accuracy, consider setting iptables rules to drop outbound RSTs from your
// ephemeral port range to prevent kernel interference:
//
//	iptables -A OUTPUT -p tcp --tcp-flags RST RST --sport 32768:61000 -j DROP
//
// or with nftables:
//
//	nft add rule inet filter output tcp flags rst tcp sport 32768-61000 drop
//
// This implementation sniffs replies via AF_PACKET + TPACKET_V3 ring (zero-copy),
// uses classic BPF to reduce userland traffic, and PACKET_FANOUT to scale across cores.
// Packet crafting uses raw IPv4+TCP with IP_HDRINCL (unsafe only for ring setup, not packet crafting).
//
// Linux-only.
// https://www.kernel.org/doc/Documentation/networking/packet_mmap.txt
type SYNScanner struct {
	timeout     time.Duration
	concurrency int
	logger      logger.Logger

	sendSocket  int // Raw IPv4 socket for sending (IP_HDRINCL enabled)
	sendSocket6 int // Raw IPv6 socket for sending full IPv6 packets
	rings       []*ringBuf
	cancel      context.CancelFunc

	sourceIP  net.IP
	sourceIP6 net.IP
	iface     string // Network interface name

	fanoutGroup int
	retireTovMs uint32 // configurable retire timeout in milliseconds
	// ringPollTimeoutMs controls how long ring readers block in poll().
	// If <=0, defaults to max(retireTovMs, 50ms) to avoid busy wakeups.
	ringPollTimeoutMs int

	mu            sync.Mutex
	portTargetMap map[uint16]string   // Maps source port -> target key ("ip:port")
	targetPorts   map[string][]uint16 // Maps target key -> source ports (reverse index)
	targetIP      map[string]string   // target key -> canonical destination IP
	results       map[string]models.Result

	portAlloc *PortAllocator

	retryAttempts  int           // e.g., 2
	retryMinJitter time.Duration // e.g., 20 * time.Millisecond
	retryMaxJitter time.Duration // e.g., 40 * time.Millisecond

	rl atomic.Value // stores rateLimiter (never nil after initialization)

	// Batched retry queue
	retryCh chan retryItem

	readersWG sync.WaitGroup // tracks the outer listener, which itself waits for all ring readers

	// Internal enqueue callback (set by Scan) and user callback (settable anytime).
	// Do NOT call user callback from ring threads; tee it in the emitter goroutine.
	resultCallback func(models.Result) // internal, owned by Scan
	userCallback   atomic.Value        // of type func(models.Result)

	// Packet template for allocation reuse
	packetTemplate [40]byte // IPv4 (20) + TCP (20) header template

	// Sendmmsg batch configuration
	sendBatchSize int

	// Pool for sendmmsg batch arrays to reduce allocations
	batchPool sync.Pool

	// Pool for 40-byte packet buffers to reduce GC churn in hot path
	packetPool sync.Pool

	// Dynamic port range for scanning (avoiding system ephemeral ports)
	scanPortStart uint16
	scanPortEnd   uint16

	// Port deadline tracking for reaper (replaces per-port time.AfterFunc)
	portDeadline map[uint16]time.Time

	// Reaper for coarse port cleanup sweeps
	reaperWG     sync.WaitGroup
	reaperCancel context.CancelFunc

	// Thread-safe random source for IP ID generation
	randMu sync.Mutex
	rand   *rand.Rand

	// Observability counters for performance monitoring
	stats ScannerStats

	// wakeFD is an eventfd used to wake ring readers from blocking poll
	// on scan cancellation, eliminating periodic poll timeouts and syscalls.
	wakeFD int
}

var _ Scanner = (*SYNScanner)(nil)
var _ CapabilityProvider = (*SYNScanner)(nil)

// SYNScannerOptions contains optional configuration for the SYN scanner
type SYNScannerOptions struct {
	// SendBatchSize is the number of packets to send per sendmmsg call
	// If 0, defaults to defaultSendBatchSize or SENDMMSG_BATCH_SIZE env var
	SendBatchSize int
	// RateLimit is the packets per second limit
	// If 0, a safe default will be calculated based on port window and timeout
	RateLimit int
	// RateLimitBurst is the burst size for rate limiting
	// If 0, defaults to RateLimit
	RateLimitBurst int
	// RouteDiscoveryHost is the target address for local IP discovery
	// If empty, defaults to "8.8.8.8:80"
	RouteDiscoveryHost string

	// Ring buffer tuning options for memory vs latency tradeoffs
	// RingBlockSize is the size of each ring buffer block in bytes
	// If 0, defaults to defaultBlockSize (1 MiB)
	RingBlockSize uint32
	// RingBlockCount is the number of blocks in the ring buffer
	// If 0, defaults to defaultBlockCount (8 blocks = 8 MiB total)
	RingBlockCount uint32
	// RingFrameSize is the frame size hint for packet alignment
	// If 0, defaults to defaultFrameSize (2048 bytes)
	RingFrameSize uint32

	// Interface specifies which network interface to use for scanning
	// If empty, the interface will be auto-detected based on routing table
	// Examples: "eth0", "wlan0", "enp0s3"
	// Useful for multi-homed hosts or container environments
	Interface string

	// NAT/Firewall options for advanced environments
	// SuppressRSTReply can be set to true to avoid generating RST packets
	// This helps in environments where firewall rules might interfere
	// Note: This is optional and most environments don't need it
	SuppressRSTReply bool

	// GlobalRingMemoryMB is the total memory cap (in MB) for all ring buffers
	// across all CPU cores. If 0, defaults to 64MB total. This prevents
	// excessive memory usage on high-CPU systems by distributing the cap.
	GlobalRingMemoryMB int

	// RingReaders limits the number of AF_PACKET ring readers (and rings).
	// If 0, defaults to min(4, runtime.NumCPU()). More readers can increase
	// wakeups on low-reply scans without benefit.
	RingReaders int

	// RingPollTimeoutMs sets the poll() timeout in milliseconds for ring readers.
	// If 0, defaults to max(TPACKET_RETIRE_TOV_MS, 50). Raising this reduces
	// wakeups when traffic is sparse, cutting CPU in listenForReplies.
	RingPollTimeoutMs int
}

func (s *SYNScanner) Capabilities() ScannerCapabilities {
	caps := ScannerCapabilities{
		RawSYNIPv4:  s != nil && s.sendSocket != 0 && s.sourceIP.To4() != nil,
		RawSYNIPv6:  s != nil && s.sendSocket6 != 0 && s.sourceIP6.To16() != nil && s.sourceIP6.To4() == nil,
		Diagnostics: make(map[string]string, 1),
	}

	if caps.RawSYNIPv6 {
		caps.Diagnostics["raw_syn_ipv6"] = "enabled"
	} else {
		caps.Diagnostics["raw_syn_ipv6"] = "unavailable: no raw IPv6 send socket and usable local IPv6 source address on the scanner interface"
	}

	return caps
}

// batchArrays holds reusable arrays for sendmmsg batching
type batchArrays struct {
	addrs  []unix.RawSockaddrInet4
	addrs6 []unix.RawSockaddrInet6
	iovecs []unix.Iovec
	hdrs   []Mmsghdr
}

type synBatchEntry struct {
	dst4      [4]byte
	dst6      [16]byte
	ipv6      bool
	srcPort   uint16
	packet    []byte
	pooled    bool
	targetKey string
	target    models.Target
}
