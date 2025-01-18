// Package sweeper pkg/sweeper/combined_scanner.go

package sweeper

import (
	"context"
	"log"
	"sync"
	"time"
)

type CombinedScanner struct {
	tcpScanner  *TCPScanner
	icmpScanner *ICMPScanner
	done        chan struct{}
}

func NewCombinedScanner(timeout time.Duration, concurrency, icmpCount int) *CombinedScanner {
	return &CombinedScanner{
		tcpScanner:  NewTCPScanner(timeout, concurrency),
		icmpScanner: NewICMPScanner(timeout, concurrency, icmpCount),
		done:        make(chan struct{}),
	}
}

func (s *CombinedScanner) Stop() error {
	close(s.done)
	_ = s.tcpScanner.Stop()
	_ = s.icmpScanner.Stop()
	return nil
}

func (s *CombinedScanner) Scan(ctx context.Context, targets []Target) (<-chan Result, error) {
	results := make(chan Result)

	// Separate targets by mode
	var tcpTargets, icmpTargets []Target
	for _, target := range targets {
		switch target.Mode {
		case ModeTCP:
			tcpTargets = append(tcpTargets, target)
		case ModeICMP:
			icmpTargets = append(icmpTargets, target)
		default:
			log.Printf("Unknown scan mode for target %v: %v", target, target.Mode)
		}
	}

	var wg sync.WaitGroup

	// Start TCP scanner if we have TCP targets
	if len(tcpTargets) > 0 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			tcpResults, err := s.tcpScanner.Scan(ctx, tcpTargets)
			if err != nil {
				log.Printf("TCP scan error: %v", err)
				return
			}
			for result := range tcpResults {
				select {
				case <-ctx.Done():
					return
				case <-s.done:
					return
				case results <- result:
				}
			}
		}()
	}

	// Start ICMP scanner if we have ICMP targets
	if len(icmpTargets) > 0 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			icmpResults, err := s.icmpScanner.Scan(ctx, icmpTargets)
			if err != nil {
				log.Printf("ICMP scan error: %v", err)
				return
			}
			for result := range icmpResults {
				select {
				case <-ctx.Done():
					return
				case <-s.done:
					return
				case results <- result:
				}
			}
		}()
	}

	// Close results when all scans complete
	go func() {
		wg.Wait()
		close(results)
	}()

	return results, nil
}
