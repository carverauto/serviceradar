/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 */

package banner_grab

import (
	"context"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

func TestProbeHTTPWritesHeadAndCapturesResponse(t *testing.T) {
	t.Parallel()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
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
	if stats.ObservationsTotal != 1 {
		t.Fatalf("ObservationsTotal = %d, want 1", stats.ObservationsTotal)
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
