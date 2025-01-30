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
	listenerStartDelay = 10 * time.Millisecond
	responseWaitDelay  = 100 * time.Millisecond
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

	go s.listenForReplies(ctx)
	time.Sleep(listenerStartDelay)

	go func() {
		defer close(results)
		s.processTargets(ctx, targets, results, rateLimit)
	}()

	return results, nil
}

func (s *ICMPScanner) processTargets(ctx context.Context, targets []models.Target, results chan<- models.Result, rateLimit time.Duration) {
	batchSize := s.concurrency
	for i := 0; i < len(targets); i += batchSize {
		end := i + batchSize
		if end > len(targets) {
			end = len(targets)
		}

		batch := targets[i:end]

		var wg sync.WaitGroup

		for _, target := range batch {
			if target.Mode != models.ModeICMP {
				continue
			}

			wg.Add(1)

			go func(target models.Target) {
				defer wg.Done()
				s.sendPingsToTarget(ctx, target, rateLimit)
			}(target)
		}

		wg.Wait()
		time.Sleep(responseWaitDelay)

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

	s.responses.Delete(target.Host)
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
