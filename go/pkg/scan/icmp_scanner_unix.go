//go:build !windows

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
	"net"
	"sync"
	"syscall"
	"time"

	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
	"golang.org/x/net/ipv6"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

const (
	defaultICMPRateLimit = 1000 // packets per second
	defaultICMPTimeout   = 5 * time.Second
	batchInterval        = 10 * time.Millisecond
	defaultICMPCount     = 3 // default number of ICMP packets per target
	invalidRawSocketFD   = -1
)

type ICMPSweeper struct {
	rateLimit   int
	timeout     time.Duration
	identifier  int
	icmpCount   int // number of ICMP packets to send per target
	rawSocketFD int
	conn        *icmp.PacketConn
	conn6       *icmp.PacketConn
	mu          sync.Mutex
	results     map[string]models.Result
	cancel      context.CancelFunc
	logger      logger.Logger

	// Per-host tracking for multi-packet ICMP
	hostStats map[string]*hostICMPStats

	// Streaming results callback for immediate result emission
	resultCallback func(models.Result)
}

// hostICMPStats tracks ICMP statistics per host for multi-packet scanning
type hostICMPStats struct {
	sent      int
	received  int
	totalRTT  time.Duration // sum of all response times for averaging
	firstSeen time.Time
	lastSeen  time.Time
	sendTimes map[int]time.Time // send time per sequence number for accurate RTT
	mu        sync.Mutex
}

var _ Scanner = (*ICMPSweeper)(nil)
var _ CapabilityProvider = (*ICMPSweeper)(nil)

const (
	defaultIdentifierMod = 65536
)

// NewICMPSweeper creates a new scanner for ICMP sweeping.
func NewICMPSweeper(timeout time.Duration, rateLimit int, log logger.Logger, opts ...ICMPSweeperOption) (*ICMPSweeper, error) {
	if timeout == 0 {
		timeout = defaultICMPTimeout
	}

	if rateLimit == 0 {
		rateLimit = defaultICMPRateLimit
	}

	// Create identifier for this scanner instance
	identifier := int(time.Now().UnixNano() % defaultIdentifierMod)

	// Create raw socket for IPv4 sending.
	fd := invalidRawSocketFD
	socketFD, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_ICMP)
	if err != nil {
		log.Warn().Err(err).Msg("Failed to create ICMPv4 raw socket")
	} else {
		fd = socketFD
	}

	var conn *icmp.PacketConn
	if fd >= 0 {
		var listenErr error

		// Create IPv4 listener for receiving.
		conn, listenErr = icmp.ListenPacket("ip4:icmp", "0.0.0.0")
		if listenErr != nil {
			if closeErr := syscall.Close(fd); closeErr != nil {
				log.Error().Err(closeErr).Msg("Failed to close ICMPv4 raw socket")
				return nil, closeErr
			}

			fd = invalidRawSocketFD
			log.Warn().Err(listenErr).Msg("Failed to create ICMPv4 listener")
		}
	}

	conn6, err6 := icmp.ListenPacket("ip6:ipv6-icmp", "::")
	if err6 != nil {
		log.Warn().Err(err6).Msg("Failed to create ICMPv6 listener")
	}

	if conn == nil && conn6 == nil {
		if err != nil {
			return nil, fmt.Errorf("failed to create ICMP sockets: %w", err)
		}

		return nil, fmt.Errorf("failed to create ICMP sockets: %w", err6)
	}

	s := &ICMPSweeper{
		rateLimit:   rateLimit,
		timeout:     timeout,
		identifier:  identifier,
		icmpCount:   defaultICMPCount,
		rawSocketFD: fd,
		conn:        conn,
		conn6:       conn6,
		results:     make(map[string]models.Result),
		hostStats:   make(map[string]*hostICMPStats),
		logger:      log,
	}

	// Apply options
	for _, opt := range opts {
		opt(s)
	}

	log.Info().
		Int("icmpCount", s.icmpCount).
		Int("rateLimit", s.rateLimit).
		Dur("timeout", s.timeout).
		Bool("ipv4", s.conn != nil).
		Bool("ipv6", s.conn6 != nil).
		Msg("Created ICMP sweeper with multi-packet support")

	return s, nil
}

