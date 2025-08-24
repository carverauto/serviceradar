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
	"container/heap"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"math/rand"
	"net"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe" // only for PACKET_RX_RING req pointer & tiny endianness probe

	"golang.org/x/sys/unix"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// Using architecture-specific sendmmsg implementation and Mmsghdr struct
// This ensures correct ABI/struct layout across all supported architectures
// Definitions are provided in separate files with build tags for each architecture
//
// TODO: IPv6 Support - implement separate v6 scanner with RAWv6 + eBPF/XDP or cBPF on ETH_P_IPV6
// This would require:
// - Separate IPv6 packet templates and header construction
// - IPv6-aware BPF filters (etherType 0x86DD, ICMPv6 handling)
// - AF_INET6 raw sockets with IPV6_HDRINCL equivalent
// - Neighbor discovery for L2 address resolution
// - Consider eBPF/XDP for better performance with IPv6 extension headers

// getRetireTovMs returns the configurable retire timeout in milliseconds.
// Checks TPACKET_RETIRE_TOV_MS environment variable, falls back to defaultRetireTovMs.
func getRetireTovMs() uint32 {
	if env := os.Getenv("TPACKET_RETIRE_TOV_MS"); env != "" {
		if ms, err := strconv.ParseUint(env, 10, 32); err == nil && ms >= 1 && ms <= 100 {
			return uint32(ms)
		}
	}

	return defaultRetireTovMs
}

// getSendBatchSize returns the configurable sendmmsg batch size.
// Checks SENDMMSG_BATCH_SIZE environment variable, falls back to defaultSendBatchSize.
func getSendBatchSize() int {
	if env := os.Getenv("SENDMMSG_BATCH_SIZE"); env != "" {
		if size, err := strconv.Atoi(env); err == nil && size >= 1 && size <= 512 {
			return size
		}
	}

	return defaultSendBatchSize
}

const (
	// TCP flags
	synFlag = 0x02
	rstFlag = 0x04
	ackFlag = 0x10

	// Default ephemeral port range (will be replaced by dynamic detection)
	// Keep these only as absolute fallbacks
	defaultEphemeralPortStart = 32768
	defaultEphemeralPortEnd   = 61000

	// Network constants
	defaultTCPWindow = 65535
	maxPortNumber    = 65535

	// Ethernet type
	etherTypeIPv4 = 0x0800
	etherTypeVLAN = 0x8100
	etherTypeQinQ = 0x88A8
	etherType9100 = 0x9100 // common vendor tag

	// TPACKETv3 constants / defaults
	defaultBlockSize   = 1 << 20 // 1 MiB per block
	defaultBlockCount  = 8       // 8 MiB total ring (was 64 - overkill)
	defaultFrameSize   = 2048    // alignment hint
	defaultRetireTovMs = 10      // flush block to user within 10ms (configurable via env or constructor)

	// Memory limits to prevent excessive allocation on large SMP systems
	defaultGlobalRingMemoryMB = 64      // Default global ring buffer memory cap in MB (distributed across CPUs)
	maxBlockSize              = 8 << 20 // Maximum block size: 8 MiB
	maxBlockCount             = 32      // Maximum number of blocks

	// tpacket v3 block ownership
	tpStatusUser   = 0x0001 // TP_STATUS_USER
	tpStatusLosing = 0x0004 // TP_STATUS_LOSING (see linux/if_packet.h)

	// Max number of SYNs to send per sendmmsg() call.
	// 32–128 is typically a sweet spot; 64 is a safe default.
	defaultSendBatchSize = 64

	// Size of the retry queue channel (enough for large scans with a couple of attempts).
	retryQueueSize = 1 << 17 // 131072
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
	RetriesAttempted  uint64 // Number of retry attempts made
	RetriesSuccessful uint64 // Number of successful retries

	// Port allocation statistics
	PortsAllocated uint64 // Total port allocations
	PortsReleased  uint64 // Total port releases
	PortExhaustion uint64 // Number of times port allocator was exhausted

	// Rate limiting statistics
	RateLimitDeferrals uint64 // Packet send operations deferred due to rate limiting

	// Timing statistics (in nanoseconds, for precision)
	LastStatsReset int64 // Timestamp of last stats reset (UnixNano)
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
		PortsAllocated:      atomic.LoadUint64(&s.stats.PortsAllocated),
		PortsReleased:       atomic.LoadUint64(&s.stats.PortsReleased),
		PortExhaustion:      atomic.LoadUint64(&s.stats.PortExhaustion),
		RateLimitDeferrals:  atomic.LoadUint64(&s.stats.RateLimitDeferrals),
		LastStatsReset:      atomic.LoadInt64(&s.stats.LastStatsReset),
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
	atomic.StoreUint64(&s.stats.PortsAllocated, 0)
	atomic.StoreUint64(&s.stats.PortsReleased, 0)
	atomic.StoreUint64(&s.stats.PortExhaustion, 0)
	atomic.StoreUint64(&s.stats.RateLimitDeferrals, 0)
	atomic.StoreInt64(&s.stats.LastStatsReset, time.Now().UnixNano())
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
		optlen := int(unsafe.Sizeof(st))
		
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
	ticker := time.NewTicker(30 * time.Second) // Log every 30s during active scans
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
				dropRate := float64(0)
				if stats.PacketsSent > 0 {
					dropRate = float64(stats.PacketsDropped) / float64(stats.PacketsSent) * 100
				}

				s.logger.Info().
					Uint64("packets_sent", stats.PacketsSent).
					Uint64("packets_recv", stats.PacketsRecv).
					Uint64("packets_dropped", stats.PacketsDropped).
					Float64("drop_rate_percent", dropRate).
					Uint64("ring_blocks_processed", stats.RingBlocksProcessed).
					Uint64("ring_blocks_dropped", stats.RingBlocksDropped).
					Uint64("retries_attempted", stats.RetriesAttempted).
					Uint64("retries_successful", stats.RetriesSuccessful).
					Uint64("ports_allocated", stats.PortsAllocated).
					Uint64("rate_limit_deferrals", stats.RateLimitDeferrals).
					Msg("SYN scanner telemetry")
			}
		}
	}
}

// u32ptr gets a pointer to a uint32 at a specific offset in a byte slice.
// mmap'd memory is shared; use atomics to enforce ordering with the kernel.
func u32ptr(b []byte, off int) *uint32 {
	return (*uint32)(unsafe.Pointer(&b[off]))
}

// loadU32 performs an atomic load, which acts as an "acquire" memory barrier.
func loadU32(b []byte, off int) uint32 {
	// Defensive check to prevent out-of-bounds access
	if off < 0 || off+4 > len(b) {
		return 0
	}

	return atomic.LoadUint32(u32ptr(b, off))
}

// storeU32 performs an atomic store, which acts as a "release" memory barrier.
func storeU32(b []byte, off int, v uint32) {
	// Defensive check to prevent out-of-bounds access
	if off < 0 || off+4 > len(b) {
		return
	}

	atomic.StoreUint32(u32ptr(b, off), v)
}

// Host-endian detector for tpacket headers (host-endian on Linux)
var hostEndian = func() binary.ByteOrder {
	var x uint16 = 0x0102

	b := *(*[2]byte)(unsafe.Pointer(&x))

	if b[0] == 0x01 {
		return binary.BigEndian
	}

	return binary.LittleEndian
}()

// tokenBucket is a tiny global limiter (tokens/sec with a burst).
type tokenBucket struct {
	rate  float64 // tokens per second
	burst float64 // max tokens
	mu    sync.Mutex
	toks  float64
	last  time.Time
}

func newTokenBucket(pps, burst int) *tokenBucket {
	if pps <= 0 {
		return nil
	}

	if burst <= 0 {
		burst = pps
	}

	return &tokenBucket{
		rate:  float64(pps),
		burst: float64(burst),
		toks:  float64(burst),
		last:  time.Now(),
	}
}

// AllowN returns how many tokens can be spent immediately (<= n).
func (tb *tokenBucket) AllowN(n int) int {
	tb.mu.Lock()
	defer tb.mu.Unlock()

	now := time.Now()

	dt := now.Sub(tb.last).Seconds()

	if dt > 0 {
		tb.toks += dt * tb.rate
		if tb.toks > tb.burst {
			tb.toks = tb.burst
		}

		tb.last = now
	}

	if tb.toks < 1 {
		return 0
	}

	want := float64(n)

	if tb.toks < want {
		n = int(tb.toks)
	}

	tb.toks -= float64(n)

	return n
}

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

	sendSocket int // Raw IPv4 socket for sending (IP_HDRINCL enabled)
	rings      []*ringBuf
	cancel     context.CancelFunc

	sourceIP net.IP
	iface    string // Network interface name

	fanoutGroup int
	retireTovMs uint32 // configurable retire timeout in milliseconds

	mu            sync.Mutex
	portTargetMap map[uint16]string   // Maps source port -> target key ("ip:port")
	targetPorts   map[string][]uint16 // Maps target key -> source ports (reverse index)
	targetIP      map[string][4]byte  // target key -> dest IPv4 bytes
	results       map[string]models.Result

	portAlloc *PortAllocator

	retryAttempts  int           // e.g., 2
	retryMinJitter time.Duration // e.g., 20 * time.Millisecond
	retryMaxJitter time.Duration // e.g., 40 * time.Millisecond

	rl atomic.Value // stores *tokenBucket

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
}

var _ Scanner = (*SYNScanner)(nil)

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
}

// batchArrays holds reusable arrays for sendmmsg batching
type batchArrays struct {
	addrs  []unix.RawSockaddrInet4
	iovecs []unix.Iovec
	hdrs   []Mmsghdr
}

// IPv4
type IPv4Hdr struct {
	IHL      uint8
	Protocol uint8
	SrcIP    net.IP
	DstIP    net.IP
}

func parseIPv4(b []byte) (*IPv4Hdr, int, error) {
	if len(b) < 20 {
		return nil, 0, fmt.Errorf("short IPv4 header")
	}

	vihl := b[0]
	if vihl>>4 != 4 {
		return nil, 0, fmt.Errorf("not IPv4")
	}

	ihl := vihl & 0x0F

	hdrLen := int(ihl) * 4

	if hdrLen < 20 || len(b) < hdrLen {
		return nil, 0, fmt.Errorf("bad IPv4 header length")
	}

	return &IPv4Hdr{
		IHL:      ihl,
		Protocol: b[9],
		SrcIP:    net.IPv4(b[12], b[13], b[14], b[15]),
		DstIP:    net.IPv4(b[16], b[17], b[18], b[19]),
	}, hdrLen, nil
}

