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

// NewSYNScanner creates a new SYN scanner with custom options
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
func NewSYNScanner(timeout time.Duration, concurrency int, log logger.Logger, opts *SYNScannerOptions) (*SYNScanner, error) {
	log.Debug().Msg("Starting SYN scanner initialization")

	if timeout == 0 {
		timeout = 1 * time.Second // SYN scans can be faster
	}

	if concurrency == 0 {
		concurrency = 256 // Reasonable default to avoid port exhaustion
	}

	sendSocket, sendSocket6, err := openRawSendSockets(log)
	if err != nil {
		return nil, err
	}

	sourceIP, iface, err := resolveScannerSource(log, opts)
	if err != nil {
		closeRawSendSockets(log, sendSocket, sendSocket6)

		return nil, err
	}

	sourceIP6 := getInterfaceIPv6(iface)
	if sourceIP6 == nil && sendSocket6 != 0 {
		log.Warn().Str("interface", iface).Msg("No usable IPv6 source address on scanner interface; raw SYN IPv6 disabled")
		_ = syscall.Close(sendSocket6)
		sendSocket6 = 0
	} else if sourceIP6 != nil {
		log.Info().Str("sourceIP6", sourceIP6.String()).Str("interface", iface).Msg("Using local IPv6 source for raw SYN scanner")
	}

	scanPortStart, scanPortEnd := selectScannerPortRange(log, opts)

	log.Debug().Msg("Setting up ring buffers")

	ringCount := scannerRingCount(opts)

	log.Debug().Int("ringCount", ringCount).Msg("Ring setup parameters")

	// Rings carry the reply filter only while a scan is listening; see
	// startCaptureLocked. Build it now so a bad local address fails here.
	replyFilter, err := buildReplyFilter(sourceIP, sourceIP6, scanPortStart, scanPortEnd)
	if err != nil {
		closeRawSendSockets(log, sendSocket, sendSocket6)

		return nil, fmt.Errorf("BPF filter construction failed: %w", err)
	}

	layout := computeRingLayout(opts, ringCount, uint32(os.Getpagesize()))
	logRingLayout(log, layout)

	rings, fanoutGroup, err := openCaptureRings(log, iface, ringCount, layout)
	if err != nil {
		closeRawSendSockets(log, sendSocket, sendSocket6)

		return nil, err
	}

	log.Debug().Int("ringCount", len(rings)).Msg("All ring buffers created successfully")

	retireTov := getRetireTovMs()
	log.Debug().Uint32("retireTovMs", retireTov).Msg("Using configurable retire TOV")

	batchSize := scannerSendBatchSize(opts)

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
		rand:              rand.New(rand.NewPCG(uint64(time.Now().UnixNano()), uint64(os.Getpid()))),
		ringPollTimeoutMs: scannerRingPollTimeoutMs(opts, retireTov),
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

	// Initialize packet buffer pool to reduce GC churn in hot path. It holds
	// array pointers so Put does not allocate a slice header per packet.
	scanner.packetPool = sync.Pool{
		New: func() interface{} {
			return new([ipv4TcpPacketSize]byte)
		},
	}

	// Initialize packet template for reuse
	scanner.initPacketTemplate()

	rateLimitPPS, rateLimitBurst := scannerRateLimit(log, opts, timeout, scanPortStart, scanPortEnd)
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

// openRawSendSockets opens the IPv4 raw send socket the scanner writes its own
// IP headers to, and the optional IPv6 one; sendSocket6 is 0 when IPv6 raw
// sending is unavailable.
func openRawSendSockets(log logger.Logger) (sendSocket, sendSocket6 int, err error) {
	log.Debug().Msg("Creating raw socket for sending")

	// Create raw socket for sending packets with custom IP headers
	sendSocket, err = syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_TCP)
	if err != nil {
		return 0, 0, fmt.Errorf("cannot create raw send socket (requires root): %w", err)
	}

	log.Debug().Int("socket", sendSocket).Msg("Raw socket created successfully")
	log.Debug().Msg("Setting IP_HDRINCL socket option")

	if err = syscall.SetsockoptInt(sendSocket, syscall.IPPROTO_IP, syscall.IP_HDRINCL, 1); err != nil {
		if closeErr := syscall.Close(sendSocket); closeErr != nil {
			log.Warn().Err(closeErr).Msg("Failed to close socket")
		}

		return 0, 0, fmt.Errorf("cannot set IP_HDRINCL (requires root): %w", err)
	}

	// Optional performance optimizations
	_ = unix.SetNonblock(sendSocket, true)
	_ = syscall.SetsockoptInt(sendSocket, syscall.SOL_SOCKET, syscall.SO_SNDBUF, sendBufferSizeMB<<bitsPerShift) // 8MB send buffer

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

	return sendSocket, sendSocket6, nil
}

