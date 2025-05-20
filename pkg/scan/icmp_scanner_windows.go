//go:build windows
// +build windows

package scan

import (
	"context"
	"fmt"
	"log"
	"net"
	"sync"
	"syscall"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"golang.org/x/net/icmp"
	"golang.org/x/sys/windows"
)

const (
	defaultICMPRateLimit = 1000 // packets per second
	defaultICMPTimeout   = 5 * time.Second
	batchInterval        = 10 * time.Millisecond
)

type ICMPSweeper struct {
	rateLimit   int
	timeout     time.Duration
	identifier  int
	rawSocketFD syscall.Handle
	conn        *icmp.PacketConn
	mu          sync.Mutex
	results     map[string]models.Result
	cancel      context.CancelFunc
}

var _ Scanner = (*ICMPSweeper)(nil)

const (
	defaultIdentifierMod = 65536
)

// NewICMPSweeper creates a new scanner for ICMP sweeping.
func NewICMPSweeper(timeout time.Duration, rateLimit int) (*ICMPSweeper, error) {
	if timeout == 0 {
		timeout = defaultICMPTimeout
	}

	if rateLimit == 0 {
		rateLimit = defaultICMPRateLimit
	}

	// Create identifier for this scanner instance
	identifier := int(time.Now().UnixNano() % defaultIdentifierMod)

	// Create raw socket for sending
	// Use windows.IPPROTO_ICMP for Windows
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, windows.IPPROTO_ICMP)
	if err != nil {
		return nil, fmt.Errorf("failed to create raw socket: %w", err)
	}

	// Create listener for receiving
	// Note: icmp.ListenPacket has known issues on Windows for raw ICMP (Issue #38427)
	// You might need a more robust solution for listening on Windows if this doesn't work reliably.
	conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		syscall.Close(fd) // Use syscall.Close for Windows
		return nil, fmt.Errorf("failed to create ICMP listener: %w", err)
	}

	s := &ICMPSweeper{
		rateLimit:   rateLimit,
		timeout:     timeout,
		identifier:  identifier,
		rawSocketFD: fd,
		conn:        conn,
		results:     make(map[string]models.Result),
	}

	return s, nil
}

// Scan, sendPings, calculatePacketsPerInterval, prepareEchoRequest,
// calculateBatchEnd, checkBufferPressure, processBatch,
// recordInitialResult, listenForReplies, readReply, processReply,
// processResults, filterICMPTargets remain the same as in your original
// icmp_scanner.go, as they don't involve platform-specific syscall usage directly.

// sendPingToTarget sends a single ICMP ping and records initial result.
func (s *ICMPSweeper) sendPingToTarget(target models.Target, data []byte) {
	ipAddr := net.ParseIP(target.Host)
	if ipAddr == nil || ipAddr.To4() == nil {
		log.Printf("Invalid IPv4 address: %s", target.Host)
		return
	}

	addr := [4]byte{}
	copy(addr[:], ipAddr.To4())
	sockaddr := &syscall.SockaddrInet4{Addr: addr}

	// rawSocketFD is syscall.Handle for Windows, so direct use is fine
	if err := syscall.Sendto(s.rawSocketFD, data, 0, sockaddr); err != nil {
		log.Printf("Error sending ICMP to %s: %v", target.Host, err)
	}

	s.recordInitialResult(target)
}

// Stop stops the scanner and releases resources.
func (s *ICMPSweeper) Stop(_ context.Context) error {
	if s.cancel != nil {
		s.cancel()
	}

	// Close the connection and socket
	if s.conn != nil {
		err := s.conn.Close()
		if err != nil {
			log.Printf("Error closing ICMP connection: %v", err)
			return err
		}
	}

	if s.rawSocketFD != 0 {
		err := syscall.Close(s.rawSocketFD) // Use syscall.Close for Windows
		if err != nil {
			log.Printf("Error closing raw socket: %v", err)
			return err
		}

		s.rawSocketFD = 0
	}

	return nil
}

// filterICMPTargets filters only ICMP targets from the given slice.
func filterICMPTargets(targets []models.Target) []models.Target {
	var filtered []models.Target

	for _, t := range targets {
		if t.Mode == models.ModeICMP {
			filtered = append(filtered, t)
		}
	}

	return filtered
}
