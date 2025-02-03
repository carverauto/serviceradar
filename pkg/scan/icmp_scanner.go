package scan

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
	"golang.org/x/time/rate"
)

const (
	maxPacketSize                   = 1500
	templateSize                    = 8
	defaultMaxSocketAge             = 10 * time.Minute
	defaultMaxIdleTime              = 1 * time.Minute
	defaultListenerTimeoutMultipler = 2
	defaultListenerStartupDelay     = 1 * time.Second
	defaultShutdownDelay            = 1 * time.Second
	packetReadDeadline              = 100 * time.Millisecond
	cleanupInterval                 = 30 * time.Second
	icmpProtocol                    = 1 // Protocol number for ICMP.
	defaultMaxSockets               = 10
	templateIDOffset                = 4
	templateChecksum                = 2
)

var (
	errInvalidParameters        = errors.New("invalid parameters: timeout, concurrency, and count must be greater than zero")
	errNoAvailableSocketsInPool = errors.New("no available sockets in pool")
)

type pingResponse struct {
	received  atomic.Int64
	totalTime atomic.Int64
	lastSeen  atomic.Value
	sendTime  atomic.Value
	dropped   atomic.Int64
	sent      atomic.Int64
}

// socketEntry represents a pooled socket with metadata.
type socketEntry struct {
	conn      *icmp.PacketConn
	createdAt time.Time
	lastUsed  atomic.Value
	inUse     atomic.Int32
	closed    atomic.Bool
}

// socketPool manages a collection of ICMP sockets with lifecycle tracking.
type socketPool struct {
	mu            sync.RWMutex
	sockets       []*socketEntry
	maxAge        time.Duration
	maxIdle       time.Duration
	maxSockets    int
	cleanupTicker *time.Ticker
	done          chan struct{}
}

type ICMPScanner struct {
	timeout       time.Duration
	concurrency   int
	count         int
	socketPool    *socketPool
	bufferPool    *bufferPool
	done          chan struct{}
	closeDoneOnce sync.Once // ADDED
	template      []byte
	responses     sync.Map
}

// bufferPool manages a pool of reusable byte buffers.
type bufferPool struct {
	pool sync.Pool
}

// startCleanup starts the background cleanup goroutine.
func (p *socketPool) startCleanup() {
	p.cleanupTicker = time.NewTicker(cleanupInterval)

	go func() {
		for {
			select {
			case <-p.done:
				return
			case <-p.cleanupTicker.C:
				p.cleanup()
			}
		}
	}()
}

func (p *socketPool) getSocket() (*icmp.PacketConn, func(), error) {
	p.mu.Lock()
	defer p.mu.Unlock()

	now := time.Now()

	// First try to find an available socket
	for _, entry := range p.sockets {
		if entry.closed.Load() {
			continue
		}

		lastUsed := entry.lastUsed.Load().(time.Time)
		if now.Sub(entry.createdAt) <= p.maxAge &&
			now.Sub(lastUsed) <= p.maxIdle &&
			entry.inUse.Load() == 0 {

			entry.lastUsed.Store(now)
			entry.inUse.Add(1)

			// Create a copy of entry for the closure to avoid race conditions
			e := entry
			return e.conn, func() {
				e.inUse.Add(-1)
				e.lastUsed.Store(time.Now())
			}, nil
		}
	}

	// Create new socket if pool isn't full
	if len(p.sockets) < p.maxSockets {
		conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
		if err != nil {
			return nil, nil, err
		}

		entry := &socketEntry{
			conn:      conn,
			createdAt: now,
		}
		entry.lastUsed.Store(now)
		entry.inUse.Store(1)
		p.sockets = append(p.sockets, entry)

		// Create a copy of entry for the closure
		e := entry
		return e.conn, func() {
			e.inUse.Add(-1)
			e.lastUsed.Store(time.Now())
		}, nil
	}

	// Try to find a closeable socket
	for _, entry := range p.sockets {
		if entry.inUse.Load() == 0 && !entry.closed.Load() {
			// Close the old socket
			if err := entry.conn.Close(); err != nil {
				log.Printf("Error closing old socket: %v", err)
			}
			entry.closed.Store(true)

			// Create new socket
			conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
			if err != nil {
				return nil, nil, err
			}

			entry.conn = conn
			entry.createdAt = now
			entry.lastUsed.Store(now)
			entry.closed.Store(false)
			entry.inUse.Store(1)

			// Create a copy of entry for the closure
			e := entry
			return e.conn, func() {
				e.inUse.Add(-1)
				e.lastUsed.Store(time.Now())
			}, nil
		}
	}

	return nil, nil, errNoAvailableSocketsInPool
}

