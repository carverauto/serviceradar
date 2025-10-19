package scan

import (
	"errors"
	"net"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

func TestCalculatePacketsPerInterval(t *testing.T) {
	sweeper := &ICMPSweeper{rateLimit: 1000}
	packets := sweeper.calculatePacketsPerInterval()

	expected := 10 // 1000 / (1000 / 10ms) = 10 packets
	if packets != expected {
		t.Errorf("calculatePacketsPerInterval() = %d, want %d", packets, expected)
	}

	sweeper.rateLimit = 50

	packets = sweeper.calculatePacketsPerInterval()
	if packets != 1 { // Minimum is 1
		t.Errorf("calculatePacketsPerInterval() = %d, want 1 for low rate", packets)
	}
}

func TestProcessResults(t *testing.T) {
	sweeper := &ICMPSweeper{
		results: make(map[string]models.Result),
		mu:      sync.Mutex{},
	}

	targets := []models.Target{
		{Host: "8.8.8.8", Mode: models.ModeICMP},
		{Host: "1.1.1.1", Mode: models.ModeICMP},
	}

	now := time.Now()
	sweeper.results["8.8.8.8"] = models.Result{
		Target:     targets[0],
		Available:  true,
		RespTime:   10 * time.Millisecond,
		PacketLoss: 0,
		FirstSeen:  now,
		LastSeen:   now,
	}

	resultCh := make(chan models.Result, len(targets))
	sweeper.processResults(targets, resultCh)
	close(resultCh)

	results := make([]models.Result, 0, len(targets))
	for r := range resultCh {
		results = append(results, r)
	}

	if len(results) != len(targets) {
		t.Errorf("processResults() sent %d results, want %d", len(results), len(targets))
	}

	for _, r := range results {
		if r.Target.Host == "8.8.8.8" && !r.Available {
			t.Errorf("Expected 8.8.8.8 to be available")
		}

		if r.Target.Host == "1.1.1.1" && r.Available {
			t.Errorf("Expected 1.1.1.1 to be unavailable")
		}
	}
}

func TestICMPSweeperSendPingFallback(t *testing.T) {
	mockConn := &mockICMPConn{}
	sweeper := &ICMPSweeper{
		rawSocketFD: 1,
		conn:        mockConn,
		results:     make(map[string]models.Result),
		logger:      logger.NewTestLogger(),
		rawSend: func(_ int, _ []byte, _ *syscall.SockaddrInet4) error {
			return syscall.EINVAL
		},
	}

	target := models.Target{Host: "10.42.111.75", Mode: models.ModeICMP}
	sweeper.sendPingToTarget(target, []byte{0x8, 0x0})

	if mockConn.writes != 1 {
		t.Fatalf("expected fallback to perform one write, got %d", mockConn.writes)
	}

	if mockConn.lastDest == nil || mockConn.lastDest.String() != target.Host {
		t.Fatalf("unexpected fallback destination: %#v", mockConn.lastDest)
	}

	if _, exists := sweeper.invalidDestinations[target.Host]; exists {
		t.Fatalf("did not expect host %s to be marked invalid", target.Host)
	}

	result, ok := sweeper.results[target.Host]
	if !ok {
		t.Fatalf("expected result for host %s", target.Host)
	}
	if result.Error != nil {
		t.Fatalf("expected nil error after successful fallback, got %v", result.Error)
	}
}

func TestICMPSweeperSendPingNoFallbackForOtherErrors(t *testing.T) {
	mockConn := &mockICMPConn{}
	sweeper := &ICMPSweeper{
		rawSocketFD: 1,
		conn:        mockConn,
		results:     make(map[string]models.Result),
		logger:      logger.NewTestLogger(),
		rawSend: func(_ int, _ []byte, _ *syscall.SockaddrInet4) error {
			return syscall.EPERM
		},
	}

	target := models.Target{Host: "10.42.111.75", Mode: models.ModeICMP}
	sweeper.sendPingToTarget(target, []byte{0x8, 0x0})

	if mockConn.writes != 0 {
		t.Fatalf("expected no fallback writes, got %d", mockConn.writes)
	}

	result, ok := sweeper.results[target.Host]
	if !ok {
		t.Fatalf("expected result for host %s", target.Host)
	}
	if !errors.Is(result.Error, syscall.EPERM) {
		t.Fatalf("expected EPERM error, got %v", result.Error)
	}

	if _, exists := sweeper.invalidDestinations[target.Host]; exists {
		t.Fatalf("did not expect host %s to be marked invalid", target.Host)
	}
}

func TestICMPSweeperMarksInvalidDestinations(t *testing.T) {
	mockConn := &mockICMPConn{
		writeErr: syscall.EINVAL,
	}

	sweeper := &ICMPSweeper{
		rawSocketFD: 1,
		conn:        mockConn,
		results:     make(map[string]models.Result),
		logger:      logger.NewTestLogger(),
		rawSend: func(_ int, _ []byte, _ *syscall.SockaddrInet4) error {
			return syscall.EINVAL
		},
		invalidDestinations: make(map[string]struct{}),
	}

	target := models.Target{Host: "10.42.111.80", Mode: models.ModeICMP}

	sweeper.sendPingToTarget(target, []byte{0x8, 0x0})

	if mockConn.writes != 1 {
		t.Fatalf("expected fallback attempt, got %d writes", mockConn.writes)
	}

	if _, exists := sweeper.invalidDestinations[target.Host]; !exists {
		t.Fatalf("expected host %s to be marked invalid", target.Host)
	}

	result, ok := sweeper.results[target.Host]
	if !ok {
		t.Fatalf("expected result for host %s", target.Host)
	}
	if !errors.Is(result.Error, errInvalidICMPDestination) {
		t.Fatalf("expected errInvalidICMPDestination, got %v", result.Error)
	}

	// Subsequent sends should be skipped without invoking fallback again.
	sweeper.sendPingToTarget(target, []byte{0x8, 0x0})
	if mockConn.writes != 1 {
		t.Fatalf("expected no additional writes after marking invalid, got %d", mockConn.writes)
	}
}

type mockICMPConn struct {
	writes   int
	lastDest net.Addr
	writeErr error
}

func (m *mockICMPConn) SetReadDeadline(time.Time) error {
	return nil
}

func (m *mockICMPConn) ReadFrom([]byte) (int, net.Addr, error) {
	return 0, nil, nil
}

func (m *mockICMPConn) WriteTo(b []byte, addr net.Addr) (int, error) {
	m.writes++
	m.lastDest = addr
	if m.writeErr != nil {
		return 0, m.writeErr
	}

	return len(b), nil
}

func (m *mockICMPConn) Close() error {
	return nil
}
