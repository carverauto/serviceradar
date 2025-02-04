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
	closeOnce   sync.Once
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

func (s *CombinedScanner) processTargetsWithError(
	ctx context.Context,
	scanner Scanner,
	scannerName string,
	targets []models.Target,
	results chan<- models.Result,
	errCh chan<- error,
) {
	if scanner == nil {
		return
	}

	scanResults, err := scanner.Scan(ctx, targets)
	if err != nil && !errors.Is(err, context.Canceled) {
		select {
		case errCh <- fmt.Errorf("%s scan error: %w", scannerName, err):
		default:
		}
		return
	}

	// Forward results until channel closes or context cancelled
	for {
		select {
		case result, ok := <-scanResults:
			if !ok {
				return
			}
			select {
			case results <- result:
			case <-ctx.Done():
				return
			}
		case <-ctx.Done():
			return
		}
	}
}

// Scan starts scanning and returns a results channel or an error immediately if any underlying scanner returns an error.
func (s *CombinedScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	if len(targets) == 0 {
		empty := make(chan models.Result)
		close(empty)
		return empty, nil
	}

	// Create buffered results channel
	results := make(chan models.Result, len(targets))
	errCh := make(chan error, 2)

	// Create scan context
	scanCtx, cancel := context.WithCancel(ctx)

	// Initialize WaitGroup for scan completion
	var wg sync.WaitGroup

	// Separate targets
	separated := s.separateTargets(targets)
	log.Printf("Processing targets - TCP: %d, ICMP: %d", len(separated.tcp), len(separated.icmp))

	// Start TCP scanning if needed
	if len(separated.tcp) > 0 && s.tcpScanner != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.processTargetsWithError(scanCtx, s.tcpScanner, "TCP", separated.tcp, results, errCh)
		}()
	}

	// Start ICMP scanning if needed
	if len(separated.icmp) > 0 && s.icmpScanner != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.processTargetsWithError(scanCtx, s.icmpScanner, "ICMP", separated.icmp, results, errCh)
		}()
	}

	// Create completion channel
	done := make(chan struct{})

	// Start cleanup goroutine
	go func() {
		defer close(done)
		defer close(results)
		defer cancel()

		// Wait for completion or cancellation
		complete := make(chan struct{})
		go func() {
			wg.Wait()
			close(complete)
		}()

		select {
		case <-complete:
			log.Println("Scan completed successfully")
		case <-ctx.Done():
			log.Println("Scan context cancelled")
		case <-s.done:
			log.Println("Scanner stopping due to shutdown")
		}
	}()

	// Check for immediate errors
	select {
	case err := <-errCh:
		if err != nil && !errors.Is(err, context.Canceled) {
			cancel()
			return nil, err
		}
		return results, nil
	case <-time.After(10 * time.Millisecond):
		return results, nil
	}
}

func (s *CombinedScanner) processTCPTargets(ctx context.Context, targets []models.Target, results chan<- models.Result) error {
	scanResults, err := s.tcpScanner.Scan(ctx, targets)
	if err != nil {
		return err
	}

	return s.forwardResults(ctx, scanResults, results)
}

func (s *CombinedScanner) processICMPTargets(ctx context.Context, targets []models.Target, results chan<- models.Result) error {
	scanResults, err := s.icmpScanner.Scan(ctx, targets)
	if err != nil {
		return err
	}

	return s.forwardResults(ctx, scanResults, results)
}

func (s *CombinedScanner) forwardResults(ctx context.Context, input <-chan models.Result, output chan<- models.Result) error {
	for {
		select {
		case result, ok := <-input:
			if !ok {
				return nil
			}
			select {
			case output <- result:
			case <-ctx.Done():
				return ctx.Err()
			case <-s.done:
				return nil
			}
		case <-ctx.Done():
			return ctx.Err()
		case <-s.done:
			return nil
		}
	}
}

func (s *CombinedScanner) Stop(ctx context.Context) error {
	log.Println("CombinedScanner.Stop called")

	s.closeOnce.Do(func() {
		close(s.done)
	})

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
		return fmt.Errorf("errors during stop: %v", errs)
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
