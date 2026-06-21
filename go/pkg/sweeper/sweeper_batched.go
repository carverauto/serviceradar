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
	"fmt"
	"sync"

	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan"
)

func (s *NetworkSweeper) runBatchedSweep(ctx context.Context, targetEstimate int) error {
	s.mu.RLock()
	icmpScanner := s.icmpScanner
	tcpScanner := s.tcpScanner
	tcpConnectScanner := s.tcpConnectScanner
	s.mu.RUnlock()
	icmpCaps := scannerCapabilities(icmpScanner)
	tcpCaps := scannerCapabilities(tcpScanner)
	tcpConnectCaps := scannerCapabilities(tcpConnectScanner)

	s.resultsMu.Lock()
	s.deviceResults = make(map[string]*DeviceResultAggregator)
	s.resultsMu.Unlock()

	bannerPhase := s.startBannerGrabPhase(ctx)
	finishedBannerPhase := false
	defer func() {
		if !finishedBannerPhase {
			s.abortBannerGrabPhase(bannerPhase)
		}
	}()

	runner := &sweepBatchRunner{
		sweeper:           s,
		ctx:               ctx,
		icmpScanner:       icmpScanner,
		tcpScanner:        tcpScanner,
		tcpConnectScanner: tcpConnectScanner,
		icmpTargets:       make([]models.Target, 0, defaultTargetBatch),
		tcpTargets:        make([]models.Target, 0, defaultTargetBatch),
		tcpConnectTargets: make([]models.Target, 0, defaultTargetBatch),
	}

	if tcpStream, ok, err := s.startStreamingScan(ctx, tcpScanner, scannerProtocolTCP, targetEstimate); err != nil {
		return err
	} else if ok {
		runner.tcpStream = tcpStream
	}

	if tcpConnectStream, ok, err := s.startStreamingScan(ctx, tcpConnectScanner, "tcp_connect", targetEstimate); err != nil {
		return err
	} else if ok {
		runner.tcpConnectStream = tcpConnectStream
	}

	s.logger.Info().
		Int("estimatedTargets", targetEstimate).
		Int("batchSize", defaultTargetBatch).
		Bool("tcpStreaming", runner.tcpStream != nil).
		Bool("tcpConnectStreaming", runner.tcpConnectStream != nil).
		Bool("icmpScannerAvailable", icmpScanner != nil).
		Bool("tcpScannerAvailable", tcpScanner != nil).
		Bool("tcpConnectScannerAvailable", tcpConnectScanner != nil).
		Bool("icmpIPv4Available", icmpCaps.ICMPv4).
		Bool("icmpIPv6Available", icmpCaps.ICMPv6).
		Bool("tcpRawSYNIPv4Available", tcpCaps.RawSYNIPv4).
		Bool("tcpRawSYNIPv6Available", tcpCaps.RawSYNIPv6).
		Bool("tcpConnectIPv4Available", tcpConnectCaps.TCPConnectIPv4).
		Bool("tcpConnectIPv6Available", tcpConnectCaps.TCPConnectIPv6).
		Msg("Starting batched sweep")

	if err := s.generateTargetsBatched(runner.addTarget); err != nil {
		runner.closeStreams()
		return fmt.Errorf("failed to generate batched targets: %w", err)
	}

	if err := runner.flushAll(); err != nil {
		return err
	}

	err := s.finishBannerGrabPhase(bannerPhase)
	finishedBannerPhase = true
	if err != nil {
		return err
	}

	s.finalizeDeviceAggregators(ctx)

	s.logger.Info().
		Int("estimatedTargets", targetEstimate).
		Int("icmpTargets", runner.icmpCount).
		Int("tcpTargets", runner.tcpCount).
		Int("tcpConnectTargets", runner.tcpConnectCount).
		Int("ipv4Targets", runner.ipv4Count).
		Int("ipv6Targets", runner.ipv6Count).
		Int("ipv6TCPConnectFallbackTargets", runner.ipv6TCPConnectFallbackCount).
		Msg("Batched sweep completed successfully")

	return nil
}

type sweepTargetStream struct {
	ctx         context.Context
	targets     chan models.Target
	scanErrs    <-chan error
	processDone <-chan error
	closeOnce   sync.Once
}

func (h *sweepTargetStream) add(target models.Target) error {
	select {
	case h.targets <- target:
		return nil
	case <-h.ctx.Done():
		return h.ctx.Err()
	}
}

func (h *sweepTargetStream) closeAndWait() error {
	h.closeOnce.Do(func() {
		close(h.targets)
	})

	var firstErr error

	if err := <-h.processDone; err != nil {
		firstErr = err
	}

	for err := range h.scanErrs {
		if err != nil && firstErr == nil {
			firstErr = err
		}
	}

	return firstErr
}

func (h *sweepTargetStream) closeOnly() {
	h.closeOnce.Do(func() {
		close(h.targets)
	})
}

func (s *NetworkSweeper) startStreamingScan(
	ctx context.Context,
	scanner scan.Scanner,
	scanType string,
	targetEstimate int,
) (*sweepTargetStream, bool, error) {
	streamingScanner, ok := scanner.(scan.StreamingScanner)
	if !ok {
		return nil, false, nil
	}

	targetCh := make(chan models.Target, defaultTargetBatch)
	results, scanErrs, err := streamingScanner.ScanStream(ctx, targetCh, scan.StreamOptions{
		TargetEstimate: targetEstimate,
		BatchSize:      defaultTargetBatch,
	})
	if err != nil {
		close(targetCh)

		return nil, false, err
	}

	processDone := make(chan error, 1)
	go func() {
		processDone <- s.processResultsStream(ctx, results, scanType)
	}()

	return &sweepTargetStream{
		ctx:         ctx,
		targets:     targetCh,
		scanErrs:    scanErrs,
		processDone: processDone,
	}, true, nil
}
