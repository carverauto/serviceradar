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
	"sync/atomic"
	"syscall"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"golang.org/x/net/icmp"
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
	responses   sync.Map
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

	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_ICMP)
	if err != nil {
		return nil, fmt.Errorf("failed to create socket: %w", err)
	}

	s := &ICMPScanner{
		timeout:     timeout,
		concurrency: concurrency,
		count:       count,
		done:        make(chan struct{}),
		rawSocket:   fd,
	}

	s.buildTemplate()

	return s, nil
}

func (s *ICMPScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	if s.rawSocket == -1 {
		return nil, errInvalidSocket
	}

	results := make(chan models.Result, len(targets))
	rateLimit := time.Second / time.Duration(s.concurrency)

	// Start listener
	go s.listenForReplies(ctx)

	go func() {
		defer close(results)

		for _, target := range targets {
			if target.Mode != models.ModeICMP {
				continue
			}

			// Initialize response tracking for this target
			resp := s.initializeResponseTracking(target.Host)

			// Send pings and track sent count
			s.sendPings(ctx, target.Host, resp, rateLimit)

			// Get final results and send to the results channel
			s.sendResults(ctx, results, target)
		}
	}()

	return results, nil
}

// initializeResponseTracking initializes response tracking for a target.
func (s *ICMPScanner) initializeResponseTracking(host string) *pingResponse {
	resp := &pingResponse{
		lastSeen: atomic.Value{},
		sendTime: atomic.Value{},
	}
	resp.lastSeen.Store(time.Time{})
	resp.sendTime.Store(time.Time{})
	s.responses.Store(host, resp)

	return resp
}

// sendPings sends ICMP pings to the target and tracks sent/dropped packets.
func (s *ICMPScanner) sendPings(ctx context.Context, host string, resp *pingResponse, rateLimit time.Duration) {
	var wg sync.WaitGroup

	workerCount := s.concurrency

	// Create a worker pool
	for i := 0; i < workerCount; i++ {
		wg.Add(1)

		go func() {
			defer wg.Done()

			for j := 0; j < s.count/workerCount; j++ {
				select {
				case <-ctx.Done():
					return
				case <-s.done:
					return
				default:
					resp.sent.Add(1)

					if err := s.sendPing(net.ParseIP(host)); err != nil {
						log.Printf("Error sending ping to %s: %v", host, err)
						resp.dropped.Add(1)
					}
				}
				time.Sleep(rateLimit)
			}
		}()
	}

	wg.Wait()
}

func calculateAvgResponseTime(totalTime, received int64) time.Duration {
	if received > 0 {
		return time.Duration(totalTime) / time.Duration(received)
	}

	return 0
}

func calculatePacketLoss(sent, received int64) float64 {
	if sent > 0 {
		return float64(sent-received) / float64(sent) * 100
	}

	return 0
}

// sendResults calculates and sends the final results for a target.
func (s *ICMPScanner) sendResults(ctx context.Context, results chan<- models.Result, target models.Target) {
	value, ok := s.responses.Load(target.Host)
	if !ok {
		return
	}

	resp := value.(*pingResponse)

	received := resp.received.Load()
	sent := resp.sent.Load()
	totalTime := resp.totalTime.Load()
	lastSeen := resp.lastSeen.Load().(time.Time)

	avgResponseTime := calculateAvgResponseTime(totalTime, received)
	packetLoss := calculatePacketLoss(sent, received)

	select {
	case results <- models.Result{
		Target:     target,
		Available:  received > 0,
		RespTime:   avgResponseTime,
		PacketLoss: packetLoss,
		LastSeen:   lastSeen,
		FirstSeen:  time.Now(),
	}:
	case <-ctx.Done():
		return
	case <-s.done:
		return
	}
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
	const addrSize = 4

	var addr [addrSize]byte

	copy(addr[:], ip.To4())

	dest := syscall.SockaddrInet4{
		Addr: addr,
	}

	if value, ok := s.responses.Load(ip.String()); ok {
		resp := value.(*pingResponse)
		resp.sendTime.Store(time.Now())
	}

	return syscall.Sendto(s.rawSocket, s.template, 0, &dest)
}

func (s *ICMPScanner) listenForReplies(ctx context.Context) {
	conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		log.Printf("Failed to start ICMP listener: %v", err)
		return
	}
	defer func(conn *icmp.PacketConn) {
		err := conn.Close()
		if err != nil {
			log.Printf("Failed to close ICMP listener: %v", err)
		}
	}(conn)

	buffer := make([]byte, maxPacketSize)

	for {
		select {
		case <-ctx.Done():
			return
		case <-s.done:
			return
		default:
			if err := conn.SetReadDeadline(time.Now().Add(packetReadDeadline)); err != nil {
				continue
			}

			_, peer, err := conn.ReadFrom(buffer)
			if err != nil {
				if !os.IsTimeout(err) {
					log.Printf("Error reading ICMP packet: %v", err)
				}

				continue
			}

			ipStr := peer.String()

			value, ok := s.responses.Load(ipStr)
			if !ok {
				continue
			}

			resp := value.(*pingResponse)
			resp.received.Add(1)

			now := time.Now()
			sendTime := resp.sendTime.Load().(time.Time)
			resp.totalTime.Add(now.Sub(sendTime).Nanoseconds())
			resp.lastSeen.Store(now)
		}
	}
}

func (s *ICMPScanner) Stop() error {
	close(s.done)

	if s.rawSocket != 0 {
		if err := syscall.Close(s.rawSocket); err != nil {
			return fmt.Errorf("failed to close raw socket: %w", err)
		}

		s.rawSocket = 0
	}

	return nil
}
