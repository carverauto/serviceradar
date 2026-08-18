/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 */

package banner_grab

import (
	"context"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

func TestProbeHTTPWritesHeadAndCapturesResponse(t *testing.T) {
	t.Parallel()

	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen() error = %v", err)
	}
	defer func() { _ = listener.Close() }()

	requests := make(chan string, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr != nil {
			return
		}
		defer func() { _ = conn.Close() }()

		buf := make([]byte, 256)
		n, _ := conn.Read(buf)
		requests <- string(buf[:n])
		_, _ = conn.Write([]byte("HTTP/1.1 200 OK\r\nServer: nginx\r\n\r\n"))
	}()

	host, port := splitListenerAddr(t, listener.Addr())
	observation, err := ProbeHTTP(context.Background(), host, port, ProbeOpts{
		ConnectTimeout: time.Second,
		ReadTimeout:    time.Second,
		MaxBannerBytes: 128,
	})
	if err != nil {
		t.Fatalf("ProbeHTTP() error = %v", err)
	}

	if got := <-requests; !strings.HasPrefix(got, "HEAD / HTTP/1.1\r\n") {
		t.Fatalf("HTTP request = %q, want HEAD request", got)
	}
	if !strings.Contains(string(observation.BannerBytes), "Server: nginx") {
		t.Fatalf("banner = %q, want nginx server header", string(observation.BannerBytes))
	}
	if observation.Protocol != ProtocolHTTP || observation.Source != SourceSweepActive {
		t.Fatalf("observation metadata = %#v", observation)
	}
}

func TestEngineFiltersFreshEligibleCandidatesAndStreamsObservations(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	engine := New(Config{
		Enabled:               true,
		Protocols:             []string{ProtocolHTTP},
		Ports:                 map[string][]int{ProtocolHTTP: {8080}},
		ConnectTimeout:        time.Second,
		ReadTimeout:           time.Second,
		MaxBannerBytes:        128,
		MaxGlobalConcurrency:  2,
		MaxCandidateQueue:     4,
		MinReprobeInterval:    time.Hour,
		PerHostRateLimit:      time.Millisecond,
		MaxConcurrencyPerHost: 1,
		DialContext:           fakeHTTPDialer("HTTP/1.1 200 OK\r\nServer: fixture\r\n\r\n"),
	})

	observations := engine.Start(ctx)
	result := models.Result{
		Target:    models.Target{Host: "192.0.2.10", Port: 8080, Mode: models.ModeTCP},
		Available: true,
	}

	if err := engine.SubmitResult(ctx, result); err != nil {
		t.Fatalf("SubmitResult() error = %v", err)
	}

	got := <-observations
	if got.Host != "192.0.2.10" || got.Port != 8080 || got.Protocol != ProtocolHTTP {
		t.Fatalf("observation = %#v", got)
	}
	if got.ObservationID == 0 {
		t.Fatalf("ObservationID = 0, want assigned id")
	}

	if err := engine.SubmitResult(ctx, result); err != nil {
		t.Fatalf("SubmitResult() second error = %v", err)
	}

	engine.Stop()
	for range observations {
	}

	stats := engine.Stats()
	if stats.CandidatesTotal != 1 {
		t.Fatalf("CandidatesTotal = %d, want 1 fresh-gated candidate", stats.CandidatesTotal)
	}
	if stats.SkippedFreshTotal != 1 {
		t.Fatalf("SkippedFreshTotal = %d, want 1", stats.SkippedFreshTotal)
	}
	if stats.ObservationsTotal != 1 {
		t.Fatalf("ObservationsTotal = %d, want 1", stats.ObservationsTotal)
	}
	if stats.BannerBytesTotal != uint64(len(got.BannerBytes)) {
		t.Fatalf("BannerBytesTotal = %d, want %d", stats.BannerBytesTotal, len(got.BannerBytes))
	}
	engine.RecordMatchBatch(128, 1)
	stats = engine.Stats()
	if stats.MatchBatchesTotal != 1 || stats.MatchBatchBytesTotal != 128 || stats.MatchesTotal != 1 {
		t.Fatalf(
			"match stats batches=%d bytes=%d matches=%d, want 1/128/1",
			stats.MatchBatchesTotal,
			stats.MatchBatchBytesTotal,
			stats.MatchesTotal,
		)
	}
}