// TCP
type TCPHdr struct {
	SrcPort uint16
	DstPort uint16
	Seq     uint32
	Ack     uint32
	Flags   uint8
}

func parseTCP(b []byte) (*TCPHdr, int, error) {
	if len(b) < 20 {
		return nil, 0, fmt.Errorf("short TCP header")
	}

	dataOff := (b[12] >> 4) & 0x0F
	hdrLen := int(dataOff) * 4

	if hdrLen < 20 || len(b) < hdrLen {
		return nil, 0, fmt.Errorf("bad TCP header length")
	}

	return &TCPHdr{
		SrcPort: binary.BigEndian.Uint16(b[0:2]),
		DstPort: binary.BigEndian.Uint16(b[2:4]),
		Seq:     binary.BigEndian.Uint32(b[4:8]),
		Ack:     binary.BigEndian.Uint32(b[8:12]),
		Flags:   b[13],
	}, hdrLen, nil
}

// BPF + Fanout
// TODO: double-tag (QinQ) variant or an auxdata-aware approach
func attachBPF(fd int, localIP net.IP, sportLo, sportHi uint16) error {
	ip4 := localIP.To4()
	if ip4 == nil {
		return fmt.Errorf("attachBPF: non-IPv4 local IP")
	}

	// Precompute BE16 halves of local IP for comparisons
	ipHi := uint32(binary.BigEndian.Uint16(ip4[0:2]))
	ipLo := uint32(binary.BigEndian.Uint16(ip4[2:4]))

	// IMPORTANT: compare dport (loaded in network order) with network-order bounds
	lo := uint32(htons(sportLo))
	hi := uint32(htons(sportHi))

	// Instruction indices shown at left for sanity.
	prog := []unix.SockFilter{
		//  0: EtherType @ [12]
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 12},
		//  1: vlan? (0x8100) -> jump to VLAN block @18
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 0x8100, Jt: 16, Jf: 0},
		//  2: vlan? (0x88a8) -> VLAN block @18
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 0x88A8, Jt: 15, Jf: 0},
		//  3: vlan? (0x9100) -> VLAN block @18
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 0x9100, Jt: 14, Jf: 0},

		// Non-VLAN path (IPv4 at L2+14)
		//  4: if EtherType != IPv4 -> drop
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 0x0800, Jt: 1, Jf: 0},
		//  5: drop
		{Code: unix.BPF_RET | unix.BPF_K, K: 0},
		//  6: proto @ [23]
		{Code: unix.BPF_LD | unix.BPF_B | unix.BPF_ABS, K: 23},
		//  7: if proto != TCP -> drop (jf=9 to instr 17)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 6, Jt: 0, Jf: 9},
		//  8: dst ip upper 16 @ [30]
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 30},
		//  9: if upper != local -> drop (jf=7 to 17)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: ipHi, Jt: 0, Jf: 7},
		// 10: dst ip lower 16 @ [32]
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 32},
		// 11: if lower != local -> drop (jf=5 to 17)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: ipLo, Jt: 0, Jf: 5},
		// 12: X = 4*(IHL) @ [14]
		{Code: unix.BPF_LDX | unix.BPF_MSH | unix.BPF_B | unix.BPF_ABS, K: 14},
		// 13: tcp dport @ [16+X]
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_IND, K: 16},
		// 14: if dport < lo -> drop (jf=2 to 17)
		{Code: unix.BPF_JMP | unix.BPF_JGE | unix.BPF_K, K: lo, Jt: 0, Jf: 2},
		// 15: if dport > hi -> drop (jt=1 to 17)
		{Code: unix.BPF_JMP | unix.BPF_JGT | unix.BPF_K, K: hi, Jt: 1, Jf: 0},
		// 16: accept
		{Code: unix.BPF_RET | unix.BPF_K, K: 0xFFFFFFFF},
		// 17: drop
		{Code: unix.BPF_RET | unix.BPF_K, K: 0},

		// VLAN path (single tag; IPv4 at L2+18)
		// 18: inner EtherType @ [16]
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 16},
		// 19: if inner EtherType != IPv4 -> drop (jf=11 to 31)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 0x0800, Jt: 0, Jf: 11},
		// 20: proto @ [27]
		{Code: unix.BPF_LD | unix.BPF_B | unix.BPF_ABS, K: 27},
		// 21: if proto != TCP -> drop (jf=9 to 31)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: 6, Jt: 0, Jf: 9},
		// 22: dst ip upper 16 @ [34]
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 34},
		// 23: if upper != local -> drop (jf=7 to 31)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: ipHi, Jt: 0, Jf: 7},
		// 24: dst ip lower 16 @ [36]
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_ABS, K: 36},
		// 25: if lower != local -> drop (jf=5 to 31)
		{Code: unix.BPF_JMP | unix.BPF_JEQ | unix.BPF_K, K: ipLo, Jt: 0, Jf: 5},
		// 26: X = 4*(IHL) @ [18]
		{Code: unix.BPF_LDX | unix.BPF_MSH | unix.BPF_B | unix.BPF_ABS, K: 18},
		// 27: tcp dport @ [20+X]  (18 + 2 + X)
		{Code: unix.BPF_LD | unix.BPF_H | unix.BPF_IND, K: 20},
		// 28: if dport < lo -> drop (jf=2 to 31)
		{Code: unix.BPF_JMP | unix.BPF_JGE | unix.BPF_K, K: lo, Jt: 0, Jf: 2},
		// 29: if dport > hi -> drop (jt=1 to 31)
		{Code: unix.BPF_JMP | unix.BPF_JGT | unix.BPF_K, K: hi, Jt: 1, Jf: 0},
		// 30: accept
		{Code: unix.BPF_RET | unix.BPF_K, K: 0xFFFFFFFF},
		// 31: drop
		{Code: unix.BPF_RET | unix.BPF_K, K: 0},
	}

	fprog := unix.SockFprog{Len: uint16(len(prog)), Filter: &prog[0]}

	return unix.SetsockoptSockFprog(fd, unix.SOL_SOCKET, unix.SO_ATTACH_FILTER, &fprog)
}

func enableFanout(fd int, groupID int) error {
	// Correct: (groupID << 16) | (type | flags)
	val := (groupID & 0xFFFF) << 16
	val |= unix.PACKET_FANOUT_HASH | unix.PACKET_FANOUT_FLAG_DEFRAG

	return unix.SetsockoptInt(fd, unix.SOL_PACKET, unix.PACKET_FANOUT, val)
}

// AF_PACKET Open/Bind

func openSnifferOnInterface(iFace string) (int, error) {
	fd, err := unix.Socket(unix.AF_PACKET, unix.SOCK_RAW, int(htons(unix.ETH_P_ALL)))
	if err != nil {
		return 0, fmt.Errorf("AF_PACKET socket: %w", err)
	}

	ifi, err := net.InterfaceByName(iFace)
	if err != nil {
		_ = unix.Close(fd)

		return 0, fmt.Errorf("iFace %s: %w", iFace, err)
	}

	sll := &unix.SockaddrLinklayer{Protocol: htons(unix.ETH_P_ALL), Ifindex: ifi.Index}
	if err := unix.Bind(fd, sll); err != nil {
		_ = unix.Close(fd)

		return 0, fmt.Errorf("bind %s: %w", iFace, err)
	}

	return fd, nil
}

// VLAN-aware L2/L3 parsing + cBPF

func ethernetL3(b []byte) (eth uint16, l3off int, err error) {
	if len(b) < 14 {
		return 0, 0, fmt.Errorf("short ethernet")
	}

	off := 12
	eth = binary.BigEndian.Uint16(b[off : off+2])
	l3off = 14

	// Peel up to two tags (802.1Q / QinQ / 0x9100)
	for i := 0; i < 2; i++ {
		if eth == etherTypeVLAN || eth == etherTypeQinQ || eth == etherType9100 {
			if len(b) < l3off+4 {
				return 0, 0, fmt.Errorf("short vlan header")
			}

			// skip TCI (2 bytes) and read inner ethertype
			eth = binary.BigEndian.Uint16(b[l3off+2 : l3off+4])
			l3off += 4
		} else {
			break
		}
	}

	return eth, l3off, nil
}

// TPACKETv3 Ring
// Mirrors Linux's struct tpacket_req3 (all fields uint32)
type tpacketReq3 struct {
	BlockSize      uint32 // tp_block_size
	BlockNr        uint32 // tp_block_nr
	FrameSize      uint32 // tp_frame_size
	FrameNr        uint32 // tp_frame_nr
	RetireBlkTov   uint32 // tp_retire_blk_tov (ms)
	SizeofPriv     uint32 // tp_sizeof_priv
	FeatureReqWord uint32 // tp_feature_req_word
}

type ringBuf struct {
	fd        int
	mem       []byte
	blockSize uint32
	blockNr   uint32
}

func setupTPacketV3(fd int, blockSize, blockNr, frameSize, retireMs uint32) (*ringBuf, error) {
	if err := unix.SetsockoptInt(fd, unix.SOL_PACKET, unix.PACKET_VERSION, unix.TPACKET_V3); err != nil {
		return nil, fmt.Errorf("PACKET_VERSION TPACKET_V3: %w", err)
	}

	req := tpacketReq3{
		BlockSize:    blockSize,
		BlockNr:      blockNr,
		FrameSize:    frameSize,
		FrameNr:      (blockSize / frameSize) * blockNr,
		RetireBlkTov: retireMs,
	}

	_, _, errno := unix.Syscall6(unix.SYS_SETSOCKOPT,
		uintptr(fd),
		uintptr(unix.SOL_PACKET),
		uintptr(unix.PACKET_RX_RING),
		uintptr(unsafe.Pointer(&req)),
		uintptr(unsafe.Sizeof(req)),
		0,
	)

	if errno != 0 {
		return nil, fmt.Errorf("PACKET_RX_RING: %w", errno)
	}

	total := int(blockSize * blockNr)

	mem, err := unix.Mmap(fd, 0, total, unix.PROT_READ|unix.PROT_WRITE, unix.MAP_SHARED)
	if err != nil {
		return nil, fmt.Errorf("mmap ring: %w", err)
	}

	return &ringBuf{fd: fd, mem: mem, blockSize: blockSize, blockNr: blockNr}, nil
}

// Offsets inside tpacket_block_desc.v3 (host-endian)
const (
	blk_version_off  = 0
	blk_off_priv_off = 4
	blk_h1_off       = blk_off_priv_off + 4 // 8

	h1_status_off    = blk_h1_off + 0  // u32 block_status
	h1_num_pkts_off  = blk_h1_off + 4  // u32 num_pkts
	h1_first_pkt_off = blk_h1_off + 8  // u32 offset_to_first_pkt
	h1_blk_len_off   = blk_h1_off + 12 // u32 blk_len
	h1_seq_off       = blk_h1_off + 16 // u64 seq_num
)

