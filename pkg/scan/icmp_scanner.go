package scan

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
	"golang.org/x/time/rate"
)

const (
	maxPacketSize             = 1500
	templateSize              = 8
	packetReadDeadline        = 100 * time.Millisecond
	listenerStartDelay        = 10 * time.Millisecond
	maxPooledSockets          = 10 // Maximum number of sockets to pool
	listenerTimeoutMultiplier = 2
	timeoutMultiplier         = 2
	icmpProtocol              = 1                      // Protocol number for ICMP.
	shutdownDelay             = 100 * time.Millisecond // Delay before shutdown to allow final responses.
	errorLimiterFreq          = 100 * time.Millisecond
	errorLimiterRate          = 10
)

var (
	errInvalidSocket          = errors.New("invalid socket")
	errInvalidParameters      = errors.New("invalid parameters: timeout, concurrency, and count must be greater than zero")
	errNoAvailableSocketsPool = errors.New("no available sockets in the pool")
)

type ICMPError struct {
	Type    uint8
	Code    uint8
	SrcAddr *net.IPAddr
	DstAddr *net.IPAddr
	SrcPort int
	DstPort int
	RawData []byte
}

type ICMPErrorPacket struct {
	Type     uint8
	Code     uint8
	Original []byte
	SrcIP    net.IP
	DstIP    net.IP
	SrcPort  uint16
	DstPort  uint16
}

type ICMPScanner struct {
	timeout      time.Duration
	concurrency  int
	count        int
	done         chan struct{}
	connPool     chan *icmp.PacketConn // Pool of PacketConn objects
	rawSocket    int
	template     []byte
	responses    sync.Map
	maxSockets   int
	socketMutex  sync.Mutex
	activeSocket *icmp.PacketConn
	errorLimiter *rate.Limiter
}

type pingResponse struct {
	received  atomic.Int64
	totalTime atomic.Int64
	lastSeen  atomic.Value
	sendTime  atomic.Value
	dropped   atomic.Int64
	sent      atomic.Int64
}

func NewICMPScanner(timeout time.Duration, concurrency, count int) (*ICMPScanner, error) {
	if timeout <= 0 || concurrency <= 0 || count <= 0 {
		return nil, errInvalidParameters
	}

	s := &ICMPScanner{
		timeout:      timeout,
		concurrency:  concurrency,
		count:        count,
		done:         make(chan struct{}),
		connPool:     make(chan *icmp.PacketConn, maxPooledSockets),
		maxSockets:   maxPooledSockets,
		socketMutex:  sync.Mutex{},
		errorLimiter: rate.NewLimiter(rate.Every(errorLimiterFreq), errorLimiterRate),
	}

	// Pre-fill connection pool
	for i := 0; i < maxPooledSockets; i++ {
		conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
		if err != nil {
			s.closeAllPooledConnections()
			return nil, fmt.Errorf("failed to create socket: %w", err)
		}
		s.connPool <- conn
	}

	s.buildTemplate()

	return s, nil
}

func (s *ICMPScanner) closeAllPooledConnections() {
	for {
		select {
		case conn := <-s.connPool:
			err := conn.Close()
			if err != nil {
				return
			}
		default:
			return
		}
	}
}

func (s *ICMPScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	if s.rawSocket == -1 {
		return nil, errInvalidSocket
	}

	results := make(chan models.Result, len(targets))
	rateLimit := time.Second / time.Duration(s.concurrency)

	// Create new context with timeout
	scanCtx, cancel := context.WithTimeout(ctx, s.timeout*listenerTimeoutMultiplier)

	// Start listener before sending pings
	go s.listenForReplies(scanCtx)
	time.Sleep(listenerStartDelay)

	go func() {
		defer cancel() // Cancel context when processing is done
		defer close(results)
		s.processTargets(scanCtx, targets, results, rateLimit)
	}()

	return results, nil
}