func (s *ICMPSweeper) Capabilities() ScannerCapabilities {
	if s == nil {
		return ScannerCapabilities{}
	}

	return ScannerCapabilities{
		ICMPv4: s.icmpv4Available(),
		ICMPv6: s.conn6 != nil,
	}
}

func (s *ICMPSweeper) icmpv4Available() bool {
	return s != nil && s.conn != nil && rawSocketAvailable(s.rawSocketFD)
}

func rawSocketAvailable(fd int) bool {
	return fd >= 0
}

// ICMPSweeperOption configures an ICMPSweeper instance.
type ICMPSweeperOption func(*ICMPSweeper)

// WithICMPCount sets the number of ICMP packets to send per target.
func WithICMPCount(count int) ICMPSweeperOption {
	return func(s *ICMPSweeper) {
		if count > 0 {
			s.icmpCount = count
		}
	}
}

// Scan performs the ICMP sweep and returns results.
func (s *ICMPSweeper) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	icmpTargets := filterICMPTargets(targets)

	if len(icmpTargets) == 0 {
		ch := make(chan models.Result)
		close(ch)

		return ch, nil
	}

	scanCtx, cancel := context.WithCancel(ctx)
	s.cancel = cancel

	resultCh := make(chan models.Result, len(icmpTargets))

	// Reset results and hostStats maps for this scan
	s.mu.Lock()
	s.results = make(map[string]models.Result)
	s.hostStats = make(map[string]*hostICMPStats)
	s.mu.Unlock()

	// Start listener goroutine
	listenerDone := make(chan struct{})

	go func() {
		defer close(listenerDone)

		s.listenForReplies(scanCtx, icmpTargets)
	}()

	// Start sender goroutine
	senderDone := make(chan struct{})

	go func() {
		defer close(senderDone)

		s.sendPings(scanCtx, icmpTargets)
	}()

	// Process results after scanning is done or timeout
	go func() {
		defer close(resultCh)

		// Wait for sender to finish or context to be canceled
		select {
		case <-senderDone:
			// Wait for all replies or timeout
			timer := time.NewTimer(s.timeout)
			select {
			case <-timer.C:
				// Timeout reached
			case <-scanCtx.Done():
				if !timer.Stop() {
					<-timer.C
				}
			}
		case <-scanCtx.Done():
		}

		cancel()
		<-listenerDone

		// Process and send results
		s.processResults(icmpTargets, resultCh)
	}()

	return resultCh, nil
}

// sendPings sends ICMP echo requests to all targets with rate limiting.
// Sends icmpCount packets per target with incrementing sequence numbers.
func (s *ICMPSweeper) sendPings(ctx context.Context, targets []models.Target) {
	packetsPerInterval := s.calculatePacketsPerInterval()

	s.logger.Info().
		Int("targetCount", len(targets)).
		Int("icmpCount", s.icmpCount).
		Int("totalPackets", len(targets)*s.icmpCount).
		Int("rateLimit", s.rateLimit).
		Int("packetsPerInterval", packetsPerInterval).
		Msg("Sending ICMP pings with multi-packet support")

	// Send icmpCount packets per target
	for seq := 1; seq <= s.icmpCount; seq++ {
		data, err := s.prepareEchoRequest(seq)
		if err != nil {
			s.logger.Error().Err(err).Int("seq", seq).Msg("Error marshaling ICMP message")
			continue
		}

		s.sendBatches(ctx, targets, data, packetsPerInterval, seq)

		// Brief pause between rounds to allow replies to come back
		if seq < s.icmpCount {
			select {
			case <-ctx.Done():
				return
			case <-time.After(50 * time.Millisecond):
			}
		}
	}
}

