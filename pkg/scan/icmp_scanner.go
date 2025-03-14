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
	"os"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
)

// ICMPScanner implements a scanner for ICMP echo requests
type ICMPScanner struct {
	timeout     time.Duration
	count       int
	concurrency int
	cancel      context.CancelFunc
	cancelMu    sync.Mutex
}

// NewICMPScanner creates a new ICMP scanner
func NewICMPScanner(timeout time.Duration, count int) Scanner {
	// Set default values if not provided
	if timeout == 0 {
		timeout = 5 * time.Second
	}
	if count == 0 {
		count = 1
	}

	return &ICMPScanner{
		timeout:     timeout,
		count:       count,
		concurrency: 20, // Default concurrency
	}
}

// Scan performs an ICMP scan on the provided targets
func (s *ICMPScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	// Filter to keep only ICMP targets
	icmpTargets := make([]models.Target, 0, len(targets))
	for _, target := range targets {
		if target.Mode == models.ModeICMP {
			icmpTargets = append(icmpTargets, target)
		}
	}

	if len(icmpTargets) == 0 {
		// No ICMP targets to scan, return empty channel
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

	// Create buffered work channel
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
		for _, target := range icmpTargets {
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

// worker processes ICMP scanning tasks
func (s *ICMPScanner) worker(ctx context.Context, workCh <-chan models.Target, resultCh chan<- models.Result) {
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

			// Ping the host
			available, respTime, packetLoss, err := s.pingHost(ctx, target.Host)

			// Update result
			result.Available = available
			result.RespTime = respTime
			result.PacketLoss = packetLoss
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

// pingHost sends ICMP echo requests to a host
func (s *ICMPScanner) pingHost(ctx context.Context, host string) (bool, time.Duration, float64, error) {
	// Resolve hostname to IP address
	ipAddr, err := net.ResolveIPAddr("ip4", host)
	if err != nil {
		return false, 0, 100.0, fmt.Errorf("failed to resolve host %s: %w", host, err)
	}

	// Create ICMP connection
	conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		return false, 0, 100.0, fmt.Errorf("failed to create ICMP connection: %w", err)
	}
	defer conn.Close()

	// Create message
	message := icmp.Message{
		Type: ipv4.ICMPTypeEcho,
		Code: 0,
		Body: &icmp.Echo{
			ID:   os.Getpid() & 0xffff,
			Seq:  1,
			Data: []byte("ServiceRadar ICMP probe"),
		},
	}

	// Marshal message
	binary, err := message.Marshal(nil)
	if err != nil {
		return false, 0, 100.0, fmt.Errorf("failed to marshal ICMP message: %w", err)
	}

	// Track successful pings and response times
	var successCount int
	var totalRTT time.Duration

	// Send multiple pings based on count configuration
	for i := 0; i < s.count; i++ {
		// Check if context is done
		select {
		case <-ctx.Done():
			return false, 0, 100.0, ctx.Err()
		default:
			// Continue
		}

		// Set read deadline
		err = conn.SetReadDeadline(time.Now().Add(s.timeout))
		if err != nil {
			return false, 0, 100.0, fmt.Errorf("failed to set read deadline: %w", err)
		}

		// Send ping
		start := time.Now()
		_, err = conn.WriteTo(binary, ipAddr)
		if err != nil {
			return false, 0, 100.0, fmt.Errorf("failed to send ICMP packet: %w", err)
		}

		// Receive reply
		reply := make([]byte, 1500)
		n, _, err := conn.ReadFrom(reply)
		if err != nil {
			// If timeout, continue to next ping
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				continue
			}
			return false, 0, 100.0, fmt.Errorf("failed to receive ICMP reply: %w", err)
		}

		// Calculate RTT
		rtt := time.Since(start)
		totalRTT += rtt

		// Parse reply
		parsedReply, err := icmp.ParseMessage(ipv4.ICMPTypeEcho.Protocol(), reply[:n])
		if err != nil {
			continue
		}

		// Check if it's an echo reply
		if parsedReply.Type == ipv4.ICMPTypeEchoReply {
			successCount++
		}
	}

	// Calculate results
	if successCount > 0 {
		packetLoss := 100.0 * float64(s.count-successCount) / float64(s.count)
		avgRTT := totalRTT / time.Duration(successCount)
		return true, avgRTT, packetLoss, nil
	}

	return false, 0, 100.0, nil
}

// Stop terminates the scanner
func (s *ICMPScanner) Stop(ctx context.Context) error {
	s.cancelMu.Lock()
	defer s.cancelMu.Unlock()

	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}

	return nil
}
