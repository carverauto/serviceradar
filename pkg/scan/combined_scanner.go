package scan

import (
	"context"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

var (
	errScannerStop = errors.New("scanner stop error")
)

const (
	errChannelSize = 2
	timeAfter      = 10 * time.Millisecond
)

type CombinedScanner struct {
	tcpScanner  Scanner
	icmpScanner Scanner
	done        chan struct{}
}

// NewCombinedScanner creates a new CombinedScanner, which can scan both TCP and ICMP targets.
func NewCombinedScanner(
	timeout time.Duration,
	concurrency, icmpCount, maxIdle int,
	maxLifetime, idleTimeout time.Duration) *CombinedScanner {
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
		tcpScanner:  NewTCPScanner(timeout, concurrency, maxIdle, maxLifetime, idleTimeout),
		icmpScanner: icmpScanner,
		done:        make(chan struct{}),
	}
}

// Scan starts scanning and returns a results channel or an error immediately if any underlying scanner returns an error.
func (s *CombinedScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {

	if len(targets) == 0 {
		empty := make(chan models.Result)
		close(empty)

		return empty, nil
	}

	// Create a scan context we control.
	scanCtx, scanCancel := context.WithCancel(ctx)

	// Channel for scan results.
	results := make(chan models.Result, len(targets))
	// Channel for immediate error reporting.
	errCh := make(chan error, errChannelSize) // one per scanner at most

	// Separate targets into TCP and ICMP.
	separated := s.separateTargets(targets)
	log.Printf("Processing targets - TCP: %d, ICMP: %d", len(separated.tcp), len(separated.icmp))

	var wg sync.WaitGroup

	// Start TCP scanning, if needed.
	if len(separated.tcp) > 0 {
		wg.Add(1)

		go func() {
			defer wg.Done()
			s.processTargetsWithError(scanCtx, s.tcpScanner, "TCP", separated.tcp, results, errCh)
		}()
	}

	// Start ICMP scanning, if needed.
	if len(separated.icmp) > 0 {
		wg.Add(1)

		go func() {
			defer wg.Done()
			s.processTargetsWithError(scanCtx, s.icmpScanner, "ICMP", separated.icmp, results, errCh)
		}()
	}

	// Monitor parent context or scanner done channel.
	go func() {
		select {
		case <-ctx.Done():
			scanCancel()
		case <-s.done:
			scanCancel()
		}
	}()

	// Check briefly for immediate errors.
	select {
	case err := <-errCh:
		scanCancel()
		wg.Wait()
		close(results)

		return nil, err
	case <-time.After(timeAfter):
	}

	// Close results channel when all workers are done.
	go func() {
		wg.Wait()
		scanCancel() // signal completion
		close(results)
	}()

	return results, nil
}

// processTargetsWithError wraps the common processing logic and reports an error if scanner fails.
func (*CombinedScanner) processTargetsWithError(
	ctx context.Context,
	scanner Scanner,
	scannerName string,
	targets []models.Target,
	results chan<- models.Result,
	errCh chan<- error,
) {
	if scanner == nil {
		log.Printf("%s scanner not available", scannerName)

		return
	}

	scanResults, err := scanner.Scan(ctx, targets)
	if err != nil {
		err = fmt.Errorf("%s scan error: %w", scannerName, err)
		// Use a guard clause to report the error if possible.
		select {
		case errCh <- err:
		default:
		}

		return
	}

	for {
		select {
		case <-ctx.Done():
			log.Printf("%s scanner context canceled", scannerName)
			return
		case result, ok := <-scanResults:
			if !ok {
				return
			}
			select {
			case results <- result:
			case <-ctx.Done():
				return
			}
		}
	}
}

// Stop ensures clean shutdown.
func (s *CombinedScanner) Stop(ctx context.Context) error {
	log.Printf("CombinedScanner.Stop called")
	close(s.done)

	var errs []error

	if s.tcpScanner != nil {
		if err := s.tcpScanner.Stop(ctx); err != nil {
			errs = append(errs, fmt.Errorf("TCP scanner stop error: %w", err))
		}
	}

	if s.icmpScanner != nil {
		if err := s.icmpScanner.Stop(ctx); err != nil {
			errs = append(errs, fmt.Errorf("%w - %w", errScannerStop, err))
		}
	}

	if len(errs) > 0 {
		return fmt.Errorf("%w - %v", errScannerStop, errs)
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

type scanTargets struct {
	tcp  []models.Target
	icmp []models.Target
}
