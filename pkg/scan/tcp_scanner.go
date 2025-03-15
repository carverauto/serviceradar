package scan

import (
	"context"
	"fmt"
	"log"
	"net"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

type TCPSweeper struct {
	timeout     time.Duration
	concurrency int
	cancel      context.CancelFunc
}

var _ Scanner = (*TCPSweeper)(nil)

func NewTCPSweeper(timeout time.Duration, concurrency int) *TCPSweeper {
	if timeout == 0 {
		timeout = 5 * time.Second
	}

	if concurrency == 0 {
		concurrency = 20
	}

	return &TCPSweeper{
		timeout:     timeout,
		concurrency: concurrency,
	}
}

const (
	defaultConcurrencyMultiplier = 2
)

func (s *TCPSweeper) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	tcpTargets := filterTCPTargets(targets)
	if len(tcpTargets) == 0 {
		ch := make(chan models.Result)
		close(ch)

		return ch, nil
	}

	scanCtx, cancel := context.WithCancel(ctx)
	s.cancel = cancel

	resultCh := make(chan models.Result, len(tcpTargets))
	workCh := make(chan models.Target, s.concurrency*defaultConcurrencyMultiplier)

	var wg sync.WaitGroup

	for i := 0; i < s.concurrency; i++ {
		wg.Add(1)

		go func() {
			defer wg.Done()
			s.worker(scanCtx, workCh, resultCh)
		}()
	}

	go func() {
		defer close(workCh)

		for _, t := range tcpTargets {
			select {
			case <-scanCtx.Done():
				return
			case workCh <- t:
			}
		}
	}()

	go func() {
		wg.Wait()

		close(resultCh)
	}()

	return resultCh, nil
}

func (s *TCPSweeper) worker(ctx context.Context, workCh <-chan models.Target, resultCh chan<- models.Result) {
	for t := range workCh {
		result := models.Result{
			Target:    t,
			FirstSeen: time.Now(),
			LastSeen:  time.Now(),
		}

		avail, rtt, err := s.checkPort(ctx, t.Host, t.Port)
		result.Available = avail
		result.RespTime = rtt

		if err != nil {
			result.Error = err
		}

		select {
		case <-ctx.Done():
			return
		case resultCh <- result:
		}
	}
}

func (s *TCPSweeper) checkPort(ctx context.Context, host string, port int) (bool, time.Duration, error) {
	_, cancel := context.WithTimeout(ctx, s.timeout)
	defer cancel()

	start := time.Now()

	conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", host, port), s.timeout)
	if err != nil {
		return false, 0, err
	}

	defer func(conn net.Conn) {
		err := conn.Close()
		if err != nil {
			log.Printf("failed to close connection: %v", err)
		}
	}(conn)

	return true, time.Since(start), nil
}

func (s *TCPSweeper) Stop(_ context.Context) error {
	if s.cancel != nil {
		s.cancel()
	}

	return nil
}

func filterTCPTargets(targets []models.Target) []models.Target {
	var filtered []models.Target

	for _, t := range targets {
		if t.Mode == models.ModeTCP {
			filtered = append(filtered, t)
		}
	}

	return filtered
}
