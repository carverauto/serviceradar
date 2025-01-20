package scan

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

type CombinedScanner struct {
	tcpScanner  Scanner
	icmpScanner Scanner
	done        chan struct{}
}

// NewCombinedScanner creates a new CombinedScanner instance
func NewCombinedScanner(timeout time.Duration, concurrency, icmpCount int) *CombinedScanner {
	return &CombinedScanner{
		tcpScanner:  NewTCPScanner(timeout, concurrency),
		icmpScanner: NewICMPScanner(timeout, concurrency, icmpCount),
		done:        make(chan struct{}),
	}
}

func (s *CombinedScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	if len(targets) == 0 {
		empty := make(chan models.Result)
		close(empty)
		return empty, nil
	}

	separated := s.separateTargets(targets)
	results := make(chan models.Result)

	// If we have only one type of target, handle it directly
	if len(separated.tcp) > 0 && len(separated.icmp) == 0 {
		tcpResults, err := s.tcpScanner.Scan(ctx, separated.tcp)
		if err != nil {
			return nil, fmt.Errorf("TCP scan error: %w", err)
		}
		return tcpResults, nil
	}

	if len(separated.icmp) > 0 && len(separated.tcp) == 0 {
		icmpResults, err := s.icmpScanner.Scan(ctx, separated.icmp)
		if err != nil {
			return nil, fmt.Errorf("ICMP scan error: %w", err)
		}
		return icmpResults, nil
	}

	// For mixed scans, use goroutines
	var wg sync.WaitGroup
	errChan := make(chan error, 2)

	// Start TCP scanner
	var tcpResults <-chan models.Result
	if len(separated.tcp) > 0 {
		var err error
		tcpResults, err = s.tcpScanner.Scan(ctx, separated.tcp)
		if err != nil {
			return nil, fmt.Errorf("TCP scan error: %w", err)
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.forwardResults(ctx, tcpResults, results)
		}()
	}

	// Start ICMP scanner
	var icmpResults <-chan models.Result
	if len(separated.icmp) > 0 {
		var err error
		icmpResults, err = s.icmpScanner.Scan(ctx, separated.icmp)
		if err != nil {
			return nil, fmt.Errorf("ICMP scan error: %w", err)
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.forwardResults(ctx, icmpResults, results)
		}()
	}

	// Close results when both scanners are done
	go func() {
		wg.Wait()
		close(results)
		close(errChan)
	}()

	return results, nil
}

func (*CombinedScanner) separateTargets(targets []models.Target) scanTargets {
	var separated scanTargets

	for _, target := range targets {
		switch target.Mode {
		case models.ModeTCP:
			separated.tcp = append(separated.tcp, target)
		case models.ModeICMP:
			separated.icmp = append(separated.icmp, target)
		default:
			log.Printf("Unknown scan mode for target %v: %v", target, target.Mode)
		}
	}

	return separated
}

func (s *CombinedScanner) forwardResults(ctx context.Context, in <-chan models.Result, out chan<- models.Result) {
	for {
		select {
		case r, ok := <-in:
			if !ok {
				return
			}
			select {
			case out <- r:
			case <-ctx.Done():
				return
			case <-s.done:
				return
			}
		case <-ctx.Done():
			return
		case <-s.done:
			return
		}
	}
}

func (s *CombinedScanner) Stop() error {
	close(s.done)
	_ = s.tcpScanner.Stop()
	_ = s.icmpScanner.Stop()
	return nil
}

type scanTargets struct {
	tcp  []models.Target
	icmp []models.Target
}
