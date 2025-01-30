package scan

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

const (
	errorChannelSize = 2
	stopTimer        = 5 * time.Second
)

type CombinedScanner struct {
	tcpScanner  Scanner
	icmpScanner Scanner
	done        chan struct{}
}

func NewCombinedScanner(timeout time.Duration, concurrency, icmpCount int) *CombinedScanner {
	var icmpScanner Scanner

	if icmpCount > 0 {
		var err error

		icmpConcurrency := concurrency / 4

		if icmpConcurrency < 1 {
			icmpConcurrency = 1
		}

		icmpScanner, err = NewICMPScanner(timeout, icmpConcurrency, icmpCount)
		if err != nil {
			log.Printf("ICMP scanning not available: %v, falling back to TCP only", err)

			icmpScanner = nil // Explicitly set to nil to be clear
		}
	}

	return &CombinedScanner{
		tcpScanner:  NewTCPScanner(timeout, concurrency),
		icmpScanner: icmpScanner,
		done:        make(chan struct{}),
	}
}

func (s *CombinedScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	if len(targets) == 0 {
		empty := make(chan models.Result)
		close(empty)
		return empty, nil
	}

	// Deep copy targets to avoid concurrent modification issues
	targetsCopy := make([]models.Target, len(targets))
	copy(targetsCopy, targets)

	// Calculate total hosts based on the copy to avoid modifying the original targets
	uniqueHosts := make(map[string]struct{})
	for _, target := range targetsCopy {
		uniqueHosts[target.Host] = struct{}{}
	}
	totalHosts := len(uniqueHosts)

	// Separate targets based on the copy
	separated := s.separateTargets(targetsCopy)
	log.Printf("Scanning targets - TCP: %d, ICMP: %d, Unique Hosts: %d",
		len(separated.tcp), len(separated.icmp), totalHosts)

	// Add total hosts to metadata in a safe way
	for i := range separated.tcp {
		if separated.tcp[i].Metadata == nil {
			separated.tcp[i].Metadata = make(map[string]interface{})
		}
		separated.tcp[i].Metadata["total_hosts"] = totalHosts
	}
	for i := range separated.icmp {
		if separated.icmp[i].Metadata == nil {
			separated.icmp[i].Metadata = make(map[string]interface{})
		}
		separated.icmp[i].Metadata["total_hosts"] = totalHosts
	}

	// Handle single scanner cases
	if result := s.handleSingleScannerCase(ctx, separated); result != nil {
		return result.resultChan, result.err
	}

	// Handle mixed scanner case
	return s.handleMixedScanners(ctx, separated)
}

func (s *CombinedScanner) handleMixedScanners(ctx context.Context, targets scanTargets) (<-chan models.Result, error) {
	results := make(chan models.Result, len(targets.tcp)+len(targets.icmp))
	var wg sync.WaitGroup

	// Start TCP scanner if needed
	if len(targets.tcp) > 0 {
		wg.Add(1)
		go func(tcpTargets []models.Target) {
			defer wg.Done()
			tcpResults, err := s.tcpScanner.Scan(ctx, tcpTargets)
			if err != nil {
				log.Printf("TCP scan error: %v", err)
				return
			}
			s.forwardResults(ctx, tcpResults, results)
		}(targets.tcp)
	}

	// Start ICMP scanner if available and needed
	if s.icmpScanner != nil && len(targets.icmp) > 0 {
		wg.Add(1)
		go func(icmpTargets []models.Target) {
			defer wg.Done()
			icmpResults, err := s.icmpScanner.Scan(ctx, icmpTargets)
			if err != nil {
				log.Printf("ICMP scan error: %v", err)
				return
			}
			s.forwardResults(ctx, icmpResults, results)
		}(targets.icmp)
	}

	// Wait for completion in a separate goroutine
	go func() {
		wg.Wait()
		close(results)
	}()

	return results, nil
}

type scanResult struct {
	resultChan <-chan models.Result
	err        error
}

// handleSingleScannerCase handles cases where only one type of scanner is needed.
func (s *CombinedScanner) handleSingleScannerCase(ctx context.Context, targets scanTargets) *scanResult {
	if len(targets.tcp) > 0 && len(targets.icmp) == 0 {
		results, err := s.tcpScanner.Scan(ctx, targets.tcp)
		if err != nil {
			return &scanResult{nil, fmt.Errorf("TCP scan error: %w", err)}
		}

		return &scanResult{results, nil}
	}

	if len(targets.icmp) > 0 && len(targets.tcp) == 0 {
		results, err := s.icmpScanner.Scan(ctx, targets.icmp)
		if err != nil {
			return &scanResult{nil, fmt.Errorf("ICMP scan error: %w", err)}
		}

		return &scanResult{results, nil}
	}

	return nil
}

func (*CombinedScanner) separateTargets(targets []models.Target) scanTargets {
	separated := scanTargets{
		tcp:  make([]models.Target, 0, len(targets)),
		icmp: make([]models.Target, 0, len(targets)),
	}

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
		case result, ok := <-in:
			if !ok {
				return
			}
			select {
			case out <- result:
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

func (s *CombinedScanner) Stop(ctx context.Context) error {
	// setup a timeout on the context
	shutdownCtx, cancel := context.WithTimeout(ctx, stopTimer)
	defer cancel()

	close(s.done)
	_ = s.tcpScanner.Stop(shutdownCtx)
	_ = s.icmpScanner.Stop(shutdownCtx)

	return nil
}

type scanTargets struct {
	tcp  []models.Target
	icmp []models.Target
}
