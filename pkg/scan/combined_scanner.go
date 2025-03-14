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
	"log"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// CombinedScanner implements a scanner that can handle both TCP and ICMP scanning
type CombinedScanner struct {
	tcpScanner  Scanner
	icmpScanner Scanner
	timeout     time.Duration
	concurrency int
	icmpCount   int
	maxIdle     int
	maxLifetime time.Duration
	idleTimeout time.Duration
	mu          sync.Mutex
}

// NewCombinedScanner creates a combined scanner that can handle both TCP and ICMP protocols
func NewCombinedScanner(
	timeout time.Duration,
	concurrency int,
	icmpCount int,
	maxIdle int,
	maxLifetime time.Duration,
	idleTimeout time.Duration,
) *CombinedScanner {
	// Create the TCP scanner
	tcpScanner := NewTCPScanner(timeout, concurrency)

	// Create the ICMP scanner
	icmpScanner := NewICMPScanner(timeout, icmpCount)

	return &CombinedScanner{
		tcpScanner:  tcpScanner,
		icmpScanner: icmpScanner,
		timeout:     timeout,
		concurrency: concurrency,
		icmpCount:   icmpCount,
		maxIdle:     maxIdle,
		maxLifetime: maxLifetime,
		idleTimeout: idleTimeout,
	}
}

// Scan performs scanning for all provided targets
func (s *CombinedScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	// Create a combined result channel with buffering
	resultCh := make(chan models.Result, 1000)

	// Split targets by protocol
	var icmpTargets, tcpTargets []models.Target

	for _, target := range targets {
		switch target.Mode {
		case models.ModeICMP:
			icmpTargets = append(icmpTargets, target)
		case models.ModeTCP:
			tcpTargets = append(tcpTargets, target)
		default:
			log.Printf("Warning: Unknown target mode: %s", target.Mode)
		}
	}

	log.Printf("Processing targets - TCP: %d, ICMP: %d", len(tcpTargets), len(icmpTargets))

	// Create wait group to track scan completion
	var wg sync.WaitGroup

	// Launch TCP scan if we have TCP targets
	if len(tcpTargets) > 0 {
		wg.Add(1)
		go func() {
			defer wg.Done()

			// Start TCP scan
			tcpResults, err := s.tcpScanner.Scan(ctx, tcpTargets)
			if err != nil {
				log.Printf("Error starting TCP scan: %v", err)
				return
			}

			// Forward results to the combined channel
			for result := range tcpResults {
				select {
				case <-ctx.Done():
					return
				case resultCh <- result:
					// Successfully forwarded the result
				}
			}
		}()
	}

	// Launch ICMP scan if we have ICMP targets
	if len(icmpTargets) > 0 {
		wg.Add(1)
		go func() {
			defer wg.Done()

			// Start ICMP scan
			icmpResults, err := s.icmpScanner.Scan(ctx, icmpTargets)
			if err != nil {
				log.Printf("Error starting ICMP scan: %v", err)
				return
			}

			// Forward results to the combined channel
			for result := range icmpResults {
				select {
				case <-ctx.Done():
					return
				case resultCh <- result:
					// Successfully forwarded the result
				}
			}
		}()
	}

	// Close the result channel when all scans are complete
	go func() {
		wg.Wait()
		close(resultCh)
		log.Printf("All scans completed")
	}()

	return resultCh, nil
}

// Stop terminates all scanners
func (s *CombinedScanner) Stop(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	var errors []error

	// Stop TCP scanner
	if err := s.tcpScanner.Stop(ctx); err != nil {
		errors = append(errors, fmt.Errorf("error stopping TCP scanner: %w", err))
	}

	// Stop ICMP scanner
	if err := s.icmpScanner.Stop(ctx); err != nil {
		errors = append(errors, fmt.Errorf("error stopping ICMP scanner: %w", err))
	}

	// Return error if any occurred
	if len(errors) > 0 {
		return fmt.Errorf("errors stopping scanners: %v", errors)
	}

	return nil
}
