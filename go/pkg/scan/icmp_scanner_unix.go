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

// ICMPSweeper sends ICMP echo requests and matches the replies. One sweeper
// may serve concurrent Scan calls: they share its sockets and echo identifier,
// a single reader per address family receives every reply, and each reply is
// routed to the scans waiting on its source address.
type ICMPSweeper struct {
	rateLimit   int
	timeout     time.Duration
	identifier  int
	icmpCount   int // number of ICMP packets to send per target
	rawSocketFD int
	conn        *icmp.PacketConn
	conn6       *icmp.PacketConn
	logger      logger.Logger

	// mu guards sessions, readersStarted, stopped and resultCallback. It is
	// never held while a session's lock is taken.
	mu             sync.Mutex
	sessions       map[*icmpScanSession]struct{}
	readersStarted bool
	stopped        bool

	// scans counts in-flight Scan calls and readers the reply readers, so
	// Stop closes the sockets only after nothing uses them.
	scans   sync.WaitGroup
	readers sync.WaitGroup

	// Streaming results callback for immediate result emission
	resultCallback func(models.Result)
}

// icmpScanSession is the state of one Scan call.
type icmpScanSession struct {
	// targets maps each target's canonical IP to its result key (the
	// target's Host as given). It is not modified after creation.
	targets map[string]string
	cancel  context.CancelFunc
	// callback is the sweeper's result callback when the scan started.
	callback func(models.Result)

	mu        sync.Mutex
	results   map[string]models.Result
	hostStats map[string]*hostICMPStats
}

