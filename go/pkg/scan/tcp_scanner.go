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
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

type TCPSweeper struct {
	timeout     time.Duration
	concurrency int
	cancel      context.CancelFunc
	logger      logger.Logger
	dialContext dialContextFunc
}

var _ Scanner = (*TCPSweeper)(nil)
var _ CapabilityProvider = (*TCPSweeper)(nil)
var _ StreamingScanner = (*TCPSweeper)(nil)

type dialContextFunc func(context.Context, string, string) (net.Conn, error)

func NewTCPSweeper(timeout time.Duration, concurrency int, log logger.Logger) *TCPSweeper {
	if timeout == 0 {
		timeout = 5 * time.Second
	}

	if concurrency == 0 {
		// Increased default for large-scale scanning
		concurrency = 500
	}

	dialer := &net.Dialer{}

	return &TCPSweeper{
		timeout:     timeout,
		concurrency: concurrency,
		logger:      log,
		dialContext: dialer.DialContext,
	}
}

func (*TCPSweeper) Capabilities() ScannerCapabilities {
	return ScannerCapabilities{
		TCPConnectIPv4: true,
		TCPConnectIPv6: true,
	}
}

const (
	defaultConcurrencyMultiplier = 2
)

func (s *TCPSweeper) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	tcpTargets := filterTCPTargets(targets)
	if len(tcpTargets) == 0 {
		ch := make(chan models.Result)
		close(ch)

		return ch, nil
	}

	scanCtx, cancel := context.WithCancel(ctx)
	s.cancel = cancel

	resultCh := make(chan models.Result, len(tcpTargets))
	workCh := make(chan models.Target, s.concurrency*defaultConcurrencyMultiplier)

	var wg sync.WaitGroup

	for i := 0; i < s.concurrency; i++ {
		wg.Add(1)

		go func() {
			defer wg.Done()

			s.worker(scanCtx, workCh, resultCh)
		}()
	}

	go func() {
		defer close(workCh)

		for _, t := range tcpTargets {
			select {
			case <-scanCtx.Done():
				return
			case workCh <- t:
			}
		}
	}()

	go func() {
		wg.Wait()

		close(resultCh)
	}()

	return resultCh, nil
}

// ScanStream consumes TCP targets incrementally without requiring callers to
// materialize the full target list. This is the path large sweeps and banner
// grab should prefer when full TCP connects are required.
func (s *TCPSweeper) ScanStream(
	ctx context.Context,
	targets <-chan models.Target,
	_ StreamOptions,
) (<-chan models.Result, <-chan error, error) {
	scanCtx, cancel := context.WithCancel(ctx)
	s.cancel = cancel

	resultBuffer := s.concurrency * defaultConcurrencyMultiplier
	if resultBuffer <= 0 {
		resultBuffer = 1
	}
	if resultBuffer > 10000 {
		resultBuffer = 10000
	}

	resultCh := make(chan models.Result, resultBuffer)
	errCh := make(chan error, 1)

	var wg sync.WaitGroup

	for i := 0; i < s.concurrency; i++ {
		wg.Add(1)

		go func() {
			defer wg.Done()

			s.streamWorker(scanCtx, targets, resultCh)
		}()
	}

	go func() {
		wg.Wait()
		close(resultCh)

		if err := scanCtx.Err(); err != nil && ctx.Err() != nil {
			errCh <- err
		}

		close(errCh)
	}()

	return resultCh, errCh, nil
}

func (s *TCPSweeper) worker(ctx context.Context, workCh <-chan models.Target, resultCh chan<- models.Result) {
	for t := range workCh {
		result := s.scanTarget(ctx, t)

		select {
		case <-ctx.Done():
			return
		case resultCh <- result:
		}
	}
}

func (s *TCPSweeper) streamWorker(ctx context.Context, targets <-chan models.Target, resultCh chan<- models.Result) {
	for {
		select {
		case <-ctx.Done():
			return
		case target, ok := <-targets:
			if !ok {
				return
			}

			if target.Mode != models.ModeTCP && target.Mode != models.ModeTCPConnect {
				continue
			}

			result := s.scanTarget(ctx, target)

			select {
			case <-ctx.Done():
				return
			case resultCh <- result:
			}
		}
	}
}

func (s *TCPSweeper) scanTarget(ctx context.Context, target models.Target) models.Result {
	now := time.Now()
	result := models.Result{
		Target:    target,
		FirstSeen: now,
		LastSeen:  now,
	}

	avail, rtt, err := s.checkPort(ctx, target.Host, target.Port)
	result.Available = avail
	result.RespTime = rtt

	if err != nil {
		result.Error = err
	}

	return result
}

func (s *TCPSweeper) checkPort(ctx context.Context, host string, port int) (bool, time.Duration, error) {
	// Create per-probe timeout context that respects both parent context and timeout
	probeCtx, cancel := context.WithTimeout(ctx, s.timeout)
	defer cancel()

	start := time.Now()

	conn, err := s.dial(probeCtx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		// Enhanced error handling with context awareness
		if probeCtx.Err() != nil {
			// Context error (timeout or cancellation)
			return false, time.Since(start), probeCtx.Err()
		}
		// Network error
		return false, time.Since(start), err
	}

	defer func(conn net.Conn) {
		err := conn.Close()
		if err != nil {
			s.logger.Error().Err(err).Msg("failed to close connection")
		}
	}(conn)

	return true, time.Since(start), nil
}

func (s *TCPSweeper) dial(ctx context.Context, network, address string) (net.Conn, error) {
	if s.dialContext != nil {
		return s.dialContext(ctx, network, address)
	}

	var dialer net.Dialer

	return dialer.DialContext(ctx, network, address)
}

func (s *TCPSweeper) Stop() error {
	if s.cancel != nil {
		s.cancel()
	}

	return nil
}

func filterTCPTargets(targets []models.Target) []models.Target {
	var filtered []models.Target

	for _, t := range targets {
		if t.Mode == models.ModeTCP || t.Mode == models.ModeTCPConnect {
			filtered = append(filtered, t)
		}
	}

	return filtered
}
