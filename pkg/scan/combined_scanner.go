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
	stopTimer = 5 * time.Second
)

type CombinedScanner struct {
	tcpScanner  Scanner
	icmpScanner Scanner
	done        chan struct{}
}

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

// pkg/scan/combined_scanner.go

func (s *CombinedScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	// Add debug logging for context
	log.Printf("CombinedScanner.Scan starting with context: %p", ctx)
	defer log.Printf("CombinedScanner.Scan complete with context: %p", ctx)

	if len(targets) == 0 {
		empty := make(chan models.Result)
		close(empty)
		return empty, nil
	}

	// Create a new context with cancellation that we control
	scanCtx, scanCancel := context.WithCancel(ctx)

	// Create buffered results channel
	results := make(chan models.Result, len(targets))

	// Start a goroutine to monitor parent context
	go func() {
		select {
		case <-ctx.Done():
			log.Printf("Parent context cancelled: %v", ctx.Err())
			scanCancel()
		case <-s.done:
			log.Printf("Scanner stopped")
			scanCancel()
		}
	}()

	// Start another goroutine to handle cleanup
	go func() {
		<-scanCtx.Done()
		log.Printf("Scan context cancelled, cleaning up resources")
		// Ensure results channel is closed after all work is done
		defer close(results)

		// Additional cleanup if needed
	}()

	// Process targets
	separated := s.separateTargets(targets)
	log.Printf("Processing targets - TCP: %d, ICMP: %d", len(separated.tcp), len(separated.icmp))

	// Start the scanners
	var wg sync.WaitGroup

	if len(separated.tcp) > 0 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.processTCPTargets(scanCtx, separated.tcp, results)
		}()
	}

	if len(separated.icmp) > 0 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.processICMPTargets(scanCtx, separated.icmp, results)
		}()
	}

	// Wait for completion in a separate goroutine
	go func() {
		wg.Wait()
		scanCancel() // Signal completion
	}()

	return results, nil
}

func (s *CombinedScanner) processTCPTargets(ctx context.Context, targets []models.Target, results chan<- models.Result) {
	if s.tcpScanner == nil {
		log.Printf("TCP scanner not available")
		return
	}

	tcpResults, err := s.tcpScanner.Scan(ctx, targets)
	if err != nil {
		log.Printf("TCP scan error: %v", err)
		return
	}

	for {
		select {
		case <-ctx.Done():
			log.Printf("TCP scanner context cancelled")
			return
		case result, ok := <-tcpResults:
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

func (s *CombinedScanner) processICMPTargets(ctx context.Context, targets []models.Target, results chan<- models.Result) {
	if s.icmpScanner == nil {
		log.Printf("ICMP scanner not available")
		return
	}

	icmpResults, err := s.icmpScanner.Scan(ctx, targets)
	if err != nil {
		log.Printf("ICMP scan error: %v", err)
		return
	}

	for {
		select {
		case <-ctx.Done():
			log.Printf("ICMP scanner context cancelled")
			return
		case result, ok := <-icmpResults:
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

// Stop ensures clean shutdown
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
			errs = append(errs, fmt.Errorf("ICMP scanner stop error: %w", err))
		}
	}

	if len(errs) > 0 {
		return fmt.Errorf("scanner stop errors: %v", errs)
	}

	return nil
}

const (
	workerChannelSize = 2
)

type scanWorker struct {
	scanner Scanner
	targets []models.Target
	name    string
}

func (s *CombinedScanner) handleMixedScanners(ctx context.Context, targets scanTargets) (<-chan models.Result, error) {
	results := make(chan models.Result, len(targets.tcp)+len(targets.icmp))

	var wg sync.WaitGroup

	// Set up workers for each scanner type
	workers := s.setupWorkers(targets)

	log.Printf("handleMixedScanners: starting with context: %p", ctx) // Log context

	// Use a separate context for each worker to handle early cancellation
	workerCtx, cancelWorkers := context.WithCancel(ctx)
	defer cancelWorkers() // Ensure workers are canceled if we exit early

	// Start workers
	for _, w := range workers {
		if len(w.targets) > 0 {
			wg.Add(1)

			go func(worker scanWorker) {
				defer wg.Done()

				scanResults, err := worker.scanner.Scan(workerCtx, worker.targets)
				if err != nil {
					log.Printf("Error from %s scanner: %v", worker.name, err)
					return
				}

				// Forward results
				for result := range scanResults {
					select {
					case results <- result:
					case <-workerCtx.Done(): // Stop forwarding if the worker context is done
						return
					}
				}
			}(w)
		}
	}

	// Close results when all workers are done
	go func() {
		wg.Wait()
		close(results)
	}()

	return results, nil
}

func (s *CombinedScanner) setupWorkers(targets scanTargets) []scanWorker {
	workers := make([]scanWorker, 0, workerChannelSize)

	if len(targets.tcp) > 0 {
		workers = append(workers, scanWorker{
			scanner: s.tcpScanner,
			targets: targets.tcp,
			name:    "TCP",
		})
	}

	if s.icmpScanner != nil && len(targets.icmp) > 0 {
		workers = append(workers, scanWorker{
			scanner: s.icmpScanner,
			targets: targets.icmp,
			name:    "ICMP",
		})
	}

	return workers
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

type scanTargets struct {
	tcp  []models.Target
	icmp []models.Target
}
