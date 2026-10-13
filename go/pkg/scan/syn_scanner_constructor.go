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
	"fmt"
	"math/rand/v2"
	"net"
	"os"
	"runtime"
	"sync"
	"syscall"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"golang.org/x/sys/unix"
)

//
//nolint:gocyclo // Complex initialization with many configuration options and platform-specific setup
func NewSYNScanner(timeout time.Duration, concurrency int, log logger.Logger, opts *SYNScannerOptions) (*SYNScanner, error) {
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
		if closeErr := syscall.Close(sendSocket); closeErr != nil {
			log.Warn().Err(closeErr).Msg("Failed to close socket")
		}

		return nil, fmt.Errorf("cannot set IP_HDRINCL (requires root): %w", err)
	}

	// Optional performance optimizations
	_ = unix.SetNonblock(sendSocket, true)
	_ = syscall.SetsockoptInt(sendSocket, syscall.SOL_SOCKET, syscall.SO_SNDBUF, sendBufferSizeMB<<bitsPerShift) // 8MB send buffer

	sendSocket6 := 0
	if fd, err := syscall.Socket(syscall.AF_INET6, syscall.SOCK_RAW, syscall.IPPROTO_RAW); err != nil {
		log.Warn().Err(err).Msg("Raw IPv6 send socket unavailable; raw SYN IPv6 will be disabled")
	} else {
		sendSocket6 = fd
		_ = unix.SetNonblock(sendSocket6, true)
		_ = syscall.SetsockoptInt(sendSocket6, syscall.SOL_SOCKET, syscall.SO_SNDBUF, sendBufferSizeMB<<bitsPerShift)
		if err := unix.SetsockoptInt(sendSocket6, unix.IPPROTO_IPV6, unix.IPV6_HDRINCL, 1); err != nil {
			log.Debug().Err(err).Msg("IPV6_HDRINCL not accepted on raw IPv6 socket; continuing with IPPROTO_RAW")
		}
	}

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
		closeRawSendSockets(log, sendSocket, sendSocket6)

		return nil, fmt.Errorf("failed to get local IP and interface: %w", err)
	}

	log.Debug().Str("sourceIP", sourceIP.String()).Str("interface", iface).Msg("Local IP and interface found")

	// Honor SYNScannerOptions.Interface - override auto-discovered interface if specified
	if opts != nil && opts.Interface != "" {
		ifi, err := net.InterfaceByName(opts.Interface)
		if err != nil {
			closeRawSendSockets(log, sendSocket, sendSocket6)

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
			closeRawSendSockets(log, sendSocket, sendSocket6)

			return nil, fmt.Errorf("%w: %q", ErrInterfaceNoIPv4, opts.Interface)
		}

		sourceIP = ip4
		iface = ifi.Name

		log.Info().Str("sourceIP", sourceIP.String()).Str("interface", iface).Msg("Using user-specified interface")
	}

	sourceIP = sourceIP.To4()
	if sourceIP == nil {
		closeRawSendSockets(log, sendSocket, sendSocket6)

		return nil, ErrNonIPv4SourceIP
	}

	sourceIP6 := getInterfaceIPv6(iface)
	if sourceIP6 == nil && sendSocket6 != 0 {
		log.Warn().Str("interface", iface).Msg("No usable IPv6 source address on scanner interface; raw SYN IPv6 disabled")
		_ = syscall.Close(sendSocket6)
		sendSocket6 = 0
	} else if sourceIP6 != nil {
		log.Info().Str("sourceIP6", sourceIP6.String()).Str("interface", iface).Msg("Using local IPv6 source for raw SYN scanner")
	}

	// Detect safe port range for scanning
	log.Debug().Msg("Detecting safe port range for scanning")

	scanPortStart, scanPortEnd := findSafeScannerPortRange(log)
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
	fanoutGroup := 0

	// Determine ring reader count
	ringCount := runtime.NumCPU()
	if opts != nil && opts.RingReaders > 0 && opts.RingReaders < ringCount {
		ringCount = opts.RingReaders
	}

	if ringCount > defaultRingCount { // default cap to avoid excessive idle wakeups
		ringCount = defaultRingCount
	}

	log.Debug().Int("ringCount", ringCount).Msg("Ring setup parameters")

	// Rings carry the reply filter only while a scan is listening; see
	// startCaptureLocked. Build it now so a bad local address fails here.
	replyFilter, err := buildReplyFilter(sourceIP, sourceIP6, scanPortStart, scanPortEnd)
	if err != nil {
		closeRawSendSockets(log, sendSocket, sendSocket6)

		return nil, fmt.Errorf("BPF filter construction failed: %w", err)
	}

	layout := computeRingLayout(opts, ringCount, uint32(os.Getpagesize()))

	if layout.raisedToMinimum {
		log.Warn().
			Uint32("globalCapMB", uint32(layout.globalCapMB)).
			Int("totalRings", layout.totalRings).
			Uint32("computedPerRing", layout.computedPerRingBytes).
			Uint32("minPerRingBytes", layout.perRingBytes).
			Msg("Global ring memory cap too low for CPU count, using minimum per-ring size")
	}

	if layout.adjusted() {
		log.Info().
			Uint32("originalBlockSize", layout.requestedBlockSize).
			Uint32("originalBlockCount", layout.requestedBlockCount).
			Uint32("globalCapMB", uint32(layout.globalCapMB)).
			Int("totalRings", layout.totalRings).
			Uint32("perRingBytes", layout.perRingBytes).
			Uint32("finalBlockSize", layout.blockSize).
			Uint32("finalBlockCount", layout.blockCount).
			Uint32("finalRingMemoryMB", (layout.blockSize*layout.blockCount)/(1024*1024)).
			Msg("Applied global ring memory cap distributed across CPUs")
	}

	rings := make([]*ringBuf, 0, ringCount)

	for i := 0; i < ringCount; i++ {
		log.Debug().Int("ringIndex", i).Msg("Creating ring buffer")
		log.Debug().Str("interface", iface).Msg("Opening sniffer on interface")

		fd, err := openSnifferOnInterface(iface)
		if err != nil {
			log.Error().Err(err).Msg("Failed to open sniffer on interface")

			for _, r := range rings {
				_ = unix.Munmap(r.mem)
				_ = unix.Close(r.fd)
			}

			closeRawSendSockets(log, sendSocket, sendSocket6)

			return nil, fmt.Errorf("openSnifferOnInterface failed: %w", err)
		}

		log.Debug().Int("fd", fd).Msg("Sniffer opened successfully")

		if i == 0 {
			fanoutGroup, err = createFanoutGroup(fd)
		} else {
			err = enableFanout(fd, fanoutGroup)
		}

		if err != nil {
			log.Error().Err(err).Msg("Failed to enable packet fanout")

			_ = unix.Close(fd)

			for _, r := range rings {
				_ = unix.Munmap(r.mem)
				_ = unix.Close(r.fd)
			}

			closeRawSendSockets(log, sendSocket, sendSocket6)

			return nil, fmt.Errorf("configure packet fanout failed: %w", err)
		}

		if i == 0 {
			log.Info().
				Int("fanoutGroup", fanoutGroup).
				Int("ringCount", ringCount).
				Str("interface", iface).
				Msg("Created isolated packet fanout group")
		} else {
			log.Debug().Int("fanoutGroup", fanoutGroup).Int("ringIndex", i).
				Msg("Joined packet ring to scanner fanout group")
		}

		log.Debug().Msg("Attaching idle BPF filter")

		if err := attachSocketFilter(fd, idleCaptureFilter()); err != nil {
			log.Error().Err(err).Msg("Failed to attach BPF filter")

			_ = unix.Close(fd)

			for _, r := range rings {
				_ = unix.Munmap(r.mem)
				_ = unix.Close(r.fd)
			}

			closeRawSendSockets(log, sendSocket, sendSocket6)

			return nil, fmt.Errorf("BPF filter attachment failed: %w", err)
		}

		log.Debug().Msg("BPF filter attached successfully")

		ringRetireTov := getRetireTovMs()

		log.Debug().Uint32("blockSize", layout.blockSize).Uint32("blockCount", layout.blockCount).Uint32("frameSize", layout.frameSize).Uint32("retireMs", ringRetireTov).Msg("Setting up TPACKET_V3")

		rb, err := setupTPacketV3(fd, layout.blockSize, layout.blockCount, layout.frameSize, ringRetireTov)
		if err != nil {
			log.Error().Err(err).Msg("Failed to setup TPACKET_V3")

			_ = unix.Close(fd)

			for _, r := range rings {
				_ = unix.Munmap(r.mem)
				_ = unix.Close(r.fd)
			}

			closeRawSendSockets(log, sendSocket, sendSocket6)

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
		timeout:       timeout,
		concurrency:   concurrency,
		logger:        log,
		sendSocket:    sendSocket,
		sendSocket6:   sendSocket6,
		rings:         rings,
		sourceIP:      sourceIP,
		sourceIP6:     sourceIP6,
		iface:         iface,
		fanoutGroup:   fanoutGroup,
		replyFilter:   replyFilter,
		gate:          rawSYNScanGate,
		retireTovMs:   retireTov,
		portAlloc:     NewPortAllocator(scanPortStart, scanPortEnd),
		scanPortStart: scanPortStart,
		scanPortEnd:   scanPortEnd,
		// Use a single retry by default to reduce false negatives from packet loss
		// without significantly increasing scan duration.
		retryAttempts:  2,
		retryMinJitter: 20 * time.Millisecond,
		retryMaxJitter: 40 * time.Millisecond,
		sendBatchSize:  batchSize,
		// Initialize maps to prevent nil pointer dereference
		portTargetMap: make(map[uint16]string),
		targetPorts:   make(map[string][]uint16),
		targetIP:      make(map[string]string),
		results:       make(map[string]models.Result),
		portDeadline:  make(map[uint16]time.Time),
		// Initialize thread-safe random source for IP ID generation
		rand: rand.New(rand.NewPCG(uint64(time.Now().UnixNano()), uint64(os.Getpid()))),
	}

	// Configure ring poll timeout: default to max(retireTovMs, 50ms) unless overridden
	if opts != nil && opts.RingPollTimeoutMs > 0 {
		scanner.ringPollTimeoutMs = opts.RingPollTimeoutMs
	} else {
		pollMs := int(retireTov)
		if pollMs < 50 {
			pollMs = 50
		}

		scanner.ringPollTimeoutMs = pollMs
	}

	// Initialize batch pool for sendmmsg arrays
	scanner.batchPool = sync.Pool{
		New: func() interface{} {
			return &batchArrays{
				addrs:  make([]unix.RawSockaddrInet4, 0, batchSize),
				addrs6: make([]unix.RawSockaddrInet6, 0, batchSize),
				iovecs: make([]unix.Iovec, 0, batchSize),
				hdrs:   make([]Mmsghdr, 0, batchSize),
			}
		},
	}

	// Initialize packet buffer pool to reduce GC churn in hot path
	scanner.packetPool = sync.Pool{
		New: func() interface{} {
			return make([]byte, ipv4TcpPacketSize)
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
		safeCapacityPPS /= capacityReduction // Reduce to 25% of calculated capacity

		if safeCapacityPPS < minSafeRatePPS {
			safeCapacityPPS = minSafeRatePPS // Minimum viable rate
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

		if rateLimitPPS > maxConservativeRate {
			rateLimitPPS = maxConservativeRate // conservative cap at 25k pps
		}

		rateLimitBurst = rateLimitPPS
	}

	scanner.SetRateLimit(rateLimitPPS, rateLimitBurst)

	log.Debug().Int("rateLimit", rateLimitPPS).Int("burst", rateLimitBurst).Msg("Set rate limit to prevent port exhaustion")

	// Start the coarse port cleanup reaper
	scanner.startReaper()

	// Initialize LastStatsReset so first telemetry log has meaningful baseline
	scanner.ResetStats()

	log.Info().
		Dur("tcp_timeout", scanner.timeout).
		Uint16("scanPortStart", scanner.scanPortStart).
		Uint16("scanPortEnd", scanner.scanPortEnd).
		Int("windowSize", int(scanner.scanPortEnd-scanner.scanPortStart+1)).
		Int("rateLimitPPS", rateLimitPPS).
		Int("rateLimitBurst", rateLimitBurst).
		Msg("SYN scanner configuration")

	return scanner, nil
}

func closeRawSendSockets(log logger.Logger, sendSocket, sendSocket6 int) {
	if sendSocket != 0 {
		if closeErr := syscall.Close(sendSocket); closeErr != nil {
			log.Warn().Err(closeErr).Msg("Failed to close IPv4 raw send socket")
		}
	}

	if sendSocket6 != 0 {
		if closeErr := syscall.Close(sendSocket6); closeErr != nil {
			log.Warn().Err(closeErr).Msg("Failed to close IPv6 raw send socket")
		}
	}
}

// ringLayout is the TPACKET_V3 geometry every ring of one scanner uses.
type ringLayout struct {
	blockSize  uint32
	blockCount uint32
	frameSize  uint32

	// What the options (or defaults) asked for, before limits and the cap.
	requestedBlockSize  uint32
	requestedBlockCount uint32

	globalCapMB          int
	totalRings           int
	computedPerRingBytes uint32 // the global cap divided across the rings
	perRingBytes         uint32 // the per-ring budget actually applied
	raisedToMinimum      bool   // the cap share was below minRingMemoryMB
}

func (l ringLayout) adjusted() bool {
	return l.blockSize != l.requestedBlockSize || l.blockCount != l.requestedBlockCount
}

// computeRingLayout applies the ring options over the defaults, then the
// per-block limits, kernel alignment (a multiple of the frame and page size)
// and the global memory cap shared by ringCount rings.
func computeRingLayout(opts *SYNScannerOptions, ringCount int, page uint32) ringLayout {
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

	// Compute global memory cap and distribute across the *actual* number of rings
	globalRingMemoryMB := defaultGlobalRingMemoryMB
	if opts != nil && opts.GlobalRingMemoryMB > 0 {
		globalRingMemoryMB = opts.GlobalRingMemoryMB
	}

	totalRings := ringCount
	if totalRings <= 0 {
		totalRings = 1
	}

	layout := ringLayout{
		requestedBlockSize:  blockSize,
		requestedBlockCount: blockCount,
		globalCapMB:         globalRingMemoryMB,
		totalRings:          totalRings,
	}

	perRingBytes := uint32((globalRingMemoryMB * 1024 * 1024) / totalRings)
	layout.computedPerRingBytes = perRingBytes

	// Ensure minimum per-ring memory (at least 1MB per ring)
	minPerRingBytes := uint32(minRingMemoryMB * bytesPerKB * bytesPerKB) // 1MB
	if perRingBytes < minPerRingBytes {
		perRingBytes = minPerRingBytes
		layout.raisedToMinimum = true
	}

	layout.perRingBytes = perRingBytes

	// Apply individual block limits first
	if blockSize > maxBlockSize {
		blockSize = maxBlockSize
	}

	if blockCount > maxBlockCount {
		blockCount = maxBlockCount
	}

	// lcm(frameSize, page)
	gcd := func(a, b uint32) uint32 {
		for b != 0 {
			a, b = b, a%b
		}

		return a
	}

	lcm := func(a, b uint32) uint32 { return a / gcd(a, b) * b }

	align := lcm(frameSize, page)

	// Round blockSize up to satisfy (multiple of frameSize and page size)
	if blockSize%frameSize != 0 || blockSize%page != 0 {
		bs := ((blockSize + align - 1) / align) * align
		if bs > maxBlockSize {
			bs = (maxBlockSize / align) * align
		}

		if bs == 0 {
			bs = align
		}

		blockSize = bs
	}

	currentRingBytes := blockSize * blockCount
	if currentRingBytes > perRingBytes {
		// First, try to reduce blockCount while keeping a valid blockSize
		if blockSize <= perRingBytes {
			targetBlockCount := perRingBytes / blockSize

			if targetBlockCount < 1 {
				targetBlockCount = 1
			}

			blockCount = targetBlockCount
		} else {
			// blockSize itself is too large: shrink it to fit at least one block
			blockCount = 1

			// Largest aligned blockSize that fits
			blockSize = (perRingBytes / align) * align

			if blockSize < align {
				// fall back to minimum legal aligned size
				blockSize = align
			}
		}
	}

	// TPACKET_V3 behaves poorly with a single block: enforce a minimum
	if blockCount < 2 {
		// Prefer shrinking blockSize a bit rather than blockCount=1. Halve it:
		// rounding an already aligned size down to alignment never shrinks it,
		// which spun this loop forever when one block filled the budget.
		blockCount = 2
		for blockSize*blockCount > perRingBytes {
			next := ((blockSize / 2) / align) * align
			if next < align {
				blockSize = align

				break
			}

			blockSize = next
		}
	}

	layout.blockSize = blockSize
	layout.blockCount = blockCount
	layout.frameSize = frameSize

	return layout
}
