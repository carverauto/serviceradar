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
	"os"
	"strconv"
	"time"
)

// Using architecture-specific sendmmsg implementation and Mmsghdr struct
// This ensures correct ABI/struct layout across all supported architectures
// Definitions are provided in separate files with build tags for each architecture
//
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
	etherTypeIPv6 = 0x86DD
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
	// 32-128 is typically a sweet spot; 64 is a safe default.
	defaultSendBatchSize = 64

	// Size of the retry queue channel (enough for large scans with a couple of attempts).
	retryQueueSize = 1 << 17 // 131072

	// Timing constants
	telemetryLogInterval = 30 * time.Second       // Log telemetry every 30s during active scans
	rateLimitBackoff     = 200 * time.Microsecond // Backoff when rate limited
	defaultGracePeriod   = 200 * time.Millisecond // Maximum grace period

	// Network packet size constants
	ipv4HeaderMinSize  = 20   // Minimum IPv4 header size
	ipv6HeaderSize     = 40   // Fixed IPv6 header size
	icmpv6HeaderSize   = 8    // ICMPv6 error header size before the embedded packet
	tcpHeaderMinSize   = 20   // Minimum TCP header size
	ethernetHeaderSize = 14   // Ethernet header size
	ipv4TcpPacketSize  = 40   // Combined IPv4 (20) + TCP (20) header size
	ipv6TcpPacketSize  = 60   // Combined IPv6 (40) + TCP (20) header size
	ipv4Version        = 4    // IPv4 version number
	ipv6Version        = 6    // IPv6 version number
	ipv4ProtocolCheck  = 0x01 // IPv4 protocol check value
	ipProtoICMPv6      = 58   // IPv6 ICMP protocol number
	icmpv6DstUnreach   = 1    // ICMPv6 Destination Unreachable
	icmpv6PacketTooBig = 2    // ICMPv6 Packet Too Big
	icmpv6TimeExceeded = 3    // ICMPv6 Time Exceeded

	// Buffer and memory constants
	sendBufferSizeMB    = 8     // Send buffer size in MB (8MB = 8<<20)
	minRingMemoryMB     = 1     // Minimum ring memory per ring (1MB = 1024*1024)
	minSafeRatePPS      = 500   // Minimum safe packet rate (packets per second)
	maxConservativeRate = 25000 // Conservative maximum rate limit (25k pps)
	defaultTTL          = 64    // Default IP TTL value
	maxRandomID         = 65535 // Maximum random ID value
	tcpWindowSize       = 65535 // TCP window size

	// Performance and concurrency constants
	minShardCount        = 4  // Minimum number of shards
	maxShardCount        = 32 // Maximum number of shards
	defaultRingCount     = 4  // Default ring count cap
	memoryAllocationHint = 16 // Memory allocation hint for shards

	// Port range management constants
	highPortThreshold    = 20000 // Threshold for high port numbers
	lowPortFallback      = 10000 // Fallback start for low port range
	minPortRange         = 5000  // Minimum required port range size
	highPortUpperBound   = 60000 // Upper bound for high port detection
	safePortUpperBound   = 65000 // Safe upper bound for port allocation
	portDensitySampleDiv = 20    // Divisor for port density sampling (5% = 1/20)
	portSearchStart      = 1024  // Start of port search range
	reservedDensityLimit = 0.5   // Maximum allowed reserved port density

	// Rate calculation constants
	capacityReduction   = 4  // Capacity reduction factor for conservative estimation
	burstCapacityHint   = 4  // Hint for burst capacity allocation
	timeoutGraceDivisor = 4  // Timeout grace period divisor
	growthMultiplier    = 13 // Growth multiplier for IP allocation

	// Binary constants
	bytesPerKB   = 1024 // Bytes per kilobyte
	bitsPerShift = 20   // Bit shift for MB conversion (1MB = 1<<20)
	uint32Size   = 4    // Size of uint32 in bytes
)
