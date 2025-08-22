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
	"errors"
	"fmt"
	"math"
	"math/rand"
	"net"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	// TCP flags
	synFlag = 0x02
	rstFlag = 0x04
	ackFlag = 0x10

	// Ephemeral port range start for source ports
	ephemeralPortStart = 10000

	// Network constants
	maxEthernetFrameSize = 1500
	defaultTCPWindow     = 1024
	maxPortNumber        = 65535
)

// SYNScanner performs SYN scanning (half-open scanning) for faster TCP port detection
type SYNScanner struct {
	timeout     time.Duration
	concurrency int
	logger      logger.Logger
	sendSocket  int // Raw socket file descriptor for sending packets
	listenConn  net.PacketConn
	cancel      context.CancelFunc
	sourceIP    net.IP

	mu            sync.Mutex
	portTargetMap map[uint16]string // Maps source port to target key ("ip:port")
	results       map[string]models.Result
	nextPort      uint32
}

var _ Scanner = (*SYNScanner)(nil)

// NewSYNScanner creates a new SYN scanner
func NewSYNScanner(timeout time.Duration, concurrency int, log logger.Logger) (*SYNScanner, error) {
	if timeout == 0 {
		timeout = 1 * time.Second // SYN scans can be faster
	}

	if concurrency == 0 {
		concurrency = 1000 // Can handle much higher concurrency
	}

	// Create raw socket for sending packets with custom IP headers
	sendSocket, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_TCP)
	if err != nil {
		return nil, fmt.Errorf("cannot create raw send socket (requires root): %w", err)
	}

	if err = syscall.SetsockoptInt(sendSocket, syscall.IPPROTO_IP, syscall.IP_HDRINCL, 1); err != nil {
		syscall.Close(sendSocket)
		return nil, fmt.Errorf("cannot set IP_HDRINCL (requires root): %w", err)
	}

	// Create a listening connection to receive TCP responses
	listenConn, err := net.ListenPacket("ip4:tcp", "0.0.0.0")
	if err != nil {
		syscall.Close(sendSocket)
		return nil, fmt.Errorf("cannot create raw listen socket (requires root): %w", err)
	}

	// Find a local IP to use as the source for outgoing packets
	sourceIP, err := getLocalIP()
	if err != nil {
		syscall.Close(sendSocket)
		listenConn.Close()

		return nil, fmt.Errorf("failed to get local IP: %w", err)
	}

	return &SYNScanner{
		timeout:     timeout,
		concurrency: concurrency,
		logger:      log,
		sendSocket:  sendSocket,
		listenConn:  listenConn,
		sourceIP:    sourceIP,
		nextPort:    ephemeralPortStart,
	}, nil
}

// Scan performs SYN scanning on the given targets
func (s *SYNScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	tcpTargets := filterTCPTargets(targets)
	resultCh := make(chan models.Result, len(tcpTargets))

	if len(tcpTargets) == 0 {
		close(resultCh)
		return resultCh, nil
	}

	scanCtx, cancel := context.WithCancel(ctx)
	s.cancel = cancel

	// Initialize state for the new scan
	s.mu.Lock()
	s.results = make(map[string]models.Result, len(tcpTargets))
	s.portTargetMap = make(map[uint16]string, len(tcpTargets))
	s.mu.Unlock()

	// Start a single listener goroutine to handle all incoming packets
	var listenerWg sync.WaitGroup

	listenerWg.Add(1)

	go func() {
		defer listenerWg.Done()
		s.listenForReplies(scanCtx)
	}()

	// Start worker pool to send SYN packets
	workCh := make(chan models.Target, s.concurrency)

	var senderWg sync.WaitGroup

	for i := 0; i < s.concurrency; i++ {
		senderWg.Add(1)

		go func() {
			defer senderWg.Done()
			s.worker(scanCtx, workCh)
		}()
	}

	// Feed targets to the workers
	go func() {
		for _, t := range tcpTargets {
			select {
			case workCh <- t:
			case <-scanCtx.Done():
				return
			}
		}

		close(workCh)
	}()

	// Wait for all components to finish and process results
	go func() {
		senderWg.Wait()

		// Wait for potential late responses
		time.Sleep(s.timeout)

		// Stop the listener
		cancel()
		listenerWg.Wait()

		// Process and send results
		s.processResults(tcpTargets, resultCh)
		close(resultCh)
	}()

	return resultCh, nil
}

// worker sends SYN packets to targets from the work channel
func (s *SYNScanner) worker(ctx context.Context, workCh <-chan models.Target) {
	for {
		select {
		case target, ok := <-workCh:
			if !ok {
				return
			}

			s.sendSyn(target)
		case <-ctx.Done():
			return
		}
	}
}

