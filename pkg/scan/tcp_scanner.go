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
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

type TCPSweeper struct {
	timeout     time.Duration
	concurrency int
	cancel      context.CancelFunc
	logger      logger.Logger
}

var _ Scanner = (*TCPSweeper)(nil)

func NewTCPSweeper(timeout time.Duration, concurrency int, log logger.Logger) *TCPSweeper {
	if timeout == 0 {
		timeout = 5 * time.Second
	}

	if concurrency == 0 {
		// Increased default for large-scale scanning
		concurrency = 500
	}

	return &TCPSweeper{
		timeout:     timeout,
		concurrency: concurrency,
		logger:      log,
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

func (s *TCPSweeper) worker(ctx context.Context, workCh <-chan models.Target, resultCh chan<- models.Result) {
	for t := range workCh {
		result := models.Result{
			Target:    t,
			FirstSeen: time.Now(),
			LastSeen:  time.Now(),
		}

		avail, rtt, err := s.checkPort(ctx, t.Host, t.Port)
		result.Available = avail
		result.RespTime = rtt

		if err != nil {
			result.Error = err
		}

		select {
		case <-ctx.Done():
			return
		case resultCh <- result:
		}
	}
}

func (s *TCPSweeper) checkPort(ctx context.Context, host string, port int) (bool, time.Duration, error) {
	// Create per-probe timeout context that respects both parent context and timeout
	probeCtx, cancel := context.WithTimeout(ctx, s.timeout)
	defer cancel()

	start := time.Now()

	// Use context-aware Dial instead of DialTimeout
	var dialer net.Dialer

	conn, err := dialer.DialContext(probeCtx, "tcp", fmt.Sprintf("%s:%d", host, port))
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

func (s *TCPSweeper) Stop() error {
	if s.cancel != nil {
		s.cancel()
	}

	return nil
}

func filterTCPTargets(targets []models.Target) []models.Target {
	var filtered []models.Target

	for _, t := range targets {
		if t.Mode == models.ModeTCP {
			filtered = append(filtered, t)
		}
	}

	return filtered
}
