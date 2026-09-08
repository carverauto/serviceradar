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
	"github.com/carverauto/serviceradar/go/pkg/scan"
)

type sweepBatchRunner struct {
	sweeper                     *NetworkSweeper
	ctx                         context.Context
	icmpScanner                 scan.Scanner
	tcpScanner                  scan.Scanner
	tcpConnectScanner           scan.Scanner
	tcpStream                   *sweepTargetStream
	tcpConnectStream            *sweepTargetStream
	icmpTargets                 []models.Target
	tcpTargets                  []models.Target
	tcpConnectTargets           []models.Target
	icmpCount                   int
	tcpCount                    int
	tcpConnectCount             int
	ipv4Count                   int
	ipv6Count                   int
	ipv6TCPConnectFallbackCount int
}

func (r *sweepBatchRunner) addTarget(target models.Target) error {
	r.recordRoute(target)

	switch target.Mode {
	case models.ModeICMP:
		r.icmpTargets = append(r.icmpTargets, target)
		r.icmpCount++
		if len(r.icmpTargets) >= defaultTargetBatch {
			if err := r.flushMode("icmp", r.icmpScanner, &r.icmpTargets); err != nil {
				return err
			}
		}
	case models.ModeTCP:
		if r.tcpStream != nil {
			r.tcpCount++

			return r.tcpStream.add(target)
		}

		r.tcpTargets = append(r.tcpTargets, target)
		r.tcpCount++
		if len(r.tcpTargets) >= defaultTargetBatch {
			if err := r.flushMode(scannerProtocolTCP, r.tcpScanner, &r.tcpTargets); err != nil {
				return err
			}
		}
	case models.ModeTCPConnect:
		if r.tcpConnectStream != nil {
			r.tcpConnectCount++

			return r.tcpConnectStream.add(target)
		}

		r.tcpConnectTargets = append(r.tcpConnectTargets, target)
		r.tcpConnectCount++
		if len(r.tcpConnectTargets) >= defaultTargetBatch {
			if err := r.flushMode("tcp_connect", r.tcpConnectScanner, &r.tcpConnectTargets); err != nil {
				return err
			}
		}
	case models.ModeMTR:
		// MTR is handled by the agent's ad-hoc scan path, not the persistent
		// sweeper batch runner.
	}

	return nil
}

func (r *sweepBatchRunner) recordRoute(target models.Target) {
	if target.Metadata == nil {
		return
	}

	switch target.Metadata[metadataAddressFamily] {
	case addressFamilyIPv4:
		r.ipv4Count++
	case addressFamilyIPv6:
		r.ipv6Count++
	}

	if fallback, ok := target.Metadata[metadataIPv6RawSYNFallback].(bool); ok && fallback {
		r.ipv6TCPConnectFallbackCount++
	}
}

func (r *sweepBatchRunner) flushAll() error {
	if err := r.flushMode("icmp", r.icmpScanner, &r.icmpTargets); err != nil {
		return err
	}

	if err := r.flushMode(scannerProtocolTCP, r.tcpScanner, &r.tcpTargets); err != nil {
		return err
	}

	if err := r.flushMode("tcp_connect", r.tcpConnectScanner, &r.tcpConnectTargets); err != nil {
		return err
	}

	if r.tcpStream != nil {
		if err := r.tcpStream.closeAndWait(); err != nil {
			return err
		}
	}

	if r.tcpConnectStream != nil {
		return r.tcpConnectStream.closeAndWait()
	}

	return nil
}

func (r *sweepBatchRunner) closeStreams() {
	if r.tcpStream != nil {
		r.tcpStream.closeOnly()
	}

	if r.tcpConnectStream != nil {
		r.tcpConnectStream.closeOnly()
	}
}

func (r *sweepBatchRunner) flushMode(scanType string, scanner scan.Scanner, targets *[]models.Target) error {
	if len(*targets) == 0 {
		return nil
	}

	if scanner == nil {
		r.sweeper.logger.Warn().
			Str("scanType", scanType).
			Int("targets", len(*targets)).
			Msg("Targets found but scanner is not available, skipping scan batch")
		*targets = (*targets)[:0]

		return nil
	}

	batch := *targets
	*targets = (*targets)[:0]

	return r.sweeper.scanAndProcessBatch(r.ctx, scanner, batch, scanType)
}
