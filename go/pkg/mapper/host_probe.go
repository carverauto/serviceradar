package mapper

import (
	"context"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan"
)

const (
	hostProbeTimeout   = 2 * time.Second
	hostProbeRateLimit = 100
)

type noopHostProbeService struct{}

func (noopHostProbeService) Probe(_ context.Context, _ string) error { return nil }
func (noopHostProbeService) Close() error                            { return nil }

type sharedICMPProbeService struct {
	mu      sync.Mutex
	sweeper *scan.ICMPSweeper
}

func newSharedICMPProbeService(log logger.Logger) (HostProber, error) {
	sweeper, err := scan.NewICMPSweeper(time.Second, hostProbeRateLimit, log)
	if err != nil {
		return nil, err
	}

	return &sharedICMPProbeService{sweeper: sweeper}, nil
}

func (s *sharedICMPProbeService) Probe(ctx context.Context, host string) error {
	if s == nil || s.sweeper == nil || host == "" {
		return nil
	}

	probeCtx, cancel := context.WithTimeout(ctx, hostProbeTimeout)
	defer cancel()

	s.mu.Lock()
	resultCh, err := s.sweeper.Scan(probeCtx, []models.Target{{Host: host, Mode: models.ModeICMP}})
	s.mu.Unlock()
	if err != nil {
		return err
	}

	reachable := false
	for result := range resultCh {
		if result.Available {
			reachable = true
		}
	}

	if reachable {
		return nil
	}

	return ErrNoICMPResponse
}

func (s *sharedICMPProbeService) Close() error {
	if s == nil || s.sweeper == nil {
		return nil
	}
	return s.sweeper.Stop()
}