const (
	defaultRateLimitDivisor = 1000
	defaultBatchSize        = 5
	defaultMaxBatchSize     = 50
	defaultBatchDivisor     = 2
)

// calculatePacketsPerInterval determines the batch size based on rate limit.
func (s *ICMPSweeper) calculatePacketsPerInterval() int {
	packets := s.rateLimit / int(defaultRateLimitDivisor/batchInterval.Milliseconds())
	if packets < 1 {
		return 1
	}

	return packets
}

// prepareEchoRequest builds the ICMP echo request with the given sequence number.
func (s *ICMPSweeper) prepareEchoRequest(seq int) ([]byte, error) {
	return s.prepareEchoRequestForFamily(seq, false)
}

func (s *ICMPSweeper) prepareEchoRequestForFamily(seq int, isIPv6 bool) ([]byte, error) {
	var msgType icmp.Type = ipv4.ICMPTypeEcho
	if isIPv6 {
		msgType = ipv6.ICMPTypeEchoRequest
	}

	msg := icmp.Message{
		Type: msgType,
		Code: 0,
		Body: &icmp.Echo{
			ID:   s.identifier,
			Seq:  seq,
			Data: []byte("ping"),
		},
	}

	return msg.Marshal(nil)
}

const (
	defaultPauseTime = 50 * time.Millisecond
)

// sendBatches manages the sending of ping batches.
func (s *ICMPSweeper) sendBatches(ctx context.Context, targets []models.Target, data []byte, batchSize int, seq int) {
	ticker := time.NewTicker(batchInterval)
	defer ticker.Stop()

	targetIndex := 0
	maxBatchSize := batchSize

	if maxBatchSize > defaultMaxBatchSize { // Cap batch size to avoid buffer issues
		maxBatchSize = defaultMaxBatchSize
	}

	for range ticker.C {
		if ctx.Err() != nil {
			return
		}

		batchEnd := s.calculateBatchEnd(targetIndex, maxBatchSize, len(targets))
		batch := targets[targetIndex:batchEnd]

		s.processBatch(batch, data, seq)

		targetIndex = batchEnd
		if targetIndex >= len(targets) {
			return
		}

		// Back off if we hit buffer limits
		if s.checkBufferPressure() {
			time.Sleep(defaultPauseTime) // Brief pause

			maxBatchSize /= defaultBatchDivisor // Reduce batch size
			if maxBatchSize < defaultBatchSize {
				maxBatchSize = defaultBatchSize
			}

			s.logger.Debug().Int("newBatchSize", maxBatchSize).Msg("Reduced batch size due to buffer pressure")
		}
	}
}

// checkBufferPressure Check for buffer pressure (simplified, could use system metrics).
func (*ICMPSweeper) checkBufferPressure() bool {
	// Placeholder: Ideally, check syscall.Sendto errors or kernel buffer stats
	// For now, assume pressure if last send failed (requires error tracking)
	return false // Replace with real logic if needed
}

// calculateBatchEnd determines the end index for the current batch.
func (*ICMPSweeper) calculateBatchEnd(index, batchSize, totalTargets int) int {
	end := index + batchSize
	if end > totalTargets {
		return totalTargets
	}

	return end
}

// processBatch sends pings to a batch of targets.
func (s *ICMPSweeper) processBatch(targets []models.Target, data []byte, seq int) {
	for _, target := range targets {
		ipAddr := net.ParseIP(target.Host)
		if ipAddr == nil {
			continue
		}

		sendData := data
		if ipAddr.To4() == nil {
			var err error
			sendData, err = s.prepareEchoRequestForFamily(seq, true)
			if err != nil {
				s.logger.Error().Err(err).Int("seq", seq).Msg("Error marshaling ICMPv6 message")
				continue
			}
		}

		s.sendPingToTarget(target, sendData, seq)
	}
}

