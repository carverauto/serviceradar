/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package scan

import (
	"context"
	"encoding/binary"
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
	// Default rate limit in packets per second
	defaultRateLimit = 1000

	// ICMP protocol number for socket creation
	icmpProtocol = 1

	// Default timeout for ICMP packets
	defaultPacketTimeout = 2 * time.Second

	// Buffer size for listening
	packetBufferSize = 1500

	// Maximum number of pending results to buffer before blocking
	resultBufferSize = 10000

	// Batch size for sending packets
	batchSize = 100

	// Interval between packet batches to maintain rate limit
	batchInterval = 10 * time.Millisecond
)

// FastICMPScanner implements an optimized ICMP echo request scanner using raw sockets
type FastICMPScanner struct {
	rateLimit      int           // Maximum number of packets to send per second
	packetTimeout  time.Duration // Timeout for individual packets
	rawSocketFD    int           // Raw socket file descriptor for sending
	conn           *icmp.PacketConn
	echoTemplate   []byte               // Template for ICMP Echo Request packets
	responseCache  map[string]struct{}  // Cache of responding IPs
	mu             sync.RWMutex         // Mutex for cache access
	connMu         sync.Mutex           // Mutex for connection
	responseTimers map[string]time.Time // Track packet send times
	timersMu       sync.RWMutex
	sequence       uint16 // Sequence number for ICMP packets
	sequenceMu     sync.Mutex
	cancel         context.CancelFunc // For stopping the scanner
}

// NewFastICMPScanner creates a new optimized ICMP scanner
func NewFastICMPScanner(timeout time.Duration, rateLimit int) (Scanner, error) {
	if timeout == 0 {
		timeout = defaultPacketTimeout
	}

	if rateLimit == 0 {
		rateLimit = defaultRateLimit
	}

	scanner := &FastICMPScanner{
		rateLimit:      rateLimit,
		packetTimeout:  timeout,
		responseCache:  make(map[string]struct{}),
		responseTimers: make(map[string]time.Time),
		sequence:       1,
	}

	// Initialize the raw socket for sending
	if err := scanner.initRawSocket(); err != nil {
		return nil, fmt.Errorf("failed to initialize raw socket: %w", err)
	}

	// Build the echo request template
	scanner.buildEchoTemplate()

	return scanner, nil
}

// initRawSocket initializes the raw socket for sending ICMP packets
func (s *FastICMPScanner) initRawSocket() error {
	var err error
	s.rawSocketFD, err = syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, icmpProtocol)
	if err != nil {
		return fmt.Errorf("failed to create raw socket: %w", err)
	}

	// Set socket options if needed
	err = syscall.SetsockoptInt(s.rawSocketFD, syscall.SOL_SOCKET, syscall.SO_RCVBUF, 2*1024*1024)
	if err != nil {
		// Log but continue
		log.Printf("Warning: Failed to set socket receive buffer: %v", err)
	}

	return nil
}

// buildEchoTemplate creates an ICMP Echo Request packet template
func (s *FastICMPScanner) buildEchoTemplate() {
	s.echoTemplate = make([]byte, 8)
	s.echoTemplate[0] = 8 // Echo Request type
	s.echoTemplate[1] = 0 // Code 0
	// Checksum at bytes 2-3 will be calculated per packet
	binary.BigEndian.PutUint16(s.echoTemplate[4:], 0) // Identifier
	binary.BigEndian.PutUint16(s.echoTemplate[6:], 1) // Sequence number
}

// calculateChecksum calculates the ICMP checksum for a packet
func calculateChecksum(data []byte) uint16 {
	var sum uint32
	for i := 0; i < len(data); i += 2 {
		if i+1 < len(data) {
			sum += uint32(data[i])<<8 | uint32(data[i+1])
		} else {
			sum += uint32(data[i]) << 8
		}
	}
	sum = (sum >> 16) + (sum & 0xffff)
	sum = sum + (sum >> 16)
	return ^uint16(sum)
}

