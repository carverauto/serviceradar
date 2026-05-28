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
	"errors"
	"log"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

func TestNewTCPSweeper(t *testing.T) {
	tests := []struct {
		name        string
		timeout     time.Duration
		concurrency int
		wantTimeout time.Duration
		wantConc    int
	}{
		{
			name:        "default values",
			timeout:     0,
			concurrency: 0,
			wantTimeout: 5 * time.Second,
			wantConc:    500,
		},
		{
			name:        "custom values",
			timeout:     2 * time.Second,
			concurrency: 10,
			wantTimeout: 2 * time.Second,
			wantConc:    10,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := NewTCPSweeper(tt.timeout, tt.concurrency, logger.NewTestLogger())

			if s.timeout != tt.wantTimeout {
				t.Errorf("timeout = %v, want %v", s.timeout, tt.wantTimeout)
			}

			if s.concurrency != tt.wantConc {
				t.Errorf("concurrency = %v, want %v", s.concurrency, tt.wantConc)
			}
		})
	}
}

func TestTCPSweeper_Scan(t *testing.T) {
	s := NewTCPSweeper(1*time.Second, 2, logger.NewTestLogger())

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	targets := []models.Target{
		{Host: "localhost", Port: 8080, Mode: models.ModeTCP},
		{Host: "localhost", Port: 9999, Mode: models.ModeTCP},
		{Host: "localhost", Port: 80, Mode: models.ModeICMP}, // Should be filtered out
	}

	resultCh, err := s.Scan(ctx, targets)
	if err != nil {
		t.Fatalf("Scan() error = %v", err)
	}

	results := make([]models.Result, 0, len(targets))
	for r := range resultCh {
		results = append(results, r)
	}

	// Expect only TCP targets (2 out of 3)
	if len(results) != 2 {
		t.Errorf("Expected 2 results, got %d", len(results))
	}

	for _, r := range results {
		if r.Target.Mode != models.ModeTCP {
			t.Errorf("Expected only TCP targets, got %v", r.Target.Mode)
		}
	}
}

func TestTCPSweeper_checkPort(t *testing.T) {
	s := NewTCPSweeper(1*time.Second, 2, logger.NewTestLogger())
	ctx := context.Background()

	tests := []struct {
		name      string
		host      string
		port      int
		wantAvail bool
		wantErr   bool
	}{
		{
			name:      "unreachable port",
			host:      "localhost",
			port:      9999, // Assuming 9999 is unused
			wantAvail: false,
			wantErr:   true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			avail, rtt, err := s.checkPort(ctx, tt.host, tt.port)
			if avail != tt.wantAvail {
				t.Errorf("checkPort() avail = %v, want %v", avail, tt.wantAvail)
			}

			if (err != nil) != tt.wantErr {
				t.Errorf("checkPort() err = %v, wantErr %v", err, tt.wantErr)
			}

			if tt.wantAvail && rtt < 0 {
				t.Errorf("Expected non-negative RTT for available port, got %v", rtt)
			}
		})
	}
}

func TestTCPSweeperCapabilities(t *testing.T) {
	t.Parallel()

	caps := (&TCPSweeper{}).Capabilities()
	if !caps.TCPConnectIPv4 || !caps.TCPConnectIPv6 {
		t.Fatalf("expected TCP connect IPv4 and IPv6 capabilities, got %#v", caps)
	}
	if caps.RawSYNIPv4 || caps.RawSYNIPv6 {
		t.Fatalf("TCP connect scanner should not advertise raw SYN capabilities: %#v", caps)
	}
}

func TestTCPSweeper_worker(t *testing.T) {
	s := NewTCPSweeper(1*time.Second, 2, logger.NewTestLogger())

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	workCh := make(chan models.Target, 1)
	resultCh := make(chan models.Result, 1)

	target := models.Target{Host: "localhost", Port: 9999, Mode: models.ModeTCP}
	workCh <- target

	close(workCh)

	var wg sync.WaitGroup

	wg.Add(1)

	go func() {
		defer wg.Done()

		s.worker(ctx, workCh, resultCh)
	}()

	wg.Wait()
	close(resultCh)
	result := <-resultCh

	// Compare fields explicitly since != isn't defined for structs
	if result.Target.Host != target.Host || result.Target.Port != target.Port || result.Target.Mode != target.Mode {
		t.Errorf("worker processed wrong target: got %+v, want %+v", result.Target, target)
	}

	if result.Available {
		t.Errorf("Expected unavailable result for port 9999 in test env")
	}

	if result.Error == nil {
		t.Errorf("Expected an error for unreachable port")
	}
}

func TestTCPSweeper_Stop(t *testing.T) {
	s := NewTCPSweeper(1*time.Second, 2, logger.NewTestLogger())
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel

	err := s.Stop()
	if err != nil {
		t.Errorf("Stop() error = %v", err)
	}

	// Verify context was canceled
	select {
	case <-ctx.Done():
		// Expected
	default:
		t.Errorf("Context not canceled after Stop()")
	}
}