// sendPingToTarget sends a single ICMP ping and tracks it in hostStats.
func (s *ICMPSweeper) sendPingToTarget(target models.Target, data []byte, seq int) {
	ipAddr := net.ParseIP(target.Host)
	if ipAddr == nil {
		s.logger.Debug().Str("host", target.Host).Msg("Invalid IP address")

		return
	}

	// Record initial result BEFORE sending the first packet to avoid race condition
	// where handleReply could run before the result exists in the map
	if seq == 1 {
		s.recordInitialResult(target)
	}

	// Track sent packet in hostStats
	now := time.Now()

	s.mu.Lock()
	stats, exists := s.hostStats[target.Host]
	if !exists {
		stats = &hostICMPStats{
			firstSeen: now,
			sendTimes: make(map[int]time.Time),
		}
		s.hostStats[target.Host] = stats
	}
	s.mu.Unlock()

	stats.mu.Lock()
	stats.sent++
	stats.sendTimes[seq] = now // Record send time for this sequence number
	stats.mu.Unlock()

	if ip4 := ipAddr.To4(); ip4 != nil {
		if !s.icmpv4Available() {
			s.recordUnavailableResult(target, ErrICMPv4Unavailable)
			return
		}

		addr := [4]byte{}
		copy(addr[:], ip4)
		sockaddr := &syscall.SockaddrInet4{Addr: addr}

		if err := syscall.Sendto(s.rawSocketFD, data, 0, sockaddr); err != nil {
			s.logger.Error().Err(err).Str("host", target.Host).Int("seq", seq).Msg("Error sending ICMP")
			return
		}

		return
	}

	if s.conn6 == nil {
		s.recordUnavailableResult(target, ErrICMPv6Unavailable)
		return
	}

	if _, err := s.conn6.WriteTo(data, &net.IPAddr{IP: ipAddr}); err != nil {
		s.logger.Error().Err(err).Str("host", target.Host).Int("seq", seq).Msg("Error sending ICMP")
		return
	}
}

func (s *ICMPSweeper) recordUnavailableResult(target models.Target, resultErr error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	result := models.Result{
		Target:     target,
		Available:  false,
		Error:      resultErr,
		FirstSeen:  now,
		LastSeen:   now,
		PacketLoss: 100,
	}
	s.emitResult(target.Host, &result)
}

// recordInitialResult stores the initial ping result.
func (s *ICMPSweeper) recordInitialResult(target models.Target) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	result := models.Result{
		Target:     target,
		Available:  false,
		FirstSeen:  now,
		LastSeen:   now,
		PacketLoss: 100,
	}
	s.emitResult(target.Host, &result)
}

const (
	defaultBytesRead    = 1500
	defaultReadDeadline = 100 * time.Millisecond
)

// listenForReplies listens for and processes ICMP echo replies.
func (s *ICMPSweeper) listenForReplies(ctx context.Context, targets []models.Target) {
	targetMap := make(map[string]string)
	for _, t := range targets {
		if canonical := canonicalIPString(t.Host); canonical != "" {
			targetMap[canonical] = t.Host
		}
	}

	var wg sync.WaitGroup
	if s.conn != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.listenForRepliesOnConn(ctx, s.conn, targetMap, 1, ipv4.ICMPTypeEchoReply)
		}()
	}
	if s.conn6 != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.listenForRepliesOnConn(ctx, s.conn6, targetMap, 58, ipv6.ICMPTypeEchoReply)
		}()
	}

	wg.Wait()
}