// Scan performs ICMP scanning for the given targets
func (s *FastICMPScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	// Filter only ICMP targets
	icmpTargets := make([]models.Target, 0, len(targets))
	for _, target := range targets {
		if target.Mode == models.ModeICMP {
			icmpTargets = append(icmpTargets, target)
		}
	}

	if len(icmpTargets) == 0 {
		log.Printf("No ICMP targets to scan")
		resultCh := make(chan models.Result)
		close(resultCh)
		return resultCh, nil
	}

	log.Printf("Starting ICMP scan for %d targets with rate limit of %d packets/sec",
		len(icmpTargets), s.rateLimit)

	// Create a cancellable context
	scanCtx, cancel := context.WithCancel(ctx)
	s.cancel = cancel

	// Create a listening connection for ICMP replies
	if err := s.initListeningConn(); err != nil {
		return nil, fmt.Errorf("failed to initialize listening connection: %w", err)
	}

	resultCh := make(chan models.Result, resultBufferSize)
	doneCh := make(chan struct{})

	// Start a goroutine to listen for ICMP echo replies
	go s.listenForReplies(scanCtx, resultCh, doneCh)

	// Start a goroutine to send ICMP echo requests
	go s.sendRequests(scanCtx, icmpTargets, resultCh, doneCh)

	return resultCh, nil
}

// initListeningConn initializes the connection for listening to ICMP replies
func (s *FastICMPScanner) initListeningConn() error {
	s.connMu.Lock()
	defer s.connMu.Unlock()

	var err error
	s.conn, err = icmp.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		return fmt.Errorf("failed to listen for ICMP packets: %w", err)
	}

	return nil
}

// listenForReplies listens for ICMP echo replies and sends results to the result channel
func (s *FastICMPScanner) listenForReplies(ctx context.Context, resultCh chan<- models.Result, doneCh <-chan struct{}) {
	defer func() {
		s.connMu.Lock()
		if s.conn != nil {
			s.conn.Close()
			s.conn = nil
		}
		s.connMu.Unlock()
		log.Printf("ICMP reply listener stopped")
	}()

	packet := make([]byte, packetBufferSize)
	for {
		select {
		case <-ctx.Done():
			log.Printf("Context canceled, stopping ICMP reply listener")
			return
		case <-doneCh:
			log.Printf("Done signal received, stopping ICMP reply listener")
			return
		default:
			// Non-blocking check for termination signals
		}

		// Set a read deadline to prevent blocking indefinitely
		if err := s.conn.SetReadDeadline(time.Now().Add(100 * time.Millisecond)); err != nil {
			log.Printf("Error setting read deadline: %v", err)
			continue
		}

		n, peer, err := s.conn.ReadFrom(packet)
		if err != nil {
			// Check if it's a timeout error
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				// This is just a timeout, continue listening
				continue
			}
			log.Printf("Error reading ICMP packet: %v", err)
			continue
		}

		// Process the packet
		s.processReply(peer.String(), packet[:n], resultCh)
	}
}

// processReply processes an ICMP echo reply and sends a result
func (s *FastICMPScanner) processReply(sourceIP string, packet []byte, resultCh chan<- models.Result) {
	// Parse the ICMP message
	msg, err := icmp.ParseMessage(ipv4.ICMPTypeEchoReply.Protocol(), packet)
	if err != nil {
		log.Printf("Error parsing ICMP message: %v", err)
		return
	}

	// Check if it's an echo reply
	if msg.Type != ipv4.ICMPTypeEchoReply {
		// Not an echo reply, ignore
		return
	}

	// Add to response cache
	s.mu.Lock()
	s.responseCache[sourceIP] = struct{}{}
	s.mu.Unlock()

	// Calculate response time
	var respTime time.Duration
	s.timersMu.RLock()
	if sendTime, ok := s.responseTimers[sourceIP]; ok {
		respTime = time.Since(sendTime)
	}
	s.timersMu.RUnlock()

	// Create a result
	result := models.Result{
		Target: models.Target{
			Host: sourceIP,
			Mode: models.ModeICMP,
		},
		Available:  true,
		FirstSeen:  time.Now(),
		LastSeen:   time.Now(),
		RespTime:   respTime,
		PacketLoss: 0.0,
	}

	// Send result to the channel
	select {
	case resultCh <- result:
		// Successfully sent the result
	default:
		// Channel is full, log and continue
		log.Printf("Warning: Result channel full, dropping ICMP result for %s", sourceIP)
	}
}

