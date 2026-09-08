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
	"time"

	"github.com/carverauto/serviceradar/go/pkg/scan"
)

func (s *NetworkSweeper) Start(ctx context.Context) error {
	s.logger.Info().Dur("interval", s.config.Interval).Msg("Starting network sweeper")

	done := s.ensureControlChannels()

	select {
	case <-done:
		s.logger.Info().Msg("Sweep already stopped, skipping start")
		return nil
	default:
	}

	s.ensureScannersInitialized()

	initialCtx, initialCancel := context.WithTimeout(ctx, scanTimeout)
	if err := s.runSweepWithLock(initialCtx); err != nil {
		initialCancel()

		s.logger.Error().Err(err).Msg("Initial sweep failed")
	} else {
		s.logger.Info().Msg("Initial sweep completed successfully")
	}

	initialCancel()

	ticker := time.NewTicker(s.config.Interval)
	defer ticker.Stop()

	s.logger.Debug().Dur("interval", s.config.Interval).Msg("Entering sweep loop")

	for {
		select {
		case <-ctx.Done():
			s.logger.Info().Msg("Context canceled, stopping sweeper")

			return ctx.Err()
		case <-done:
			s.logger.Info().Msg("Received done signal, stopping sweeper")

			return nil
		case <-s.tickerReset:
			s.mu.RLock()
			newInterval := s.config.Interval
			s.mu.RUnlock()
			s.logger.Info().Dur("newInterval", newInterval).Msg("Resetting sweep ticker due to interval change")
			ticker.Reset(newInterval)
		case t := <-ticker.C:
			s.logger.Debug().Time("tickTime", t).Msg("Ticker fired, starting periodic sweep")

			sweepCtx, sweepCancel := context.WithTimeout(ctx, scanTimeout)
			if err := s.runSweepWithLock(sweepCtx); err != nil {
				s.logger.Error().Err(err).Msg("Periodic sweep failed")
			} else {
				s.logger.Debug().Msg("Periodic sweep completed successfully")
			}

			sweepCancel()
		}
	}
}

// RunOnce triggers a single sweep cycle immediately.
func (s *NetworkSweeper) RunOnce(ctx context.Context) error {
	done := s.ensureControlChannels()

	select {
	case <-done:
		s.logger.Info().Msg("Sweep already stopped, skipping run-once")
		return nil
	default:
	}

	s.ensureScannersInitialized()

	sweepCtx, sweepCancel := context.WithTimeout(ctx, scanTimeout)
	defer sweepCancel()

	if err := s.runSweepWithLock(sweepCtx); err != nil {
		s.logger.Error().Err(err).Msg("Run-once sweep failed")
		return err
	}

	return nil
}

// Stop gracefully stops sweeping.
func (s *NetworkSweeper) Stop() error {
	s.logger.Info().Msg("Stopping network sweeper")

	var done chan struct{}
	alreadyStopped := false
	var icmpScanner scan.Scanner
	var tcpScanner scan.Scanner
	var tcpConnectScanner scan.Scanner

	s.mu.Lock()
	alreadyStopped = s.stopped
	s.stopped = true
	done = s.done
	icmpScanner = s.icmpScanner
	s.icmpScanner = nil
	tcpScanner = s.tcpScanner
	s.tcpScanner = nil
	tcpConnectScanner = s.tcpConnectScanner
	s.tcpConnectScanner = nil
	s.mu.Unlock()

	switch {
	case done == nil:
		s.logger.Debug().Msg("Sweep service already stopped")
	case alreadyStopped:
		s.logger.Debug().Msg("Sweep service already stopped")
	default:
		close(done)
	}

	if icmpScanner != nil {
		if err := icmpScanner.Stop(); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop ICMP scanner")
		}
	}

	if tcpScanner != nil {
		if err := tcpScanner.Stop(); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop TCP scanner")
		}
	}

	if tcpConnectScanner != nil {
		if err := tcpConnectScanner.Stop(); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop TCP connect scanner")
		}
	}

	return nil
}

func (s *NetworkSweeper) ensureControlChannels() chan struct{} {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.done == nil {
		s.done = make(chan struct{})
		if s.stopped {
			close(s.done)
		}
	}

	return s.done
}

func (s *NetworkSweeper) ensureScannersInitialized() {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.ensureScannersInitializedLocked()
}

// ensureScannersInitializedLocked initializes only scanners requested by the
// active config. The caller must hold s.mu.
func (s *NetworkSweeper) ensureScannersInitializedLocked() {
	if s.icmpScanner == nil {
		s.icmpScanner = initializeICMPScanner(s.config, s.logger)
	}

	if s.tcpScanner == nil {
		s.tcpScanner = initializeTCPScanner(s.config, s.logger)
	}

	if s.tcpConnectScanner == nil {
		s.tcpConnectScanner = initializeTCPConnectScanner(s.config, s.logger)
	}
}
