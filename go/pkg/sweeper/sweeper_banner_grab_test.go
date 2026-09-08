/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package sweeper

import (
	"context"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan/banner_grab"
	"go.uber.org/mock/gomock"
)

func TestProcessResultsStreamSubmitsBannerGrabCandidates(t *testing.T) {
	t.Parallel()

	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen() error = %v", err)
	}
	defer func() { _ = listener.Close() }()

	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr != nil {
			return
		}
		defer func() { _ = conn.Close() }()

		buf := make([]byte, 512)
		_, _ = conn.Read(buf)
		_, _ = conn.Write([]byte("HTTP/1.1 200 OK\r\nServer: fixture\r\n\r\n"))
	}()

	host, port := testTCPAddr(t, listener.Addr())
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockStore := NewMockStore(ctrl)
	mockProcessor := NewMockResultProcessor(ctrl)
	mockProcessor.EXPECT().Process(gomock.Any()).Return(nil)
	mockStore.EXPECT().SaveResult(gomock.Any(), gomock.Any()).Return(nil)

	var (
		mu           sync.Mutex
		observations []banner_grab.BannerObservation
	)

	sweeper := &NetworkSweeper{
		config: &models.Config{
			BannerGrab: models.BannerGrab{
				Enabled:                true,
				Protocols:              []string{banner_grab.ProtocolHTTP},
				Ports:                  map[string][]int{banner_grab.ProtocolHTTP: {port}},
				ConnectTimeoutMS:       1000,
				ReadTimeoutMS:          1000,
				MaxBannerBytes:         128,
				MaxGlobalConcurrency:   1,
				MaxConcurrencyPerHost:  1,
				MaxCandidateQueue:      4,
				MatchBatchSize:         2,
				MatchBatchMaxBytes:     4096,
				MinReprobeIntervalSec:  86400,
				PerHostRateLimitMillis: 1,
			},
		},
		store:     mockStore,
		processor: mockProcessor,
		logger:    logger.NewTestLogger(),
		bannerHandler: func(_ context.Context, _ models.BannerGrab, _ *banner_grab.Engine, stream <-chan banner_grab.BannerObservation) error {
			for observation := range stream {
				mu.Lock()
				observations = append(observations, observation)
				mu.Unlock()
			}

			return nil
		},
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	phase := sweeper.startBannerGrabPhase(ctx)
	results := make(chan models.Result, 1)
	results <- models.Result{
		Target:    models.Target{Host: host, Port: port, Mode: models.ModeTCP},
		Available: true,
	}
	close(results)

	if err := sweeper.processResultsStream(ctx, results, scannerProtocolTCP); err != nil {
		t.Fatalf("processResultsStream() error = %v", err)
	}
	if err := sweeper.finishBannerGrabPhase(phase); err != nil {
		t.Fatalf("finishBannerGrabPhase() error = %v", err)
	}

	mu.Lock()
	defer mu.Unlock()

	if len(observations) != 1 {
		t.Fatalf("observations len = %d, want 1", len(observations))
	}
	if got := string(observations[0].BannerBytes); got == "" {
		t.Fatalf("empty banner observation")
	}
	stats := sweeper.GetBannerGrabStats()
	if stats == nil {
		t.Fatalf("GetBannerGrabStats() = nil, want completed stats")
		return
	}
	if stats.CandidatesTotal != 1 || stats.ProbesTotal != 1 {
		t.Fatalf("banner stats candidates=%d probes=%d, want 1/1", stats.CandidatesTotal, stats.ProbesTotal)
	}
}

func testTCPAddr(t *testing.T, addr net.Addr) (string, int) {
	t.Helper()

	tcpAddr, ok := addr.(*net.TCPAddr)
	if !ok {
		t.Fatalf("addr = %T, want *net.TCPAddr", addr)
	}

	return tcpAddr.IP.String(), tcpAddr.Port
}