// Offsets inside struct tpacket3_hdr (host-endian)
const (
	pkt_next_off    = 0  // u32 tp_next_offset
	pkt_sec_off     = 4  // u32 tp_sec (unused)
	pkt_nsec_off    = 8  // u32 tp_nsec (unused)
	pkt_snaplen_off = 12 // u32 tp_snaplen
	pkt_len_off     = 16 // u32 tp_len (unused)
	pkt_status_off  = 20 // u32 tp_status (unused here)
	pkt_mac_off     = 24 // u16 tp_mac
	pkt_net_off     = 26 // u16 tp_net (unused)
)

func (r *ringBuf) block(i uint32) []byte {
	// Defensive checks for nil or invalid ring buffer
	if r == nil || r.mem == nil || len(r.mem) == 0 {
		return nil
	}

	base := int(i * r.blockSize)
	end := base + int(r.blockSize)

	if base < 0 || end > len(r.mem) || base >= end {
		return nil
	}

	return r.mem[base:end]
}

func (s *SYNScanner) runRingReader(ctx context.Context, r *ringBuf) {
	pfd := []unix.PollFd{{Fd: int32(r.fd), Events: unix.POLLIN | unix.POLLERR | unix.POLLHUP | unix.POLLNVAL}}
	cur := uint32(0)

	for {
		// First, drain any ready blocks without polling
		drained := false
		for {
			select {
			case <-ctx.Done():
				return
			default:
			}

			blk := r.block(cur)
			if blk == nil || len(blk) < int(h1_first_pkt_off+4) {
				break
			}

			status := loadU32(blk, h1_status_off)
			if status&tpStatusUser == 0 {
				break // no more ready blocks
			}

			// Check for TP_STATUS_LOSING - indicates buffer overrun/dropped block
			if status&tpStatusLosing != 0 {
				atomic.AddUint64(&s.stats.RingBlocksDropped, 1)
			}

			// process one ready block
			numPkts := hostEndian.Uint32(blk[h1_num_pkts_off : h1_num_pkts_off+4])
			first := hostEndian.Uint32(blk[h1_first_pkt_off : h1_first_pkt_off+4])

			if int(first) >= 0 && int(first) < len(blk) && numPkts > 0 {
				off := int(first)

				for p := uint32(0); p < numPkts; p++ {
					if off+int(pkt_mac_off+2) > len(blk) {
						break
					}

					ph := blk[off:]

					if int(pkt_next_off+4) > len(ph) ||
						int(pkt_snaplen_off+4) > len(ph) ||
						int(pkt_mac_off+2) > len(ph) {

						break
					}

					snap := int(hostEndian.Uint32(ph[pkt_snaplen_off : pkt_snaplen_off+4]))
					mac := int(hostEndian.Uint16(ph[pkt_mac_off : pkt_mac_off+2]))

					if mac >= 0 && snap >= 0 && mac+snap <= len(ph) {
						s.processEthernetFrame(ph[mac : mac+snap])
					}

					next := int(hostEndian.Uint32(ph[pkt_next_off : pkt_next_off+4]))
					if next <= 0 || off+next > len(blk) {
						break
					}

					off += next
				}
			}

			// hand ownership back
			storeU32(blk, h1_status_off, 0)
			cur = (cur + 1) % r.blockNr
			drained = true

			// Update stats counter for each processed block
			atomic.AddUint64(&s.stats.RingBlocksProcessed, 1)
		}

		if drained {
			continue // see if more blocks are ready without poll
		}

		// Nothing ready; block in poll
		_, err := unix.Poll(pfd, int(s.retireTovMs)) // align with retire tov
		if err != nil {
			// EINTR and EAGAIN are fine; anything else, exit this reader
			if errors.Is(err, unix.EINTR) || errors.Is(err, unix.EAGAIN) {
				continue
			}

			return
		}

		// Check for socket errors after successful poll
		if pfd[0].Revents&(unix.POLLERR|unix.POLLHUP|unix.POLLNVAL) != 0 {
			// Socket is in error state, exit this reader
			return
		}
	}
}

// NewSYNScanner creates a new SYN scanner with default options
// Deprecated: Use NewSYNScannerWithOptions for more control
func NewSYNScanner(timeout time.Duration, concurrency int, log logger.Logger) (*SYNScanner, error) {
	return NewSYNScannerWithOptions(timeout, concurrency, log, nil)
}

