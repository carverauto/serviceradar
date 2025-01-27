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
}

func NewICMPScanner(timeout time.Duration, concurrency, count int) (*ICMPScanner, error) {
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

	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_ICMP)
	if err != nil {
		return nil, fmt.Errorf("failed to create raw socket: %w", err)
	}

	s.rawSocket = fd

	s.buildTemplate()

	return s, nil
}

func (s *ICMPScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
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

			ip := net.ParseIP(target.Host)
			if ip == nil {
				continue
			}

			// Initialize response for this target
			s.mu.Lock()
			if _, exists := s.responses[target.Host]; !exists {
				s.responses[target.Host] = &pingResponse{}
			}
			s.mu.Unlock()

			// Send pings
			for i := 0; i < s.count; i++ {
				select {
				case <-ctx.Done():
					return
				case <-s.done:
					return
				default:
					if err := s.sendPing(ip); err != nil {
						log.Printf("Error sending ping to %s: %v", target.Host, err)
						continue
					}
				}
				time.Sleep(rateLimit)
			}

			// Get results
			s.mu.RLock()
			resp := s.responses[target.Host]
			s.mu.RUnlock()

			if resp == nil {
				resp = &pingResponse{} // Ensure resp is never nil
			}

			// Calculate average response time only if there were successful pings
			var avgResponseTime time.Duration
			if resp.received > 0 {
				avgResponseTime = resp.totalTime / time.Duration(resp.received)
			} else {
				avgResponseTime = 0
			}

			results <- models.Result{
				Target:     target,
				Available:  resp.received > 0,
				RespTime:   avgResponseTime,
				PacketLoss: float64(s.count-resp.received) / float64(s.count) * 100,
				LastSeen:   resp.lastSeen,
			}
		}
	}()

	return results, nil
}

func (s *ICMPScanner) buildTemplate() {
	s.template = make([]byte, 8)
	s.template[0] = 8 // Echo Request
	s.template[1] = 0 // Code 0

	// Add identifier
	id := uint16(os.Getpid() & 0xffff)
	binary.BigEndian.PutUint16(s.template[4:], id)

	// Calculate checksum
	binary.BigEndian.PutUint16(s.template[2:], s.calculateChecksum(s.template))
}

func (s *ICMPScanner) calculateChecksum(data []byte) uint16 {
	var sum uint32
	for i := 0; i < len(data); i += 2 {
		sum += uint32(data[i])<<8 | uint32(data[i+1])
	}
	sum = (sum >> 16) + (sum & 0xffff)
	return ^uint16(sum)
}

func (s *ICMPScanner) sendPing(ip net.IP) error {
	var addr [4]byte
	copy(addr[:], ip.To4())

	dest := syscall.SockaddrInet4{
		Addr: addr,
	}

	return syscall.Sendto(s.rawSocket, s.template, 0, &dest)
}

func (s *ICMPScanner) listenForReplies(ctx context.Context) {
	conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		log.Printf("Failed to start ICMP listener: %v", err)
		return
	}
	defer conn.Close()

	packet := make([]byte, 1500)
	for {
		select {
		case <-ctx.Done():
			return
		case <-s.done:
			return
		default:
			if err := conn.SetReadDeadline(time.Now().Add(100 * time.Millisecond)); err != nil {
				continue
			}

			n, peer, err := conn.ReadFrom(packet)
			if err != nil {
				var netErr net.Error
				if errors.As(err, &netErr) && netErr.Timeout() {
					continue
				}
				log.Printf("Error reading ICMP packet: %v", err)
				continue
			}

			msg, err := icmp.ParseMessage(1, packet[:n])
			if err != nil {
				continue
			}

			if msg.Type == ipv4.ICMPTypeEchoReply {
				s.mu.Lock()
				ipStr := peer.String()
				if resp, exists := s.responses[ipStr]; exists {
					resp.received++
					resp.lastSeen = time.Now()
				}
				s.mu.Unlock()
			}
		}
	}
}

func (s *ICMPScanner) Stop() error {
	close(s.done)
	if s.rawSocket != 0 {
		if err := syscall.Close(s.rawSocket); err != nil {
			return fmt.Errorf("failed to close raw socket: %w", err)
		}
	}
	return nil
}
