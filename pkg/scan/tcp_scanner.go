package scan

import (
	"context"
	"log"
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

type TCPScanner struct {
	timeout     time.Duration
	concurrency int
	done        chan struct{}
	// scan        func(context.Context, []models.Target) (<-chan models.Result, error)
}

func NewTCPScanner(timeout time.Duration, concurrency int) *TCPScanner {
	return &TCPScanner{
		timeout:     timeout,
		concurrency: concurrency,
		done:        make(chan struct{}),
	}
}

func (s *TCPScanner) Stop() error {
	close(s.done)
	return nil
}

func (s *TCPScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	results := make(chan models.Result, len(targets)) // Buffer all potential results
	targetChan := make(chan models.Target, s.concurrency)

	// Create context that we can cancel if we need to stop early
	scanCtx, cancel := context.WithCancel(ctx)

	// Ensure cleanup on error
	var err error
	defer func() {
		if err != nil {
			cancel()
		}
	}()

	var wg sync.WaitGroup

	// Start worker pool
	for i := 0; i < s.concurrency; i++ {
		wg.Add(1)

		go func() {
			defer wg.Done()

			for {
				select {
				case target, ok := <-targetChan:
					if !ok {
						return
					}

					s.scanTarget(scanCtx, target, results)
				case <-scanCtx.Done():
					return
				case <-s.done:
					return
				}
			}
		}()
	}

	// Feed targets
	go func() {
		defer close(targetChan)

		for _, target := range targets {
			select {
			case targetChan <- target:
			case <-scanCtx.Done():
				return
			case <-s.done:
				return
			}
		}
	}()

	// Wait for completion and close results
	go func() {
		wg.Wait()
		cancel() // Cleanup context
		close(results)
	}()

	return results, nil
}

func (s *TCPScanner) scanTarget(ctx context.Context, target models.Target, results chan<- models.Result) {
	start := time.Now()
	result := models.Result{
		Target:    target,
		FirstSeen: start,
		LastSeen:  start,
	}

	// Create connection timeout context
	connCtx, cancel := context.WithTimeout(ctx, s.timeout)
	defer cancel()

	// Try to connect
	var d net.Dialer

	addr := net.JoinHostPort(target.Host, strconv.Itoa(target.Port))

	conn, err := d.DialContext(connCtx, "tcp", addr)
	result.RespTime = time.Since(start)

	if err != nil {
		result.Error = err
		result.Available = false
	} else {
		result.Available = true

		if err := conn.Close(); err != nil {
			log.Printf("Error closing connection: %v", err)
		}
	}

	// Send result with proper context handling
	select {
	case results <- result:
	case <-ctx.Done():
	case <-s.done:
	}
}
