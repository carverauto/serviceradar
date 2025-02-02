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
	maxPacketSize       = 1500
	templateSize        = 8
	packetReadDeadline  = 100 * time.Millisecond
	listenerStartDelay  = 10 * time.Millisecond
	responseWaitDelay   = 100 * time.Millisecond
	maxPooledSockets    = 10 // Maximum number of sockets to pool
	maxConcurrentPings  = 100
	pingInterval        = 10 * time.Millisecond
	ipHeaderLen         = 20
	icmpHeaderLen       = 8
	minPacketSize       = ipHeaderLen + icmpHeaderLen
	icmpErrorOffset     = 28 // Offset to the original packet in ICMP error messages
	icmpDestUnreachable = 3
	icmpTimeExceeded    = 11
	ipSrcOffset         = 12 // Offset to source IP in IP header
	ipDstOffset         = 16 // Offset to destination IP in IP header
	portSrcOffset       = 20 // Source port offset from IP header start
	portDstOffset       = 22 // Destination port offset from IP header start
)

var (
	errInvalidSocket     = errors.New("invalid socket")
	errInvalidParameters = errors.New("invalid parameters: timeout, concurrency, and count must be greater than zero")
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
	debugLog     bool
}

type pingResponse struct {
	received  atomic.Int64
	totalTime atomic.Int64
	lastSeen  atomic.Value
	sendTime  atomic.Value
	dropped   atomic.Int64
	sent      atomic.Int64
	errors    map[string]int
	mu        sync.Mutex // Protect the errors map
}

func parseICMPError(data []byte) (*ICMPError, error) {
	if len(data) < minPacketSize {
		return nil, fmt.Errorf("packet too short (%d bytes)", len(data))
	}

	// First validate this is an ICMP error message
	if data[0] != icmpDestUnreachable && data[0] != icmpTimeExceeded {
		return nil, fmt.Errorf("not an ICMP error message (type: %d)", data[0])
	}

	e := &ICMPError{
		Type:    data[0],
		Code:    data[1],
		RawData: make([]byte, len(data)),
	}
	copy(e.RawData, data)

	// Skip ICMP header to get to original IP packet
	if len(data) < icmpHeaderLen+ipHeaderLen {
		return e, fmt.Errorf("truncated ICMP error message")
	}

	originalIP := data[icmpHeaderLen:]

	// Validate IP version (should be IPv4)
	if (originalIP[0] >> 4) != 4 {
		return e, fmt.Errorf("not an IPv4 packet in ICMP payload")
	}

	// Extract source and destination IPs
	srcIP := net.IP(originalIP[ipSrcOffset : ipSrcOffset+4])
	dstIP := net.IP(originalIP[ipDstOffset : ipDstOffset+4])

	// Validate IP addresses
	if srcIP.IsUnspecified() || srcIP.IsMulticast() || srcIP.IsLoopback() {
		return e, fmt.Errorf("invalid source IP: %v", srcIP)
	}
	if dstIP.IsUnspecified() || dstIP.IsMulticast() || dstIP.IsLoopback() {
		return e, fmt.Errorf("invalid destination IP: %v", dstIP)
	}

	e.SrcAddr = &net.IPAddr{IP: srcIP}
	e.DstAddr = &net.IPAddr{IP: dstIP}

	// Get the protocol (TCP/UDP/etc)
	protocol := originalIP[9]

	// Extract ports for TCP/UDP
	if protocol == 6 || protocol == 17 { // TCP or UDP
		if len(originalIP) >= ipHeaderLen+4 {
			e.SrcPort = int(binary.BigEndian.Uint16(originalIP[ipHeaderLen : ipHeaderLen+2]))
			e.DstPort = int(binary.BigEndian.Uint16(originalIP[ipHeaderLen+2 : ipHeaderLen+4]))

			// Basic port validation
			if e.SrcPort < 0 || e.SrcPort > 65535 ||
				e.DstPort < 0 || e.DstPort > 65535 {
				return e, fmt.Errorf("invalid ports: src=%d dst=%d", e.SrcPort, e.DstPort)
			}
		}
	}

	return e, nil
}

