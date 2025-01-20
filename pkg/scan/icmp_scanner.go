package scan

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
)

const (
	protocolICMP    = 1
	messageSize     = 64
	maxPacketSize   = 1500
	defaultAttempts = 3
)

type ICMPScanner struct {
	timeout     time.Duration
	concurrency int
	count       int
	done        chan struct{}
	scan        func(context.Context, []models.Target) (<-chan models.Result, error)
}

type ICMPWorkerConfig struct {
	conn     *icmp.PacketConn
	target   models.Target
	attempts int
	timeout  time.Duration
}

func NewICMPScanner(timeout time.Duration, concurrency, count int) *ICMPScanner {
	if count <= 0 {
		count = defaultAttempts
	}

	return &ICMPScanner{
		timeout:     timeout,
		concurrency: concurrency,
		count:       count,
		done:        make(chan struct{}),
	}
}

func (s *ICMPScanner) Stop() error {
	close(s.done)

	return nil
}

func (s *ICMPScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	if s.scan != nil {
		return s.scan(ctx, targets)
	}

	results := make(chan models.Result)
	targetChan := make(chan models.Target)

	conn, err := s.createICMPConnection()
	if err != nil {
		if os.IsPermission(err) {
			log.Printf("Warning: ICMP scanning requires root privileges, falling back to TCP: %v", err)
			return s.fallbackScan(ctx, targets)
		}

		return nil, fmt.Errorf("failed to create ICMP connection: %w", err)
	}

	// Start worker pool
	var wg sync.WaitGroup
	for i := 0; i < s.concurrency; i++ {
		wg.Add(1)

		go func() {
			defer wg.Done()
			s.worker(ctx, &ICMPWorkerConfig{
				conn:     conn,
				attempts: s.count,
				timeout:  s.timeout,
			}, targetChan, results)
		}()
	}

	// Feed targets
	go func() {
		defer close(targetChan)

		for _, target := range targets {
			select {
			case <-ctx.Done():
				return
			case <-s.done:
				return
			case targetChan <- target:
			}
		}
	}()

	// Close results when done
	go func() {
		wg.Wait()

		if err := conn.Close(); err != nil {
			log.Printf("Error closing ICMP connection: %v", err)
		}

		close(results)
	}()

	return results, nil
}

func (*ICMPScanner) createICMPConnection() (*icmp.PacketConn, error) {
	return icmp.ListenPacket("ip4:icmp", "0.0.0.0")
}

func (s *ICMPScanner) worker(ctx context.Context, config *ICMPWorkerConfig, targets <-chan models.Target, results chan<- models.Result) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-s.done:
			return
		case target, ok := <-targets:
			if !ok {
				return
			}

			config.target = target

			result := s.pingHost(ctx, config)
			select {
			case <-ctx.Done():
				return
			case <-s.done:
				return
			case results <- result:
			}
		}
	}
}

func (s *ICMPScanner) pingHost(ctx context.Context, config *ICMPWorkerConfig) models.Result {
	start := time.Now()
	result := models.Result{
		Target:    config.target,
		FirstSeen: start,
		LastSeen:  start,
	}

	var successfulPings int

	var totalTime time.Duration

	for i := 0; i < config.attempts; i++ {
		if available, respTime := s.sendPing(ctx, config); available {
			successfulPings++
			totalTime += respTime
		}
	}

	// Calculate results
	if successfulPings > 0 {
		result.Available = true
		result.RespTime = totalTime / time.Duration(successfulPings)
	} else {
		result.Available = false
		result.RespTime = config.timeout
	}

	if successfulPings < config.attempts {
		result.PacketLoss = float64(config.attempts-successfulPings) / float64(config.attempts) * 100
	}

	return result
}

func (*ICMPScanner) sendPing(_ context.Context, config *ICMPWorkerConfig) (bool, time.Duration) {
	start := time.Now()

	// Create ICMP message
	msg := &icmp.Message{
		Type: ipv4.ICMPTypeEcho,
		Code: 0,
		Body: &icmp.Echo{
			ID:   os.Getpid() & 0xffff,
			Seq:  1,
			Data: make([]byte, messageSize),
		},
	}

	// Marshal the message
	msgBytes, err := msg.Marshal(nil)
	if err != nil {
		log.Printf("Error marshaling ICMP message: %v", err)

		return false, 0
	}

	// Set read deadline
	if err = config.conn.SetReadDeadline(time.Now().Add(config.timeout)); err != nil {
		log.Printf("Error setting read deadline: %v", err)

		return false, 0
	}

	// Parse target IP
	ip := net.ParseIP(config.target.Host)
	if ip == nil {
		log.Printf("Invalid IP address: %s", config.target.Host)

		return false, 0
	}

	// Send ping
	if _, err = config.conn.WriteTo(msgBytes, &net.IPAddr{IP: ip}); err != nil {
		log.Printf("Error sending ICMP packet to %s: %v", ip, err)

		return false, 0
	}

	// Wait for response
	reply := make([]byte, maxPacketSize)

	n, peer, err := config.conn.ReadFrom(reply)
	if err != nil {
		var err net.Error

		if errors.As(err, &err) && err.Timeout() {
			return false, config.timeout
		}

		log.Printf("Error receiving ICMP reply from %s: %v", ip, err)

		return false, 0
	}

	// Parse response
	rm, err := icmp.ParseMessage(protocolICMP, reply[:n])
	if err != nil {
		log.Printf("Error parsing ICMP message from %s: %v", peer, err)

		return false, 0
	}

	elapsed := time.Since(start)
	success := rm.Type == ipv4.ICMPTypeEchoReply

	if success {
		log.Printf("Received ICMP reply from %v: time=%v", peer, elapsed)
	}

	return success, elapsed
}

func (s *ICMPScanner) fallbackScan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	// Convert ICMP targets to TCP targets
	tcpTargets := make([]models.Target, len(targets))

	for i, target := range targets {
		tcpTargets[i] = models.Target{
			Host: target.Host,
			Port: 80, // Try a common port for host discovery
			Mode: models.ModeTCP,
		}
	}

	scanner := NewTCPScanner(s.timeout, s.concurrency)

	return scanner.Scan(ctx, tcpTargets)
}