// NewSYNScannerWithOptions creates a new SYN scanner with custom options
//
// The scanner automatically detects a safe port range that doesn't conflict with
// the system's ephemeral ports or other local applications by reading:
// - /proc/sys/net/ipv4/ip_local_port_range (system ephemeral range)
// - /proc/sys/net/ipv4/ip_local_reserved_ports (reserved ports)
//
// Rate limiting guidance:
// Set rate limit to avoid source-port exhaustion. The available window depends
// on the detected safe range. Each port is in-flight for ~timeout+grace.
// Safe starting rate: pps ≈ window/(timeout+grace)
//
// Configure rate limit before starting a scan for best results, though SetRateLimit
// uses atomic.Value and is safe to call anytime, including during active scans.
//
// Example: scanner.SetRateLimit(20000, 5000) // 20k pps, 5k burst
func NewSYNScannerWithOptions(timeout time.Duration, concurrency int, log logger.Logger, opts *SYNScannerOptions) (*SYNScanner, error) {
	log.Debug().Msg("Starting SYN scanner initialization")

	if timeout == 0 {
		timeout = 1 * time.Second // SYN scans can be faster
	}

	if concurrency == 0 {
		concurrency = 256 // Reasonable default to avoid port exhaustion
	}

	log.Debug().Msg("Creating raw socket for sending")

	// Create raw socket for sending packets with custom IP headers
	sendSocket, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_TCP)
	if err != nil {
		return nil, fmt.Errorf("cannot create raw send socket (requires root): %w", err)
	}

	log.Debug().Int("socket", sendSocket).Msg("Raw socket created successfully")
	log.Debug().Msg("Setting IP_HDRINCL socket option")

	if err = syscall.SetsockoptInt(sendSocket, syscall.IPPROTO_IP, syscall.IP_HDRINCL, 1); err != nil {
		syscall.Close(sendSocket)
		return nil, fmt.Errorf("cannot set IP_HDRINCL (requires root): %w", err)
	}

	// Optional performance optimizations
	_ = unix.SetNonblock(sendSocket, true)
	_ = syscall.SetsockoptInt(sendSocket, syscall.SOL_SOCKET, syscall.SO_SNDBUF, 8<<20) // 8MB send buffer

	log.Debug().Msg("IP_HDRINCL set successfully")
	log.Debug().Msg("Getting local IP and interface")

	// Find a local IP and interface to use
	var routeDiscoveryTarget string

	if opts != nil && opts.RouteDiscoveryHost != "" {
		routeDiscoveryTarget = opts.RouteDiscoveryHost
		log.Debug().Str("target", routeDiscoveryTarget).Msg("Using configured route discovery target")
	} else {
		routeDiscoveryTarget = "8.8.8.8:80"
	}

	sourceIP, iface, err := getLocalIPAndInterfaceWithTarget(routeDiscoveryTarget)
	if err != nil {
		syscall.Close(sendSocket)

		return nil, fmt.Errorf("failed to get local IP and interface: %w", err)
	}

	log.Debug().Str("sourceIP", sourceIP.String()).Str("interface", iface).Msg("Local IP and interface found")

	// Honor SYNScannerOptions.Interface - override auto-discovered interface if specified
	if opts != nil && opts.Interface != "" {
		ifi, err := net.InterfaceByName(opts.Interface)
		if err != nil {
			syscall.Close(sendSocket)
			return nil, fmt.Errorf("interface %q: %w", opts.Interface, err)
		}
		addrs, _ := ifi.Addrs()
		var ip4 net.IP
		for _, a := range addrs {
			if ipnet, ok := a.(*net.IPNet); ok && ipnet.IP.To4() != nil {
				ip4 = ipnet.IP.To4()
				break
			}
		}
		if ip4 == nil {
			syscall.Close(sendSocket)
			return nil, fmt.Errorf("interface %q has no IPv4 address", opts.Interface)
		}
		sourceIP = ip4
		iface = ifi.Name
		log.Info().Str("sourceIP", sourceIP.String()).Str("interface", iface).Msg("Using user-specified interface")
	}

	sourceIP = sourceIP.To4()
	if sourceIP == nil {
		syscall.Close(sendSocket)

		return nil, fmt.Errorf("non-IPv4 source IP")
	}

	// Detect safe port range for scanning
	log.Debug().Msg("Detecting safe port range for scanning")

	scanPortStart, scanPortEnd, err := findSafeScannerPortRange(log)
	if err != nil {
		// This shouldn't happen as findSafeScannerPortRange always returns something
		// but handle it just in case
		log.Error().Err(err).Msg("Failed to find safe port range, using defaults")
		scanPortStart = defaultEphemeralPortStart
		scanPortEnd = defaultEphemeralPortEnd
	}
	// Log at Info level if non-default range chosen (ops folks want to see the actual window)
	if scanPortStart != defaultEphemeralPortStart || scanPortEnd != defaultEphemeralPortEnd {
		log.Info().Uint16("start", scanPortStart).Uint16("end", scanPortEnd).
			Int("windowSize", int(scanPortEnd-scanPortStart+1)).
			Msg("Scanner using dynamically selected port range")
	} else {
		log.Debug().Uint16("scanPortStart", scanPortStart).Uint16("scanPortEnd", scanPortEnd).
			Msg("Using default port range for scanning")
	}

	// Document SuppressRSTReply option with actionable guidance
	if opts != nil && opts.SuppressRSTReply {
		log.Warn().Msg("SuppressRSTReply requested. Consider applying:\n" +
			"  nft add rule inet filter output tcp flags rst tcp sport " +
			fmt.Sprintf("%d-%d", scanPortStart, scanPortEnd) + " drop")
	}

	log.Debug().Msg("Setting up ring buffers")

	// Build NumCPU ring readers with BPF + FANOUT
	// Setup order: open → fanout → BPF → TPACKET_V3 → mmap
	// This order is preferred by most codebases and avoids potential PACKET_RX_RING EINVAL issues.
	fanoutGroup := (os.Getpid() * 131) & 0xFFFF

	n := runtime.NumCPU()
	log.Debug().Int("numCPU", n).Int("fanoutGroup", fanoutGroup).Msg("Ring setup parameters")

	rings := make([]*ringBuf, 0, n)

	for i := 0; i < n; i++ {
		log.Debug().Int("ringIndex", i).Msg("Creating ring buffer")
		log.Debug().Str("interface", iface).Msg("Opening sniffer on interface")

		fd, err := openSnifferOnInterface(iface)
		if err != nil {
			log.Error().Err(err).Msg("Failed to open sniffer on interface")

			for _, r := range rings {
				_ = unix.Munmap(r.mem)
				_ = unix.Close(r.fd)
			}

			syscall.Close(sendSocket)

			return nil, fmt.Errorf("openSnifferOnInterface failed: %w", err)
		}

		log.Debug().Int("fd", fd).Msg("Sniffer opened successfully")
		
		log.Debug().Int("fanoutGroup", fanoutGroup).Msg("Enabling packet fanout")
		if err := enableFanout(fd, fanoutGroup); err != nil {
			log.Error().Err(err).Msg("Failed to enable packet fanout")
			_ = unix.Close(fd)

			for _, r := range rings {
				_ = unix.Munmap(r.mem)
				_ = unix.Close(r.fd)
			}

			syscall.Close(sendSocket)

			return nil, fmt.Errorf("enableFanout failed: %w", err)
		}

		log.Debug().Msg("Packet fanout enabled successfully")
		log.Debug().Msg("Attaching BPF filter")

		if err := attachBPF(fd, sourceIP, scanPortStart, scanPortEnd); err != nil {
			log.Error().Err(err).Msg("Failed to attach BPF filter")

			_ = unix.Close(fd)

			for _, r := range rings {
				_ = unix.Munmap(r.mem)
				_ = unix.Close(r.fd)
			}

			syscall.Close(sendSocket)

			return nil, fmt.Errorf("BPF filter attachment failed: %w", err)
		}

		log.Debug().Msg("BPF filter attached successfully")
		ringRetireTov := getRetireTovMs()

		// Use ring buffer options from SYNScannerOptions or defaults
		blockSize := uint32(defaultBlockSize)
		blockCount := uint32(defaultBlockCount)
		frameSize := uint32(defaultFrameSize)

		if opts != nil {
			if opts.RingBlockSize > 0 {
				blockSize = opts.RingBlockSize
			}

			if opts.RingBlockCount > 0 {
				blockCount = opts.RingBlockCount
			}

			if opts.RingFrameSize > 0 {
				frameSize = opts.RingFrameSize
			}
		}

		// Compute global memory cap and distribute across CPUs
		globalRingMemoryMB := defaultGlobalRingMemoryMB
		if opts != nil && opts.GlobalRingMemoryMB > 0 {
			globalRingMemoryMB = opts.GlobalRingMemoryMB
		}

		totalRings := runtime.NumCPU()
		perRingBytes := uint32((globalRingMemoryMB * 1024 * 1024) / totalRings)

		// Ensure minimum per-ring memory (at least 1MB per ring)
		minPerRingBytes := uint32(1024 * 1024) // 1MB
		if perRingBytes < minPerRingBytes {
			perRingBytes = minPerRingBytes
			log.Warn().
				Uint32("globalCapMB", uint32(globalRingMemoryMB)).
				Int("totalRings", totalRings).
				Uint32("computedPerRing", uint32((globalRingMemoryMB*1024*1024)/totalRings)).
				Uint32("minPerRingBytes", minPerRingBytes).
				Msg("Global ring memory cap too low for CPU count, using minimum per-ring size")
		}

		// Apply individual block limits first
		originalBlockSize := blockSize
		originalBlockCount := blockCount

		if blockSize > maxBlockSize {
			blockSize = maxBlockSize
		}

		if blockCount > maxBlockCount {
			blockCount = maxBlockCount
		}

		// Distribute global cap: adjust blockSize*blockCount to fit perRingBytes
		currentRingBytes := blockSize * blockCount
		if currentRingBytes > perRingBytes {
			// Try to maintain the requested block size if possible
			targetBlockCount := perRingBytes / blockSize
			if targetBlockCount >= 1 {
				blockCount = targetBlockCount
			} else {
				// Block size too large, reduce it and set minimum block count
				blockSize = perRingBytes
				if blockSize > maxBlockSize {
					blockSize = maxBlockSize
				}
				blockCount = 1
			}

			log.Info().
				Uint32("originalBlockSize", originalBlockSize).
				Uint32("originalBlockCount", originalBlockCount).
				Uint32("globalCapMB", uint32(globalRingMemoryMB)).
				Int("totalRings", totalRings).
				Uint32("perRingBytes", perRingBytes).
				Uint32("finalBlockSize", blockSize).
				Uint32("finalBlockCount", blockCount).
				Uint32("finalRingMemoryMB", (blockSize*blockCount)/(1024*1024)).
				Msg("Applied global ring memory cap distributed across CPUs")
		}

		log.Debug().Uint32("blockSize", blockSize).Uint32("blockCount", blockCount).Uint32("frameSize", frameSize).Uint32("retireMs", ringRetireTov).Msg("Setting up TPACKET_V3")

		rb, err := setupTPacketV3(fd, blockSize, blockCount, frameSize, ringRetireTov)
		if err != nil {
			log.Error().Err(err).Msg("Failed to setup TPACKET_V3")
			_ = unix.Close(fd)

			for _, r := range rings {
				_ = unix.Munmap(r.mem)
				_ = unix.Close(r.fd)
			}

			syscall.Close(sendSocket)

			return nil, fmt.Errorf("setupTPacketV3 failed: %w", err)
		}

		log.Debug().Msg("TPACKET_V3 setup successfully")

		rings = append(rings, rb)
	}

	log.Debug().Int("ringCount", len(rings)).Msg("All ring buffers created successfully")

	retireTov := getRetireTovMs()
	log.Debug().Uint32("retireTovMs", retireTov).Msg("Using configurable retire TOV")

	// Determine batch size from options, env var, or default
	batchSize := defaultSendBatchSize
	if opts != nil && opts.SendBatchSize > 0 {
		batchSize = opts.SendBatchSize
	} else {
		// Fall back to env var if no option provided
		batchSize = getSendBatchSize()
	}
	log.Debug().Int("sendBatchSize", batchSize).Msg("Using configurable sendmmsg batch size")

	scanner := &SYNScanner{
		timeout:        timeout,
		concurrency:    concurrency,
		logger:         log,
		sendSocket:     sendSocket,
		rings:          rings,
		sourceIP:       sourceIP,
		iface:          iface,
		fanoutGroup:    fanoutGroup,
		retireTovMs:    retireTov,
		portAlloc:      NewPortAllocator(scanPortStart, scanPortEnd),
		scanPortStart:  scanPortStart,
		scanPortEnd:    scanPortEnd,
		retryAttempts:  2,
		retryMinJitter: 20 * time.Millisecond,
		retryMaxJitter: 40 * time.Millisecond,
		sendBatchSize:  batchSize,
		// Initialize maps to prevent nil pointer dereference
		portTargetMap: make(map[uint16]string),
		targetPorts:   make(map[string][]uint16),
		targetIP:      make(map[string][4]byte),
		results:       make(map[string]models.Result),
		portDeadline:  make(map[uint16]time.Time),
		// Initialize thread-safe random source for IP ID generation
		rand: rand.New(rand.NewSource(time.Now().UnixNano())),
	}

	// Initialize batch pool for sendmmsg arrays
	scanner.batchPool = sync.Pool{
		New: func() interface{} {
			return &batchArrays{
				addrs:  make([]unix.RawSockaddrInet4, 0, batchSize),
				iovecs: make([]unix.Iovec, 0, batchSize),
				hdrs:   make([]Mmsghdr, 0, batchSize),
			}
		},
	}

	// Initialize packet buffer pool to reduce GC churn in hot path
	scanner.packetPool = sync.Pool{
		New: func() interface{} {
			return make([]byte, 40)
		},
	}

	// Initialize packet template for reuse
	scanner.initPacketTemplate()

	// Set rate limit from options or calculate safe default
	var rateLimitPPS, rateLimitBurst int

	// Calculate safe default capacity to prevent source port exhaustion
	window := int(scanPortEnd - scanPortStart + 1) // actual available ports

	hold := timeout + timeout/4 // timeout + grace period

	if hold <= 0 {
		hold = 1 * time.Second
	}

	safeCapacityPPS := int(float64(window) / hold.Seconds())

	// Auto-trim safeCapacityPPS when falling back to default ephemeral window
	// The fallback range 32768-61000 conflicts with system ephemeral ports, so we need to be more conservative
	const (
		fallbackStart = 32768
		fallbackEnd   = 61000
	)
	
	isFallbackRange := scanPortStart == fallbackStart && scanPortEnd == fallbackEnd
	if isFallbackRange {
		// Apply conservative multiplier when using risky fallback range
		// This reduces contention with system ephemeral port allocation
		originalSafeCapacity := safeCapacityPPS
		safeCapacityPPS = safeCapacityPPS / 4 // Reduce to 25% of calculated capacity
		if safeCapacityPPS < 500 {
			safeCapacityPPS = 500 // Minimum viable rate
		}
		
		log.Warn().
			Int("originalCapacity", originalSafeCapacity).
			Int("trimmedCapacity", safeCapacityPPS).
			Msg("Auto-trimmed safeCapacityPPS due to fallback to conflicting ephemeral window")
	}

	if opts != nil && opts.RateLimit > 0 {
		// Use explicitly provided rate limit
		rateLimitPPS = opts.RateLimit
		rateLimitBurst = opts.RateLimitBurst
		if rateLimitBurst <= 0 {
			rateLimitBurst = rateLimitPPS
		}

		// Warn if user rate limit exceeds safe window/hold capacity
		if rateLimitPPS > safeCapacityPPS {
			log.Warn().
				Int("userRateLimit", rateLimitPPS).
				Int("safeCapacity", safeCapacityPPS).
				Int("windowSize", window).
				Dur("holdDuration", hold).
				Msg("User rate limit exceeds safe window/hold capacity - may cause port allocator starvation")
		}
	} else {
		// Use calculated safe default
		rateLimitPPS = safeCapacityPPS

		// Apply reasonable bounds
		if rateLimitPPS < 1000 {
			rateLimitPPS = 1000 // minimum 1k pps
		}

		if rateLimitPPS > 25000 {
			rateLimitPPS = 25000 // conservative cap at 25k pps
		}

		rateLimitBurst = rateLimitPPS
	}

	scanner.SetRateLimit(rateLimitPPS, rateLimitBurst)
	log.Debug().Int("rateLimit", rateLimitPPS).Int("burst", rateLimitBurst).Msg("Set rate limit to prevent port exhaustion")

	// Start the coarse port cleanup reaper
	scanner.startReaper()

	// Initialize LastStatsReset so first telemetry log has meaningful baseline
	scanner.ResetStats()

	return scanner, nil
}

