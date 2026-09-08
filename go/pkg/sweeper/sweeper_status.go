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

	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan"
)

func (s *NetworkSweeper) GetStatus(ctx context.Context) (*models.SweepSummary, error) {
	s.mu.RLock()
	inProgress := s.sweepInProgress
	cachedSummary := cloneSweepSummary(s.lastSummary)
	s.mu.RUnlock()

	if inProgress && cachedSummary != nil {
		return cachedSummary, nil
	}
	if inProgress {
		return &models.SweepSummary{LastSweep: 0}, nil
	}

	summary, err := s.store.GetSweepSummary(ctx)
	if err != nil {
		return nil, err
	}

	s.mu.RLock()
	lastSweep := s.lastSweep
	s.mu.RUnlock()

	if lastSweep.IsZero() {
		// The store summary is updated as individual scanner results arrive. Do not
		// expose that in-progress timestamp as a completed sweep marker, or the
		// agent push loop can stream partial ICMP/TCP snapshots as final results.
		summary.LastSweep = 0
	} else {
		summary.LastSweep = lastSweep.Unix()
	}

	return summary, nil
}

func cloneSweepSummary(summary *models.SweepSummary) *models.SweepSummary {
	if summary == nil {
		return nil
	}

	clone := *summary
	clone.Ports = append([]models.PortCount(nil), summary.Ports...)
	clone.Hosts = make([]models.HostResult, 0, len(summary.Hosts))

	for i := range summary.Hosts {
		clone.Hosts = append(clone.Hosts, models.DeepCopyHostResult(&summary.Hosts[i]))
	}

	return &clone
}

// GetResults retrieves sweep results based on filter.
func (s *NetworkSweeper) GetResults(ctx context.Context, filter *models.ResultFilter) ([]models.Result, error) {
	s.logger.Debug().Interface("filter", filter).Msg("Getting results with filter")

	return s.store.GetResults(ctx, filter)
}

// GetConfig returns current sweeper configuration.
func (s *NetworkSweeper) GetConfig() models.Config {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return *s.config
}

// GetScannerStats returns aggregated scanner statistics from the TCP scanner.
// Returns nil if the scanner doesn't support statistics.
func (s *NetworkSweeper) GetScannerStats() *models.ScannerStats {
	s.mu.RLock()
	defer s.mu.RUnlock()

	// Check if the TCP scanner supports stats (SYN scanner does)
	if statsProvider, ok := s.tcpScanner.(scan.StatsProvider); ok {
		scanStats := statsProvider.GetStats()
		addressFamily := scannerStatsAddressFamily(s.tcpScanner)
		scannerPath := scannerStatsPath(s.tcpScanner)

		// Calculate drop rate
		var rxDropRate float64
		if scanStats.PacketsRecv > 0 {
			rxDropRate = float64(scanStats.PacketsDropped) / float64(scanStats.PacketsRecv) * 100.0
		}

		return &models.ScannerStats{
			Protocol:             scannerProtocolTCP,
			AddressFamily:        addressFamily,
			ScannerPath:          scannerPath,
			PacketsSent:          scanStats.PacketsSent,
			PacketsRecv:          scanStats.PacketsRecv,
			PacketsDropped:       scanStats.PacketsDropped,
			RingBlocksProcessed:  scanStats.RingBlocksProcessed,
			RingBlocksDropped:    scanStats.RingBlocksDropped,
			RetriesAttempted:     scanStats.RetriesAttempted,
			RetriesSuccessful:    scanStats.RetriesSuccessful,
			RetriesDropped:       scanStats.RetriesDropped,
			PortsAllocated:       scanStats.PortsAllocated,
			PortsReleased:        scanStats.PortsReleased,
			PortExhaustionCount:  scanStats.PortExhaustion,
			RateLimitDeferrals:   scanStats.RateLimitDeferrals,
			RateLimitWaits:       scanStats.RateLimitWaits,
			SourcePortWaits:      scanStats.SourcePortWaits,
			RateLimitWaitTimeMs:  scanStats.RateLimitWaitNanos / uint64(time.Millisecond),
			SourcePortWaitTimeMs: scanStats.SourcePortWaitNanos / uint64(time.Millisecond),
			RxDropRatePercent:    rxDropRate,
			DialsStarted:         scanStats.DialsStarted,
			DialsSucceeded:       scanStats.DialsSucceeded,
			DialTimeouts:         scanStats.DialTimeouts,
			DialResets:           scanStats.DialResets,
			DialResourceErrors:   scanStats.DialResourceErrors,
			ActiveDials:          scanStats.ActiveDials,
			MaxActiveDials:       scanStats.MaxActiveDials,
			QueueDepth:           scanStats.QueueDepth,
			MaxQueueDepth:        scanStats.MaxQueueDepth,
		}
	}

	return nil
}