func (s *ICMPScanner) processTargets(ctx context.Context, targets []models.Target, results chan<- models.Result, rateLimit time.Duration) {
	// Create a wait group for batch processing
	var wg sync.WaitGroup

	// Create a separate context that won't be canceled until all responses are received
	scanCtx, cancel := context.WithTimeout(context.Background(), s.timeout*timeoutMultiplier)
	defer cancel()

	// Create rate limiter for the entire scan
	limiter := rate.NewLimiter(rate.Every(time.Second/time.Duration(s.concurrency)), s.concurrency)

	for i := 0; i < len(targets); i += s.concurrency {
		end := i + s.concurrency
		if end > len(targets) {
			end = len(targets)
		}

		batch := targets[i:end]
		for _, target := range batch {
			if target.Mode != models.ModeICMP {
				continue
			}

			wg.Add(1)

			go func(target models.Target) {
				defer wg.Done()

				// Wait for rate limiter
				if err := limiter.Wait(scanCtx); err != nil {
					log.Printf("Rate limiter error for target %s: %v", target.Host, err)
					return
				}

				s.sendPingsToTarget(scanCtx, target, rateLimit)
			}(target)
		}

		// Wait for batch to complete before moving to next batch
		wg.Wait()

		// Gather results for completed batch
		for _, target := range batch {
			if target.Mode != models.ModeICMP {
				continue
			}

			s.sendResultsForTarget(ctx, results, target)
		}
	}
}

func (s *ICMPScanner) sendPingsToTarget(ctx context.Context, target models.Target, rateLimit time.Duration) {
	resp := &pingResponse{}
	resp.lastSeen.Store(time.Time{})
	resp.sendTime.Store(time.Now())
	s.responses.Store(target.Host, resp)

	for i := 0; i < s.count; i++ {
		select {
		case <-ctx.Done():
			return
		case <-s.done:
			return
		default:
			resp.sent.Add(1)

			if err := s.sendPing(net.ParseIP(target.Host)); err != nil {
				log.Printf("Error sending ping to %s: %v", target.Host, err)
				resp.dropped.Add(1)
			}

			time.Sleep(rateLimit)
		}
	}
}

func (s *ICMPScanner) sendResultsForTarget(ctx context.Context, results chan<- models.Result, target models.Target) {
	value, ok := s.responses.Load(target.Host)
	if !ok {
		return
	}

	resp := value.(*pingResponse)
	received := resp.received.Load()
	sent := resp.sent.Load()
	totalTime := resp.totalTime.Load()
	lastSeen := resp.lastSeen.Load().(time.Time)

	avgResponseTime := time.Duration(0)
	if received > 0 {
		avgResponseTime = time.Duration(totalTime) / time.Duration(received)
	}

	packetLoss := float64(0)
	if sent > 0 {
		packetLoss = float64(sent-received) / float64(sent) * 100
	}

	result := models.Result{
		Target:     target,
		Available:  received > 0,
		RespTime:   avgResponseTime,
		PacketLoss: packetLoss,
		LastSeen:   lastSeen,
		FirstSeen:  time.Now(),
	}

	// Send the result or handle context cancellation
	select {
	case results <- result:
	case <-ctx.Done():
		return
	case <-s.done:
		return
	}

	s.responses.Delete(target.Host)
}

func (s *ICMPScanner) acquireSocket() (*icmp.PacketConn, error) {
	s.socketMutex.Lock()
	defer s.socketMutex.Unlock()

	if s.activeSocket == nil {
		select {
		case conn := <-s.connPool:
			s.activeSocket = conn
		default:
			return nil, errNoAvailableSocketsPool
		}
	}

	return s.activeSocket, nil
}

// listenForReplies starts an ICMP listener and processes incoming replies.
func (s *ICMPScanner) listenForReplies(ctx context.Context) {
	conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		log.Printf("Failed to start ICMP listener: %v", err)
		return
	}
	// Ensure connection is closed on exit.
	defer func(conn *icmp.PacketConn) {
		if err := conn.Close(); err != nil {
			log.Printf("Error closing ICMP listener: %v", err)
		}
	}(conn)

	// Create a separate listener context that lasts longer than the parent.
	listenerCtx, cancel := context.WithTimeout(context.Background(), s.timeout*listenerTimeoutMultiplier)
	defer cancel()

	// Allocate the buffer once.
	buffer := make([]byte, maxPacketSize)

	// Channel to signal graceful shutdown.
	done := make(chan struct{})

	// Goroutine that waits for cancellation.
	go func() {
		select {
		case <-ctx.Done():
			time.Sleep(shutdownDelay)
			close(done)
		case <-listenerCtx.Done():
			close(done)
		}
	}()

	// Main loop: read and process ICMP packets.
	for {
		select {
		case <-done:
			return
		default:
			// Set the read deadline.
			if err := conn.SetReadDeadline(time.Now().Add(packetReadDeadline)); err != nil {
				continue
			}

			// Read from the connection.
			n, peer, err := conn.ReadFrom(buffer)
			if err != nil {
				if !os.IsTimeout(err) {
					log.Printf("Error reading ICMP packet: %v", err)
				}

				continue
			}

			// Delegate processing of the packet.
			s.handleICMPPacket(buffer[:n], peer)
		}
	}
}