func TestDisabledEngineProducesNoOutboundTraffic(t *testing.T) {
	t.Parallel()

	var dials atomic.Uint64
	engine := New(Config{
		Enabled:              false,
		Protocols:            []string{ProtocolSSH},
		Ports:                map[string][]int{ProtocolSSH: {22}},
		MaxGlobalConcurrency: 1,
		MaxCandidateQueue:    2,
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			dials.Add(1)
			return newScriptedConn([]byte("SSH-2.0-OpenSSH_9.6\r\n"), io.EOF, nil), nil
		},
	})

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	observations := engine.Start(ctx)
	if err := engine.SubmitResult(ctx, models.Result{
		Target:    models.Target{Host: "192.0.2.10", Port: 22, Mode: models.ModeTCP},
		Available: true,
	}); err != nil {
		t.Fatalf("SubmitResult() error = %v", err)
	}

	engine.Stop()
	for range observations {
	}

	stats := engine.Stats()
	if dials.Load() != 0 {
		t.Fatalf("dials = %d, want 0", dials.Load())
	}
	if stats.CandidatesTotal != 0 || stats.ProbesTotal != 0 || stats.ObservationsTotal != 0 {
		t.Fatalf(
			"stats candidates/probes/observations = %d/%d/%d, want 0/0/0",
			stats.CandidatesTotal,
			stats.ProbesTotal,
			stats.ObservationsTotal,
		)
	}
}

func TestSSHOnlyEngineProbesExactlyFreshLiveEndpoints(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	const expectedLiveSSH = 3

	var dials atomic.Uint64
	engine := New(Config{
		Enabled:               true,
		Protocols:             []string{ProtocolSSH},
		Ports:                 map[string][]int{ProtocolSSH: {22}},
		ConnectTimeout:        time.Second,
		ReadTimeout:           time.Second,
		MaxBannerBytes:        128,
		MaxGlobalConcurrency:  2,
		MaxCandidateQueue:     4,
		MaxConcurrencyPerHost: 1,
		PerHostRateLimit:      time.Nanosecond,
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			dials.Add(1)
			return newScriptedConn([]byte("SSH-2.0-OpenSSH_9.6\r\n"), io.EOF, nil), nil
		},
	})

	observations := engine.Start(ctx)
	liveHosts := map[int]bool{2: true, 3: true, 10: true}

	for hostID := 1; hostID <= 14; hostID++ {
		if err := engine.SubmitResult(ctx, models.Result{
			Target:    models.Target{Host: "192.0.2." + portString(hostID), Port: 22, Mode: models.ModeTCP},
			Available: liveHosts[hostID],
		}); err != nil {
			t.Fatalf("SubmitResult(%d) error = %v", hostID, err)
		}
	}

	engine.Stop()

	var gotObservations int
	for range observations {
		gotObservations++
	}

	stats := engine.Stats()
	if dials.Load() != expectedLiveSSH {
		t.Fatalf("dials = %d, want %d", dials.Load(), expectedLiveSSH)
	}
	if gotObservations != expectedLiveSSH {
		t.Fatalf("observations = %d, want %d", gotObservations, expectedLiveSSH)
	}
	if stats.CandidatesTotal != expectedLiveSSH || stats.ProbesTotal != expectedLiveSSH {
		t.Fatalf(
			"stats candidates/probes = %d/%d, want %d/%d",
			stats.CandidatesTotal,
			stats.ProbesTotal,
			expectedLiveSSH,
			expectedLiveSSH,
		)
	}
}