// resolveScannerSource picks the IPv4 source address and interface the scanner
// sends from: the route toward the discovery target, unless the options name an
// interface.
func resolveScannerSource(log logger.Logger, opts *SYNScannerOptions) (net.IP, string, error) {
	log.Debug().Msg("Getting local IP and interface")

	// Find a local IP and interface to use
	routeDiscoveryTarget := "8.8.8.8:80"
	if opts != nil && opts.RouteDiscoveryHost != "" {
		routeDiscoveryTarget = opts.RouteDiscoveryHost
		log.Debug().Str("target", routeDiscoveryTarget).Msg("Using configured route discovery target")
	}

	sourceIP, iface, err := getLocalIPAndInterfaceWithTarget(routeDiscoveryTarget)
	if err != nil {
		return nil, "", fmt.Errorf("failed to get local IP and interface: %w", err)
	}

	log.Debug().Str("sourceIP", sourceIP.String()).Str("interface", iface).Msg("Local IP and interface found")

	// Honor SYNScannerOptions.Interface - override auto-discovered interface if specified
	if opts != nil && opts.Interface != "" {
		sourceIP, err = interfaceIPv4(opts.Interface)
		if err != nil {
			return nil, "", err
		}

		iface = opts.Interface

		log.Info().Str("sourceIP", sourceIP.String()).Str("interface", iface).Msg("Using user-specified interface")
	}

	sourceIP = sourceIP.To4()
	if sourceIP == nil {
		return nil, "", ErrNonIPv4SourceIP
	}

	return sourceIP, iface, nil
}

// interfaceIPv4 returns the first IPv4 address of the named interface.
func interfaceIPv4(name string) (net.IP, error) {
	ifi, err := net.InterfaceByName(name)
	if err != nil {
		return nil, fmt.Errorf("interface %q: %w", name, err)
	}

	addrs, _ := ifi.Addrs()

	for _, a := range addrs {
		if ipnet, ok := a.(*net.IPNet); ok && ipnet.IP.To4() != nil {
			return ipnet.IP.To4(), nil
		}
	}

	return nil, fmt.Errorf("%w: %q", ErrInterfaceNoIPv4, name)
}

// selectScannerPortRange picks the source-port window the scanner owns and
// logs it.
func selectScannerPortRange(log logger.Logger, opts *SYNScannerOptions) (start, end uint16) {
	// Detect safe port range for scanning
	log.Debug().Msg("Detecting safe port range for scanning")

	start, end = findSafeScannerPortRange(log)
	// Log at Info level if non-default range chosen (ops folks want to see the actual window)
	if start != defaultEphemeralPortStart || end != defaultEphemeralPortEnd {
		log.Info().Uint16("start", start).Uint16("end", end).
			Int("windowSize", int(end-start+1)).
			Msg("Scanner using dynamically selected port range")
	} else {
		log.Debug().Uint16("scanPortStart", start).Uint16("scanPortEnd", end).
			Msg("Using default port range for scanning")
	}

	// Document SuppressRSTReply option with actionable guidance
	if opts != nil && opts.SuppressRSTReply {
		log.Warn().Msg("SuppressRSTReply requested. Consider applying:\n" +
			"  nft add rule inet filter output tcp flags rst tcp sport " +
			fmt.Sprintf("%d-%d", start, end) + " drop")
	}

	return start, end
}

// scannerRingCount is the number of capture rings: one per CPU, lowered by the
// options and capped at defaultRingCount to avoid excessive idle wakeups.
func scannerRingCount(opts *SYNScannerOptions) int {
	ringCount := runtime.NumCPU()
	if opts != nil && opts.RingReaders > 0 && opts.RingReaders < ringCount {
		ringCount = opts.RingReaders
	}

	return min(ringCount, defaultRingCount)
}

// logRingLayout reports when the ring geometry departs from what was requested.
func logRingLayout(log logger.Logger, layout ringLayout) {
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
}

