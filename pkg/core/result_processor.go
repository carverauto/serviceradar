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

package core

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// processHostResults processes host results and creates sweep results
func (s *Server) processHostResults(
	hosts []models.HostResult, pollerID, partition, agentID string, now time.Time) []*models.DeviceUpdate {
	resultsToStore := make([]*models.DeviceUpdate, 0, len(hosts))

	for _, host := range hosts {
		if host.Host == "" {
			s.logger.Debug().
				Str("poller_id", pollerID).
				Str("partition", partition).
				Str("agent_id", agentID).
				Str("host", host.Host).
				Bool("ip", host.Available).
				Str("source", string(models.DiscoverySourceSweep)).
				Msg("Skipping host with empty host field")

			continue
		}

		metadata := s.buildHostMetadata(&host)

		result := &models.DeviceUpdate{
			AgentID:     agentID,
			PollerID:    pollerID,
			Partition:   partition,
			DeviceID:    fmt.Sprintf("%s:%s", partition, host.Host),
			Source:      models.DiscoverySourceSweep,
			IP:          host.Host,
			MAC:         nil, // HostResult doesn't have MAC field
			Hostname:    nil, // HostResult doesn't have Hostname field
			Timestamp:   now,
			IsAvailable: host.Available,
			Metadata:    metadata,
		}

		resultsToStore = append(resultsToStore, result)
	}

	return resultsToStore
}

// buildHostMetadata builds metadata from host result
func (*Server) buildHostMetadata(host *models.HostResult) map[string]string {
	metadata := make(map[string]string)

	// Add response time if available
	if host.ResponseTime > 0 {
		metadata["response_time_ns"] = fmt.Sprintf("%d", host.ResponseTime.Nanoseconds())
	}

	// Add ICMP status if available
	if host.ICMPStatus != nil {
		metadata["icmp_available"] = fmt.Sprintf("%t", host.ICMPStatus.Available)
		metadata["icmp_round_trip_ns"] = fmt.Sprintf("%d", host.ICMPStatus.RoundTrip.Nanoseconds())
		metadata["icmp_packet_loss"] = fmt.Sprintf("%f", host.ICMPStatus.PacketLoss)
	}

	// Add port results if available
	if len(host.PortResults) > 0 {
		portData, _ := json.Marshal(host.PortResults)
		metadata["port_results"] = string(portData)

		// Also store open ports list for quick reference
		var openPorts []int

		for _, pr := range host.PortResults {
			if pr.Available {
				openPorts = append(openPorts, pr.Port)
			}
		}

		if len(openPorts) > 0 {
			openPortsData, _ := json.Marshal(openPorts)
			metadata["open_ports"] = string(openPortsData)
		}
	}

	return metadata
}
