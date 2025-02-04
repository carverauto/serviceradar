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
	errStopScanner = errors.New("errors during Stop")
)

const (
	errChannelSize      = 2
	defaultScanErrTimer = 10 * time.Millisecond
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
		s.reportScanError(scannerName, err, errCh)
		return
	}

	s.forwardScanResults(ctx, scanResults, results)
}

// reportScanError sends the scanner error to the error channel.
func (*CombinedScanner) reportScanError(scannerName string, err error, errCh chan<- error) {
	select {
	case errCh <- fmt.Errorf("%s scan error: %w", scannerName, err):
	default:
	}
}

// forwardScanResults reads results from scanResults and sends them to results,
// stopping if the channel closes or the context is canceled.
func (*CombinedScanner) forwardScanResults(
	ctx context.Context, scanResults <-chan models.Result, results chan<- models.Result) {
	for {
		select {
		case <-ctx.Done():
			return
		case result, ok := <-scanResults:
			if !ok {
				return
			}

			if !sendResult(ctx, results, &result) {
				return
			}
		}
	}
}

// sendResult attempts to send a result on the results channel or aborts if the context is done.
func sendResult(ctx context.Context, results chan<- models.Result, result *models.Result) bool {
	select {
	case results <- *result:
		return true
	case <-ctx.Done():
		return false
	}
}

// Scan starts scanning and returns a results channel or an error immediately if any underlying scanner returns an error.
func (s *CombinedScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	// If no targets, return an immediately closed channel.
	if len(targets) == 0 {
		empty := make(chan models.Result)
		close(empty)

		return empty, nil
	}

	// Create channels.
	results := make(chan models.Result, len(targets))
	errCh := make(chan error, errChannelSize)

	// Create a scan context that can be canceled.
	scanCtx, cancel := context.WithCancel(ctx)

	// Initialize a WaitGroup to track scanning goroutines.
	var wg sync.WaitGroup

	// Separate targets into TCP and ICMP.
	separated := s.separateTargets(targets)
	log.Printf("Processing targets - TCP: %d, ICMP: %d", len(separated.tcp), len(separated.icmp))

	// Start scanning goroutines.
	s.startScanning(scanCtx, &wg, separated, results, errCh)

	// Start cleanup (canceling context and closing results when done).
	s.startCleanup(ctx, scanCtx, &wg, cancel, results)

	// Wait a short period for any immediate errors.
	return s.waitForImmediateError(errCh, cancel, results)
}

// startScanning launches scanning goroutines for TCP and/or ICMP targets.
func (s *CombinedScanner) startScanning(
	scanCtx context.Context,
	wg *sync.WaitGroup,
	separated scanTargets, // scanTargets is defined below.
	results chan<- models.Result,
	errCh chan<- error,
) {
	if len(separated.tcp) > 0 && s.tcpScanner != nil {
		wg.Add(1)

		go func() {
			defer wg.Done()
			s.processTargetsWithError(scanCtx, s.tcpScanner, "TCP", separated.tcp, results, errCh)
		}()
	}

	if len(separated.icmp) > 0 && s.icmpScanner != nil {
		wg.Add(1)

		go func() {
			defer wg.Done()
			s.processTargetsWithError(scanCtx, s.icmpScanner, "ICMP", separated.icmp, results, errCh)
		}()
	}
}

// startCleanup starts a goroutine that waits for scanning to finish, then cancels and closes channels.
func (s *CombinedScanner) startCleanup(
	ctx context.Context,
	_ context.Context,
	wg *sync.WaitGroup,
	cancel context.CancelFunc,
	results chan models.Result,
) {
	go func() {
		// Ensure that the scan context is canceled and the results channel is closed.
		defer cancel()
		defer close(results)

		// Wait for all scanning goroutines to finish.
		complete := make(chan struct{})
		go func() {
			wg.Wait()
			close(complete)
		}()

		// Log based on why cleanup is happening.
		select {
		case <-complete:
			log.Println("Scan completed successfully")
		case <-ctx.Done():
			log.Println("Scan context canceled")
		case <-s.done:
			log.Println("Scanner stopping due to shutdown")
		}
	}()
}

// waitForImmediateError checks for an immediate error on errCh, waiting up to defaultScanErrTimer.
func (*CombinedScanner) waitForImmediateError(
	errCh <-chan error,
	cancel context.CancelFunc,
	results chan models.Result,
) (<-chan models.Result, error) {
	select {
	case err := <-errCh:
		if err != nil && !errors.Is(err, context.Canceled) {
			cancel()

			return nil, err
		}

		return results, nil
	case <-time.After(defaultScanErrTimer):
		return results, nil
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
		return fmt.Errorf("%w: %v", errStopScanner, errs)
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