func TestFilterTCPTargets(t *testing.T) {
	targets := []models.Target{
		{Host: "1.1.1.1", Port: 80, Mode: models.ModeTCP},
		{Host: "2.2.2.2", Port: 22, Mode: models.ModeTCP},
		{Host: "2001:db8::1", Port: 443, Mode: models.ModeTCPConnect},
		{Host: "3.3.3.3", Mode: models.ModeICMP},
	}

	filtered := filterTCPTargets(targets)
	if len(filtered) != 3 {
		t.Errorf("filterTCPTargets() len = %d, want 3", len(filtered))
	}

	for _, target := range filtered { // Renamed loop variable to avoid shadowing 't'
		if target.Mode != models.ModeTCP && target.Mode != models.ModeTCPConnect {
			t.Errorf("Expected only TCP/TCP connect targets, got %v", target.Mode)
		}
	}
}

func TestTCPSweeperScanStreamProcessesTCPConnectTargets(t *testing.T) {
	const (
		concurrency = int64(8)
		targetCount = 100
	)

	s := NewTCPSweeper(1*time.Second, int(concurrency), logger.NewTestLogger())
	releaseDialers := make(chan struct{})

	var activeDials int64
	var maxActiveDials int64
	var dialCount int64

	s.dialContext = func(ctx context.Context, _, _ string) (net.Conn, error) {
		current := atomic.AddInt64(&activeDials, 1)
		recordMaxInt64(&maxActiveDials, current)
		atomic.AddInt64(&dialCount, 1)

		select {
		case <-releaseDialers:
		case <-ctx.Done():
			atomic.AddInt64(&activeDials, -1)

			return nil, ctx.Err()
		}

		atomic.AddInt64(&activeDials, -1)

		return &mockConn{}, nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	targets := make(chan models.Target, concurrency*2)
	results, errs, err := s.ScanStream(ctx, targets, StreamOptions{})
	if err != nil {
		t.Fatalf("ScanStream() error = %v", err)
	}

	go func() {
		defer close(targets)

		for i := 0; i < targetCount; i++ {
			targets <- models.Target{
				Host: "192.0.2.10",
				Port: 10000 + i,
				Mode: models.ModeTCPConnect,
			}
		}

		targets <- models.Target{Host: "192.0.2.10", Mode: models.ModeICMP}
	}()

	waitForActiveDialers(t, &maxActiveDials, concurrency)
	close(releaseDialers)

	var resultCount int
	for result := range results {
		resultCount++

		if result.Target.Mode != models.ModeTCPConnect {
			t.Fatalf("unexpected streamed target mode: %v", result.Target.Mode)
		}
	}

	for err := range errs {
		if err != nil {
			t.Fatalf("ScanStream() async error = %v", err)
		}
	}

	if resultCount != targetCount {
		t.Fatalf("ScanStream() emitted %d results, want %d", resultCount, targetCount)
	}

	if got := atomic.LoadInt64(&dialCount); got != targetCount {
		t.Fatalf("dial count = %d, want %d", got, targetCount)
	}

	if got := atomic.LoadInt64(&maxActiveDials); got > concurrency {
		t.Fatalf("max active dials = %d, want <= %d", got, concurrency)
	}

	stats := s.GetStats()
	if stats.DialsStarted != targetCount {
		t.Fatalf("DialsStarted = %d, want %d", stats.DialsStarted, targetCount)
	}

	if stats.DialsSucceeded != targetCount {
		t.Fatalf("DialsSucceeded = %d, want %d", stats.DialsSucceeded, targetCount)
	}

	if stats.MaxActiveDials > uint64(concurrency) {
		t.Fatalf("MaxActiveDials = %d, want <= %d", stats.MaxActiveDials, concurrency)
	}

	if stats.ActiveDials != 0 {
		t.Fatalf("ActiveDials = %d, want 0 after scan", stats.ActiveDials)
	}
}

var (
	errTooManyOpenFiles      = errors.New("dial tcp: socket: too many open files")
	errCannotAssignRequested = errors.New("dial tcp: connect: cannot assign requested address")
)

func TestTCPSweeperStatsClassifiesDialOutcomes(t *testing.T) {
	tests := []struct {
		name              string
		err               error
		wantTimeouts      uint64
		wantResets        uint64
		wantResourceError uint64
	}{
		{
			name:         "timeout",
			err:          context.DeadlineExceeded,
			wantTimeouts: 1,
		},
		{
			name:       "refused",
			err:        errConnectionRefused,
			wantResets: 1,
		},
		{
			name:              "fd pressure",
			err:               errTooManyOpenFiles,
			wantResourceError: 1,
		},
		{
			name:              "ephemeral port pressure",
			err:               errCannotAssignRequested,
			wantResourceError: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := NewTCPSweeper(1*time.Second, 1, logger.NewTestLogger())
			s.dialContext = func(context.Context, string, string) (net.Conn, error) {
				return nil, tt.err
			}

			_, _, _ = s.checkPort(context.Background(), "192.0.2.10", 22)

			stats := s.GetStats()
			if stats.DialsStarted != 1 {
				t.Fatalf("DialsStarted = %d, want 1", stats.DialsStarted)
			}

			if stats.DialsSucceeded != 0 {
				t.Fatalf("DialsSucceeded = %d, want 0", stats.DialsSucceeded)
			}

			if stats.DialTimeouts != tt.wantTimeouts {
				t.Fatalf("DialTimeouts = %d, want %d", stats.DialTimeouts, tt.wantTimeouts)
			}

			if stats.DialResets != tt.wantResets {
				t.Fatalf("DialResets = %d, want %d", stats.DialResets, tt.wantResets)
			}

			if stats.DialResourceErrors != tt.wantResourceError {
				t.Fatalf("DialResourceErrors = %d, want %d", stats.DialResourceErrors, tt.wantResourceError)
			}

			if stats.ActiveDials != 0 {
				t.Fatalf("ActiveDials = %d, want 0 after failed dial", stats.ActiveDials)
			}
		})
	}
}

