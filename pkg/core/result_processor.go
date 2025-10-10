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
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	maxPortResultsDetailed = 512 // limit detailed port results persisted per host
	maxOpenPortsDetailed   = 256 // limit open ports persisted per host
)

// processHostResults processes host results and creates sweep results
func (s *Server) processHostResults(
	ctx context.Context,
	hosts []models.HostResult,
	pollerID, partition, agentID string,
	now time.Time,
) []*models.DeviceUpdate {
	resultsToStore := make([]*models.DeviceUpdate, 0, len(hosts))

	canonicalByIP := s.lookupCanonicalSweepIdentities(ctx, hosts)

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

		if snapshot, ok := canonicalByIP[host.Host]; ok {
			s.applyCanonicalSnapshotToSweep(result, snapshot)
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

func (s *Server) lookupCanonicalSweepIdentities(ctx context.Context, hosts []models.HostResult) map[string]canonicalSnapshot {
	if len(hosts) == 0 {
		return nil
	}

	uniqueIPs := make([]string, 0, len(hosts))
	seen := make(map[string]struct{}, len(hosts))
	for _, host := range hosts {
		ip := strings.TrimSpace(host.Host)
		if ip == "" {
			continue
		}
		if _, ok := seen[ip]; ok {
			continue
		}
		seen[ip] = struct{}{}
		uniqueIPs = append(uniqueIPs, ip)
	}

	if len(uniqueIPs) == 0 {
		return nil
	}

	var (
		result      = make(map[string]canonicalSnapshot, len(uniqueIPs))
		cacheMisses []string
	)

	if s.canonicalCache != nil {
		hits, misses := s.canonicalCache.getBatch(uniqueIPs)
		for ip, snap := range hits {
			result[ip] = snap
		}
		cacheMisses = misses
	} else {
		cacheMisses = uniqueIPs
	}

	if len(cacheMisses) == 0 || s.DB == nil {
		return result
	}

	const chunkSize = 512

	for i := 0; i < len(cacheMisses); i += chunkSize {
		end := i + chunkSize
		if end > len(cacheMisses) {
			end = len(cacheMisses)
		}

		chunk := cacheMisses[i:end]
		if len(chunk) == 0 {
			continue
		}

		devices, err := s.DB.GetUnifiedDevicesByIPsOrIDs(ctx, chunk, nil)
		if err != nil {
			s.logger.Warn().Err(err).Msg("Failed to fetch canonical devices for sweep hydration")
			continue
		}

		for _, device := range devices {
			if device == nil {
				continue
			}
			ip := strings.TrimSpace(device.IP)
			if ip == "" {
				continue
			}

			snapshot := canonicalSnapshot{
				DeviceID: strings.TrimSpace(device.DeviceID),
			}

			if device.MAC != nil {
				snapshot.MAC = strings.TrimSpace(device.MAC.Value)
			}

			if device.Metadata != nil && device.Metadata.Value != nil {
				snapshot.Metadata = device.Metadata.Value
			}

			if !snapshotHasStrongIdentity(snapshot) {
				continue
			}

			result[ip] = snapshot
			if s.canonicalCache != nil {
				s.canonicalCache.store(ip, snapshot)
			}
		}
	}

	return result
}

func snapshotHasStrongIdentity(snapshot canonicalSnapshot) bool {
	if strings.TrimSpace(snapshot.MAC) != "" {
		return true
	}
	if len(snapshot.Metadata) == 0 {
		return false
	}
	if strings.TrimSpace(snapshot.Metadata["armis_device_id"]) != "" {
		return true
	}
	if strings.TrimSpace(snapshot.Metadata["integration_id"]) != "" {
		return true
	}
	if strings.TrimSpace(snapshot.Metadata["netbox_device_id"]) != "" {
		return true
	}
	return false
}

func (s *Server) applyCanonicalSnapshotToSweep(update *models.DeviceUpdate, snapshot canonicalSnapshot) {
	if update == nil {
		return
	}

	if snapshot.DeviceID != "" {
		update.DeviceID = snapshot.DeviceID
		if update.Metadata == nil {
			update.Metadata = make(map[string]string)
		}
		if strings.TrimSpace(update.Metadata["canonical_device_id"]) == "" {
			update.Metadata["canonical_device_id"] = snapshot.DeviceID
		}
	}

	if snapshot.MAC != "" {
		mac := strings.ToUpper(snapshot.MAC)
		if update.MAC == nil || strings.TrimSpace(*update.MAC) == "" {
			update.MAC = &mac
		}
		if update.Metadata == nil {
			update.Metadata = make(map[string]string)
		}
		if strings.TrimSpace(update.Metadata["mac"]) == "" {
			update.Metadata["mac"] = mac
		}
	}

	if len(snapshot.Metadata) == 0 {
		return
	}

	if update.Metadata == nil {
		update.Metadata = make(map[string]string, len(snapshot.Metadata))
	}

	copyIfEmpty := func(key string) {
		if val, ok := snapshot.Metadata[key]; ok {
			trimmed := strings.TrimSpace(val)
			if trimmed != "" && strings.TrimSpace(update.Metadata[key]) == "" {
				update.Metadata[key] = trimmed
			}
		}
	}

	copyIfEmpty("armis_device_id")
	copyIfEmpty("integration_id")
	copyIfEmpty("integration_type")
	copyIfEmpty("netbox_device_id")
	copyIfEmpty("canonical_partition")
	copyIfEmpty("canonical_metadata_hash")
	copyIfEmpty("canonical_hostname")
}