func newSocketPool(maxSockets int, maxAge, maxIdle time.Duration) *socketPool {
	if maxAge == 0 {
		maxAge = defaultMaxSocketAge
	}
	if maxIdle == 0 {
		maxIdle = defaultMaxIdleTime
	}
	if maxSockets <= 0 {
		maxSockets = defaultMaxSockets
	}

	pool := &socketPool{
		maxAge:     maxAge,
		maxIdle:    maxIdle,
		maxSockets: maxSockets,
		sockets:    make([]*socketEntry, 0, maxSockets),
		done:       make(chan struct{}),
	}

	// Start the cleanup goroutine
	pool.startCleanup()

	return pool
}

// cleanup removes stale sockets from the pool.
func (p *socketPool) cleanup() {
	p.mu.Lock()
	defer p.mu.Unlock()

	now := time.Now()
	validSockets := make([]*socketEntry, 0, len(p.sockets))

	for _, entry := range p.sockets {
		// Skip already closed sockets
		if entry.closed.Load() {
			continue
		}

		lastUsed := entry.lastUsed.Load().(time.Time)

		// Check if socket is too old or has been idle too long
		if now.Sub(entry.createdAt) > p.maxAge ||
			now.Sub(lastUsed) > p.maxIdle {

			// Close socket if it exists and isn't already closed
			if entry.conn != nil {
				if err := entry.conn.Close(); err != nil {
					log.Printf("Error closing stale socket: %v", err)
				}
				entry.closed.Store(true)
			}
			continue
		}

		validSockets = append(validSockets, entry)
	}

	p.sockets = validSockets
}

// close cleans up all sockets in the pool.
func (p *socketPool) close() {
	if p.cleanupTicker != nil {
		p.cleanupTicker.Stop()
	}

	close(p.done)

	p.mu.Lock()
	defer p.mu.Unlock()

	for _, entry := range p.sockets {
		if err := entry.conn.Close(); err != nil {
			log.Printf("Error closing socket during shutdown: %v", err)
		}
	}

	p.sockets = nil
}

// newBufferPool creates a new buffer pool.
func newBufferPool(bufferSize int) *bufferPool {
	return &bufferPool{
		pool: sync.Pool{
			New: func() interface{} {
				return make([]byte, bufferSize)
			},
		},
	}
}

func (p *bufferPool) get() []byte {
	return p.pool.Get().([]byte)
}

// put returns a byte slice to the pool.
func (p *bufferPool) put(buf []byte) {
	p.pool.Put(buf) //nolint:staticcheck // Explicitly ignore SA6002 for this specific case
}

// NewICMPScanner creates a new ICMP scanner.
func NewICMPScanner(timeout time.Duration, concurrency, count int) (*ICMPScanner, error) {
	if timeout <= 0 || concurrency <= 0 || count <= 0 {
		return nil, errInvalidParameters
	}

	scanner := &ICMPScanner{
		timeout:       timeout,
		concurrency:   concurrency,
		count:         count,
		socketPool:    newSocketPool(defaultMaxSockets, defaultMaxSocketAge, defaultMaxIdleTime),
		bufferPool:    newBufferPool(maxPacketSize),
		done:          make(chan struct{}),
		closeDoneOnce: sync.Once{}, // ADDED
		responses:     sync.Map{},
	}

	scanner.buildTemplate()

	return scanner, nil
}

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

