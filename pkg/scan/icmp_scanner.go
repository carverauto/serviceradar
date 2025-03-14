package scan

import (
	"context"
	"fmt"
	"log"
	"net"
	"sync"
	"syscall"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
)

const (
	defaultICMPRateLimit = 1000 // packets per second
	defaultICMPTimeout   = 5 * time.Second
	batchInterval        = 10 * time.Millisecond
)

type ICMPSweeper struct {
	rateLimit   int
	timeout     time.Duration
	identifier  int
	rawSocketFD int
	conn        *icmp.PacketConn
	mu          sync.Mutex
	results     map[string]models.Result
	cancel      context.CancelFunc
}

var _ Scanner = (*ICMPSweeper)(nil)

// NewICMPSweeper creates a new scanner for ICMP sweeping
func NewICMPSweeper(timeout time.Duration, rateLimit int) (*ICMPSweeper, error) {
	if timeout == 0 {
		timeout = defaultICMPTimeout
	}
	if rateLimit == 0 {
		rateLimit = defaultICMPRateLimit
	}

	// Create identifier for this scanner instance
	identifier := int(time.Now().UnixNano() % 65536)

	// Create raw socket for sending
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_ICMP)
	if err != nil {
		return nil, fmt.Errorf("failed to create raw socket: %w", err)
	}

	// Create listener for receiving
	conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		syscall.Close(fd)
		return nil, fmt.Errorf("failed to create ICMP listener: %w", err)
	}

	s := &ICMPSweeper{
		rateLimit:   rateLimit,
		timeout:     timeout,
		identifier:  identifier,
		rawSocketFD: fd,
		conn:        conn,
		results:     make(map[string]models.Result),
	}

	return s, nil
}

// Scan performs the ICMP sweep and returns results
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
			// Context canceled
		}

		// Stop the listener
		cancel()
		<-listenerDone

		// Process and send results
		s.processResults(icmpTargets, resultCh)
	}()

	return resultCh, nil
}

// sendPings sends ICMP echo requests to all targets with rate limiting
func (s *ICMPSweeper) sendPings(ctx context.Context, targets []models.Target) {
	packetsPerInterval := s.rateLimit / int(1000/batchInterval.Milliseconds())
	if packetsPerInterval < 1 {
		packetsPerInterval = 1
	}

	log.Printf("Sending ICMP pings to %d targets (rate: %d/sec, batch: %d)",
		len(targets), s.rateLimit, packetsPerInterval)

	// Build echo request template only once
	echoRequest := &icmp.Echo{
		ID:   s.identifier,
		Seq:  1,
		Data: []byte("ping"),
	}

	msg := icmp.Message{
		Type: ipv4.ICMPTypeEcho,
		Code: 0,
		Body: echoRequest,
	}

	data, err := msg.Marshal(nil)
	if err != nil {
		log.Printf("Error marshaling ICMP message: %v", err)
		return
	}

	ticker := time.NewTicker(batchInterval)
	defer ticker.Stop()

	targetIndex := 0
	for range ticker.C {
		select {
		case <-ctx.Done():
			return
		default:
			// Determine batch size for this interval
			batchEnd := targetIndex + packetsPerInterval
			if batchEnd > len(targets) {
				batchEnd = len(targets)
			}

			// Process this batch
			for i := targetIndex; i < batchEnd; i++ {
				target := targets[i]
				ipAddr := net.ParseIP(target.Host)
				if ipAddr == nil || ipAddr.To4() == nil {
					log.Printf("Invalid IPv4 address: %s", target.Host)
					continue
				}

				// Prepare sockaddr
				var addr [4]byte
				copy(addr[:], ipAddr.To4())
				sockaddr := &syscall.SockaddrInet4{Addr: addr}

				// Send packet
				err := syscall.Sendto(s.rawSocketFD, data, 0, sockaddr)
				if err != nil {
					log.Printf("Error sending ICMP to %s: %v", target.Host, err)
				}

				// Record initial result (will be updated if response received)
				s.mu.Lock()
				s.results[target.Host] = models.Result{
					Target:     target,
					Available:  false,
					FirstSeen:  time.Now(),
					LastSeen:   time.Now(),
					PacketLoss: 100,
				}
				// print result
				fmt.Println(s.results[target.Host])
				s.mu.Unlock()
			}

			targetIndex = batchEnd
			if targetIndex >= len(targets) {
				return
			}
		}
	}
}

// listenForReplies listens for and processes ICMP echo replies
func (s *ICMPSweeper) listenForReplies(ctx context.Context, targets []models.Target) {
	// Create a map for faster lookup of target hosts
	targetMap := make(map[string]struct{})
	for _, t := range targets {
		targetMap[t.Host] = struct{}{}
	}

	buf := make([]byte, 1500)

	// Set a reasonable read deadline so we don't block indefinitely
	readDeadline := 100 * time.Millisecond

	for {
		select {
		case <-ctx.Done():
			return
		default:
			s.conn.SetReadDeadline(time.Now().Add(readDeadline))
			n, addr, err := s.conn.ReadFrom(buf)
			if err != nil {
				if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
					// Just a timeout, continue to next read
					continue
				}
				log.Printf("Error reading ICMP reply: %v", err)
				continue
			}

			// Get the source IP
			ip := addr.String()

			// Check if this is one of our targets
			if _, ok := targetMap[ip]; !ok {
				// Not our target, ignore
				continue
			}

			// Parse the message
			msg, err := icmp.ParseMessage(1, buf[:n])
			if err != nil {
				log.Printf("Error parsing ICMP message from %s: %v", ip, err)
				continue
			}

			// We only care about echo replies
			if msg.Type != ipv4.ICMPTypeEchoReply {
				continue
			}

			// Check if it's our echo (matching identifier)
			echo, ok := msg.Body.(*icmp.Echo)
			if !ok || echo.ID != s.identifier {
				continue
			}

			// This is a valid reply to our ping
			s.mu.Lock()
			if result, ok := s.results[ip]; ok {
				result.Available = true
				result.RespTime = time.Since(result.FirstSeen)
				result.PacketLoss = 0
				result.LastSeen = time.Now()
				s.results[ip] = result
			}
			s.mu.Unlock()
		}
	}
}

// processResults sends final results to the result channel
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

// Stop stops the scanner and releases resources
func (s *ICMPSweeper) Stop(ctx context.Context) error {
	if s.cancel != nil {
		s.cancel()
	}

	// Close the connection and socket
	if s.conn != nil {
		s.conn.Close()
	}

	if s.rawSocketFD != 0 {
		syscall.Close(s.rawSocketFD)
		s.rawSocketFD = 0
	}

	return nil
}

// filterICMPTargets filters only ICMP targets from the given slice
func filterICMPTargets(targets []models.Target) []models.Target {
	var filtered []models.Target
	for _, t := range targets {
		if t.Mode == models.ModeICMP {
			filtered = append(filtered, t)
		}
	}
	return filtered
}