func (s *ICMPSweeper) listenForRepliesOnConn(
	ctx context.Context,
	conn *icmp.PacketConn,
	targetMap map[string]string,
	protocol int,
	echoReplyType icmp.Type,
) {
	buf := make([]byte, defaultBytesRead)

	for {
		select {
		case <-ctx.Done():
			return
		default:
			if err := conn.SetReadDeadline(time.Now().Add(defaultReadDeadline)); err != nil {
				if errors.Is(err, net.ErrClosed) {
					s.logger.Debug().Msg("ICMP connection closed, stopping listener")
					return
				}

				s.logger.Error().Err(err).Msg("Error setting read deadline")
				continue
			}

			reply, err := s.readReply(conn, buf)
			if err != nil {
				if errors.Is(err, net.ErrClosed) {
					s.logger.Debug().Msg("ICMP reply reader stopping: connection closed")
					return
				}

				continue
			}

			if err := s.processReply(reply, targetMap, protocol, echoReplyType); err != nil {
				continue
			}
		}
	}
}

// readReply reads an ICMP reply from the connection.
func (s *ICMPSweeper) readReply(conn *icmp.PacketConn, buf []byte) (reply struct {
	n    int
	addr net.Addr
	data []byte
}, err error) {
	n, addr, err := conn.ReadFrom(buf)
	if err != nil {
		var netErr net.Error

		if errors.As(err, &netErr) && netErr.Timeout() {
			return reply, nil // Timeout is not an error in this context
		}

		if errors.Is(err, net.ErrClosed) {
			s.logger.Debug().Msg("ICMP connection closed while reading reply")
			return reply, err
		}

		s.logger.Error().Err(err).Msg("Error reading ICMP reply")

		return reply, err
	}

	return struct {
		n    int
		addr net.Addr
		data []byte
	}{n, addr, buf[:n]}, nil
}

// processReply processes a valid ICMP reply.
func (s *ICMPSweeper) processReply(reply struct {
	n    int
	addr net.Addr
	data []byte
}, targetMap map[string]string, protocol int, echoReplyType icmp.Type) error {
	if reply.addr == nil {
		// Timeout or invalid reply, skip processing
		return nil
	}

	ip := addrIPString(reply.addr)
	if ip == "" {
		return nil
	}

	// Verify this is one of our targets
	resultKey, ok := targetMap[ip]
	if !ok {
		return nil // Not an error, just not our target
	}

	// Parse the ICMP message
	msg, err := icmp.ParseMessage(protocol, reply.data)
	if err != nil {
		s.logger.Error().Err(err).Str("ip", ip).Msg("Error parsing ICMP message")
		return err
	}

	// Verify it's an echo reply with our identifier
	echo, ok := msg.Body.(*icmp.Echo)
	if !ok || msg.Type != echoReplyType || echo.ID != s.identifier {
		return nil // Not an error, just not our reply
	}

	now := time.Now()
	seq := echo.Seq

	// Update hostStats with received packet
	s.mu.Lock()
	stats, statsExist := s.hostStats[resultKey]
	s.mu.Unlock()

	if statsExist {
		stats.mu.Lock()
		stats.received++
		// Calculate RTT based on when this specific packet was sent
		if sendTime, ok := stats.sendTimes[seq]; ok {
			rtt := now.Sub(sendTime)
			stats.totalRTT += rtt
			delete(stats.sendTimes, seq) // Clean up to prevent memory growth
		}
		stats.lastSeen = now
		stats.mu.Unlock()
	}

	// Update the result - mark as available if ANY reply is received
	s.mu.Lock()
	defer s.mu.Unlock()

	if result, ok := s.results[resultKey]; ok {
		result.Available = true
		result.LastSeen = now

		// Calculate response time and packet loss from stats
		if statsExist {
			stats.mu.Lock()
			if stats.received > 0 {
				// Average response time from all received replies
				result.RespTime = stats.totalRTT / time.Duration(stats.received)
			}
			if stats.sent > 0 {
				// Packet loss = (sent - received) / sent * 100
				result.PacketLoss = float64(stats.sent-stats.received) / float64(stats.sent) * 100
			}
			stats.mu.Unlock()
		} else {
			// Fallback for single packet case
			result.RespTime = now.Sub(result.FirstSeen)
			result.PacketLoss = 0
		}

		// Write the updated result back to the map
		// (result is a value copy, so we must store it back)
		s.results[resultKey] = result

		s.emitResult(resultKey, &result)
	}

	return nil
}

