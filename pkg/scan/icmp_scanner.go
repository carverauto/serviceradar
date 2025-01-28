// Package scan pkg/scan/icmp_scanner.go
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
	"syscall"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
)

const (
	scannerShutdownTimeout    = 5 * time.Second
	maxPacketSize             = 1500
	templateSize              = 8
	packetReadDeadline        = 100 * time.Millisecond
	listenForReplyIdleTimeout = 2 * time.Second
	setReadDeadlineTimeout    = 100 * time.Millisecond
	idleTimeoutMultiplier     = 2
)

var (
	errInvalidSocket     = errors.New("invalid socket")
	errInvalidParameters = errors.New("invalid parameters: timeout, concurrency, and count must be greater than zero")
)

type ICMPScanner struct {
	timeout     time.Duration
	concurrency int
	count       int
	done        chan struct{}
	rawSocket   int
	template    []byte
	responses   map[string]*pingResponse
	mu          sync.RWMutex
	listenerWg  sync.WaitGroup
}

type pingResponse struct {
	received  int
	totalTime time.Duration
	lastSeen  time.Time
	sendTime  time.Time
	dropped   int
	sent      int
}

func NewICMPScanner(timeout time.Duration, concurrency, count int) (*ICMPScanner, error) {
	// Validate parameters before proceeding
	if timeout <= 0 || concurrency <= 0 || count <= 0 {
		return nil, errInvalidParameters
	}

	s := &ICMPScanner{
		timeout:     timeout,
		concurrency: concurrency,
		count:       count,
		done:        make(chan struct{}),
		responses:   make(map[string]*pingResponse),
	}

	// Create raw socket
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_ICMP)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errInvalidSocket, err)
	}

	s.rawSocket = fd

	s.buildTemplate()

	return s, nil
}

func (s *ICMPScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	if s.rawSocket == -1 {
		return nil, errInvalidSocket
	}

	results := make(chan models.Result)
	rateLimit := time.Second / time.Duration(s.concurrency)

	// Start listener
	go s.listenForReplies(ctx)

	go func() {
		defer close(results)

		for _, target := range targets {
			if target.Mode != models.ModeICMP {
				continue
			}

			// Initialize response for this target
			s.mu.Lock()
			if _, exists := s.responses[target.Host]; !exists {
				s.responses[target.Host] = &pingResponse{}
			}
			s.mu.Unlock()

			// Send pings and track sent count
			for i := 0; i < s.count; i++ {
				select {
				case <-ctx.Done():
					return
				case <-s.done:
					return
				default:
					s.mu.Lock()
					s.responses[target.Host].sent++
					s.mu.Unlock()

					if err := s.sendPing(net.ParseIP(target.Host)); err != nil {
						log.Printf("Error sending ping to %s: %v", target.Host, err)
						s.mu.Lock()
						s.responses[target.Host].dropped++
						s.mu.Unlock()
					}
				}
				time.Sleep(rateLimit)
			}

			// Calculate results
			s.mu.RLock()

			resp := s.responses[target.Host]

			var avgResponseTime time.Duration

			if resp.received > 0 {
				avgResponseTime = resp.totalTime / time.Duration(resp.received)
			}

			packetLoss := float64(resp.sent-resp.received) / float64(resp.sent) * 100
			s.mu.RUnlock()

			results <- models.Result{
				Target:     target,
				Available:  resp.received > 0,
				RespTime:   avgResponseTime,
				PacketLoss: packetLoss,
				LastSeen:   resp.lastSeen,
			}
		}
	}()

	return results, nil
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

// calculateChecksum calculates the ICMP checksum for a byte slice.
// The checksum is the one's complement of the sum of the 16-bit integers in the data.
// If the data has an odd length, the last byte is padded with zero.
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

func (s *ICMPScanner) sendPing(ip net.IP) error {
	const (
		addrSize = 4
	)

	var addr [addrSize]byte

	copy(addr[:], ip.To4())

	dest := syscall.SockaddrInet4{
		Addr: addr,
	}

	s.mu.Lock()
	if resp, exists := s.responses[ip.String()]; exists {
		resp.sendTime = time.Now()
	}
	s.mu.Unlock()

	return syscall.Sendto(s.rawSocket, s.template, 0, &dest)
}

func (s *ICMPScanner) listenForReplies(ctx context.Context) {
	conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		log.Printf("Failed to start ICMP listener: %v", err)
		return
	}

	s.listenerWg.Add(1)

	defer func() {
		s.closeConn(conn)
		s.listenerWg.Done()
	}()

	packet := make([]byte, maxPacketSize)

	// Create a timeout timer for idle shutdown
	idleTimeout := time.NewTimer(s.timeout * idleTimeoutMultiplier)
	defer idleTimeout.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-s.done:
			return
		case <-idleTimeout.C:
			// If we've been idle too long, shut down
			log.Printf("ICMP listener idle timeout, shutting down")
			return
		default:
			// Set read deadline to ensure we don't block forever
			if err := conn.SetReadDeadline(time.Now().Add(setReadDeadlineTimeout)); err != nil {
				continue
			}

			n, peer, err := conn.ReadFrom(packet)
			if err != nil {
				// Handle timeout by continuing
				var netErr net.Error
				if errors.As(err, &netErr) && netErr.Timeout() {
					continue
				}

				log.Printf("Error reading ICMP packet: %v", err)

				continue
			}

			// Reset idle timeout since we got a packet
			idleTimeout.Reset(s.timeout * idleTimeoutMultiplier)

			s.processICMPMessage(packet[:n], peer)
		}
	}
}

func (*ICMPScanner) closeConn(conn *icmp.PacketConn) {
	if err := conn.Close(); err != nil {
		log.Printf("Failed to close ICMP listener: %v", err)
	}
}

func (s *ICMPScanner) processICMPMessage(data []byte, peer net.Addr) {
	msg, err := icmp.ParseMessage(1, data)
	if err != nil {
		return
	}

	if msg.Type == ipv4.ICMPTypeEchoReply {
		s.updateResponse(peer.String())
	}
}

func (s *ICMPScanner) updateResponse(ipStr string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if resp, exists := s.responses[ipStr]; exists {
		resp.received++

		resp.lastSeen = time.Now()

		if !resp.sendTime.IsZero() {
			resp.totalTime += time.Since(resp.sendTime)
		}
	}
}

func (s *ICMPScanner) Stop() error {
	// Signal shutdown
	close(s.done)

	// Wait for listener with timeout
	done := make(chan struct{})
	go func() {
		s.listenerWg.Wait()
		close(done)
	}()

	// Wait with timeout
	select {
	case <-done:
		// Normal shutdown
	case <-time.After(scannerShutdownTimeout):
		log.Printf("Warning: ICMP listener shutdown timed out")
	}

	if s.rawSocket != 0 {
		if err := syscall.Close(s.rawSocket); err != nil {
			return fmt.Errorf("failed to close raw socket: %w", err)
		}

		s.rawSocket = 0
	}

	return nil
}
