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
	"strconv"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	maxPortResultsDetailed = 512 // limit detailed port results persisted per host
	maxOpenPortsDetailed   = 256 // limit open ports persisted per host
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
				Bool("available", host.Available).
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
		addPortMetadata(metadata, host.PortResults)
	}

	return metadata
}

func addPortMetadata(metadata map[string]string, portResults []*models.PortResult) {
	totalPorts := len(portResults)
	metadata["port_result_count"] = strconv.Itoa(totalPorts)

	trimLimit := maxPortResultsDetailed
	if trimLimit <= 0 {
		trimLimit = totalPorts
	}

	truncated := totalPorts > trimLimit
	encodedPorts := portResults
	if truncated {
		encodedPorts = portResults[:trimLimit]
		metadata["port_results_truncated"] = "true"
		metadata["port_results_retained"] = strconv.Itoa(trimLimit)
	} else {
		metadata["port_results_truncated"] = "false"
		metadata["port_results_retained"] = strconv.Itoa(totalPorts)
	}

	if data, err := json.Marshal(encodedPorts); err == nil {
		metadata["port_results"] = string(data)
	} else {
		metadata["port_results_error"] = err.Error()
	}

	var openPorts []int
	for _, pr := range portResults {
		if pr != nil && pr.Available {
			openPorts = append(openPorts, pr.Port)
		}
	}

	if len(openPorts) == 0 {
		return
	}

	metadata["open_port_count"] = strconv.Itoa(len(openPorts))

	openLimit := maxOpenPortsDetailed
	if openLimit <= 0 {
		openLimit = len(openPorts)
	}

	openTruncated := len(openPorts) > openLimit
	if openTruncated {
		metadata["open_ports_truncated"] = "true"
		openPorts = openPorts[:openLimit]
	} else {
		metadata["open_ports_truncated"] = "false"
	}

	if data, err := json.Marshal(openPorts); err == nil {
		metadata["open_ports"] = string(data)
	} else {
		metadata["open_ports_error"] = err.Error()
	}
}