// initPacketTemplate initializes the reusable packet template with static fields
func (s *SYNScanner) initPacketTemplate() {
	// IPv4 header template (20 bytes)
	s.packetTemplate[0] = 0x45 // version=4, ihl=5
	s.packetTemplate[1] = 0    // TOS

	binary.BigEndian.PutUint16(s.packetTemplate[2:], 40) // total length (20 IP + 20 TCP)

	// ID will be set per packet: s.packetTemplate[4:6]
	binary.BigEndian.PutUint16(s.packetTemplate[6:], 0) // flags+frag

	s.packetTemplate[8] = 64 // TTL
	s.packetTemplate[9] = syscall.IPPROTO_TCP

	// checksum will be set per packet: s.packetTemplate[10:12]
	// src IP will be set per packet: s.packetTemplate[12:16]
	// dst IP will be set per packet: s.packetTemplate[16:20]

	// TCP header template (20 bytes)
	// src port will be set per packet: s.packetTemplate[20:22]
	// dst port will be set per packet: s.packetTemplate[22:24]
	// seq will be set per packet: s.packetTemplate[24:28]
	binary.BigEndian.PutUint32(s.packetTemplate[28:], 0) // ack

	s.packetTemplate[32] = (5 << 4) // data offset=5
	s.packetTemplate[33] = 0x02     // SYN flag

	binary.BigEndian.PutUint16(s.packetTemplate[34:], defaultTCPWindow) // window

	// checksum will be set per packet: s.packetTemplate[36:38]
	binary.BigEndian.PutUint16(s.packetTemplate[38:], 0) // urgent ptr
}

// generateRandomID returns a thread-safe random IP header ID
func (s *SYNScanner) generateRandomID() uint16 {
	s.randMu.Lock()
	id := uint16(s.rand.Intn(65535))
	s.randMu.Unlock()

	return id
}

// randUint32 returns a thread-safe random uint32 using the scanner's RNG
func (s *SYNScanner) randUint32() uint32 {
	s.randMu.Lock()
	v := s.rand.Uint32()
	s.randMu.Unlock()
	return v
}

// buildSynPacketFromTemplate efficiently builds a SYN packet using the pre-allocated template
func (s *SYNScanner) buildSynPacketFromTemplate(srcIP, destIP net.IP, srcPort, destPort uint16) []byte {
	// Get packet buffer from pool to reduce allocations
	packet := s.packetPool.Get().([]byte)
	copy(packet, s.packetTemplate[:])

	// Set variable IPv4 fields
	id := s.generateRandomID()

	binary.BigEndian.PutUint16(packet[4:], id) // IP ID

	copy(packet[12:16], srcIP.To4())  // src IP
	copy(packet[16:20], destIP.To4()) // dst IP

	// Calculate and set IPv4 checksum inline for hot path optimization
	binary.BigEndian.PutUint16(packet[10:], 0) // clear checksum

	ipSum := uint32(0)
	ipHdr := packet[:20]

	for i := 0; i < 20; i += 2 {
		ipSum += uint32(binary.BigEndian.Uint16(ipHdr[i:]))
	}

	for (ipSum >> 16) > 0 {
		ipSum = (ipSum & 0xFFFF) + (ipSum >> 16)
	}

	binary.BigEndian.PutUint16(packet[10:], ^uint16(ipSum))

	// Set variable TCP fields
	binary.BigEndian.PutUint16(packet[20:], srcPort)        // src port
	binary.BigEndian.PutUint16(packet[22:], destPort)       // dst port
	binary.BigEndian.PutUint32(packet[24:], s.randUint32()) // seq

	// Calculate and set TCP checksum inline for hot path optimization
	binary.BigEndian.PutUint16(packet[36:], 0) // clear checksum

	// Build pseudo-header inline to avoid allocation
	tcpSum := uint32(0)

	// Add source IP (4 bytes as 2 uint16s)
	src4 := srcIP.To4()
	tcpSum += uint32(src4[0])<<8 | uint32(src4[1])
	tcpSum += uint32(src4[2])<<8 | uint32(src4[3])

	// Add destination IP (4 bytes as 2 uint16s)
	dst4 := destIP.To4()
	tcpSum += uint32(dst4[0])<<8 | uint32(dst4[1])
	tcpSum += uint32(dst4[2])<<8 | uint32(dst4[3])

	// Add protocol (TCP = 6) and TCP length (20 bytes)
	tcpSum += uint32(syscall.IPPROTO_TCP)
	tcpSum += 20 // TCP header length

	// Add TCP header (20 bytes as 10 uint16s)
	tcpHdr := packet[20:40]
	for i := 0; i < 20; i += 2 {
		tcpSum += uint32(binary.BigEndian.Uint16(tcpHdr[i:]))
	}

	// Fold carries
	for (tcpSum >> 16) > 0 {
		tcpSum = (tcpSum & 0xFFFF) + (tcpSum >> 16)
	}

	binary.BigEndian.PutUint16(packet[36:], ^uint16(tcpSum))

	return packet
}

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

// SetRateLimit installs a global rate limit (packets/sec) with a burst.
// Pass pps<=0 to disable. If burst<=0, burst defaults to pps.
// Safe to call anytime, including during active scans.
func (s *SYNScanner) SetRateLimit(pps, burst int) {
	if pps <= 0 {
		s.rl.Store((*tokenBucket)(nil))
		return
	}

	s.rl.Store(newTokenBucket(pps, burst))
}

// allowN applies the limiter if present; otherwise returns n.
func (s *SYNScanner) allowN(n int) int {
	if tb, _ := s.rl.Load().(*tokenBucket); tb != nil {
		return tb.AllowN(n)
	}

	return n
}

type retryItem struct {
	due    time.Time
	target models.Target
	key    string
}

type retryHeap []retryItem

func (h retryHeap) Len() int           { return len(h) }
func (h retryHeap) Less(i, j int) bool { return h[i].due.Before(h[j].due) }
func (h retryHeap) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }
func (h *retryHeap) Push(x any)        { *h = append(*h, x.(retryItem)) }
func (h *retryHeap) Pop() any {
	old := *h

	n := len(old)
	x := old[n-1]

	*h = old[:n-1]

	return x
}

// sendPendingWithLimiter uses the global limiter; it may send in chunks until *pending is empty.
func (s *SYNScanner) sendPendingWithLimiter(ctx context.Context, pending *[]models.Target) {
	for len(*pending) > 0 {
		allowed := s.allowN(len(*pending))

		if allowed == 0 {
			// tiny sleep to avoid busy spinning
			atomic.AddUint64(&s.stats.RateLimitDeferrals, 1)
			time.Sleep(200 * time.Microsecond)

			continue
		}

		s.sendSynBatch(ctx, (*pending)[:allowed])
		*pending = (*pending)[allowed:]
	}
}

// runRetryQueue collects retry requests, wakes up when they're due, and sends them in batches via sendmmsg().
func (s *SYNScanner) runRetryQueue(ctx context.Context) {
	var pq retryHeap

	heap.Init(&pq)

	timer := time.NewTimer(time.Hour)
	if !timer.Stop() {
		<-timer.C
	}

	pending := make([]models.Target, 0, s.sendBatchSize)

	for {
		// If empty, wait for the first item or ctx cancel
		if pq.Len() == 0 {
			select {
			case <-ctx.Done():
				return
			case it := <-s.retryCh:
				if s.hasFinalResult(it.key) {
					continue
				}

				heap.Push(&pq, it)
			}

			continue
		}

		// Wait until the earliest item is due
		next := pq[0].due
		wait := time.Until(next)

		if wait < 0 {
			wait = 0
		}

		safeTimerReset(timer, wait)

		select {
		case <-ctx.Done():
			return

		case it := <-s.retryCh:
			if !s.hasFinalResult(it.key) {
				heap.Push(&pq, it)
			}

		case <-timer.C:
			// Pop due items and batch-send with limiter
			now := time.Now()

			pending = pending[:0]

			for pq.Len() > 0 {
				it := heap.Pop(&pq).(retryItem)

				if it.due.After(now) {
					// Not due; put back and stop
					heap.Push(&pq, it)

					break
				}

				if s.hasFinalResult(it.key) {
					continue
				}

				pending = append(pending, it.target)

				if len(pending) >= s.sendBatchSize {
					s.sendPendingWithLimiter(ctx, &pending)
				}
			}

			s.sendPendingWithLimiter(ctx, &pending)
		}
	}
}

// safeTimerReset stops t (draining if needed) then resets it to d.
func safeTimerReset(t *time.Timer, d time.Duration) {
	if !t.Stop() {
		select {
		case <-t.C:
		default:
		}
	}

	t.Reset(d)
}

func (s *SYNScanner) enqueueRetriesForBatch(batch []models.Target) {
	if s.retryAttempts <= 1 {
		return
	}

	s.mu.Lock()
	rc := s.retryCh
	s.mu.Unlock()
	if rc == nil {
		return
	}

	now := time.Now()
	span := s.retryMaxJitter - s.retryMinJitter

	for _, t := range batch {
		key := fmt.Sprintf("%s:%d", t.Host, t.Port)

		for attempt := 1; attempt < s.retryAttempts; attempt++ {
			d := s.retryMinJitter

			if span > 0 {
				d += time.Duration(rand.Int63n(int64(span)))
			}

			due := now.Add(time.Duration(attempt) * d)
			it := retryItem{due: due, target: t, key: key}
			
			// Track retry attempts
			atomic.AddUint64(&s.stats.RetriesAttempted, 1)

			select {
			case rc <- it:
			case <-time.After(2 * time.Millisecond):
				// slow path: best-effort, do not deadlock if rc drains slowly
				select {
				case rc <- it:
				default:
					// drop this retry rather than risk a stall
				}
			}
		}
	}
}

