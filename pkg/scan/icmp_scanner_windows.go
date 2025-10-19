//go:build windows
// +build windows

package scan

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"sync"
	"syscall"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
	"golang.org/x/sys/windows" // Import the Windows specific syscalls
)

const (
	defaultICMPRateLimit = 1000 // packets per second
	defaultICMPTimeout   = 5 * time.Second
	batchInterval        = 10 * time.Millisecond
)

type ICMPSweeper struct {
	rateLimit           int
	timeout             time.Duration
	identifier          int
	rawSocketFD         syscall.Handle // Change to syscall.Handle for Windows
	conn                icmpPacketConn
	mu                  sync.Mutex
	results             map[string]models.Result
	cancel              context.CancelFunc
	logger              logger.Logger
	rawSend             rawSendFunc
	invalidDestinations map[string]struct{}

	// Streaming results callback for immediate result emission
	resultCallback func(models.Result)
}

var _ Scanner = (*ICMPSweeper)(nil)

var (
	errInvalidICMPDestination = errors.New("icmp destination rejected by kernel")
	errInvalidIPv4Address     = errors.New("invalid IPv4 address")
)

type icmpPacketConn interface {
	SetReadDeadline(time.Time) error
	ReadFrom([]byte) (int, net.Addr, error)
	WriteTo([]byte, net.Addr) (int, error)
	Close() error
}

type rawSendFunc func(fd syscall.Handle, data []byte, addr *syscall.SockaddrInet4) error

const (
	defaultIdentifierMod = 65536
)