func TestEngineKeepsLargeSyntheticStreamBounded(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	const (
		totalEligible        = 10_000
		maxGlobalConcurrency = 8
		maxCandidateQueue    = 16
	)

	var (
		currentDials atomic.Uint64
		maxDials     atomic.Uint64
	)

	engine := New(Config{
		Enabled:               true,
		Protocols:             []string{ProtocolSSH},
		Ports:                 map[string][]int{ProtocolSSH: {22}},
		ConnectTimeout:        time.Second,
		ReadTimeout:           time.Second,
		MaxBannerBytes:        128,
		MaxGlobalConcurrency:  maxGlobalConcurrency,
		MaxCandidateQueue:     maxCandidateQueue,
		MaxConcurrencyPerHost: 1,
		MatchBatchSize:        512,
		PerHostRateLimit:      time.Nanosecond,
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			inFlight := currentDials.Add(1)
			recordMaxAtomic(&maxDials, inFlight)

			return newScriptedConn([]byte("SSH-2.0-OpenSSH_9.6\r\n"), io.EOF, func() {
				currentDials.Add(^uint64(0))
			}), nil
		},
	})

	observations := engine.Start(ctx)
	var gotObservations atomic.Uint64
	drained := make(chan struct{})

	go func() {
		defer close(drained)

		for range observations {
			gotObservations.Add(1)
		}
	}()

	for i := 0; i < totalEligible; i++ {
		if err := engine.SubmitResult(ctx, models.Result{
			Target:    models.Target{Host: "198.51." + portString(i/254) + "." + portString((i%254)+1), Port: 22, Mode: models.ModeTCP},
			Available: true,
		}); err != nil {
			t.Fatalf("SubmitResult(%d) error = %v", i, err)
		}
	}

	engine.Stop()
	<-drained

	stats := engine.Stats()
	if gotObservations.Load() != totalEligible {
		t.Fatalf("observations = %d, want %d", gotObservations.Load(), totalEligible)
	}
	if stats.CandidatesTotal != totalEligible || stats.ProbesTotal != totalEligible {
		t.Fatalf("stats candidates/probes = %d/%d, want %d/%d", stats.CandidatesTotal, stats.ProbesTotal, totalEligible, totalEligible)
	}
	if stats.MaxQueueDepth > maxCandidateQueue {
		t.Fatalf("MaxQueueDepth = %d, want <= %d", stats.MaxQueueDepth, maxCandidateQueue)
	}
	if maxDials.Load() > maxGlobalConcurrency {
		t.Fatalf("max concurrent dials = %d, want <= %d", maxDials.Load(), maxGlobalConcurrency)
	}
}

func TestEngineKeepsMillionHostSyntheticStreamBounded(t *testing.T) {
	// Bazel arms the env var on //go/pkg/scan/banner_grab:banner_grab_test, so this runs in the
	// ordinary unit sweep (2.45s on RBE). The var is kept rather than removed so a plain
	// `go test ./...` on a workstation still opts out of a 1M-iteration loop by default.
	if os.Getenv("SERVICERADAR_LARGE_BANNER_GRAB_TEST") != "1" {
		t.Skip("set SERVICERADAR_LARGE_BANNER_GRAB_TEST=1 to run the 1M-host banner-grab validation")
	}

	// The race sweep runs this package with -race, -test.count=5 and -test.short. Five
	// instrumented passes over a million submissions buys nothing the single unraced pass
	// above does not already assert, so opt out of the short mode explicitly.
	if testing.Short() {
		t.Skip("skipping the 1M-host banner-grab validation in short mode")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	const (
		totalHosts           = 1_000_000
		totalEligible        = totalHosts / 2
		maxGlobalConcurrency = 32
		maxCandidateQueue    = 128
	)

	var (
		currentDials atomic.Uint64
		maxDials     atomic.Uint64
	)

	engine := New(Config{
		Enabled:               true,
		Protocols:             []string{ProtocolSSH},
		Ports:                 map[string][]int{ProtocolSSH: {22}},
		ConnectTimeout:        time.Second,
		ReadTimeout:           time.Second,
		MaxBannerBytes:        128,
		MaxGlobalConcurrency:  maxGlobalConcurrency,
		MaxCandidateQueue:     maxCandidateQueue,
		MaxConcurrencyPerHost: 1,
		MatchBatchSize:        1024,
		PerHostRateLimit:      time.Nanosecond,
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			inFlight := currentDials.Add(1)
			recordMaxAtomic(&maxDials, inFlight)

			return newScriptedConn([]byte("SSH-2.0-OpenSSH_9.6\r\n"), io.EOF, func() {
				currentDials.Add(^uint64(0))
			}), nil
		},
	})

	observations := engine.Start(ctx)
	var gotObservations atomic.Uint64
	drained := make(chan struct{})

	go func() {
		defer close(drained)

		for range observations {
			gotObservations.Add(1)
		}
	}()

	for i := 0; i < totalHosts; i++ {
		if err := engine.SubmitResult(ctx, models.Result{
			Target: models.Target{
				Host: "10." + portString((i/(254*254))%254) + "." + portString((i/254)%254) + "." + portString((i%254)+1),
				Port: 22,
				Mode: models.ModeTCP,
			},
			Available: i%2 == 0,
		}); err != nil {
			t.Fatalf("SubmitResult(%d) error = %v", i, err)
		}
	}

	engine.Stop()
	<-drained

	stats := engine.Stats()
	if gotObservations.Load() != totalEligible {
		t.Fatalf("observations = %d, want %d", gotObservations.Load(), totalEligible)
	}
	if stats.CandidatesTotal != totalEligible || stats.ProbesTotal != totalEligible {
		t.Fatalf("stats candidates/probes = %d/%d, want %d/%d", stats.CandidatesTotal, stats.ProbesTotal, totalEligible, totalEligible)
	}
	if stats.MaxQueueDepth > maxCandidateQueue {
		t.Fatalf("MaxQueueDepth = %d, want <= %d", stats.MaxQueueDepth, maxCandidateQueue)
	}
	if maxDials.Load() > maxGlobalConcurrency {
		t.Fatalf("max concurrent dials = %d, want <= %d", maxDials.Load(), maxGlobalConcurrency)
	}
}

