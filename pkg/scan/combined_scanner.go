package scan

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

type CombinedScanner struct {
	tcpScanner  *TCPScanner
	icmpScanner *ICMPScanner
	done        chan struct{}
}

func NewCombinedScanner(timeout time.Duration, concurrency, icmpCount int) *CombinedScanner {
	return &CombinedScanner{
		tcpScanner:  NewTCPScanner(timeout, concurrency),
		icmpScanner: NewICMPScanner(timeout, concurrency, icmpCount),
		done:        make(chan struct{}),
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

func (s *CombinedScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	results := make(chan models.Result)
	separated := s.separateTargets(targets)

	var wg sync.WaitGroup

	s.startScanners(ctx, &wg, separated, results)

	go func() {
		wg.Wait()
		close(results)
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

func (s *CombinedScanner) startScanners(ctx context.Context, wg *sync.WaitGroup, targets scanTargets, results chan<- models.Result) {
	if len(targets.tcp) > 0 {
		wg.Add(1)

		go s.runTCPScanner(ctx, wg, targets.tcp, results)
	}

	if len(targets.icmp) > 0 {
		wg.Add(1)

		go s.runICMPScanner(ctx, wg, targets.icmp, results)
	}
}

func (s *CombinedScanner) runTCPScanner(ctx context.Context, wg *sync.WaitGroup, targets []models.Target, results chan<- models.Result) {
	defer wg.Done()

	tcpResults, err := s.tcpScanner.Scan(ctx, targets)
	if err != nil {
		log.Printf("TCP scan error: %v", err)
		return
	}

	s.processResults(ctx, tcpResults, results)
}

func (s *CombinedScanner) runICMPScanner(ctx context.Context, wg *sync.WaitGroup, targets []models.Target, results chan<- models.Result) {
	defer wg.Done()

	icmpResults, err := s.icmpScanner.Scan(ctx, targets)
	if err != nil {
		log.Printf("ICMP scan error: %v", err)
		return
	}

	s.processResults(ctx, icmpResults, results)
}

func (s *CombinedScanner) processResults(ctx context.Context, scanResults <-chan models.Result, results chan<- models.Result) {
	for result := range scanResults {
		select {
		case <-ctx.Done():
			return
		case <-s.done:
			return
		case results <- result:
		}
	}
}
