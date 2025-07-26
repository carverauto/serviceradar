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

package db

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// PublishDiscoveredInterface publishes a discovered interface to the discovered_interfaces stream
func (db *DB) PublishDiscoveredInterface(ctx context.Context, iface *models.DiscoveredInterface) error {
	// Validate required fields
	if iface.DeviceIP == "" {
		return ErrDeviceIPRequired
	}

	if iface.AgentID == "" {
		return ErrAgentIDRequired
	}

	// Ensure there's a timestamp
	if iface.Timestamp.IsZero() {
		iface.Timestamp = time.Now()
	}

	// Prepare a batch insert
	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO discovered_interfaces (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	// Format IP addresses array to JSON string if needed
	ipAddresses := iface.IPAddresses
	if ipAddresses == nil {
		ipAddresses = []string{}
	}

	// Handle metadata - it's a json.RawMessage in the model
	var metadata map[string]string

	if len(iface.Metadata) > 0 {
		// Try to unmarshal the RawMessage
		if err = json.Unmarshal(iface.Metadata, &metadata); err != nil {
			db.logger.Warn().Err(err).Msg("Unable to parse interface metadata")

			metadata = make(map[string]string)
		}
	} else {
		metadata = make(map[string]string)
	}

	// Convert metadata map to JSON string
	metadataBytes, err := json.Marshal(metadata)
	if err != nil {
		db.logger.Error().Err(err).Msg("Failed to marshal interface metadata")
		return fmt.Errorf("failed to marshal metadata: %w", err)
	}

	metadataStr := string(metadataBytes)

	// Append to batch
	err = batch.Append(
		iface.Timestamp,
		iface.AgentID,
		iface.PollerID,
		iface.DeviceIP,
		iface.DeviceID,
		iface.IfIndex,
		iface.IfName,
		iface.IfDescr,
		iface.IfAlias,
		iface.IfSpeed,
		iface.IfPhysAddress,
		ipAddresses,
		iface.IfAdminStatus,
		iface.IfOperStatus,
		metadataStr,
	)
	if err != nil {
		return fmt.Errorf("failed to append interface data: %w", err)
	}

	// Send the batch
	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to publish interface data: %w", err)
	}

	return nil
}

// PublishTopologyDiscoveryEvent publishes a topology discovery event to the topology_discovery_events stream
func (db *DB) PublishTopologyDiscoveryEvent(ctx context.Context, event *models.TopologyDiscoveryEvent) error {
	// Validate required fields
	if event.LocalDeviceIP == "" {
		return ErrLocalDeviceIPRequired
	}

	if event.AgentID == "" {
		return ErrAgentIDRequired
	}

	if event.ProtocolType == "" {
		return ErrProtocolTypeRequired
	}

	// Ensure there's a timestamp
	if event.Timestamp.IsZero() {
		event.Timestamp = time.Now()
	}

	// Prepare a batch insert
	// The stream `topology_discovery_events` has 18 user-defined columns.
	// The INSERT statement `INSERT INTO topology_discovery_events (* except _tp_time)`
	// means we need to provide values for all 18 columns.
	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO topology_discovery_events (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	// Handle metadata - it's a json.RawMessage in the model
	var metadata map[string]string

	if len(event.Metadata) > 0 {
		if err = json.Unmarshal(event.Metadata, &metadata); err != nil {
			db.logger.Warn().Err(err).Msg("Unable to parse topology event metadata, storing as raw string or empty map")

			// Fallback: try to store raw string if it's a valid JSON string, or empty map
			rawMetaStr := string(event.Metadata)
			if json.Valid(event.Metadata) {
				metadata = map[string]string{"raw_metadata": rawMetaStr}
			} else {
				metadata = make(map[string]string)
			}
		}
	} else {
		metadata = make(map[string]string)
	}

	// Convert metadata map to JSON string
	metadataBytes, err := json.Marshal(metadata)
	if err != nil {
		db.logger.Error().Err(err).Msg("Failed to marshal topology event metadata")
		return fmt.Errorf("failed to marshal metadata: %w", err)
	}

	metadataStr := string(metadataBytes)

	// Append to batch - ensuring all 18 arguments are provided
	err = batch.Append(
		event.Timestamp,              // 1
		event.AgentID,                // 2
		event.PollerID,               // 3
		event.LocalDeviceIP,          // 4
		event.LocalDeviceID,          // 5
		event.LocalIfIndex,           // 6
		event.LocalIfName,            // 7
		event.ProtocolType,           // 8
		event.NeighborChassisID,      // 9
		event.NeighborPortID,         // 10
		event.NeighborPortDescr,      // 11
		event.NeighborSystemName,     // 12
		event.NeighborManagementAddr, // 13
		// BGP specific fields from the model
		event.NeighborBGPRouterID, // 14
		event.NeighborIPAddress,   // 15
		event.NeighborAS,          // 16
		event.BGPSessionState,     // 17
		// Metadata
		metadataStr, // 18
	)
	if err != nil {
		return fmt.Errorf("failed to append topology data: %w", err)
	}

	// Send the batch
	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to publish topology data: %w", err)
	}

	return nil
}

const (
	defaultTimeout   = 30 * time.Second
	defaultBatchSize = 100
)

// PublishBatchDiscoveredInterfaces publishes multiple interfaces in a batch
func (db *DB) PublishBatchDiscoveredInterfaces(ctx context.Context, interfaces []*models.DiscoveredInterface) error {
	if len(interfaces) == 0 {
		return nil
	}

	// Create a batch context with reasonable timeout
	batchCtx, cancel := context.WithTimeout(ctx, defaultTimeout)
	defer cancel()

	// Process in smaller batches to avoid overwhelming the database
	batchSize := defaultBatchSize

	var lastErr error

	for i := 0; i < len(interfaces); i += batchSize {
		end := i + batchSize

		if end > len(interfaces) {
			end = len(interfaces)
		}

		batch := interfaces[i:end]
		for _, iface := range batch {
			if err := db.PublishDiscoveredInterface(batchCtx, iface); err != nil {
				db.logger.Error().
					Err(err).
					Str("interface_name", iface.IfName).
					Int("interface_index", int(iface.IfIndex)).
					Msg("Error publishing interface")

				lastErr = err
			}
		}
	}

	return lastErr
}

// PublishBatchTopologyDiscoveryEvents publishes multiple topology events in a batch
func (db *DB) PublishBatchTopologyDiscoveryEvents(ctx context.Context, events []*models.TopologyDiscoveryEvent) error {
	if len(events) == 0 {
		return nil
	}

	// Create a batch context with reasonable timeout
	batchCtx, cancel := context.WithTimeout(ctx, defaultTimeout)
	defer cancel()

	// Process in smaller batches to avoid overwhelming the database
	batchSize := 100 // Default batch size

	var lastErr error

	for i := 0; i < len(events); i += batchSize {
		end := i + batchSize

		if end > len(events) {
			end = len(events)
		}

		batch := events[i:end]

		for _, event := range batch {
			if err := db.PublishTopologyDiscoveryEvent(batchCtx, event); err != nil {
				db.logger.Error().Err(err).Msg("Error publishing topology event")

				lastErr = err
			}
		}
	}

	return lastErr
}
