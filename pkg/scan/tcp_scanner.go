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
	results := make(chan models.Result, len(targets))
	targetChan := make(chan models.Target, s.concurrency)

	scanCtx, cancel := context.WithCancel(ctx)

	// Launch the scan operation
	s.launchScan(scanCtx, cancel, targets, targetChan, results)

	return results, nil
}

func (s *TCPScanner) launchScan(
	ctx context.Context,
	cancel context.CancelFunc,
	targets []models.Target,
	targetChan chan models.Target,
	results chan models.Result) {
	var wg sync.WaitGroup

	// Start worker pool
	s.startWorkerPool(ctx, &wg, targetChan, results)

	// Start target feeder
	go s.feedTargets(ctx, targets, targetChan)

	// Start completion handler
	go s.handleCompletion(&wg, cancel, results)
}

func (s *TCPScanner) startWorkerPool(ctx context.Context, wg *sync.WaitGroup, targetChan chan models.Target, results chan models.Result) {
	for i := 0; i < s.concurrency; i++ {
		wg.Add(1)

		go s.runWorker(ctx, wg, targetChan, results)
	}
}

func (s *TCPScanner) runWorker(ctx context.Context, wg *sync.WaitGroup, targetChan chan models.Target, results chan models.Result) {
	defer wg.Done()

	for {
		select {
		case target, ok := <-targetChan:
			if !ok {
				return
			}

			s.scanTarget(ctx, target, results)
		case <-ctx.Done():
			return
		case <-s.done:
			return
		}
	}
}

func (s *TCPScanner) feedTargets(ctx context.Context, targets []models.Target, targetChan chan models.Target) {
	defer close(targetChan)

	for _, target := range targets {
		select {
		case targetChan <- target:
		case <-ctx.Done():
			return
		case <-s.done:
			return
		}
	}
}

func (*TCPScanner) handleCompletion(wg *sync.WaitGroup, cancel context.CancelFunc, results chan models.Result) {
	wg.Wait()
	cancel() // Cleanup context
	close(results)
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