// handleICMPPacket parses an ICMP packet and updates metrics if it is an echo reply.
func (s *ICMPScanner) handleICMPPacket(packet []byte, peerAddr net.Addr) {
	// Parse the ICMP message.
	msg, err := icmp.ParseMessage(icmpProtocol, packet)
	if err != nil {
		log.Printf("Error parsing ICMP message: %v", err)

		return
	}

	// Only process echo replies.
	if msg.Type != ipv4.ICMPTypeEchoReply {
		return
	}

	ipStr := peerAddr.String()

	value, ok := s.responses.Load(ipStr)
	if !ok {
		return
	}

	resp, ok := value.(*pingResponse)
	if !ok {
		return
	}

	// Update metrics.
	resp.received.Add(1)

	now := time.Now()

	sendTime, ok := resp.sendTime.Load().(time.Time)
	if !ok {
		return
	}

	resp.totalTime.Add(now.Sub(sendTime).Nanoseconds())
	resp.lastSeen.Store(now)

	log.Printf("Received ICMP reply from %s (response time: %.2fms)",
		ipStr, float64(now.Sub(sendTime).Nanoseconds())/float64(time.Millisecond))
}

func (s *ICMPScanner) sendPing(ip net.IP) error {
	conn, err := s.acquireSocket()
	if err != nil {
		return fmt.Errorf("failed to acquire socket for sending ping: %w", err)
	}

	var addr [4]byte

	copy(addr[:], ip.To4())

	dest := &net.IPAddr{IP: ip}

	if value, ok := s.responses.Load(ip.String()); ok {
		resp := value.(*pingResponse)
		resp.sendTime.Store(time.Now())
	}

	_, err = conn.WriteTo(s.template, dest)
	if err != nil {
		return fmt.Errorf("failed to send ICMP packet: %w", err)
	}

	return nil
}

const (
	templateIDOffset = 4
	templateChecksum = 2
)

func (s *ICMPScanner) buildTemplate() {
	const (
		templateMask = 0xffff
	)

	s.template = make([]byte, templateSize)
	s.template[0] = 8 // Echo Request
	s.template[1] = 0 // Code 0

	// Add identifier
	id := uint16(os.Getpid() & templateMask) //nolint:gosec // the mask is used to ensure the ID fits in 16 bits
	binary.BigEndian.PutUint16(s.template[templateIDOffset:], id)

	// Calculate checksum
	binary.BigEndian.PutUint16(s.template[templateChecksum:], s.calculateChecksum(s.template))
}

func (*ICMPScanner) calculateChecksum(data []byte) uint16 {
	var (
		sum    uint32
		length = len(data)
		index  int
	)

	// Main loop sums up 16-bit words
	for length > 1 {
		sum += uint32(data[index])<<8 | uint32(data[index+1])
		index += 2
		length -= 2
	}

	// Add left-over byte, if any, padded by zero
	if length > 0 {
		sum += uint32(data[index]) << 8 // Pad with a zero byte
	}

	// Fold 32-bit sum into 16 bits
	for sum>>16 != 0 {
		sum = (sum & 0xFFFF) + (sum >> 16)
	}

	// Return one's complement
	return uint16(^sum) //nolint:gosec    // Take one's complement of uint32 sum, then convert to uint16
}

func (s *ICMPScanner) Stop(_ context.Context) error {
	close(s.done)
	s.closeAllPooledConnections()

	return nil
}