// openCaptureRings opens ringCount TPACKET_V3 rings on iface in one isolated
// packet fanout group, each with the idle filter attached. Setup order is
// open, fanout, BPF, TPACKET_V3, mmap: the order most codebases use, which
// avoids PACKET_RX_RING EINVAL. On failure every ring opened so far is closed.
func openCaptureRings(log logger.Logger, iface string, ringCount int, layout ringLayout) ([]*ringBuf, int, error) {
	rings := make([]*ringBuf, 0, ringCount)
	fanoutGroup := 0

	for i := 0; i < ringCount; i++ {
		rb, err := openCaptureRing(log, iface, i, ringCount, layout, &fanoutGroup)
		if err != nil {
			for _, r := range rings {
				_ = unix.Munmap(r.mem)
				_ = unix.Close(r.fd)
			}

			return nil, 0, err
		}

		rings = append(rings, rb)
	}

	return rings, fanoutGroup, nil
}

// openCaptureRing opens ring index of the scanner. The first ring creates the
// fanout group and stores it in fanoutGroup; later rings join it.
func openCaptureRing(log logger.Logger, iface string, index, ringCount int, layout ringLayout, fanoutGroup *int) (*ringBuf, error) {
	log.Debug().Int("ringIndex", index).Msg("Creating ring buffer")
	log.Debug().Str("interface", iface).Msg("Opening sniffer on interface")

	fd, err := openSnifferOnInterface(iface)
	if err != nil {
		log.Error().Err(err).Msg("Failed to open sniffer on interface")

		return nil, fmt.Errorf("openSnifferOnInterface failed: %w", err)
	}

	log.Debug().Int("fd", fd).Msg("Sniffer opened successfully")

	if index == 0 {
		*fanoutGroup, err = createFanoutGroup(fd)
	} else {
		err = enableFanout(fd, *fanoutGroup)
	}

	if err != nil {
		log.Error().Err(err).Msg("Failed to enable packet fanout")

		_ = unix.Close(fd)

		return nil, fmt.Errorf("configure packet fanout failed: %w", err)
	}

	if index == 0 {
		log.Info().
			Int("fanoutGroup", *fanoutGroup).
			Int("ringCount", ringCount).
			Str("interface", iface).
			Msg("Created isolated packet fanout group")
	} else {
		log.Debug().Int("fanoutGroup", *fanoutGroup).Int("ringIndex", index).
			Msg("Joined packet ring to scanner fanout group")
	}

	log.Debug().Msg("Attaching idle BPF filter")

	if err := attachSocketFilter(fd, idleCaptureFilter()); err != nil {
		log.Error().Err(err).Msg("Failed to attach BPF filter")

		_ = unix.Close(fd)

		return nil, fmt.Errorf("BPF filter attachment failed: %w", err)
	}

	log.Debug().Msg("BPF filter attached successfully")

	ringRetireTov := getRetireTovMs()

	log.Debug().Uint32("blockSize", layout.blockSize).Uint32("blockCount", layout.blockCount).Uint32("frameSize", layout.frameSize).Uint32("retireMs", ringRetireTov).Msg("Setting up TPACKET_V3")

	rb, err := setupTPacketV3(fd, layout.blockSize, layout.blockCount, layout.frameSize, ringRetireTov)
	if err != nil {
		log.Error().Err(err).Msg("Failed to setup TPACKET_V3")

		_ = unix.Close(fd)

		return nil, fmt.Errorf("setupTPacketV3 failed: %w", err)
	}

	log.Debug().Msg("TPACKET_V3 setup successfully")

	return rb, nil
}

// scannerSendBatchSize is the sendmmsg batch size: the options' value, else the
// environment's, else the default.
func scannerSendBatchSize(opts *SYNScannerOptions) int {
	if opts != nil && opts.SendBatchSize > 0 {
		return opts.SendBatchSize
	}

	return getSendBatchSize()
}

// scannerRingPollTimeoutMs is the ring poll timeout: the options' value, else
// max(retireTovMs, 50ms).
func scannerRingPollTimeoutMs(opts *SYNScannerOptions, retireTov uint32) int {
	if opts != nil && opts.RingPollTimeoutMs > 0 {
		return opts.RingPollTimeoutMs
	}

	return max(int(retireTov), 50)
}

// scannerRateLimit returns the send rate limit and burst: the options' rate,
// else the most the source-port window can sustain for the reply hold time,
// bounded to [1k, maxConservativeRate] pps.
func scannerRateLimit(log logger.Logger, opts *SYNScannerOptions, timeout time.Duration, scanPortStart, scanPortEnd uint16) (rateLimitPPS, rateLimitBurst int) {
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

		return rateLimitPPS, rateLimitBurst
	}

	// Use calculated safe default with reasonable bounds: minimum 1k pps,
	// conservative cap at maxConservativeRate.
	rateLimitPPS = min(max(safeCapacityPPS, 1000), maxConservativeRate)

	return rateLimitPPS, rateLimitPPS
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