func TestHTTPDefaultsDoNotActivelyProbeTLSPort443(t *testing.T) {
	t.Parallel()

	var dials atomic.Uint64
	engine := New(Config{
		Enabled:              true,
		Protocols:            []string{ProtocolHTTP},
		MaxGlobalConcurrency: 1,
		MaxCandidateQueue:    2,
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			dials.Add(1)
			return newScriptedConn([]byte("HTTP/1.1 200 OK\r\n\r\n"), io.EOF, nil), nil
		},
	})

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	observations := engine.Start(ctx)
	if err := engine.SubmitResult(ctx, models.Result{
		Target:    models.Target{Host: "192.0.2.10", Port: 443, Mode: models.ModeTCP},
		Available: true,
	}); err != nil {
		t.Fatalf("SubmitResult() error = %v", err)
	}

	engine.Stop()
	for range observations {
	}

	stats := engine.Stats()
	if dials.Load() != 0 {
		t.Fatalf("dials = %d, want 0", dials.Load())
	}
	if stats.CandidatesTotal != 0 || stats.ProbesTotal != 0 {
		t.Fatalf("stats candidates/probes = %d/%d, want 0/0", stats.CandidatesTotal, stats.ProbesTotal)
	}
}

func TestEngineProbeCountersForTimeoutResetAndPartialBanner(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		conn        net.Conn
		wantTimeout uint64
		wantReset   uint64
		wantObs     uint64
		wantErrors  uint64
	}{
		{
			name:        "timeout",
			conn:        newScriptedConn(nil, timeoutError{}, nil),
			wantTimeout: 1,
		},
		{
			name:      "reset",
			conn:      newScriptedConn(nil, syscall.ECONNRESET, nil),
			wantReset: 1,
		},
		{
			name:    "partial banner",
			conn:    newScriptedConn([]byte("SSH-2.0-partial"), io.EOF, nil),
			wantObs: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			engine := New(Config{
				Enabled:               true,
				Protocols:             []string{ProtocolSSH},
				Ports:                 map[string][]int{ProtocolSSH: {22}},
				ConnectTimeout:        time.Second,
				ReadTimeout:           time.Second,
				MaxBannerBytes:        128,
				MaxGlobalConcurrency:  1,
				MaxCandidateQueue:     2,
				MaxConcurrencyPerHost: 1,
				PerHostRateLimit:      time.Nanosecond,
				DialContext: func(context.Context, string, string) (net.Conn, error) {
					return tt.conn, nil
				},
			})

			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()

			observations := engine.Start(ctx)
			if err := engine.SubmitResult(ctx, models.Result{
				Target:    models.Target{Host: "192.0.2.10", Port: 22, Mode: models.ModeTCP},
				Available: true,
			}); err != nil {
				t.Fatalf("SubmitResult() error = %v", err)
			}

			engine.Stop()
			for range observations {
			}

			stats := engine.Stats()
			if stats.TimeoutTotal != tt.wantTimeout ||
				stats.ConnectionResetTotal != tt.wantReset ||
				stats.ObservationsTotal != tt.wantObs ||
				stats.ErrorsTotal != tt.wantErrors {
				t.Fatalf(
					"stats timeout/reset/observations/errors = %d/%d/%d/%d, want %d/%d/%d/%d",
					stats.TimeoutTotal,
					stats.ConnectionResetTotal,
					stats.ObservationsTotal,
					stats.ErrorsTotal,
					tt.wantTimeout,
					tt.wantReset,
					tt.wantObs,
					tt.wantErrors,
				)
			}
		})
	}
}