// processResults sends final results to the result channel.
func (s *ICMPSweeper) processResults(targets []models.Target, ch chan<- models.Result) {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Send all results to the channel, with final packet loss calculations
	for _, target := range targets {
		if result, ok := s.results[target.Host]; ok {
			// Update final stats from hostStats
			if stats, statsExist := s.hostStats[target.Host]; statsExist {
				stats.mu.Lock()
				if stats.sent > 0 {
					result.PacketLoss = float64(stats.sent-stats.received) / float64(stats.sent) * 100
					if stats.received > 0 && result.RespTime == 0 {
						result.RespTime = stats.totalRTT / time.Duration(stats.received)
					}
				}

				// Log partial success for debugging
				if stats.received > 0 && stats.received < stats.sent {
					s.logger.Debug().
						Str("host", target.Host).
						Int("sent", stats.sent).
						Int("received", stats.received).
						Float64("packetLoss", result.PacketLoss).
						Dur("avgRTT", result.RespTime).
						Msg("Partial ICMP success - host marked available")
				} else if stats.received == 0 {
					s.logger.Debug().
						Str("host", target.Host).
						Int("sent", stats.sent).
						Msg("No ICMP replies received - host marked unavailable")
				}
				stats.mu.Unlock()
			}
			ch <- result
		} else {
			// If we somehow don't have a result for this target, create a default one
			ch <- models.Result{
				Target:     target,
				Available:  false,
				PacketLoss: 100,
				FirstSeen:  time.Now(),
				LastSeen:   time.Now(),
			}
		}
	}
}

// Stop stops the scanner and releases resources.
// SetResultCallback sets a callback function that will be called immediately when a result becomes available
func (s *ICMPSweeper) SetResultCallback(callback func(models.Result)) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.resultCallback = callback
}

// emitResult stores the result and immediately calls the callback if available and result is definitive
func (s *ICMPSweeper) emitResult(host string, result *models.Result) {
	s.results[host] = *result

	// Emit immediately if callback is set and result is definitive (Available=true or has Error)
	if s.resultCallback != nil && (result.Available || result.Error != nil) {
		cb := s.resultCallback
		res := *result

		go cb(res)
	}
}

func (s *ICMPSweeper) Stop() error {
	if s.cancel != nil {
		s.cancel()
	}

	// Close the connection and socket
	if s.conn != nil {
		err := s.conn.Close()
		if err != nil {
			s.logger.Error().Err(err).Msg("Error closing ICMP connection")

			return err
		}
		s.conn = nil
	}

	if s.conn6 != nil {
		err := s.conn6.Close()
		if err != nil {
			s.logger.Error().Err(err).Msg("Error closing ICMPv6 connection")

			return err
		}
		s.conn6 = nil
	}

	if rawSocketAvailable(s.rawSocketFD) {
		err := syscall.Close(s.rawSocketFD)
		if err != nil {
			s.logger.Error().Err(err).Msg("Error closing raw socket")

			return err
		}

		s.rawSocketFD = invalidRawSocketFD
	}

	return nil
}

func canonicalIPString(host string) string {
	ip := net.ParseIP(host)
	if ip == nil {
		return ""
	}

	return ip.String()
}

func addrIPString(addr net.Addr) string {
	switch a := addr.(type) {
	case *net.IPAddr:
		return a.IP.String()
	default:
		host, _, err := net.SplitHostPort(addr.String())
		if err == nil {
			if canonical := canonicalIPString(host); canonical != "" {
				return canonical
			}
		}

		return canonicalIPString(addr.String())
	}
}

// filterICMPTargets filters only ICMP targets from the given slice.
func filterICMPTargets(targets []models.Target) []models.Target {
	var filtered []models.Target

	for _, t := range targets {
		if t.Mode == models.ModeICMP {
			filtered = append(filtered, t)
		}
	}

	return filtered
}