// NewICMPSweeper creates a new scanner for ICMP sweeping.
func NewICMPSweeper(timeout time.Duration, rateLimit int, log logger.Logger) (*ICMPSweeper, error) {
	if timeout == 0 {
		timeout = defaultICMPTimeout
	}

	if rateLimit == 0 {
		rateLimit = defaultICMPRateLimit
	}

	// Create identifier for this scanner instance
	identifier := int(time.Now().UnixNano() % defaultIdentifierMod)

	// Create raw socket for sending
	// Use windows.IPPROTO_ICMP for Windows
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, windows.IPPROTO_ICMP)
	if err != nil {
		return nil, fmt.Errorf("failed to create raw socket: %w", err)
	}

	// Create listener for receiving
	// Note: icmp.ListenPacket has known issues on Windows for raw ICMP (Issue #38427)
	// You might need a more robust solution for listening on Windows if this doesn't work reliably.
	conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		syscall.Close(fd) // Use syscall.Close for Windows
		return nil, fmt.Errorf("failed to create ICMP listener: %w", err)
	}

	s := &ICMPSweeper{
		rateLimit:           rateLimit,
		timeout:             timeout,
		identifier:          identifier,
		rawSocketFD:         fd,
		conn:                conn,
		results:             make(map[string]models.Result),
		logger:              log,
		invalidDestinations: make(map[string]struct{}),
		rawSend: func(fd syscall.Handle, data []byte, addr *syscall.SockaddrInet4) error {
			return syscall.Sendto(fd, data, 0, addr)
		},
	}

	return s, nil
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

	// Reset results map for this scan
	s.mu.Lock()
	s.results = make(map[string]models.Result)
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
func (s *ICMPSweeper) sendPings(ctx context.Context, targets []models.Target) {
	packetsPerInterval := s.calculatePacketsPerInterval()

	s.logger.Info().Int("targetCount", len(targets)).Int("rateLimit", s.rateLimit).Int("packetsPerInterval", packetsPerInterval).Msg("Sending ICMP pings")

	data, err := s.prepareEchoRequest()
	if err != nil {
		s.logger.Error().Err(err).Msg("Error marshaling ICMP message")

		return
	}

	s.sendBatches(ctx, targets, data, packetsPerInterval)
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

// prepareEchoRequest builds the ICMP echo request template.
func (s *ICMPSweeper) prepareEchoRequest() ([]byte, error) {
	msg := icmp.Message{
		Type: ipv4.ICMPTypeEcho,
		Code: 0,
		Body: &icmp.Echo{
			ID:   s.identifier,
			Seq:  1,
			Data: []byte("ping"),
		},
	}

	return msg.Marshal(nil)
}

const (
	defaultPauseTime = 50 * time.Millisecond
)

// sendBatches manages the sending of ping batches.
func (s *ICMPSweeper) sendBatches(ctx context.Context, targets []models.Target, data []byte, batchSize int) {
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

		s.processBatch(batch, data)

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
func (s *ICMPSweeper) processBatch(targets []models.Target, data []byte) {
	for _, target := range targets {
		s.sendPingToTarget(target, data)
	}
}

// sendPingToTarget sends a single ICMP ping and records initial result.
func (s *ICMPSweeper) sendPingToTarget(target models.Target, data []byte) {
	ipAddr := net.ParseIP(target.Host)
	if ipAddr == nil || ipAddr.To4() == nil {
		s.logger.Warn().Str("host", target.Host).Msg("Invalid IPv4 address")
		s.recordInitialResult(target, fmt.Errorf("%w: %s", errInvalidIPv4Address, target.Host))

		return
	}

	if s.shouldSkipInvalidDestination(target.Host) {
		s.logger.Debug().Str("host", target.Host).Msg("Skipping ICMP send for previously invalid destination")
		s.recordInitialResult(target, errInvalidICMPDestination)

		return
	}

	addr := [4]byte{}
	copy(addr[:], ipAddr.To4())
	sockaddr := &syscall.SockaddrInet4{Addr: addr}

	var sendErr error
	if err := s.sendRawPacket(data, sockaddr); err != nil {
		if handled, fallbackErr := s.tryFallbackSend(ipAddr, data, err); handled {
			sendErr = nil
		} else {
			sendErr = fallbackErr
		}
	}

	if sendErr != nil {
		if isInvalidDestinationError(sendErr) {
			wrappedErr := errors.Join(errInvalidICMPDestination, sendErr)
			s.markInvalidDestination(target.Host)
			s.logger.Warn().
				Err(sendErr).
				Str("host", target.Host).
				Msg("ICMP destination rejected, suppressing future attempts")
			s.recordInitialResult(target, wrappedErr)

			return
		}

		s.logger.Error().Err(sendErr).Str("host", target.Host).Msg("Error sending ICMP")
		s.recordInitialResult(target, sendErr)

		return
	}

	s.recordInitialResult(target, nil)
}

// recordInitialResult stores the initial ping result.
func (s *ICMPSweeper) recordInitialResult(target models.Target, sendErr error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	result := models.Result{
		Target:     target,
		Available:  false,
		FirstSeen:  now,
		LastSeen:   now,
		PacketLoss: 100,
		Error:      sendErr,
	}
	s.emitResult(target.Host, &result)
}

func (s *ICMPSweeper) sendRawPacket(data []byte, sockaddr *syscall.SockaddrInet4) error {
	if s.rawSend != nil {
		return s.rawSend(s.rawSocketFD, data, sockaddr)
	}

	return syscall.Sendto(s.rawSocketFD, data, 0, sockaddr)
}

func (s *ICMPSweeper) tryFallbackSend(ipAddr net.IP, data []byte, rawErr error) (bool, error) {
	if s.conn == nil {
		return false, rawErr
	}

	var errno syscall.Errno
	if !errors.As(rawErr, &errno) {
		return false, rawErr
	}

	if errno != syscall.EINVAL && errno != syscall.EADDRNOTAVAIL && errno != syscall.EAFNOSUPPORT {
		return false, rawErr
	}

	if _, err := s.conn.WriteTo(data, &net.IPAddr{IP: ipAddr}); err != nil {
		return false, err
	}

	s.logger.Debug().Err(rawErr).Str("host", ipAddr.String()).Msg("Fell back to PacketConn ICMP send")

	return true, nil
}

func (s *ICMPSweeper) shouldSkipInvalidDestination(host string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	_, exists := s.invalidDestinations[host]

	return exists
}

func (s *ICMPSweeper) markInvalidDestination(host string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.invalidDestinations[host] = struct{}{}
}

func isInvalidDestinationError(err error) bool {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		if errno == syscall.EINVAL || errno == syscall.EADDRNOTAVAIL || errno == syscall.EAFNOSUPPORT {
			return true
		}
	}

	var opErr *net.OpError
	if errors.As(err, &opErr) {
		return isInvalidDestinationError(opErr.Err)
	}

	var syscallErr *os.SyscallError
	if errors.As(err, &syscallErr) {
		return isInvalidDestinationError(syscallErr.Err)
	}

	return false
}

const (
	defaultBytesRead    = 1500
	defaultReadDeadline = 100 * time.Millisecond
)

// listenForReplies listens for and processes ICMP echo replies.
func (s *ICMPSweeper) listenForReplies(ctx context.Context, targets []models.Target) {
	targetMap := make(map[string]struct{})
	for _, t := range targets {
		targetMap[t.Host] = struct{}{}
	}

	buf := make([]byte, defaultBytesRead)

	for {
		select {
		case <-ctx.Done():
			return
		default:
			if err := s.conn.SetReadDeadline(time.Now().Add(defaultReadDeadline)); err != nil {
				s.logger.Error().Err(err).Msg("Error setting read deadline")
				continue
			}

			reply, err := s.readReply(buf)
			if err != nil {
				continue
			}

			if err := s.processReply(reply, targetMap); err != nil {
				continue
			}
		}
	}
}

// readReply reads an ICMP reply from the connection.
func (s *ICMPSweeper) readReply(buf []byte) (reply struct {
	n    int
	addr net.Addr
	data []byte
}, err error) {
	n, addr, err := s.conn.ReadFrom(buf)
	if err != nil {
		var netErr net.Error

		if errors.As(err, &netErr) && netErr.Timeout() {
			return reply, nil // Timeout is not an error in this context
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
}, targetMap map[string]struct{}) error {
	if reply.addr == nil {
		// Timeout or invalid reply, skip processing
		return nil
	}

	ip := reply.addr.String()

	// Verify this is one of our targets
	if _, ok := targetMap[ip]; !ok {
		return nil // Not an error, just not our target
	}

	// Parse the ICMP message
	msg, err := icmp.ParseMessage(1, reply.data)
	if err != nil {
		s.logger.Error().Err(err).Str("ip", ip).Msg("Error parsing ICMP message")
		return err
	}

	// Verify it's an echo reply with our identifier
	echo, ok := msg.Body.(*icmp.Echo)
	if !ok || msg.Type != ipv4.ICMPTypeEchoReply || echo.ID != s.identifier {
		return nil // Not an error, just not our reply
	}

	// Update the result
	s.mu.Lock()
	defer s.mu.Unlock()

	if result, ok := s.results[ip]; ok {
		result.Available = true
		result.RespTime = time.Since(result.FirstSeen)
		result.PacketLoss = 0
		result.LastSeen = time.Now()
		s.emitResult(ip, &result)
	}

	return nil
}

// processResults sends final results to the result channel.
func (s *ICMPSweeper) processResults(targets []models.Target, ch chan<- models.Result) {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Send all results to the channel
	for _, target := range targets {
		if result, ok := s.results[target.Host]; ok {
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
	}

	if s.rawSocketFD != 0 {
		err := syscall.Close(s.rawSocketFD) // Use syscall.Close for Windows
		if err != nil {
			s.logger.Error().Err(err).Msg("Error closing raw socket")

			return err
		}

		s.rawSocketFD = 0
	}

	return nil
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