// MockDialerFunc is a type for mocking net.DialTimeout.
type MockDialerFunc func(network, address string, timeout time.Duration) (net.Conn, error)

type mockConn struct{}

func (*mockConn) Close() error                     { return nil }
func (*mockConn) Read([]byte) (n int, err error)   { return 0, nil }
func (*mockConn) Write([]byte) (n int, err error)  { return 0, nil }
func (*mockConn) LocalAddr() net.Addr              { return nil }
func (*mockConn) RemoteAddr() net.Addr             { return nil }
func (*mockConn) SetDeadline(time.Time) error      { return nil }
func (*mockConn) SetReadDeadline(time.Time) error  { return nil }
func (*mockConn) SetWriteDeadline(time.Time) error { return nil }

func TestTCPSweeper_checkPort_Mocked(t *testing.T) {
	s := NewTCPSweeper(1*time.Second, 2, logger.NewTestLogger())
	ctx := context.Background()

	tests := []struct {
		name      string
		dialer    MockDialerFunc
		wantAvail bool
		wantErr   bool
	}{
		{
			name: "successful connection",
			dialer: func(_, _ string, _ time.Duration) (net.Conn, error) {
				return &mockConn{}, nil
			},
			wantAvail: true,
			wantErr:   false,
		},
		{
			name: "connection refused",
			dialer: func(_, _ string, _ time.Duration) (net.Conn, error) {
				return nil, errConnectionRefused
			},
			wantAvail: false,
			wantErr:   true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Instead of overriding net.DialTimeout, we'll call a modified checkPort with the mock dialer
			avail, rtt, err := s.checkPortWithDialer(ctx, t, "localhost", 8080, tt.dialer)
			if avail != tt.wantAvail {
				t.Errorf("checkPortWithDialer() avail = %v, want %v", avail, tt.wantAvail)
			}

			if (err != nil) != tt.wantErr {
				t.Errorf("checkPortWithDialer() err = %v, wantErr %v", err, tt.wantErr)
			}

			if tt.wantAvail && rtt < 0 {
				t.Errorf("Expected non-negative RTT for available port, got %v", rtt)
			}
		})
	}
}

// checkPortWithDialer is a test helper that allows injecting a dialer.
func (s *TCPSweeper) checkPortWithDialer(
	ctx context.Context,
	t *testing.T,
	host string,
	port int,
	dialer MockDialerFunc) (bool, time.Duration, error) {
	t.Helper()

	_, cancel := context.WithTimeout(ctx, s.timeout)
	defer cancel()

	start := time.Now()

	conn, err := dialer("tcp", host+":"+string(rune(port)), s.timeout)
	if err != nil {
		return false, 0, err
	}

	defer func(conn net.Conn) {
		err := conn.Close()
		if err != nil {
			log.Printf("failed to close connection: %v", err)
			t.Errorf("failed to close connection: %v", err)
		}
	}(conn)

	return true, time.Since(start), nil
}

func recordMaxInt64(max *int64, candidate int64) {
	for {
		current := atomic.LoadInt64(max)
		if candidate <= current {
			return
		}

		if atomic.CompareAndSwapInt64(max, current, candidate) {
			return
		}
	}
}

func waitForActiveDialers(t *testing.T, maxActive *int64, want int64) {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt64(maxActive) >= want {
			return
		}

		time.Sleep(time.Millisecond)
	}

	t.Fatalf("timed out waiting for %d active dialers; saw %d", want, atomic.LoadInt64(maxActive))
}