func TestBatcherFlushesByBytesAndCount(t *testing.T) {
	t.Parallel()

	batcher := NewBatcher(2, 1024)
	first := BannerObservation{Host: "192.0.2.1", Protocol: ProtocolSSH, Source: SourceSweepActive, BannerBytes: []byte("SSH-2.0-a")}
	second := BannerObservation{Host: "192.0.2.2", Protocol: ProtocolSSH, Source: SourceSweepActive, BannerBytes: []byte("SSH-2.0-b")}

	if batch, ok := batcher.Add(first); ok || batch != nil {
		t.Fatalf("first Add flushed batch=%v ok=%v, want no flush", batch, ok)
	}

	batch, ok := batcher.Add(second)
	if !ok || len(batch) != 2 {
		t.Fatalf("second Add batch len=%d ok=%v, want count flush", len(batch), ok)
	}
}

type scriptedConn struct {
	readBytes []byte
	readErr   error
	onClose   func()
	closeOnce sync.Once
	readOnce  bool
}

func newScriptedConn(readBytes []byte, readErr error, onClose func()) *scriptedConn {
	return &scriptedConn{
		readBytes: append([]byte(nil), readBytes...),
		readErr:   readErr,
		onClose:   onClose,
	}
}

func (c *scriptedConn) Read(p []byte) (int, error) {
	if c.readOnce {
		if c.readErr != nil {
			return 0, c.readErr
		}

		return 0, io.EOF
	}

	c.readOnce = true
	n := copy(p, c.readBytes)

	if c.readErr != nil {
		return n, c.readErr
	}

	return n, nil
}

func (c *scriptedConn) Write(p []byte) (int, error) {
	return len(p), nil
}

func (c *scriptedConn) Close() error {
	c.closeOnce.Do(func() {
		if c.onClose != nil {
			c.onClose()
		}
	})

	return nil
}

func (c *scriptedConn) LocalAddr() net.Addr {
	return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 49152}
}

func (c *scriptedConn) RemoteAddr() net.Addr {
	return &net.TCPAddr{IP: net.IPv4(192, 0, 2, 10), Port: 22}
}

func (c *scriptedConn) SetDeadline(time.Time) error {
	return nil
}

func (c *scriptedConn) SetReadDeadline(time.Time) error {
	return nil
}

func (c *scriptedConn) SetWriteDeadline(time.Time) error {
	return nil
}

type timeoutError struct{}

func (timeoutError) Error() string {
	return "read timeout"
}

func (timeoutError) Timeout() bool {
	return true
}

func (timeoutError) Temporary() bool {
	return true
}

func recordMaxAtomic(max *atomic.Uint64, candidate uint64) {
	for {
		current := max.Load()
		if candidate <= current {
			return
		}

		if max.CompareAndSwap(current, candidate) {
			return
		}
	}
}

func fakeHTTPDialer(response string) DialContextFunc {
	return func(_ context.Context, _, _ string) (net.Conn, error) {
		client, server := net.Pipe()

		go func() {
			defer func() { _ = server.Close() }()
			buf := make([]byte, 1024)
			_, _ = server.Read(buf)
			_, _ = server.Write([]byte(response))
		}()

		return client, nil
	}
}

func splitListenerAddr(t *testing.T, addr net.Addr) (string, int) {
	t.Helper()

	tcpAddr, ok := addr.(*net.TCPAddr)
	if !ok {
		t.Fatalf("addr = %T, want *net.TCPAddr", addr)
	}

	return tcpAddr.IP.String(), tcpAddr.Port
}
