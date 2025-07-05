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
	"fmt"
	"log"
	"strings"

	"github.com/carverauto/serviceradar/pkg/models"
)

// PublishSweepResult publishes a sweep result to the sweep_results stream
// The materialized view will automatically maintain unified_devices
func (db *DB) PublishSweepResult(ctx context.Context, result *models.SweepResult) error {
	if result == nil {
		return fmt.Errorf("sweep result is nil")
	}

	log.Printf("Publishing sweep result for device %s (IP: %s, Available: %t)", 
		result.DeviceID, result.IP, result.Available)

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO sweep_results (agent_id, poller_id, partition, device_id, discovery_source, ip, mac, hostname, timestamp, available, metadata)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	// Extract partition from device_id (format: "partition:ip")
	parts := strings.Split(result.DeviceID, ":")
	partition := "default"
	if len(parts) >= 2 {
		partition = parts[0]
	}

	if err := batch.Append(
		result.AgentID,
		result.PollerID,
		partition,
		result.DeviceID,
		result.DiscoverySource,
		result.IP,
		result.MAC,
		result.Hostname,
		result.Timestamp,
		result.Available,
		result.Metadata,
	); err != nil {
		if batchErr := batch.Abort(); batchErr != nil {
			return batchErr
		}
		return fmt.Errorf("failed to append sweep result: %w", err)
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to send batch: %w", err)
	}

	return nil
}

// PublishBatchSweepResults publishes multiple sweep results efficiently
// The materialized view will automatically maintain unified_devices
func (db *DB) PublishBatchSweepResults(ctx context.Context, results []*models.SweepResult) error {
	if len(results) == 0 {
		return nil
	}

	log.Printf("Publishing batch of %d sweep results to materialized view pipeline", len(results))

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO sweep_results (agent_id, poller_id, partition, device_id, discovery_source, ip, mac, hostname, timestamp, available, metadata)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	for _, result := range results {
		if result == nil {
			continue
		}

		// Extract partition from device_id (format: "partition:ip")
		parts := strings.Split(result.DeviceID, ":")
		partition := "default"
		if len(parts) >= 2 {
			partition = parts[0]
		}

		if err := batch.Append(
			result.AgentID,
			result.PollerID,
			partition,
			result.DeviceID,
			result.DiscoverySource,
			result.IP,
			result.MAC,
			result.Hostname,
			result.Timestamp,
			result.Available,
			result.Metadata,
		); err != nil {
			log.Printf("Failed to append sweep result for device %s: %v", result.DeviceID, err)
			continue
		}
	}

	if err := batch.Send(); err != nil {
		if batchErr := batch.Abort(); batchErr != nil {
			return fmt.Errorf("failed to abort batch after send error: %w", batchErr)
		}
		return fmt.Errorf("failed to send batch: %w", err)
	}

	log.Printf("Successfully published batch of %d sweep results to materialized view pipeline", len(results))
	return nil
}