// sendRequests sends ICMP echo requests to all targets
func (s *FastICMPScanner) sendRequests(ctx context.Context, targets []models.Target, resultCh chan<- models.Result, doneCh chan<- struct{}) {
	defer func() {
		// Signal that we're done sending requests
		close(doneCh)
		log.Printf("ICMP request sender stopped")
	}()

	// Calculate how many packets to send per interval to maintain rate limit
	packetsPerInterval := int(float64(s.rateLimit) * (float64(batchInterval) / float64(time.Second)))
	if packetsPerInterval < 1 {
		packetsPerInterval = 1
	}

	// Create a ticker for rate limiting
	ticker := time.NewTicker(batchInterval)
	defer ticker.Stop()

	// Track which targets have been processed
	processed := 0
	targetCount := len(targets)

	// Send packets in batches to maintain rate limit
	for processed < targetCount {
		select {
		case <-ctx.Done():
			log.Printf("Context canceled, stopping ICMP request sender")
			return
		case <-ticker.C:
			// Send a batch of packets
			endIdx := processed + packetsPerInterval
			if endIdx > targetCount {
				endIdx = targetCount
			}

			batch := targets[processed:endIdx]
			for _, target := range batch {
				// Send the packet
				if err := s.sendEchoRequest(target.Host); err != nil {
					log.Printf("Error sending ICMP echo request to %s: %v", target.Host, err)
					// Create a failed result
					result := models.Result{
						Target:    target,
						Available: false,
						FirstSeen: time.Now(),
						LastSeen:  time.Now(),
						Error:     err,
					}
					resultCh <- result
				}
			}

			processed += len(batch)
			if processed%1000 == 0 || processed == targetCount {
				log.Printf("Sent ICMP requests to %d/%d targets", processed, targetCount)
			}
		}
	}

	// Wait for final replies
	select {
	case <-ctx.Done():
		// Context canceled, return immediately
	case <-time.After(s.packetTimeout):
		// Wait for the packet timeout before finishing
	}

	// Create results for non-responding hosts
	s.handleNonResponders(targets, resultCh)
}

// sendEchoRequest sends an ICMP echo request to a target host
func (s *FastICMPScanner) sendEchoRequest(host string) error {
	// Parse the IP address
	ipAddr := net.ParseIP(host)
	if ipAddr == nil {
		return fmt.Errorf("invalid IP address: %s", host)
	}
	ipv4Addr := ipAddr.To4()
	if ipv4Addr == nil {
		return fmt.Errorf("not an IPv4 address: %s", host)
	}

	// Create a copy of the template
	packet := make([]byte, len(s.echoTemplate))
	copy(packet, s.echoTemplate)

	// Update the sequence number
	s.sequenceMu.Lock()
	binary.BigEndian.PutUint16(packet[6:], s.sequence)
	s.sequence++
	s.sequenceMu.Unlock()

	// Calculate checksum
	checksum := calculateChecksum(packet)
	binary.BigEndian.PutUint16(packet[2:], checksum)

	// Create the socket address
	var addr [4]byte
	copy(addr[:], ipv4Addr)
	sockAddr := syscall.SockaddrInet4{
		Addr: addr,
	}

	// Record the send time
	s.timersMu.Lock()
	s.responseTimers[host] = time.Now()
	s.timersMu.Unlock()

	// Send the packet using the raw socket
	if err := syscall.Sendto(s.rawSocketFD, packet, 0, &sockAddr); err != nil {
		return fmt.Errorf("failed to send ICMP packet: %w", err)
	}

	return nil
}

// handleNonResponders creates results for targets that did not respond
func (s *FastICMPScanner) handleNonResponders(targets []models.Target, resultCh chan<- models.Result) {
	now := time.Now()

	for _, target := range targets {
		s.mu.RLock()
		_, responded := s.responseCache[target.Host]
		s.mu.RUnlock()

		if !responded {
			// Create a result for a non-responding host
			result := models.Result{
				Target:     target,
				Available:  false,
				FirstSeen:  now,
				LastSeen:   now,
				RespTime:   0,
				PacketLoss: 100.0,
			}

			// Send the result
			select {
			case resultCh <- result:
				// Successfully sent the result
			default:
				// Channel is full, log and continue
				log.Printf("Warning: Result channel full, dropping non-responder result for %s", target.Host)
			}
		}
	}
}

// Stop terminates the scanner and releases resources
func (s *FastICMPScanner) Stop(ctx context.Context) error {
	// Cancel the context if it exists
	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}

	s.connMu.Lock()
	defer s.connMu.Unlock()

	// Close the connection if it's open
	if s.conn != nil {
		if err := s.conn.Close(); err != nil {
			return fmt.Errorf("failed to close ICMP connection: %w", err)
		}
		s.conn = nil
	}

	// Close the raw socket
	if s.rawSocketFD != 0 {
		if err := syscall.Close(s.rawSocketFD); err != nil {
			return fmt.Errorf("failed to close raw socket: %w", err)
		}
		s.rawSocketFD = 0
	}

	return nil
}
