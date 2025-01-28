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
	maxPacketSize      = 1500
	templateSize       = 8
	packetReadDeadline = 100 * time.Millisecond
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

	// Set default values if necessary
	if count <= 0 {
		count = 3
	}

	if concurrency <= 0 {
		concurrency = 1
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

func (*ICMPScanner) calculateChecksum(data []byte) uint16 {
	const (
		wordSize     = 2      // Size of a 16-bit word in bytes
		maxUint16    = 0xffff // Maximum value of a uint16
		bitShift     = 16     // Number of bits to shift for carry calculation
		checksumMask = 0xffff // Mask to extract the lower 16 bits
	)

	var checksum uint32

	// Sum all 16-bit words in the data
	for i := 0; i < len(data); i += wordSize {
		// Combine two bytes into a 16-bit word and add to the checksum
		checksum += uint32(data[i])<<8 | uint32(data[i+1])
	}

	// Add carry bits until the checksum fits into 16 bits
	for checksum > maxUint16 {
		checksum = (checksum >> bitShift) + (checksum & checksumMask)
	}

	// Return the one's complement of the checksum
	return ^uint16(checksum)
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
	defer s.closeConn(conn)

	packet := make([]byte, maxPacketSize)

	for {
		select {
		case <-ctx.Done():
			return
		case <-s.done:
			return
		default:
			s.handlePacket(conn, packet)
		}
	}
}

func (*ICMPScanner) closeConn(conn *icmp.PacketConn) {
	if err := conn.Close(); err != nil {
		log.Printf("Failed to close ICMP listener: %v", err)
	}
}

func (s *ICMPScanner) handlePacket(conn *icmp.PacketConn, packet []byte) {
	if err := conn.SetReadDeadline(time.Now().Add(packetReadDeadline)); err != nil {
		return
	}

	n, peer, err := conn.ReadFrom(packet)
	if err != nil {
		s.handleReadError(err)
		return
	}

	s.processICMPMessage(packet[:n], peer)
}

func (*ICMPScanner) handleReadError(err error) {
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return
	}

	log.Printf("Error reading ICMP packet: %v", err)
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
	close(s.done)

	if s.rawSocket != 0 {
		if err := syscall.Close(s.rawSocket); err != nil {
			return fmt.Errorf("failed to close raw socket: %w", err)
		}

		s.rawSocket = 0 // Mark the socket as closed
	}

	return nil
}