// hostICMPStats tracks ICMP statistics per host for multi-packet scanning.
// The owning session's mu guards it.
type hostICMPStats struct {
	sent      int
	received  int
	totalRTT  time.Duration // sum of all response times for averaging
	firstSeen time.Time
	lastSeen  time.Time
	sendTimes map[int]time.Time // send time per outstanding sequence number
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

	sockets, err := openICMPSockets()
	if err != nil {
		return nil, err
	}

	if sockets.probe.IPv4Err != nil {
		log.Warn().Err(sockets.probe.IPv4Err).Msg("Failed to open ICMPv4 sockets")
	}

	if sockets.probe.IPv6Err != nil {
		log.Warn().Err(sockets.probe.IPv6Err).Msg("Failed to open ICMPv6 listener")
	}

	if !sockets.probe.Available() {
		return nil, fmt.Errorf("failed to create ICMP sockets: %w",
			errors.Join(sockets.probe.IPv4Err, sockets.probe.IPv6Err))
	}

	s := &ICMPSweeper{
		rateLimit:   rateLimit,
		timeout:     timeout,
		identifier:  identifier,
		icmpCount:   defaultICMPCount,
		rawSocketFD: sockets.rawSocketFD,
		conn:        sockets.conn,
		conn6:       sockets.conn6,
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

// icmpSockets are the sockets an ICMPSweeper sends and receives on. A family
// that could not be opened is left closed, with its reason in probe.
type icmpSockets struct {
	rawSocketFD int
	conn        *icmp.PacketConn
	conn6       *icmp.PacketConn
	probe       ICMPSocketProbe
}

// openICMPSockets opens the IPv4 raw send socket with its listener, and the
// IPv6 listener. It fails only when a half-opened IPv4 socket cannot be closed.
func openICMPSockets() (icmpSockets, error) {
	sockets := icmpSockets{rawSocketFD: invalidRawSocketFD}

	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_ICMP)
	if err != nil {
		sockets.probe.IPv4Err = fmt.Errorf("ICMPv4 raw socket: %w", err)
	} else {
		conn, listenErr := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
		if listenErr != nil {
			if closeErr := syscall.Close(fd); closeErr != nil {
				return icmpSockets{}, fmt.Errorf("close ICMPv4 raw socket: %w", closeErr)
			}

			sockets.probe.IPv4Err = fmt.Errorf("ICMPv4 listener: %w", listenErr)
		} else {
			sockets.rawSocketFD = fd
			sockets.conn = conn
			sockets.probe.IPv4 = true
		}
	}

	conn6, err6 := icmp.ListenPacket("ip6:ipv6-icmp", "::")
	if err6 != nil {
		sockets.probe.IPv6Err = fmt.Errorf("ICMPv6 listener: %w", err6)
	} else {
		sockets.conn6 = conn6
		sockets.probe.IPv6 = true
	}

	return sockets, nil
}

// ProbeICMPSockets opens and closes the sockets NewICMPSweeper uses, so it
// reports exactly the address families an ICMP sweep could run on.
func ProbeICMPSockets() ICMPSocketProbe {
	sockets, err := openICMPSockets()
	if err != nil {
		return ICMPSocketProbe{IPv4Err: err, IPv6Err: err}
	}

	if sockets.conn != nil {
		_ = sockets.conn.Close()
	}

	if sockets.conn6 != nil {
		_ = sockets.conn6.Close()
	}

	if rawSocketAvailable(sockets.rawSocketFD) {
		_ = syscall.Close(sockets.rawSocketFD)
	}

	return sockets.probe
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

// Scan performs the ICMP sweep and returns results. It is safe to call
// concurrently; each call reports only on its own targets.
func (s *ICMPSweeper) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	icmpTargets := filterICMPTargets(targets)

	if len(icmpTargets) == 0 {
		ch := make(chan models.Result)
		close(ch)

		return ch, nil
	}

	scanCtx, cancel := context.WithCancel(ctx)

	session, err := s.startSession(icmpTargets, cancel)
	if err != nil {
		cancel()

		return nil, err
	}

	resultCh := make(chan models.Result, len(icmpTargets))

	go func() {
		defer close(resultCh)

		s.sendPings(scanCtx, session, icmpTargets)

		// Wait for replies until the timeout or cancellation.
		timer := time.NewTimer(s.timeout)
		select {
		case <-timer.C:
		case <-scanCtx.Done():
			timer.Stop()
		}

		cancel()
		s.finishSession(session, icmpTargets, resultCh)
	}()

	return resultCh, nil
}

// startSession registers a scan so the reply readers route replies to it,
// starting the readers on first use.
func (s *ICMPSweeper) startSession(targets []models.Target, cancel context.CancelFunc) (*icmpScanSession, error) {
	session := &icmpScanSession{
		targets:   make(map[string]string, len(targets)),
		cancel:    cancel,
		results:   make(map[string]models.Result, len(targets)),
		hostStats: make(map[string]*hostICMPStats, len(targets)),
	}

	for _, t := range targets {
		if canonical := canonicalIPString(t.Host); canonical != "" {
			session.targets[canonical] = t.Host
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.stopped {
		return nil, ErrICMPSweeperStopped
	}

	session.callback = s.resultCallback

	if s.sessions == nil {
		s.sessions = make(map[*icmpScanSession]struct{})
	}

	s.sessions[session] = struct{}{}
	s.scans.Add(1)
	s.startReadersLocked()

	return session, nil
}

// finishSession stops routing replies to a scan and delivers its results.
func (s *ICMPSweeper) finishSession(session *icmpScanSession, targets []models.Target, ch chan<- models.Result) {
	defer s.scans.Done()

	s.mu.Lock()
	delete(s.sessions, session)
	s.mu.Unlock()

	session.deliverResults(targets, ch, s.logger)
}

// startReadersLocked starts one reply reader per open socket. They run until
// Stop closes the sockets. The caller must hold s.mu.
func (s *ICMPSweeper) startReadersLocked() {
	if s.readersStarted {
		return
	}

	s.readersStarted = true

	if s.conn != nil {
		s.readers.Add(1)

		go s.readReplies(s.conn, protocolICMPv4, ipv4.ICMPTypeEchoReply)
	}

	if s.conn6 != nil {
		s.readers.Add(1)

		go s.readReplies(s.conn6, protocolICMPv6, ipv6.ICMPTypeEchoReply)
	}
}

// sendPings sends ICMP echo requests to all targets with rate limiting.
// Sends icmpCount packets per target with incrementing sequence numbers.
func (s *ICMPSweeper) sendPings(ctx context.Context, session *icmpScanSession, targets []models.Target) {
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

		s.sendBatches(ctx, session, targets, data, packetsPerInterval, seq)

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
func (s *ICMPSweeper) sendBatches(
	ctx context.Context,
	session *icmpScanSession,
	targets []models.Target,
	data []byte,
	batchSize int,
	seq int,
) {
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

		s.processBatch(session, batch, data, seq)

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
func (s *ICMPSweeper) processBatch(session *icmpScanSession, targets []models.Target, data []byte, seq int) {
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

		s.sendPingToTarget(session, target, sendData, seq)
	}
}

// sendPingToTarget sends a single ICMP ping and tracks it in the session.
func (s *ICMPSweeper) sendPingToTarget(session *icmpScanSession, target models.Target, data []byte, seq int) {
	ipAddr := net.ParseIP(target.Host)
	if ipAddr == nil {
		s.logger.Debug().Str("host", target.Host).Msg("Invalid IP address")

		return
	}

	// Record the send before the packet leaves so a fast reply finds it.
	session.recordSend(target, seq, time.Now())

	if ip4 := ipAddr.To4(); ip4 != nil {
		if !s.icmpv4Available() {
			session.recordUnavailable(target, ErrICMPv4Unavailable)
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
		session.recordUnavailable(target, ErrICMPv6Unavailable)
		return
	}

	if _, err := s.conn6.WriteTo(data, &net.IPAddr{IP: ipAddr}); err != nil {
		s.logger.Error().Err(err).Str("host", target.Host).Int("seq", seq).Msg("Error sending ICMP")
		return
	}
}

// recordSend counts an echo request to target with sequence number seq,
// creating the target's initial unavailable result on its first packet.
func (session *icmpScanSession) recordSend(target models.Target, seq int, now time.Time) {
	session.mu.Lock()
	defer session.mu.Unlock()

	if _, ok := session.results[target.Host]; !ok {
		session.results[target.Host] = models.Result{
			Target:     target,
			Available:  false,
			FirstSeen:  now,
			LastSeen:   now,
			PacketLoss: 100,
		}
	}

	stats, ok := session.hostStats[target.Host]
	if !ok {
		stats = &hostICMPStats{
			firstSeen: now,
			sendTimes: make(map[int]time.Time),
		}
		session.hostStats[target.Host] = stats
	}

	stats.sent++
	stats.sendTimes[seq] = now
}

func (session *icmpScanSession) recordUnavailable(target models.Target, resultErr error) {
	session.mu.Lock()
	defer session.mu.Unlock()

	now := time.Now()
	result := models.Result{
		Target:     target,
		Available:  false,
		Error:      resultErr,
		FirstSeen:  now,
		LastSeen:   now,
		PacketLoss: 100,
	}
	session.emitLocked(target.Host, &result)
}

const (
	defaultBytesRead = 1500
	readErrorBackoff = 100 * time.Millisecond

	protocolICMPv4 = 1
	protocolICMPv6 = 58
)

// readReplies reads ICMP messages from conn until it is closed and routes
// each echo reply to the scans waiting for it.
func (s *ICMPSweeper) readReplies(conn *icmp.PacketConn, protocol int, echoReplyType icmp.Type) {
	defer s.readers.Done()

	buf := make([]byte, defaultBytesRead)

	for {
		n, addr, err := conn.ReadFrom(buf)
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				s.logger.Debug().Msg("ICMP reply reader stopping: connection closed")
				return
			}

			s.logger.Error().Err(err).Msg("Error reading ICMP reply")

			// Back off so a persistent socket error cannot spin.
			time.Sleep(readErrorBackoff)

			continue
		}

		if err := s.dispatchReply(addr, buf[:n], protocol, echoReplyType, time.Now()); err != nil {
			s.logger.Error().Err(err).Str("addr", addr.String()).Msg("Error parsing ICMP message")
		}
	}
}

// dispatchReply routes an ICMP message received at now from addr to every
// scan that has the sender as a target, if it is an echo reply carrying this
// sweeper's identifier.
func (s *ICMPSweeper) dispatchReply(addr net.Addr, data []byte, protocol int, echoReplyType icmp.Type, now time.Time) error {
	if addr == nil {
		return nil
	}

	ip := addrIPString(addr)
	if ip == "" {
		return nil
	}

	s.mu.Lock()
	waiting := make([]*icmpScanSession, 0, 1)

	for session := range s.sessions {
		if _, ok := session.targets[ip]; ok {
			waiting = append(waiting, session)
		}
	}
	s.mu.Unlock()

	if len(waiting) == 0 {
		return nil // Not a reply any scan is waiting for
	}

	msg, err := icmp.ParseMessage(protocol, data)
	if err != nil {
		return err
	}

	echo, ok := msg.Body.(*icmp.Echo)
	if !ok || msg.Type != echoReplyType || echo.ID != s.identifier {
		return nil // Not our reply
	}

	for _, session := range waiting {
		session.recordReply(ip, echo.Seq, now)
	}

	return nil
}

// recordReply marks the target at ip available when it answered an echo
// request this scan sent and has not yet seen answered.
func (session *icmpScanSession) recordReply(ip string, seq int, now time.Time) {
	resultKey, ok := session.targets[ip]
	if !ok {
		return
	}

	session.mu.Lock()
	defer session.mu.Unlock()

	stats, ok := session.hostStats[resultKey]
	if !ok {
		return
	}

	// Only an outstanding sequence number counts, so a duplicate reply, or
	// a reply to another scan's request, cannot push received above sent.
	sendTime, outstanding := stats.sendTimes[seq]
	if !outstanding {
		return
	}

	delete(stats.sendTimes, seq)

	stats.received++
	stats.totalRTT += now.Sub(sendTime)
	stats.lastSeen = now

	result, ok := session.results[resultKey]
	if !ok {
		return
	}

	// Mark as available if ANY reply is received
	result.Available = true
	result.LastSeen = now
	result.RespTime = stats.totalRTT / time.Duration(stats.received)
	result.PacketLoss = float64(stats.sent-stats.received) / float64(stats.sent) * 100

	session.emitLocked(resultKey, &result)
}

// deliverResults sends the final result for every target to ch.
func (session *icmpScanSession) deliverResults(targets []models.Target, ch chan<- models.Result, log logger.Logger) {
	session.mu.Lock()
	defer session.mu.Unlock()

	for _, target := range targets {
		result, ok := session.results[target.Host]
		if !ok {
			// If we somehow don't have a result for this target, create a default one
			now := time.Now()
			ch <- models.Result{
				Target:     target,
				Available:  false,
				PacketLoss: 100,
				FirstSeen:  now,
				LastSeen:   now,
			}

			continue
		}

		if stats, statsExist := session.hostStats[target.Host]; statsExist {
			result.PacketsSent = uint32(stats.sent)
			result.PacketsReceived = uint32(stats.received)

			if stats.sent > 0 {
				result.PacketLoss = float64(stats.sent-stats.received) / float64(stats.sent) * 100
				if stats.received > 0 && result.RespTime == 0 {
					result.RespTime = stats.totalRTT / time.Duration(stats.received)
				}
			}

			if stats.received > 0 && stats.received < stats.sent {
				log.Debug().
					Str("host", target.Host).
					Int("sent", stats.sent).
					Int("received", stats.received).
					Float64("packetLoss", result.PacketLoss).
					Dur("avgRTT", result.RespTime).
					Msg("Partial ICMP success - host marked available")
			} else if stats.received == 0 {
				log.Debug().
					Str("host", target.Host).
					Int("sent", stats.sent).
					Msg("No ICMP replies received - host marked unavailable")
			}
		}

		ch <- result
	}
}

// SetResultCallback sets a callback function that will be called immediately
// when a result becomes available. It applies to scans started after the call.
func (s *ICMPSweeper) SetResultCallback(callback func(models.Result)) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.resultCallback = callback
}

// emitLocked stores the result and calls the callback when the result is
// definitive (Available=true or has Error). The caller must hold session.mu.
func (session *icmpScanSession) emitLocked(host string, result *models.Result) {
	session.results[host] = *result

	if session.callback != nil && (result.Available || result.Error != nil) {
		cb := session.callback
		res := *result

		go cb(res)
	}
}

// Stop cancels in-flight scans, waits for them to deliver their results,
// then closes the sockets. Later Scan calls fail with ErrICMPSweeperStopped.
func (s *ICMPSweeper) Stop() error {
	s.mu.Lock()
	s.stopped = true

	for session := range s.sessions {
		session.cancel()
	}
	s.mu.Unlock()

	s.scans.Wait()

	err := s.closeSockets()

	s.readers.Wait()

	return err
}

// closeSockets closes every open socket, attempting each one even when an
// earlier close fails so no descriptor is leaked.
func (s *ICMPSweeper) closeSockets() error {
	var errs []error

	if s.conn != nil {
		if err := s.conn.Close(); err != nil {
			s.logger.Error().Err(err).Msg("Error closing ICMP connection")
			errs = append(errs, err)
		}

		s.conn = nil
	}

	if s.conn6 != nil {
		if err := s.conn6.Close(); err != nil {
			s.logger.Error().Err(err).Msg("Error closing ICMPv6 connection")
			errs = append(errs, err)
		}

		s.conn6 = nil
	}

	if rawSocketAvailable(s.rawSocketFD) {
		if err := syscall.Close(s.rawSocketFD); err != nil {
			s.logger.Error().Err(err).Msg("Error closing raw socket")
			errs = append(errs, err)
		}

		s.rawSocketFD = invalidRawSocketFD
	}

	return errors.Join(errs...)
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