// Scan performs SYN scanning on the given targets
func (s *SYNScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	tcpTargets := filterTCPTargets(targets)
	resultCh := make(chan models.Result, len(tcpTargets))

	if len(tcpTargets) == 0 {
		close(resultCh)
		return resultCh, nil
	}

	scanCtx, cancel := context.WithCancel(ctx)
	scanStartTime := time.Now()

	// Start telemetry logging tied to scan lifecycle
	go s.logTelemetry(scanCtx)

	// Initialize state for the new scan and atomically set up the scan
	s.mu.Lock()
	if s.cancel != nil {
		s.mu.Unlock()
		return nil, fmt.Errorf("scan already running")
	}

	s.cancel = cancel
	s.readersWG.Add(1) // MUST come before Stop() can see non-nil cancel

	// init retry queue for this scan
	s.retryCh = make(chan retryItem, retryQueueSize)

	// start retry scheduler (and wait for it in teardown)
	s.readersWG.Add(1)
	go func() {
		defer s.readersWG.Done()
		s.runRetryQueue(scanCtx)
	}()

	s.results = make(map[string]models.Result, len(tcpTargets))
	s.portTargetMap = make(map[uint16]string, len(tcpTargets))
	s.targetPorts = make(map[string][]uint16, len(tcpTargets))
	s.targetIP = make(map[string][4]byte, len(tcpTargets))

	s.mu.Unlock()

	// Stream results immediately to resultCh (deduped so the final pass won't resend)
	emitted := make(map[string]struct{}, len(tcpTargets))

	var emittedMu sync.Mutex

	// Dedicated emitter to avoid per-result goroutines.
	// Buffered to the exact number of TCP targets; the callback enqueues at most once per target.
	emitCh := make(chan models.Result, len(tcpTargets))
	stopEmit := make(chan struct{})
	emitterDone := make(chan struct{})

	// Single goroutine drains emitCh -> resultCh, then closes resultCh after a stop signal + drain.
	go func() {
		defer close(emitterDone)
		for {
			select {
			case r := <-emitCh:
				// Forward to consumer
				resultCh <- r

				// Tee to user callback here (not in ring threads)
				if cbAny := s.userCallback.Load(); cbAny != nil {
					if cb, _ := cbAny.(func(models.Result)); cb != nil {
						cb(r)
					}
				}
			case <-stopEmit:
				// Drain any residual items and close the results channel exactly once.
				for {
					select {
					case r := <-emitCh:
						resultCh <- r

						if cbAny := s.userCallback.Load(); cbAny != nil {
							if cb, _ := cbAny.(func(models.Result)); cb != nil {
								cb(r)
							}
						}
					default:
						close(resultCh)

						return
					}
				}
			}
		}
	}()

	s.mu.Lock()
	s.resultCallback = func(r models.Result) {
		key := fmt.Sprintf("%s:%d", r.Target.Host, r.Target.Port)

		emittedMu.Lock()
		if _, seen := emitted[key]; seen {
			emittedMu.Unlock()
			return
		}

		emitted[key] = struct{}{}
		emittedMu.Unlock()

		// Non-blocking in practice: emitCh capacity == len(tcpTargets) and we enqueue ≤1 per target.
		emitCh <- r
	}

	s.mu.Unlock()

	// Start ring readers (one goroutine per ring) — manage with scanner-level WG

	go func() {
		defer s.readersWG.Done()
		s.listenForReplies(scanCtx)
	}()

	// Start worker pool to send SYN packets
	workCh := make(chan models.Target, s.concurrency)

	var senderWg sync.WaitGroup

	for i := 0; i < s.concurrency; i++ {
		senderWg.Add(1)

		go func() {
			defer senderWg.Done()
			s.worker(scanCtx, workCh)
		}()
	}

	// Feed targets to workers
	go func() {
		for _, t := range tcpTargets {
			select {
			case workCh <- t:
			case <-scanCtx.Done():
				return
			}
		}

		close(workCh)
	}()

	// Aggregate
	go func() {
		senderWg.Wait()

		// Shorter grace for late replies
		grace := s.timeout / 4
		if grace > 200*time.Millisecond {
			grace = 200 * time.Millisecond
		}

		time.Sleep(grace)

		cancel()
		s.readersWG.Wait()

		// Fallback: emit anything not yet streamed (via emitter so user callback is tee'd)
		s.mu.Lock()

		for _, t := range tcpTargets {
			key := fmt.Sprintf("%s:%d", t.Host, t.Port)
			emittedMu.Lock()

			if _, seen := emitted[key]; seen {
				emittedMu.Unlock()
				continue
			}

			emitted[key] = struct{}{}
			emittedMu.Unlock()

			r, ok := s.results[key]
			if !ok {
				r = models.Result{
					Target:    t,
					Available: false,
					Error:     fmt.Errorf("scan timed out"),
					FirstSeen: time.Now(),
					LastSeen:  time.Now(),
				}
			} else if !r.Available && r.Error == nil {
				r.Error = fmt.Errorf("scan timed out")
			}

			// Release lock while enqueueing; emitter handles backpressure and user callback tee.
			s.mu.Unlock()
			emitCh <- r
			s.mu.Lock()
		}

		// Stop future callback enqueues and finish the emitter cleanly.
		s.resultCallback = nil
		s.mu.Unlock()

		// Log final telemetry for scan completion (especially useful for short scans)
		scanDuration := time.Since(scanStartTime)
		stats := s.GetStats()
		s.logger.Info().
			Dur("scanDuration", scanDuration).
			Int("targetCount", len(tcpTargets)).
			Uint64("packetsSent", stats.PacketsSent).
			Uint64("packetsRecv", stats.PacketsRecv).
			Uint64("packetsDropped", stats.PacketsDropped).
			Uint64("rateLimitDeferrals", stats.RateLimitDeferrals).
			Msg("Scan completed")

		close(stopEmit) // signal emitter to drain and close resultCh
		<-emitterDone   // wait for emitter to finish

		s.mu.Lock()
		if s.cancel != nil {
			s.cancel = nil
		}

		s.mu.Unlock()
	}()

	return resultCh, nil
}

// worker sends SYN packets to targets from the work channel
func (s *SYNScanner) worker(ctx context.Context, workCh <-chan models.Target) {
	pending := make([]models.Target, 0, s.sendBatchSize)

	for {
		// If we have nothing pending, block for one item or exit
		if len(pending) == 0 {
			select {
			case <-ctx.Done():
				return
			case first, ok := <-workCh:
				if !ok {
					return
				}

				pending = append(pending, first)
			}
		}

		// Non-blocking drain to fill the batch
	drain:
		for len(pending) < s.sendBatchSize {
			select {
			case t, ok := <-workCh:
				if !ok { // channel closed: stop draining now
					break drain
				}
				pending = append(pending, t)
			default:
				break drain
			}
		}

		// Rate-limited send using sendmmsg (first attempts only)
		allowed := s.allowN(len(pending))
		if allowed == 0 {
			// tiny nap to let tokens accrue
			atomic.AddUint64(&s.stats.RateLimitDeferrals, 1)
			time.Sleep(200 * time.Microsecond)
			continue
		}

		// Slice to send now
		toSend := pending[:allowed]
		s.sendSynBatch(ctx, toSend)

		// Enqueue retries for what we *actually* sent now
		s.enqueueRetriesForBatch(toSend)

		// Remove the sent prefix; keep remainder for next loop
		pending = pending[allowed:]
	}
}

// listenForReplies pumps all ring readers (ctx-driven)
func (s *SYNScanner) listenForReplies(ctx context.Context) {
	var wg sync.WaitGroup

	for _, r := range s.rings {
		wg.Add(1)

		go func(rr *ringBuf) {
			defer wg.Done()
			s.runRingReader(ctx, rr)
		}(r)
	}

	<-ctx.Done()
	wg.Wait()
}

// processEthernetFrame parses an Ethernet frame and extracts TCP response information.
func (s *SYNScanner) processEthernetFrame(frame []byte) {
	ethType, l3off, err := ethernetL3(frame)
	if err != nil || ethType != etherTypeIPv4 {
		return
	}

	if len(frame) < l3off+20 {
		return
	}

	ip, ipLen, err := parseIPv4(frame[l3off:])
	if err != nil || ip.Protocol != syscall.IPPROTO_TCP {
		return
	}

	if len(frame) < l3off+ipLen+20 {
		return
	}

	tcp, _, err := parseTCP(frame[l3off+ipLen:])
	if err != nil {
		return
	}

	// Update stats counter for each parsed packet
	atomic.AddUint64(&s.stats.PacketsRecv, 1)

	// Precompute inexpensive bits *outside* the lock.
	now := time.Now()

	src4 := ip.SrcIP.To4()
	if src4 == nil {
		return
	}

	// We minimize time under s.mu. All map mutation stays inside; any potentially
	// blocking work (callback -> channel send) happens after we unlock.
	var (
		emit      bool
		toEmit    models.Result
		cb        func(models.Result)
		targetKey string
		toFree    []uint16
	)

	s.mu.Lock()

	targetKey, ok := s.portTargetMap[tcp.DstPort]
	if !ok {
		s.mu.Unlock()
		return
	}

	want := s.targetIP[targetKey]

	if src4[0] != want[0] || src4[1] != want[1] || src4[2] != want[2] || src4[3] != want[3] {
		s.mu.Unlock()
		return
	}

	result := s.results[targetKey]
	if result.Available || result.Error != nil {
		s.mu.Unlock()
		return
	}

	// Decide if this packet makes the port state "definitive".
	// We keep this simple and conservative: any SYN/ACK or RST is definitive.
	if tcp.Flags&(synFlag|ackFlag) == (synFlag | ackFlag) {
		result.Available = true
		result.Error = nil
		emit = true
	} else if tcp.Flags&rstFlag != 0 {
		result.Available = false
		result.Error = fmt.Errorf("port closed (RST)")
		emit = true
	} else {
		s.mu.Unlock()
		return
	}

	result.RespTime = time.Since(result.FirstSeen)
	result.LastSeen = now

	// Persist the updated result.
	s.results[targetKey] = result

	// Remove all src-port mappings for this target and free them after unlock.
	// Use reverse index for O(k) lookup and dedupe to avoid double release.
	ports := s.targetPorts[targetKey]
	
	// Track successful retries: if more than one source port was used, a retry succeeded
	if emit && len(ports) > 1 {
		atomic.AddUint64(&s.stats.RetriesSuccessful, 1)
	}
	
	uniq := make(map[uint16]struct{}, len(ports))

	delete(s.targetPorts, targetKey)

	for _, sp := range ports {
		if _, seen := uniq[sp]; seen {
			continue
		}
		uniq[sp] = struct{}{}
		delete(s.portTargetMap, sp)
	}

	for sp := range uniq {
		toFree = append(toFree, sp)
	}

	// If we want to emit, capture the callback and a copy of the result *under the lock*,
	// then invoke it after unlocking to avoid holding s.mu during a possibly blocking send.
	if emit && s.resultCallback != nil {
		toEmit = result
		cb = s.resultCallback
	}

	s.mu.Unlock()

	// Release ports outside the lock
	for _, sp := range toFree {
		s.portAlloc.Release(sp)
		atomic.AddUint64(&s.stats.PortsReleased, 1)
	}

	if emit && cb != nil {
		cb(toEmit)
	}
}

