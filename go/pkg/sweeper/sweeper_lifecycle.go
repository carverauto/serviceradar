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
	"errors"
	"slices"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
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

	if s.manualSchedule.Load() {
		s.logger.Info().Msg("Manual schedule active, skipping initial sweep")
	} else {
		initialCtx, initialCancel := context.WithTimeout(ctx, effectiveScanTimeout(s.config))
		if err := s.runSweepWithLock(initialCtx); err != nil {
			s.logRunError(err, "Initial sweep failed")
		} else {
			s.logger.Info().Msg("Initial sweep completed successfully")
		}

		initialCancel()
	}

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
			if s.manualSchedule.Load() {
				continue
			}

			s.logger.Debug().Time("tickTime", t).Msg("Ticker fired, starting periodic sweep")

			sweepCtx, sweepCancel := context.WithTimeout(ctx, effectiveScanTimeout(s.config))
			if err := s.runSweepWithLock(sweepCtx); err != nil {
				s.logRunError(err, "Periodic sweep failed")
			} else {
				s.logger.Debug().Msg("Periodic sweep completed successfully")
			}

			sweepCancel()
		}
	}
}

// SetManualSchedule switches the local interval ticker off or on. While on,
// Start runs no initial or periodic sweep; an external scheduler drives the
// sweeper through RunOnce. Turning it back off resumes ticking from the next
// interval boundary.
func (s *NetworkSweeper) SetManualSchedule(manual bool) {
	if s.manualSchedule.Swap(manual) != manual {
		s.logger.Info().Bool("manual_schedule", manual).Msg("Sweep schedule mode changed")
	}
}

// ManualSchedule reports whether the local interval ticker is suppressed.
func (s *NetworkSweeper) ManualSchedule() bool {
	return s.manualSchedule.Load()
}

// RunOnce triggers a single sweep cycle immediately.
func (s *NetworkSweeper) RunOnce(ctx context.Context) error {
	return s.RunOnceWithExecution(ctx, "")
}

// RunOnceWithExecution triggers one sweep whose published summary carries
// executionID. An empty id is a locally scheduled sweep. The id is bound in
// the same update that publishes the completed sweep's LastSweep, and it is
// not visible on the previous cycle while this run is still in progress.
func (s *NetworkSweeper) RunOnceWithExecution(ctx context.Context, executionID string) error {
	return s.RunOnceWithObserver(ctx, executionID, nil)
}

// RunOnceWithObserver delivers each final scanner result during this cycle.
// The observer receives the scan context and may be called concurrently by
// different scan modes. These signed plan runs enumerate every configured CIDR
// address, including IPv4 endpoints.
func (s *NetworkSweeper) RunOnceWithObserver(ctx context.Context, executionID string, observer func(context.Context, *models.Result) error) error {
	done := s.ensureControlChannels()

	select {
	case <-done:
		s.logger.Info().Msg("Sweep already stopped, skipping run-once")
		return errSweeperStopped
	default:
	}

	s.ensureScannersInitialized()

	sweepCtx, sweepCancel := context.WithTimeout(ctx, effectiveScanTimeout(s.config))
	defer sweepCancel()

	if err := s.runSweepWithObserver(sweepCtx, executionID, nil, observer); err != nil {
		s.logRunError(err, "Run-once sweep failed")
		return err
	}

	return nil
}

// RunSpec is what one planned execution probes: the networks, modes and ports
// a signed plan carries. Nothing else of the sweeper's config enters it.
type RunSpec struct {
	Networks []string
	Modes    []models.SweepMode
	Ports    []int
}

// errEmptyRunSpec refuses a planned run with nothing to probe.
var errEmptyRunSpec = errors.New("planned sweep run has no networks or modes")

// errPlannedRunObserver refuses a planned run nothing would observe.
var errPlannedRunObserver = errors.New("planned sweep run requires a result observer")

// RunPlannedWithObserver runs one execution of spec and delivers each final
// result to observer, like RunOnceWithObserver. The run probes exactly spec's
// networks, modes and ports: they replace the sweeper config's, and its device
// targets are dropped. The rest of the config (timeouts, concurrency, rate
// limits, interface, banner grab) is the one current when the run starts. A
// config update during the run takes effect from the next run.
func (s *NetworkSweeper) RunPlannedWithObserver(
	ctx context.Context,
	executionID string,
	spec RunSpec,
	observer func(context.Context, *models.Result) error,
) error {
	if len(spec.Networks) == 0 || len(spec.Modes) == 0 {
		return errEmptyRunSpec
	}
	if observer == nil {
		return errPlannedRunObserver
	}

	done := s.ensureControlChannels()

	select {
	case <-done:
		s.logger.Info().Msg("Sweep already stopped, skipping planned run")
		return errSweeperStopped
	default:
	}

	planned := func(base *models.Config) *models.Config {
		cfg := *base
		cfg.Networks = slices.Clone(spec.Networks)
		cfg.SweepModes = slices.Clone(spec.Modes)
		cfg.Ports = slices.Clone(spec.Ports)
		cfg.DeviceTargets = nil

		return &cfg
	}

	s.mu.Lock()
	timeout := effectiveScanTimeout(s.config)
	s.mu.Unlock()

	sweepCtx, sweepCancel := context.WithTimeout(ctx, timeout)
	defer sweepCancel()

	if err := s.runSweepWithObserver(sweepCtx, executionID, planned, observer); err != nil {
		s.logRunError(err, "Planned sweep failed")
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

	s.ensureScannersInitializedLocked(s.config)
}

// ensureScannersInitializedLocked initializes only scanners cfg requests, with
// cfg's scanner settings. The caller must hold s.mu.
func (s *NetworkSweeper) ensureScannersInitializedLocked(cfg *models.Config) {
	if s.icmpScanner == nil {
		s.icmpScanner = initializeICMPScanner(cfg, s.logger)
	}

	if s.tcpScanner == nil {
		s.tcpScanner = initializeTCPScanner(cfg, s.synScanGate, s.logger)
	}

	if s.tcpConnectScanner == nil {
		s.tcpConnectScanner = initializeTCPConnectScanner(cfg, s.logger)
	}
}