// sendPing sends an ICMP echo request to the target IP.
func (s *ICMPScanner) sendPing(ip net.IP) error {
	// Get a socket from the pool
	conn, release, err := s.socketPool.getSocket()
	if err != nil {
		return fmt.Errorf("failed to get socket from pool: %w", err)
	}
	defer release() // Always release the socket when done

	dest := &net.IPAddr{IP: ip}

	// Update send time if we're tracking this target
	if value, ok := s.responses.Load(ip.String()); ok {
		resp := value.(*pingResponse)
		resp.sendTime.Store(time.Now())
	}

	// Send the ICMP packet
	_, err = conn.WriteTo(s.template, dest)
	if err != nil {
		return fmt.Errorf("failed to send ICMP packet: %w", err)
	}

	return nil
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

// sendResultsForTarget processes and sends results for a target.
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

	select {
	case results <- result:
	case <-ctx.Done():
		return
	case <-s.done:
		return
	}

	s.responses.Delete(target.Host)
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

// Scan implements the Scanner interface.
// It performs ICMP scanning of the provided targets and returns results through a channel.
func (s *ICMPScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	// Filter for ICMP targets only
	icmpTargets := make([]models.Target, 0)

	for _, target := range targets {
		if target.Mode == models.ModeICMP {
			icmpTargets = append(icmpTargets, target)
		}
	}

	if len(icmpTargets) == 0 {
		// Return an empty channel if no ICMP targets
		results := make(chan models.Result)
		close(results)

		return results, nil
	}

	results := make(chan models.Result, len(icmpTargets))
	rateLimit := time.Second / time.Duration(s.concurrency)

	// Create new context with timeout
	scanCtx, cancel := context.WithTimeout(ctx, s.timeout*defaultListenerTimeoutMultipler)

	// Start listener before sending pings
	go s.listenForReplies(scanCtx)
	time.Sleep(defaultListenerStartupDelay)

	go func() {
		defer cancel() // Cancel context when processing is done
		defer close(results)

		s.processTargets(scanCtx, icmpTargets, results, rateLimit)
	}()

	return results, nil
}

// handleReadError checks if the error is a timeout and logs if it's not.
func handleReadError(err error) {
	if err != nil && !os.IsTimeout(err) {
		log.Printf("Error reading ICMP packet: %v", err)
	}
}

// parseICMPMessage parses the ICMP message and returns it or an error.
func parseICMPMessage(buffer []byte) (*icmp.Message, error) {
	msg, err := icmp.ParseMessage(icmpProtocol, buffer)
	if err != nil {
		return nil, err
	}

	return msg, nil
}

// processICMPReply processes the received ICMP reply.
func (s *ICMPScanner) processICMPReply(peer net.Addr) {
	ipStr := peer.String()

	value, ok := s.responses.Load(ipStr)
	if !ok {
		return
	}

	resp := value.(*pingResponse)
	if !ok {
		return
	}

	// Update response metrics
	now := time.Now()

	resp.received.Add(1)

	if sendTime, ok := resp.sendTime.Load().(time.Time); ok {
		resp.totalTime.Add(now.Sub(sendTime).Nanoseconds())
	}

	resp.lastSeen.Store(now)

	log.Printf("Received ICMP reply from %s (response time: %.2fms)",
		ipStr, float64(now.Sub(resp.sendTime.Load().(time.Time)).Nanoseconds())/float64(time.Millisecond))
}

// listenForReplies listens for ICMP replies and updates response metrics.
// listenForReplies listens for ICMP replies and updates response metrics.
func (s *ICMPScanner) listenForReplies(ctx context.Context) {
	log.Println("Starting listenForReplies") // ADDED LOG - function start

	// Get a socket from the pool for listening
	conn, release, err := s.socketPool.getSocket()
	if err != nil {
		log.Printf("Failed to get socket for listener: %v", err)
		return
	}
	defer release()

	// Create shutdown channel
	done := make(chan struct{})

	// Use a WaitGroup to ensure the monitoring goroutine exits
	var wg sync.WaitGroup
	wg.Add(1)

	// Monitor context cancellation
	go func() {
		log.Println("listenForReplies monitor goroutine started")
		defer wg.Done()
		select {
		case <-ctx.Done():
			log.Println("Context Done signal received in monitor goroutine") // ADDED LOG
			// Give a short delay for in-flight packets
			time.Sleep(100 * time.Millisecond)
			s.closeDoneOnce.Do(func() { close(done) })
			log.Println("done channel closed in monitor goroutine") // ADDED LOG
		case <-s.done:
			log.Println("ICMPScanner.done signal received in monitor")
			// Don't close done channel here, it might already be closed
			return
		default:
		}
		log.Println("listenForReplies monitor goroutine finished") // ADDED LOG
	}()

	// Get a buffer from the pool
	buffer := s.bufferPool.get()
	defer s.bufferPool.put(buffer)

	// Cleanup function to ensure we wait for the monitoring goroutine
	defer func() {
		close(done)
		wg.Wait()
		log.Println("listenForReplies cleanup deferral finished") // ADDED LOG
	}()
	log.Println("listenForReplies main loop started - entering loop") // ADDED LOG - before loop

	for {
		select {
		case <-done:
			log.Println("listenForReplies loop exiting due to done signal")
			return
		default:
			if ctx.Err() != nil || s.doneChanClosed() {
				log.Println("listenForReplies loop exiting due to context or scanner done")
				return
			}
			// Set a short read deadline to allow checking for shutdown
			readDeadline := time.Now().Add(100 * time.Millisecond)
			err := conn.SetReadDeadline(readDeadline)
			if err != nil {
				if !strings.Contains(err.Error(), "use of closed network connection") {
					log.Printf("Failed to set read deadline: %v", err)
				}
				return
			}
			log.Println("Set read deadline to:", readDeadline) // ADDED LOG

			n, peer, err := conn.ReadFrom(buffer)
			if err != nil {
				if !strings.Contains(err.Error(), "use of closed network connection") &&
					!strings.Contains(err.Error(), "i/o timeout") {
					log.Printf("Error reading ICMP packet: %v", err)
				} else if strings.Contains(err.Error(), "i/o timeout") {
					log.Println("ReadFrom timed out as expected") // ADDED LOG for timeout
				}
				continue
			}
			log.Printf("Read %d bytes from %v", n, peer) // ADDED LOG

			msg, err := s.parseICMPMessage(buffer[:n])
			if err != nil {
				log.Printf("Error parsing ICMP message: %v", err)
				continue
			}
			log.Println("Parsed ICMP message type:", msg.Type) // ADDED LOG

			// Process only echo replies
			if msg.Type != ipv4.ICMPTypeEchoReply {
				continue
			}

			s.processICMPReply(peer)
		}
	}
}

func (s *ICMPScanner) parseICMPMessage(buffer []byte) (*icmp.Message, error) {
	// Use the protocol number directly for ICMP
	msg, err := icmp.ParseMessage(icmpProtocol, buffer)
	if err != nil {
		return nil, fmt.Errorf("failed to parse ICMP message: %w", err)
	}

	return msg, nil
}

func (s *ICMPScanner) processTargets(ctx context.Context, targets []models.Target, results chan models.Result, rateLimit time.Duration) {
	// Create a wait group for batch processing
	var wg sync.WaitGroup

	// Create rate limiter for the entire scan
	limiter := rate.NewLimiter(rate.Every(time.Second/time.Duration(s.concurrency)), s.concurrency)

	// Process targets in batches
	for i := 0; i < len(targets); i += s.concurrency {
		end := i + s.concurrency
		if end > len(targets) {
			end = len(targets)
		}

		batch := targets[i:end]
		for _, target := range batch {
			wg.Add(1)

			go func(target models.Target) {
				defer wg.Done()

				// Wait for rate limiter
				if err := limiter.Wait(ctx); err != nil {
					log.Printf("Rate limiter error for target %s: %v", target.Host, err)
					return
				}

				s.sendPingsToTarget(ctx, target, rateLimit)
			}(target)
		}

		// Wait for batch to complete before moving to next batch
		wg.Wait()

		// Gather results for completed batch
		for _, target := range batch {
			s.sendResultsForTarget(ctx, results, target)
		}
	}
}

// Stop gracefully stops any ongoing scans.
func (s *ICMPScanner) Stop(context.Context) error {
	log.Println("ICMPScanner Stop called") // ADDED LOG
	close(s.done)
	s.socketPool.close()

	return nil
}

func (s *ICMPScanner) doneChanClosed() bool {
	select {
	case <-s.done:
		return true
	default:
		return false
	}
}