// handleLoopbackTarget handles TCP scanning for loopback addresses using connect()
func (s *SYNScanner) handleLoopbackTarget(ctx context.Context, target models.Target) {
	targetKey := fmt.Sprintf("%s:%d", target.Host, target.Port)

	result := models.Result{
		Target:    target,
		FirstSeen: time.Now(),
		LastSeen:  time.Now(),
	}

	// Use simple connect() for loopback targets
	d := net.Dialer{Timeout: s.timeout}
	addr := net.JoinHostPort(target.Host, fmt.Sprintf("%d", target.Port))

	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		result.Available = false
		result.Error = err
	} else {
		result.Available = true
		conn.Close()
	}

	result.RespTime = time.Since(result.FirstSeen)
	result.LastSeen = time.Now()

	// Store & emit without holding s.mu inside the callback.
	s.emitResult(targetKey, result)
}

// sendSyn crafts and sends a single SYN packet to the target.
func (s *SYNScanner) sendSyn(ctx context.Context, target models.Target) {
	destIP := net.ParseIP(target.Host)
	if destIP == nil || destIP.To4() == nil {
		s.logger.Warn().Str("host", target.Host).Msg("Invalid/Non-IPv4 target host")
		return
	}

	destIP = destIP.To4()

	// Special case for loopback targets - use simple connect() check
	if destIP.IsLoopback() {
		s.handleLoopbackTarget(ctx, target)
		return
	}

	// Reserve a unique source port
	srcPort, err := s.portAlloc.Reserve(ctx)
	if err != nil {
		// Update port exhaustion counter
		atomic.AddUint64(&s.stats.PortExhaustion, 1)
		s.logger.Debug().Err(err).Str("host", target.Host).Msg("No source port available")

		return
	}

	// Update successful port allocation counter
	atomic.AddUint64(&s.stats.PortsAllocated, 1)

	targetKey := fmt.Sprintf("%s:%d", target.Host, target.Port)

	// Ensure cleanup on any early return
	release := func() {
		// Also removes from targetPorts and guards against double release
		s.tryReleaseMapping(srcPort, targetKey)
	}

	ip4b := destIP.To4()

	var want [4]byte

	copy(want[:], ip4b)

	s.mu.Lock()

	s.portTargetMap[srcPort] = targetKey
	s.targetPorts[targetKey] = append(s.targetPorts[targetKey], srcPort)
	s.targetIP[targetKey] = want

	if existing, ok := s.results[targetKey]; ok && !existing.FirstSeen.IsZero() {
		existing.LastSeen = time.Now()
		s.results[targetKey] = existing
	} else {
		s.results[targetKey] = models.Result{
			Target:    target,
			FirstSeen: time.Now(),
			LastSeen:  time.Now(),
		}
	}

	s.mu.Unlock()

	// Ensure we don't hold the source port forever if the target never replies.
	// Free the mapping after timeout + grace to still accept late replies.
	grace := s.timeout / 4
	if grace > 200*time.Millisecond {
		grace = 200 * time.Millisecond
	}

	// Record deadline for reaper instead of per-port timer
	deadline := time.Now().Add(s.timeout + grace)

	s.mu.Lock()
	s.portDeadline[srcPort] = deadline
	s.mu.Unlock()

	if target.Port <= 0 || target.Port > maxPortNumber {
		s.logger.Warn().Int("port", target.Port).Msg("Invalid target port")
		release()

		return
	}

	packet := s.buildSynPacketFromTemplate(s.sourceIP, destIP, srcPort, uint16(target.Port)) //nolint:gosec
	addr := syscall.SockaddrInet4{Port: target.Port}

	copy(addr.Addr[:], destIP)

	if err := syscall.Sendto(s.sendSocket, packet, 0, &addr); err != nil {
		if err == syscall.EAGAIN || err == syscall.EWOULDBLOCK || err == syscall.EINTR {
			// TRACE level for first EAGAIN - very common and usually transient
			s.logger.Trace().Err(err).Str("host", target.Host).Msg("Transient send error, retrying")
			
			runtime.Gosched()
			if err2 := syscall.Sendto(s.sendSocket, packet, 0, &addr); err2 == nil {
				// Return packet buffer to pool after successful send
				s.packetPool.Put(packet)
				atomic.AddUint64(&s.stats.PacketsSent, 1)
				return
			} else {
				// DEBUG level for retry failure - indicates potential system pressure
				s.logger.Debug().Err(err2).Str("host", target.Host).Msg("Failed to send SYN packet after retry")
			}
		} else {
			// Log non-transient errors immediately
			s.logger.Debug().Err(err).Str("host", target.Host).Msg("Failed to send SYN packet")
		}

		// Return packet buffer to pool even on error
		s.packetPool.Put(packet)
		release()

		return
	}

	// Return packet buffer to pool after successful send
	s.packetPool.Put(packet)
	atomic.AddUint64(&s.stats.PacketsSent, 1)
}

// sendSynBatch crafts and sends SYNs for a slice of targets using sendmmsg().
// Only the *first attempt* should use this fast path; retries can go through sendSyn() or another batcher.
func (s *SYNScanner) sendSynBatch(ctx context.Context, targets []models.Target) {
	type entry struct {
		tgt       models.Target
		dst4      [4]byte
		srcPort   uint16
		packet    []byte
		targetKey string
	}

	// Build up entries we can actually batch (valid IPv4, non-loopback, port in range, port reserved)
	entries := make([]entry, 0, len(targets))

	// Pre-calc the grace we already use elsewhere
	grace := s.timeout / 4
	if grace > 200*time.Millisecond {
		grace = 200 * time.Millisecond
	}

	for _, t := range targets {
		if t.Port <= 0 || t.Port > maxPortNumber {
			continue
		}

		dst := net.ParseIP(t.Host)
		if dst == nil {
			continue
		}

		dst4 := dst.To4()
		if dst4 == nil {
			continue
		}

		if net.IP(dst4).IsLoopback() {
			// loopback: use connect path immediately
			s.handleLoopbackTarget(ctx, t)

			continue
		}

		key := fmt.Sprintf("%s:%d", t.Host, t.Port)
		if s.hasFinalResult(key) {
			continue // no need to probe again
		}

		// Reserve source port
		srcPort, err := s.portAlloc.Reserve(ctx)
		if err != nil {
			// Update port exhaustion counter
			atomic.AddUint64(&s.stats.PortExhaustion, 1)
			continue
		}

		// Update successful port allocation counter
		atomic.AddUint64(&s.stats.PortsAllocated, 1)

		// Update maps under lock (same as sendSyn)
		var want [4]byte

		copy(want[:], dst4)

		s.mu.Lock()
		if s.portTargetMap == nil {
			s.portTargetMap = make(map[uint16]string)
		}

		if s.targetPorts == nil {
			s.targetPorts = make(map[string][]uint16)
		}

		if s.targetIP == nil {
			s.targetIP = make(map[string][4]byte)
		}

		if s.results == nil {
			s.results = make(map[string]models.Result)
		}

		s.portTargetMap[srcPort] = key
		s.targetPorts[key] = append(s.targetPorts[key], srcPort)
		s.targetIP[key] = want

		if existing, ok := s.results[key]; ok && !existing.FirstSeen.IsZero() {
			existing.LastSeen = time.Now()
			s.results[key] = existing
		} else {
			s.results[key] = models.Result{
				Target:    t,
				FirstSeen: time.Now(),
				LastSeen:  time.Now(),
			}
		}

		s.mu.Unlock()

		// Record deadline for reaper instead of per-port timer
		deadline := time.Now().Add(s.timeout + grace)
		s.mu.Lock()
		s.portDeadline[srcPort] = deadline
		s.mu.Unlock()

		// Build packet
		pkt := s.buildSynPacketFromTemplate(s.sourceIP, dst4, srcPort, uint16(t.Port))

		var addr4 [4]byte

		copy(addr4[:], dst4)

		entries = append(entries, entry{
			tgt:       t,
			dst4:      addr4,
			srcPort:   srcPort,
			packet:    pkt,
			targetKey: key,
		})
	}

	if len(entries) == 0 {
		return
	}

	// Get pooled arrays for sendmmsg to reduce allocations
	ba := s.batchPool.Get().(*batchArrays)
	defer func() {
		// Reset slices for reuse
		ba.addrs = ba.addrs[:0]
		ba.iovecs = ba.iovecs[:0]
		ba.hdrs = ba.hdrs[:0]
		s.batchPool.Put(ba)
	}()

	// Resize arrays if needed
	if cap(ba.addrs) < len(entries) {
		ba.addrs = make([]unix.RawSockaddrInet4, len(entries))
		ba.iovecs = make([]unix.Iovec, len(entries))
		ba.hdrs = make([]Mmsghdr, len(entries))
	} else {
		ba.addrs = ba.addrs[:len(entries)]
		ba.iovecs = ba.iovecs[:len(entries)]
		ba.hdrs = ba.hdrs[:len(entries)]
	}

	// Use the pooled arrays
	addrs := ba.addrs
	iovecs := ba.iovecs
	hdrs := ba.hdrs

	// Fill descriptors
	for i := range entries {
		// sockaddr_in
		addrs[i] = unix.RawSockaddrInet4{
			Family: unix.AF_INET,
			Port:   htons(uint16(entries[i].tgt.Port)), // kernel expects network byte order
			Addr:   entries[i].dst4,
		}

		// iovec pointing at the packet bytes
		iovecs[i].Base = &entries[i].packet[0]
		iovecs[i].SetLen(len(entries[i].packet)) // arch‑safe setter

		// msghdr
		hdrs[i].Hdr.Name = (*byte)(unsafe.Pointer(&addrs[i]))
		hdrs[i].Hdr.Namelen = uint32(unsafe.Sizeof(addrs[i]))
		hdrs[i].Hdr.Iov = &iovecs[i]
		hdrs[i].Hdr.SetIovlen(1) // arch‑safe setter
	}

	// Send in a loop to handle partial sends; kernel will send them in order.
	off := 0

	for off < len(hdrs) {
		n, err := sendmmsg(s.sendSocket, hdrs[off:], 0)
		if n > 0 {
			off += n
			// Update stats counter after successful send
			atomic.AddUint64(&s.stats.PacketsSent, uint64(n))
		}

		if err == nil {
			continue
		}

		// Retry the same offset on transient errors
		if err == unix.EAGAIN || err == unix.EWOULDBLOCK || err == unix.EINTR {
			// tiny backoff; keep pressure high
			runtime.Gosched()

			continue
		}

		// Hard error: release the remaining unsent src ports and drop mappings
		s.logger.Debug().Err(err).Int("remaining", len(hdrs)-off).Msg("sendmmsg failed; releasing unsent ports")

		break
	}

	// Ensure GC liveness across the syscall
	runtime.KeepAlive(hdrs)
	runtime.KeepAlive(iovecs)
	runtime.KeepAlive(addrs)
	runtime.KeepAlive(entries)

	// Return all packet buffers to pool after sendmmsg completes
	for i := range entries {
		s.packetPool.Put(entries[i].packet)
	}

	// Release *unsent* ports immediately, since their SYN never left the machine.
	// Use tryReleaseMapping to keep all mappings in sync.
	for i := off; i < len(entries); i++ {
		sp := entries[i].srcPort
		s.tryReleaseMapping(sp, entries[i].targetKey)
	}
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

	return err
}

