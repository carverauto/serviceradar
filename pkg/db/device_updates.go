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

// Package db pkg/db/device_updates.go
package db

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// PublishDeviceUpdate publishes a single device update to the device_updates stream.
func (db *DB) PublishDeviceUpdate(ctx context.Context, update *models.DeviceUpdate) error {
	return db.PublishBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update})
}

// PublishBatchDeviceUpdates publishes a batch of device updates to the device_updates stream.
func (db *DB) PublishBatchDeviceUpdates(ctx context.Context, updates []*models.DeviceUpdate) error {
	// If buffering is disabled (maxBufferSize = 0), write directly
	if db.maxBufferSize == 0 {
		return db.storeDeviceUpdates(ctx, updates)
	}

	// Add to buffer and check if we need to flush
	db.mu.Lock()
	defer db.mu.Unlock()

	db.deviceUpdateBuffer = append(db.deviceUpdateBuffer, updates...)

	if len(db.deviceUpdateBuffer) >= db.maxBufferSize {
		bufferToFlush := make([]*models.DeviceUpdate, len(db.deviceUpdateBuffer))
		copy(bufferToFlush, db.deviceUpdateBuffer)
		db.deviceUpdateBuffer = db.deviceUpdateBuffer[:0] // Clear buffer

		// Release lock before the potentially slow database operation
		db.mu.Unlock()
		err := db.storeDeviceUpdates(ctx, bufferToFlush)
		db.mu.Lock()

		return err
	}

	return nil
}

// validateAndPrepareUpdate validates a device update and prepares it for storage.
// Returns true if the update is valid and ready for storage, false otherwise.
func validateAndPrepareUpdate(update *models.DeviceUpdate) bool {
	// Validate required fields
	if update.IP == "" {
		log.Printf("Skipping device update with empty IP for poller %s", update.PollerID)
		return false
	}

	if update.AgentID == "" {
		log.Printf("Skipping device update with empty AgentID for IP %s", update.IP)
		return false
	}

	if update.PollerID == "" {
		log.Printf("Skipping device update with empty PollerID for IP %s", update.IP)
		return false
	}

	// Generate device_id if not provided
	if update.DeviceID == "" {
		if update.Partition == "" {
			update.Partition = "default"
		}

		update.DeviceID = fmt.Sprintf("%s:%s", update.Partition, update.IP)
	}

	// Ensure metadata is not nil for map(string, string) column
	if update.Metadata == nil {
		update.Metadata = make(map[string]string)
	}

	// Validate timestamp is within Proton's supported range (1925-2283)
	if update.Timestamp.IsZero() || update.Timestamp.Year() < 1925 || update.Timestamp.Year() > 2283 {
		log.Printf("Invalid timestamp for IP %s: %v, using current time", update.IP, update.Timestamp)
		update.Timestamp = time.Now()
	}

	return true
}

// appendUpdateToBatch appends a device update to the batch.
// Returns true if successful, false otherwise.
func appendUpdateToBatch(batch interface{ Append(...interface{}) error }, update *models.DeviceUpdate) bool {
	err := batch.Append(
		update.DeviceID,
		update.IP,
		string(update.Source),
		update.AgentID,
		update.PollerID,
		update.Partition,
		update.Timestamp,
		update.Hostname,
		update.MAC,
		update.Metadata,
		update.IsAvailable,
		update.Confidence,
	)

	if err != nil {
		log.Printf("Failed to append device update for IP %s: %v", update.IP, err)
		return false
	}

	return true
}

// storeDeviceUpdates stores device updates in the device_updates stream.
func (db *DB) storeDeviceUpdates(ctx context.Context, updates []*models.DeviceUpdate) error {
	if len(updates) == 0 {
		return nil
	}

	log.Printf("DEBUG [database]: storeDeviceUpdates called with %d updates", len(updates))

	batch, err := db.Conn.PrepareBatch(ctx,
		"INSERT INTO device_updates (device_id, ip, source, agent_id, poller_id, "+
			"partition, timestamp, hostname, mac, metadata, is_available, confidence)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	var successfulAppends int

	for i, update := range updates {
		log.Printf("DEBUG [database]: Storing DeviceUpdate %d: IP: %s, DeviceID: %s, "+
			"Source: %s, Partition: %s",
			i+1, update.IP, update.DeviceID, update.Source, update.Partition)

		// Skip invalid updates
		if !validateAndPrepareUpdate(update) {
			continue
		}

		// Append to batch
		if appendUpdateToBatch(batch, update) {
			successfulAppends++
		}
	}

	// Only send the batch if we have successful appends
	if successfulAppends > 0 {
		if err := batch.Send(); err != nil {
			return fmt.Errorf("failed to send batch: %w", err)
		}

		log.Printf("Successfully stored %d device updates", successfulAppends)
	} else {
		log.Printf("No valid device updates to store, skipping batch send")
	}

	return nil
}