func (s *ICMPScanner) handleICMPError(peer net.Addr, data []byte) {
	icmpError, err := parseICMPError(data)
	if err != nil {
		// Only log parsing errors at debug level to avoid spam
		if s.debugLog {
			log.Printf("ICMP error parse failed: %v", err)
		}
		return
	}

	// Get error type string
	errType := "Unknown"
	switch icmpError.Type {
	case icmpDestUnreachable:
		errType = "Destination Unreachable"
		switch icmpError.Code {
		case 0:
			errType += " (Network)"
		case 1:
			errType += " (Host)"
		case 2:
			errType += " (Protocol)"
		case 3:
			errType += " (Port)"
		case 4:
			errType += " (Fragmentation needed)"
		}
	case icmpTimeExceeded:
		errType = "Time Exceeded"
	}

	// Only log valid errors that match our target network
	if icmpError.SrcAddr != nil && icmpError.DstAddr != nil {
		srcIP := icmpError.SrcAddr.IP.String()
		dstIP := icmpError.DstAddr.IP.String()

		// Check if this error is for one of our targets
		if value, ok := s.responses.Load(dstIP); ok {
			resp := value.(*pingResponse)
			resp.dropped.Add(1)

			// Log at info level since this is a valid error for our scan
			log.Printf("ICMP %s from %s for %s -> %s",
				errType, peer.String(), srcIP, dstIP)
		}
	}
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
		errorLimiter: rate.NewLimiter(rate.Every(100*time.Millisecond), 10),
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
	scanCtx, cancel := context.WithTimeout(ctx, s.timeout*2)

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

	// Create a separate context that won't be cancelled until all responses are received
	scanCtx, cancel := context.WithTimeout(context.Background(), s.timeout*2)
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
		log.Printf("Successfully sent result for target: %s", target.Host)
	case <-ctx.Done():
		log.Printf("Context cancelled while sending result for target: %s", target.Host)
		return
	case <-s.done:
		log.Printf("Scanner stopped while sending result for target: %s", target.Host)
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
			return nil, fmt.Errorf("no available sockets in the pool")
		}
	}

	return s.activeSocket, nil
}

func (s *ICMPScanner) releaseSocket() {
	s.socketMutex.Lock()
	defer s.socketMutex.Unlock()

	if s.activeSocket != nil {
		select {
		case s.connPool <- s.activeSocket:
			// Socket returned to the pool
		default:
			// Pool is full, close the socket
			err := s.activeSocket.Close()
			if err != nil {
				return
			}
		}
		s.activeSocket = nil
	}
}

func (s *ICMPScanner) listenForReplies(ctx context.Context) {
	conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		log.Printf("Failed to start ICMP listener: %v", err)
		return
	}

	// Use a separate context for the listener that won't be cancelled immediately
	listenerCtx, cancel := context.WithTimeout(context.Background(), s.timeout*2)
	defer cancel()
	defer conn.Close()

	buffer := make([]byte, maxPacketSize)

	// Create signal channel for graceful shutdown
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			// Give time for final responses before closing
			time.Sleep(100 * time.Millisecond)
			close(done)
		case <-listenerCtx.Done():
			close(done)
		}
	}()

	for {
		select {
		case <-done:
			return
		default:
			if err := conn.SetReadDeadline(time.Now().Add(packetReadDeadline)); err != nil {
				continue
			}

			n, peer, err := conn.ReadFrom(buffer)
			if err != nil {
				if !os.IsTimeout(err) {
					log.Printf("Error reading ICMP packet: %v", err)
				}
				continue
			}

			// Parse the ICMP message from the buffer, using only the bytes we received
			msg, err := icmp.ParseMessage(1, buffer[:n]) // 1 is the protocol number for ICMP
			if err != nil {
				log.Printf("Error parsing ICMP message: %v", err)
				continue
			}

			// Check if it's an echo reply
			if msg.Type != ipv4.ICMPTypeEchoReply {
				continue
			}

			// Process the response...
			ipStr := peer.String()

			value, ok := s.responses.Load(ipStr)
			if !ok {
				continue
			}

			resp := value.(*pingResponse)
			resp.received.Add(1)

			now := time.Now()
			sendTime := resp.sendTime.Load().(time.Time)

			// Update response metrics
			resp.totalTime.Add(now.Sub(sendTime).Nanoseconds())
			resp.lastSeen.Store(now)

			log.Printf("Received ICMP reply from %s (response time: %.2fms)",
				ipStr, float64(now.Sub(sendTime).Nanoseconds())/float64(time.Millisecond))
		}
	}
}

func (s *ICMPScanner) processScanResults(ctx context.Context, results chan<- models.Result, target models.Target) {
	value, ok := s.responses.Load(target.Host)
	if !ok {
		return
	}

	resp := value.(*pingResponse)
	resp.mu.Lock()

	e := make(map[string]int)
	for k, v := range resp.errors {
		e[k] = v
	}

	resp.mu.Unlock()

	result := models.Result{
		Target:     target,
		Available:  resp.received.Load() > 0,
		RespTime:   time.Duration(resp.totalTime.Load()) / time.Duration(resp.received.Load()),
		PacketLoss: float64(resp.dropped.Load()) / float64(resp.sent.Load()) * 100,
		LastSeen:   resp.lastSeen.Load().(time.Time),
		Metadata: map[string]interface{}{
			"sent":     resp.sent.Load(),
			"received": resp.received.Load(),
			"dropped":  resp.dropped.Load(),
			"errors":   e,
		},
	}

	select {
	case results <- result:
		log.Printf("Successfully sent result for target: %s", target.Host)
	case <-ctx.Done():
		log.Printf("Context cancelled while sending result for target: %s", target.Host)
		return
	}
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

func (s *ICMPScanner) Stop(ctx context.Context) error {
	close(s.done)
	s.closeAllPooledConnections()
	return nil
}
