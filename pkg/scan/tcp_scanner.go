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

	"github.com/carverauto/serviceradar/pkg/models"
)

// TCPScanner implements a network scanner for TCP ports
type TCPScanner struct {
	timeout     time.Duration
	concurrency int
	cancel      context.CancelFunc
	cancelMu    sync.Mutex
}

// NewTCPScanner creates a new TCP port scanner
func NewTCPScanner(timeout time.Duration, concurrency int) Scanner {
	// Set default values if not provided
	if timeout == 0 {
		timeout = 5 * time.Second
	}
	if concurrency == 0 {
		concurrency = 20
	}

	return &TCPScanner{
		timeout:     timeout,
		concurrency: concurrency,
	}
}

// Scan performs a TCP scan on the provided targets
func (s *TCPScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	// Filter to keep only TCP targets
	tcpTargets := make([]models.Target, 0, len(targets))
	for _, target := range targets {
		if target.Mode == models.ModeTCP {
			tcpTargets = append(tcpTargets, target)
		}
	}

	if len(tcpTargets) == 0 {
		// No TCP targets to scan, return empty channel
		resultCh := make(chan models.Result)
		close(resultCh)
		return resultCh, nil
	}

	// Create a new cancellable context
	scanCtx, cancel := context.WithCancel(ctx)

	s.cancelMu.Lock()
	s.cancel = cancel
	s.cancelMu.Unlock()

	// Create buffered result channel
	resultCh := make(chan models.Result, 1000)

	// Create buffered work channel to distribute tasks to workers
	workCh := make(chan models.Target, s.concurrency*2)

	// Start worker pool
	var wg sync.WaitGroup
	for i := 0; i < s.concurrency; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			s.worker(scanCtx, workCh, resultCh)
		}(i)
	}

	// Send targets to work channel
	go func() {
		defer close(workCh)
		for _, target := range tcpTargets {
			select {
			case <-scanCtx.Done():
				return
			case workCh <- target:
				// Target sent to worker
			}
		}
	}()

	// Close result channel when all workers are done
	go func() {
		wg.Wait()
		close(resultCh)
	}()

	return resultCh, nil
}

// worker processes TCP scanning tasks
func (s *TCPScanner) worker(ctx context.Context, workCh <-chan models.Target, resultCh chan<- models.Result) {
	for {
		select {
		case <-ctx.Done():
			return
		case target, ok := <-workCh:
			if !ok {
				// Work channel closed
				return
			}

			// Create result object
			result := models.Result{
				Target:    target,
				Available: false,
				FirstSeen: time.Now(),
				LastSeen:  time.Now(),
			}

			// Check if TCP port is open
			available, respTime, err := s.checkPort(ctx, target.Host, target.Port)

			// Update result
			result.Available = available
			result.RespTime = respTime
			if err != nil {
				result.Error = err
			}

			// Send result
			select {
			case <-ctx.Done():
				return
			case resultCh <- result:
				// Result sent successfully
			}
		}
	}
}

// checkPort attempts to connect to a TCP port
func (s *TCPScanner) checkPort(ctx context.Context, host string, port int) (bool, time.Duration, error) {
	// Create context with timeout
	dialCtx, cancel := context.WithTimeout(ctx, s.timeout)
	defer cancel()

	// Format address
	address := fmt.Sprintf("%s:%d", host, port)

	// Record start time for response time measurement
	start := time.Now()

	// Create dialer
	var dialer net.Dialer

	// Attempt to connect
	conn, err := dialer.DialContext(dialCtx, "tcp", address)
	if err != nil {
		return false, 0, err
	}

	// Successfully connected, close the connection
	defer conn.Close()

	// Calculate response time
	respTime := time.Since(start)

	return true, respTime, nil
}

// Stop terminates the scanner
func (s *TCPScanner) Stop(ctx context.Context) error {
	s.cancelMu.Lock()
	defer s.cancelMu.Unlock()

	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}

	return nil
}
