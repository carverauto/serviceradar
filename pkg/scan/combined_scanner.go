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

func (s *CombinedScanner) processTargetsWithError(
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
		// Send error or drop it if channel is full
		select {
		case errCh <- err:
		default:
		}
		return
	}

	for {
		select {
		case <-ctx.Done():
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

// Scan starts scanning and returns a results channel or an error immediately if any underlying scanner returns an error.
func (s *CombinedScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	if len(targets) == 0 {
		empty := make(chan models.Result)
		close(empty)
		return empty, nil
	}

	// Create buffered channels
	results := make(chan models.Result, len(targets))
	errCh := make(chan error, 2)

	// Create a context that we can cancel
	scanCtx, cancel := context.WithCancel(ctx)

	// Start scanning
	separated := s.separateTargets(targets)
	log.Printf("Processing targets - TCP: %d, ICMP: %d", len(separated.tcp), len(separated.icmp))

	var wg sync.WaitGroup

	// Start TCP scanning if needed
	if len(separated.tcp) > 0 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := s.processTCPTargets(scanCtx, separated.tcp, results); err != nil {
				select {
				case errCh <- fmt.Errorf("TCP scan error: %w", err):
				default:
				}
			}
		}()
	}

	// Start ICMP scanning if needed
	if len(separated.icmp) > 0 && s.icmpScanner != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := s.processICMPTargets(scanCtx, separated.icmp, results); err != nil {
				select {
				case errCh <- fmt.Errorf("ICMP scan error: %w", err):
				default:
				}
			}
		}()
	}

	// Start cleanup goroutine
	go func() {
		// Wait for all scanners to finish
		wg.Wait()

		// Check for errors
		select {
		case err := <-errCh:
			cancel()
			log.Printf("Scan error detected: %v", err)
		case <-ctx.Done():
			log.Println("Context cancelled")
		case <-s.done:
			log.Println("Scanner stopped")
		default:
			log.Println("Scan completed successfully")
		}

		// Always close results channel after all scanners are done
		close(results)
		cancel()
	}()

	// Check for immediate errors
	select {
	case err := <-errCh:
		cancel()
		return nil, err
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

// Stop gracefully stops any ongoing scans.
func (s *CombinedScanner) Stop(ctx context.Context) error {
	log.Println("CombinedScanner.Stop called")

	// Signal all scanners to stop
	close(s.done)

	var errs []error

	// Stop TCP scanner
	if s.tcpScanner != nil {
		if err := s.tcpScanner.Stop(ctx); err != nil {
			errs = append(errs, fmt.Errorf("TCP scanner stop error: %w", err))
		}
	}

	// Stop ICMP scanner
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