// Packet Crafting and Utility Functions

// Checksum helpers

func ChecksumNew(data []byte) uint16 {
	sum := uint32(0)

	for len(data) > 1 {
		sum += uint32(binary.BigEndian.Uint16(data))
		data = data[2:]
	}

	if len(data) > 0 {
		sum += uint32(data[0]) << 8
	}

	for (sum >> 16) > 0 {
		sum = (sum & 0xFFFF) + (sum >> 16)
	}

	return ^uint16(sum)
}

// TCP checksum with IPv4 pseudo-header
func TCPChecksumNew(src, dst net.IP, tcpHdr, payload []byte) uint16 {
	psh := make([]byte, 12+len(tcpHdr)+len(payload))

	copy(psh[0:4], src.To4())
	copy(psh[4:8], dst.To4())

	psh[8] = 0
	psh[9] = syscall.IPPROTO_TCP

	binary.BigEndian.PutUint16(psh[10:12], uint16(len(tcpHdr)+len(payload)))

	copy(psh[12:], tcpHdr)
	copy(psh[12+len(tcpHdr):], payload)

	return ChecksumNew(psh)
}

// readLocalPortRange reads the system's ephemeral port range from /proc
func readLocalPortRange() (uint16, uint16, error) {
	b, err := os.ReadFile("/proc/sys/net/ipv4/ip_local_port_range")
	if err != nil {
		return 0, 0, err
	}

	var lo, hi uint16

	if _, err := fmt.Sscanf(strings.TrimSpace(string(b)), "%d %d", &lo, &hi); err != nil {
		return 0, 0, fmt.Errorf("failed to parse ip_local_port_range: %w", err)
	}

	return lo, hi, nil
}

// readReservedPorts reads the reserved ports from /proc
func readReservedPorts() map[uint16]struct{} {
	ports := map[uint16]struct{}{}

	b, err := os.ReadFile("/proc/sys/net/ipv4/ip_local_reserved_ports")
	if err != nil || len(b) == 0 {
		return ports // return empty map if file doesn't exist or is empty
	}

	// Parse comma-separated list of ports and ranges
	for _, tok := range strings.Split(strings.TrimSpace(string(b)), ",") {
		tok = strings.TrimSpace(tok)
		if tok == "" {
			continue
		}

		if strings.Contains(tok, "-") {
			// Handle range like "32768-61000"
			var a, z int

			if _, err := fmt.Sscanf(tok, "%d-%d", &a, &z); err == nil {
				for p := a; p <= z && p <= 65535; p++ {
					ports[uint16(p)] = struct{}{}
				}
			}
		} else {
			// Handle single port
			if v, err := strconv.Atoi(tok); err == nil && v >= 0 && v <= 65535 {
				ports[uint16(v)] = struct{}{}
			}
		}
	}

	return ports
}

// findSafeScannerPortRange finds a safe port range for scanning that doesn't
// conflict with the system's ephemeral ports or other local applications.
// Returns the start and end of the range, or an error if no safe range found.
func findSafeScannerPortRange(log logger.Logger) (uint16, uint16, error) {
	// Default fallback range (what we were using before)
	const (
		fallbackStart = 32768
		fallbackEnd   = 61000
	)

	// Try to read system ephemeral range
	sysStart, sysEnd, err := readLocalPortRange()
	if err != nil {
		log.Warn().Err(err).Msg("Failed to read system ephemeral port range, using fallback")
		log.Warn().Uint16("start", fallbackStart).Uint16("end", fallbackEnd).
			Msg("WARNING: Using default range that may conflict with local applications!")

		return fallbackStart, fallbackEnd, nil
	}

	log.Info().Uint16("sysStart", sysStart).Uint16("sysEnd", sysEnd).
		Msg("System ephemeral port range detected")

	// Read reserved ports
	reserved := readReservedPorts()

	// Strategy: Find a range that doesn't overlap with system ephemeral range
	// Prefer ranges that are marked as reserved (to prevent other apps from using them)

	// Option 1: Use ports below the system range (if there's enough space)
	if sysStart > 20000 {
		// We can use 10000-19999 or similar
		scanStart := uint16(10000)
		scanEnd := sysStart - 1

		if scanEnd-scanStart >= 5000 { // Need at least 5000 ports
			rangeSize := int(scanEnd - scanStart + 1)
			samples := rangeSize / 20 // 5%
			if samples < 100 {
				samples = rangeSize // sample all if small
			}
			if samples < 1 {
				samples = 1
			}

			reservedCount := 0
			for i := 0; i < samples; i++ {
				p := scanStart + uint16((i*rangeSize)/samples)
				if p > scanEnd {
					break
				}
				if _, ok := reserved[p]; ok {
					reservedCount++
				}
			}
			reservedDensity := float64(reservedCount) / float64(samples)

			if reservedDensity >= 0.5 {
				log.Info().Uint16("start", scanStart).Uint16("end", scanEnd).
					Float64("reservedDensity", reservedDensity).
					Msg("Using mostly-reserved port range for scanning")
			} else {
				log.Warn().Uint16("start", scanStart).Uint16("end", scanEnd).
					Float64("reservedDensity", reservedDensity).
					Msg("Scanner port range not reserved densely; consider ip_local_reserved_ports")
			}
			return scanStart, scanEnd, nil
		}
	}

	// Option 2: Use ports above the system range (if there's enough space)
	if sysEnd < 60000 {
		scanStart := sysEnd + 1
		scanEnd := uint16(65000) // Leave some ports at the top

		if scanEnd-scanStart >= 5000 { // Need at least 5000 ports
			rangeSize := int(scanEnd - scanStart + 1)
			samples := rangeSize / 20 // 5%
			if samples < 100 {
				samples = rangeSize // sample all if small
			}
			if samples < 1 {
				samples = 1
			}

			reservedCount := 0
			for i := 0; i < samples; i++ {
				p := scanStart + uint16((i*rangeSize)/samples)
				if p > scanEnd {
					break
				}
				if _, ok := reserved[p]; ok {
					reservedCount++
				}
			}
			reservedDensity := float64(reservedCount) / float64(samples)

			if reservedDensity >= 0.5 {
				log.Info().Uint16("start", scanStart).Uint16("end", scanEnd).
					Float64("reservedDensity", reservedDensity).
					Msg("Using mostly-reserved port range for scanning")
			} else {
				log.Warn().Uint16("start", scanStart).Uint16("end", scanEnd).
					Float64("reservedDensity", reservedDensity).
					Msg("Scanner port range not reserved densely; consider ip_local_reserved_ports")
			}
			return scanStart, scanEnd, nil
		}
	}

	// Option 3: If we can't find a non-overlapping range, try to use reserved ports within the range
	// This is less ideal but better than nothing
	if lo, hi, ok := largestContiguous(reserved, 1024, 65535); ok && hi-lo+1 >= 5000 {
		log.Warn().Uint16("start", lo).Uint16("end", hi).
			Msg("Using largest contiguous reserved block for scanner ports")
		return lo, hi, nil
	}

	// Last resort: Use the fallback range with a loud warning
	log.Error().Uint16("start", fallbackStart).Uint16("end", fallbackEnd).
		Msg("ERROR: Could not find safe port range! Using fallback that WILL conflict with local applications!")
	log.Error().Msg("RECOMMENDATION: Reserve ports via 'echo 32768-61000 > /proc/sys/net/ipv4/ip_local_reserved_ports'")

	return fallbackStart, fallbackEnd, nil
}

// largestContiguous finds the largest contiguous block of reserved ports in the range [lo, hi]
func largestContiguous(res map[uint16]struct{}, lo, hi uint16) (uint16, uint16, bool) {
	var bestLo, bestHi uint16

	found, inRun := false, false

	var curLo, curHi uint16

	for pi := int(lo); pi <= int(hi); pi++ {
		p := uint16(pi)
		if _, ok := res[p]; ok {
			if !inRun {
				curLo = p
				inRun = true
			}

			curHi = p
		} else if inRun {
			if !found || int(curHi-curLo) > int(bestHi-bestLo) {
				bestLo, bestHi, found = curLo, curHi, true
			}

			inRun = false
		}
	}

	if inRun && (!found || int(curHi-curLo) > int(bestHi-bestLo)) {
		bestLo, bestHi, found = curLo, curHi, true
	}

	if found {
		return bestLo, bestHi, true
	}

	return 0, 0, false
}

func getLocalIPAndInterface() (net.IP, string, error) {
	return getLocalIPAndInterfaceWithTarget("8.8.8.8:80")
}

func getLocalIPAndInterfaceWithTarget(target string) (net.IP, string, error) {
	if target == "" {
		target = "8.8.8.8:80"
	}

	conn, err := net.Dial("udp", target)
	if err != nil {
		// Fallback for environments without internet access or blocked targets
		interfaces, err := net.Interfaces()
		if err != nil {
			return nil, "", err
		}

		for _, iface := range interfaces {
			if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
				continue
			}

			addrs, err := iface.Addrs()
			if err != nil {
				continue
			}

			for _, addr := range addrs {
				if ipnet, ok := addr.(*net.IPNet); ok && ipnet.IP.To4() != nil {
					return ipnet.IP.To4(), iface.Name, nil
				}
			}
		}

		return nil, "", fmt.Errorf("no suitable local IP address and interface found (target %s blocked)", target)
	}

	defer conn.Close()

	localAddr := conn.LocalAddr().(*net.UDPAddr)
	localIP := localAddr.IP.To4()

	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, "", err
	}

	for _, iface := range interfaces {
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}

		for _, addr := range addrs {
			if ipnet, ok := addr.(*net.IPNet); ok && ipnet.IP.Equal(localIP) {
				return localIP, iface.Name, nil
			}
		}
	}

	return nil, "", fmt.Errorf("could not find interface for local IP %s", localIP)
}

func getLocalIP() (net.IP, error) {
	ip, _, err := getLocalIPAndInterface()

	return ip, err
}

// Host to network short/long byte order conversions
func htons(n uint16) uint16 {
	if hostEndian == binary.LittleEndian {
		return (n << 8) | (n >> 8)
	}

	return n
}

func ntohs(n uint16) uint16 { return htons(n) }
