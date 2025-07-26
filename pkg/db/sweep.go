/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Package db pkg/db/sweep.go
package db

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/carverauto/serviceradar/pkg/models"
)

// StoreSweepHostStates stores sweep host states in the versioned KV stream.
func (db *DB) StoreSweepHostStates(ctx context.Context, states []*models.SweepHostState) error {
	if len(states) == 0 {
		return nil
	}

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO sweep_host_states (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	for _, state := range states {
		// Validate required fields
		if state.HostIP == "" {
			db.logger.Warn().Str("poller_id", state.PollerID).Msg("Skipping sweep host state with empty IP")
			continue
		}

		if state.AgentID == "" {
			db.logger.Warn().Str("host_ip", state.HostIP).Msg("Skipping sweep host state with empty AgentID")
			continue
		}

		if state.PollerID == "" {
			db.logger.Warn().Str("host_ip", state.HostIP).Msg("Skipping sweep host state with empty PollerID")
			continue
		}

		// Convert arrays to JSON strings
		portsScannedBytes, err := json.Marshal(state.TCPPortsScanned)
		if err != nil {
			db.logger.Error().Err(err).Str("host_ip", state.HostIP).Msg("Failed to marshal TCP ports scanned")
			continue
		}

		portsOpenBytes, err := json.Marshal(state.TCPPortsOpen)
		if err != nil {
			db.logger.Error().Err(err).Str("host_ip", state.HostIP).Msg("Failed to marshal TCP ports open")
			continue
		}

		portResultsBytes, err := json.Marshal(state.PortScanResults)
		if err != nil {
			db.logger.Error().Err(err).Str("host_ip", state.HostIP).Msg("Failed to marshal port scan results")
			continue
		}

		metadataBytes, err := json.Marshal(state.Metadata)
		if err != nil {
			db.logger.Error().Err(err).Str("host_ip", state.HostIP).Msg("Failed to marshal metadata")
			continue
		}

		err = batch.Append(
			state.HostIP,
			state.PollerID,
			state.AgentID,
			state.Partition,
			state.NetworkCIDR,
			state.Hostname,
			state.MAC,
			state.ICMPAvailable,
			state.ICMPResponseTime,
			state.ICMPPacketLoss,
			string(portsScannedBytes),
			string(portsOpenBytes),
			string(portResultsBytes),
			state.LastSweepTime,
			state.FirstSeen,
			string(metadataBytes),
		)
		if err != nil {
			db.logger.Error().Err(err).Str("host_ip", state.HostIP).Msg("Failed to append sweep host state")
			continue
		}
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to send batch: %w", err)
	}

	db.logger.Info().Int("count", len(states)).Msg("Successfully stored sweep host states")

	return nil
}

// GetSweepHostStates retrieves the latest sweep host states from the versioned KV stream.
func (db *DB) GetSweepHostStates(ctx context.Context, pollerID string, limit int) ([]*models.SweepHostState, error) {
	query := `
		SELECT 
			host_ip, poller_id, agent_id, partition, network_cidr, hostname, mac,
			icmp_available, icmp_response_time_ns, icmp_packet_loss,
			tcp_ports_scanned, tcp_ports_open, port_scan_results,
			last_sweep_time, first_seen, metadata
		FROM table(sweep_host_states)
		WHERE poller_id = ?
		ORDER BY last_sweep_time DESC
		LIMIT ?
	`

	rows, err := db.Conn.Query(ctx, query, pollerID, limit)
	if err != nil {
		return nil, fmt.Errorf("failed to query sweep host states: %w", err)
	}
	defer rows.Close()

	var states []*models.SweepHostState

	for rows.Next() {
		var state models.SweepHostState

		var portsScannedStr, portsOpenStr, portResultsStr, metadataStr string

		err := rows.Scan(
			&state.HostIP, &state.PollerID, &state.AgentID, &state.Partition,
			&state.NetworkCIDR, &state.Hostname, &state.MAC,
			&state.ICMPAvailable, &state.ICMPResponseTime, &state.ICMPPacketLoss,
			&portsScannedStr, &portsOpenStr, &portResultsStr,
			&state.LastSweepTime, &state.FirstSeen, &metadataStr,
		)
		if err != nil {
			db.logger.Error().Err(err).Msg("Failed to scan sweep host state row")
			continue
		}

		// Unmarshal JSON strings back to Go types
		if portsScannedStr != "" {
			if err := json.Unmarshal([]byte(portsScannedStr), &state.TCPPortsScanned); err != nil {
				db.logger.Warn().Err(err).Str("host_ip", state.HostIP).Msg("Failed to unmarshal TCP ports scanned")
			}
		}

		if portsOpenStr != "" {
			if err := json.Unmarshal([]byte(portsOpenStr), &state.TCPPortsOpen); err != nil {
				db.logger.Warn().Err(err).Str("host_ip", state.HostIP).Msg("Failed to unmarshal TCP ports open")
			}
		}

		if portResultsStr != "" {
			if err := json.Unmarshal([]byte(portResultsStr), &state.PortScanResults); err != nil {
				db.logger.Warn().Err(err).Str("host_ip", state.HostIP).Msg("Failed to unmarshal port scan results")
			}
		}

		if metadataStr != "" {
			if err := json.Unmarshal([]byte(metadataStr), &state.Metadata); err != nil {
				db.logger.Warn().Err(err).Str("host_ip", state.HostIP).Msg("Failed to unmarshal metadata")
			}
		}

		states = append(states, &state)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error reading sweep host states: %w", err)
	}

	return states, nil
}
