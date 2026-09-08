/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package sweeper

import (
	"context"

	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan/banner_grab"
)

type activeBannerGrabPhase struct {
	engine *banner_grab.Engine
	done   <-chan error
}

func (s *NetworkSweeper) startBannerGrabPhase(ctx context.Context) *activeBannerGrabPhase {
	if !s.config.BannerGrab.Enabled {
		return nil
	}

	engine := banner_grab.New(banner_grab.ConfigFromModel(s.config.BannerGrab))
	observations := engine.Start(ctx)

	handler := s.bannerHandler
	if handler == nil {
		handler = s.drainBannerGrabObservations
	}

	done := make(chan error, 1)
	go func() {
		done <- handler(ctx, s.config.BannerGrab, engine, observations)
	}()

	s.bannerMu.Lock()
	s.bannerPhase = engine
	s.lastBannerStats = nil
	s.bannerMu.Unlock()

	s.logger.Info().
		Strs("protocols", s.config.BannerGrab.Protocols).
		Int("maxGlobalConcurrency", s.config.BannerGrab.MaxGlobalConcurrency).
		Int("maxCandidateQueue", s.config.BannerGrab.MaxCandidateQueue).
		Msg("Started banner-grab phase")

	return &activeBannerGrabPhase{
		engine: engine,
		done:   done,
	}
}

func (s *NetworkSweeper) finishBannerGrabPhase(phase *activeBannerGrabPhase) error {
	if phase == nil {
		return nil
	}

	phase.engine.Stop()
	err := <-phase.done
	stats := phase.engine.Stats()

	s.bannerMu.Lock()
	if s.bannerPhase == phase.engine {
		s.bannerPhase = nil
	}
	s.lastBannerStats = bannerGrabStatsFromEngine(stats)
	s.bannerMu.Unlock()

	s.logger.Info().
		Uint64("candidates", stats.CandidatesTotal).
		Uint64("probes", stats.ProbesTotal).
		Uint64("observations", stats.ObservationsTotal).
		Uint64("bytesReceived", stats.BannerBytesTotal).
		Uint64("timeouts", stats.TimeoutTotal).
		Uint64("connectionResets", stats.ConnectionResetTotal).
		Uint64("emptyResponses", stats.EmptyResponseTotal).
		Uint64("errors", stats.ErrorsTotal).
		Uint64("maxQueueDepth", stats.MaxQueueDepth).
		Msg("Finished banner-grab phase")

	return err
}

func (s *NetworkSweeper) abortBannerGrabPhase(phase *activeBannerGrabPhase) {
	if phase == nil {
		return
	}

	phase.engine.Stop()
	<-phase.done

	s.bannerMu.Lock()
	if s.bannerPhase == phase.engine {
		s.bannerPhase = nil
	}
	s.bannerMu.Unlock()
}

func (s *NetworkSweeper) GetBannerGrabStats() *models.BannerGrabStats {
	s.bannerMu.RLock()
	engine := s.bannerPhase
	lastStats := s.lastBannerStats
	s.bannerMu.RUnlock()

	if engine != nil {
		return bannerGrabStatsFromEngine(engine.Stats())
	}
	if lastStats == nil {
		return nil
	}

	stats := *lastStats
	return &stats
}

func (s *NetworkSweeper) submitBannerGrabCandidate(ctx context.Context, result models.Result) error {
	s.bannerMu.RLock()
	engine := s.bannerPhase
	s.bannerMu.RUnlock()

	if engine == nil {
		return nil
	}

	return engine.SubmitResult(ctx, result)
}

func (s *NetworkSweeper) drainBannerGrabObservations(
	ctx context.Context,
	_ models.BannerGrab,
	_ *banner_grab.Engine,
	observations <-chan banner_grab.BannerObservation,
) error {
	count := 0

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case _, ok := <-observations:
			if !ok {
				if count > 0 {
					s.logger.Debug().Int("observations", count).Msg("Drained banner-grab observations without netprobe handler")
				}

				return nil
			}

			count++
		}
	}
}

func bannerGrabStatsFromEngine(stats banner_grab.Stats) *models.BannerGrabStats {
	return &models.BannerGrabStats{
		CandidatesTotal:      stats.CandidatesTotal,
		ProbesTotal:          stats.ProbesTotal,
		InFlight:             stats.InFlight,
		QueueDepth:           stats.QueueDepth,
		MatchBatchesTotal:    stats.MatchBatchesTotal,
		MatchBatchBytesTotal: stats.MatchBatchBytesTotal,
		BannerBytesTotal:     stats.BannerBytesTotal,
		SkippedFreshTotal:    stats.SkippedFreshTotal,
		SkippedBackoffTotal:  stats.SkippedBackoffTotal,
		MatchesTotal:         stats.MatchesTotal,
		EmptyResponseTotal:   stats.EmptyResponseTotal,
		ConnectionResetTotal: stats.ConnectionResetTotal,
		TimeoutTotal:         stats.TimeoutTotal,
		ErrorsTotal:          stats.ErrorsTotal,
	}
}