// listenForReplies reads incoming packets and updates scan results.
func (s *SYNScanner) listenForReplies(ctx context.Context) {
	buffer := make([]byte, maxEthernetFrameSize)

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		if err := s.listenConn.SetReadDeadline(time.Now().Add(100 * time.Millisecond)); err != nil {
			s.logger.Debug().Err(err).Msg("Failed to set read deadline")
			continue
		}

		n, addr, err := s.listenConn.ReadFrom(buffer)

		if err != nil {
			var opErr *net.OpError
			if errors.As(err, &opErr) && opErr.Timeout() {
				continue
			}

			s.logger.Debug().Err(err).Msg("Error reading from raw socket")

			continue
		}

		// We only care about IPv4 packets for now
		if ip, ok := addr.(*net.IPAddr); ok && ip.IP.To4() != nil {
			s.processPacket(ip.IP, buffer[:n])
		}
	}
}

// processPacket parses a received IP packet and updates the corresponding target's result.
func (s *SYNScanner) processPacket(srcIP net.IP, buffer []byte) {
	// Basic validation
	if len(buffer) < int(sizeIPHDR+sizeTCPHdr) {
		return
	}

	// Assumes IP header length is 20 bytes, which is common but not guaranteed.
	// A more robust implementation would parse the IHL field.
	tcpHdrBytes := buffer[sizeIPHDR : sizeIPHDR+sizeTCPHdr]
	tcpHdr := (*tcphdr)(unsafe.Pointer(&tcpHdrBytes[0]))

	dstPort := ntohs(tcpHdr.dstPort)

	s.mu.Lock()
	defer s.mu.Unlock()

	// Check if this response corresponds to one of our sent packets
	targetKey, ok := s.portTargetMap[dstPort]
	if !ok {
		return // Not a port we are tracking
	}

	result, ok := s.results[targetKey]
	if !ok || result.Target.Host != srcIP.String() {
		return // Source IP doesn't match the target for this port
	}

	// This check prevents processing duplicate responses
	if result.Available || result.Error != nil {
		return
	}

	// Check TCP flags to determine port state
	if tcpHdr.flags&(synFlag|ackFlag) == (synFlag | ackFlag) {
		result.Available = true
	} else if tcpHdr.flags&(rstFlag|ackFlag) == (rstFlag | ackFlag) {
		result.Available = false
		result.Error = fmt.Errorf("port closed (RST/ACK received)")
	} else {
		return // Not a response we are interested in
	}

	result.RespTime = time.Since(result.FirstSeen)
	result.LastSeen = time.Now()

	s.results[targetKey] = result

	// Clean up the port map to prevent reuse while it might still be in TIME_WAIT
	delete(s.portTargetMap, dstPort)
}

// sendSyn crafts and sends a single SYN packet to the target.
func (s *SYNScanner) sendSyn(target models.Target) {
	destIP := net.ParseIP(target.Host)
	if destIP == nil {
		s.logger.Warn().Str("host", target.Host).Msg("Invalid target host")
		return
	}

	destIP = destIP.To4()
	if destIP == nil {
		s.logger.Warn().Str("host", target.Host).Msg("Target is not an IPv4 address")
		return
	}

	nextPortVal := atomic.AddUint32(&s.nextPort, 1)
	if nextPortVal > maxPortNumber {
		atomic.StoreUint32(&s.nextPort, ephemeralPortStart)
		nextPortVal = ephemeralPortStart
	}

	srcPort := uint16(nextPortVal) //nolint:gosec // Port range is validated above

	// Register the target and source port for response correlation
	targetKey := fmt.Sprintf("%s:%d", target.Host, target.Port)

	s.mu.Lock()
	s.portTargetMap[srcPort] = targetKey

	s.results[targetKey] = models.Result{
		Target:    target,
		FirstSeen: time.Now(),
		LastSeen:  time.Now(),
	}

	s.mu.Unlock()

	// Build the packet
	if target.Port > maxPortNumber {
		s.logger.Warn().Int("port", target.Port).Msg("Invalid target port")
		return
	}

	packet := buildSynPacket(s.sourceIP, destIP, srcPort, uint16(target.Port)) //nolint:gosec // Port range validated above

	// Send the packet
	addr := syscall.SockaddrInet4{Port: target.Port}
	copy(addr.Addr[:], destIP)

	if err := syscall.Sendto(s.sendSocket, packet, 0, &addr); err != nil {
		s.logger.Debug().Err(err).Str("host", target.Host).Msg("Failed to send SYN packet")
	}
}

// processResults aggregates final results and sends them to the channel.
func (s *SYNScanner) processResults(targets []models.Target, ch chan<- models.Result) {
	s.mu.Lock()
	defer s.mu.Unlock()

	for _, target := range targets {
		key := fmt.Sprintf("%s:%d", target.Host, target.Port)
		if result, ok := s.results[key]; ok {
			// If result was not updated by listener, it's a timeout
			if !result.Available && result.Error == nil {
				result.Error = fmt.Errorf("scan timed out")
			}

			ch <- result
		} else {
			// Should not happen, but as a fallback
			ch <- models.Result{
				Target:    target,
				Available: false,
				Error:     fmt.Errorf("target was not processed"),
				FirstSeen: time.Now(),
				LastSeen:  time.Now(),
			}
		}
	}
}

// Stop gracefully stops the scanner
func (s *SYNScanner) Stop(_ context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}

	var err error

	if s.listenConn != nil {
		err = s.listenConn.Close()
		s.listenConn = nil
	}

	if s.sendSocket != 0 {
		if e := syscall.Close(s.sendSocket); e != nil && err == nil {
			err = e
		}

		s.sendSocket = 0
	}

	return err
}

// Packet Crafting and Utility Functions

type iphdr struct {
	versionAndIhl uint8
	tos           uint8
	totalLength   uint16
	id            uint16
	fragOff       uint16
	ttl           uint8
	protocol      uint8
	checksum      uint16
	srcAddr       uint32
	destAddr      uint32
}

type tcphdr struct {
	srcPort uint16
	dstPort uint16
	seq     uint32
	ack     uint32
	thOff   uint8
	flags   uint8
	window  uint16
	sum     uint16
	urp     uint16
}

type pseudotcphdr struct {
	srcAddr  uint32
	destAddr uint32
	zero     uint8
	protocol uint8
	length   uint16
}

const (
	sizeIPHDR        = 20 // IPv4 header is always 20 bytes (without options)
	sizeTCPHdr       = 20 // TCP header is always 20 bytes (without options)
	sizePseudoTCPHdr = 12 // Pseudo TCP header for checksum calculation
)

func buildSynPacket(srcIP, destIP net.IP, srcPort, destPort uint16) []byte {
	ipHdr := iphdr{
		versionAndIhl: (4 << 4) | 5, // IPv4, 20-byte header
		tos:           0,
		totalLength:   htons(uint16(sizeIPHDR + sizeTCPHdr)),
		id:            uint16(rand.Intn(math.MaxUint16)), //nolint:gosec // ID randomization for network packets
		fragOff:       0,
		ttl:           64,
		protocol:      syscall.IPPROTO_TCP,
		srcAddr:       binary.BigEndian.Uint32(srcIP),
		destAddr:      binary.BigEndian.Uint32(destIP),
	}

	ipHdrBytes := (*[sizeIPHDR]byte)(unsafe.Pointer(&ipHdr))
	ipHdr.checksum = checksum(ipHdrBytes[:])
	ipHdrBytes = (*[sizeIPHDR]byte)(unsafe.Pointer(&ipHdr))

	pseudoHdr := pseudotcphdr{
		srcAddr:  ipHdr.srcAddr,
		destAddr: ipHdr.destAddr,
		protocol: syscall.IPPROTO_TCP,
		length:   htons(uint16(sizeTCPHdr)),
	}

	tcpHdr := tcphdr{
		srcPort: htons(srcPort),
		dstPort: htons(destPort),
		seq:     rand.Uint32(),
		ack:     0,
		thOff:   (uint8(sizeTCPHdr) / 4) << 4,
		flags:   synFlag,
		window:  htons(defaultTCPWindow),
	}

	pseudoHdrBytes := (*[sizePseudoTCPHdr]byte)(unsafe.Pointer(&pseudoHdr))
	tcpHdrBytes := (*[sizeTCPHdr]byte)(unsafe.Pointer(&tcpHdr))

	// Calculate TCP checksum
	sumPayload := make([]byte, 0, sizePseudoTCPHdr+sizeTCPHdr)
	sumPayload = append(sumPayload, pseudoHdrBytes[:]...)
	sumPayload = append(sumPayload, tcpHdrBytes[:]...)

	tcpHdr.sum = checksum(sumPayload)

	tcpHdrBytes = (*[sizeTCPHdr]byte)(unsafe.Pointer(&tcpHdr))

	// Combine headers into final packet
	packet := make([]byte, 0, sizeIPHDR+sizeTCPHdr)

	packet = append(packet, ipHdrBytes[:]...)
	packet = append(packet, tcpHdrBytes[:]...)

	return packet
}

func checksum(payload []byte) uint16 {
	var sum uint32

	for i := 0; i+1 < len(payload); i += 2 {
		sum += uint32(binary.BigEndian.Uint16(payload[i:]))
	}

	if len(payload)%2 != 0 {
		sum += uint32(payload[len(payload)-1]) << 8
	}

	for sum > 0xffff {
		sum = (sum >> 16) + (sum & 0xffff)
	}

	return ^uint16(sum)
}

func getLocalIP() (net.IP, error) {
	conn, err := net.Dial("udp", "8.8.8.8:80")
	if err != nil {
		// Fallback for environments without internet access
		addrs, err := net.InterfaceAddrs()
		if err != nil {
			return nil, err
		}

		for _, addr := range addrs {
			if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLoopback() {
				if ipnet.IP.To4() != nil {
					return ipnet.IP.To4(), nil
				}
			}
		}

		return nil, fmt.Errorf("no suitable local IP address found")
	}

	defer conn.Close()
	localAddr := conn.LocalAddr().(*net.UDPAddr)

	return localAddr.IP.To4(), nil
}

// Host to network short/long byte order conversions
func htons(n uint16) uint16 {
	return (n << 8) | (n >> 8)
}

func ntohs(n uint16) uint16 {
	return htons(n) // Same operation
}
