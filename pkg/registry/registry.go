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

package registry

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultPartition = "default"
)

// DeviceRegistry is the concrete implementation of the registry.Manager.
type DeviceRegistry struct {
	db     db.Service
	logger logger.Logger
}

// NewDeviceRegistry creates a new, authoritative device registry.
func NewDeviceRegistry(database db.Service, log logger.Logger) *DeviceRegistry {
	return &DeviceRegistry{
		db:     database,
		logger: log,
	}
}

// ProcessDeviceUpdate is the single entry point for a new device discovery event.
func (r *DeviceRegistry) ProcessDeviceUpdate(ctx context.Context, update *models.DeviceUpdate) error {
	return r.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update})
}

// ProcessBatchDeviceUpdates processes a batch of discovery events (DeviceUpdates).
// It publishes them directly to the device_updates stream for the materialized view.
func (r *DeviceRegistry) ProcessBatchDeviceUpdates(ctx context.Context, updates []*models.DeviceUpdate) error {
	if len(updates) == 0 {
		return nil
	}

	processingStart := time.Now()
	defer func() {
		r.logger.Debug().
			Dur("duration", time.Since(processingStart)).
			Int("update_count", len(updates)).
			Msg("ProcessBatchDeviceUpdates completed")
	}()

	// Normalize updates to ensure required fields are populated
	for _, u := range updates {
		r.normalizeUpdate(u)
	}

	// Publish directly to the device_updates stream
	if err := r.db.PublishBatchDeviceUpdates(ctx, updates); err != nil {
		return fmt.Errorf("failed to publish device updates: %w", err)
	}

	r.logger.Info().
		Int("update_count", len(updates)).
		Msg("Successfully processed and published device updates")

	return nil
}

// normalizeUpdate ensures a DeviceUpdate has the minimum required information.
func (r *DeviceRegistry) normalizeUpdate(update *models.DeviceUpdate) {
	if update.IP == "" {
		r.logger.Debug().Msg("Skipping update with no IP address")
		return // Or handle error
	}

	// If DeviceID is completely empty, generate one from Partition and IP
	if update.DeviceID == "" {
		if update.Partition == "" {
			update.Partition = defaultPartition
		}

		update.DeviceID = fmt.Sprintf("%s:%s", update.Partition, update.IP)

		r.logger.Debug().
			Str("device_id", update.DeviceID).
			Msg("Generated DeviceID for update with empty DeviceID")
	} else {
		// Extract partition from DeviceID if possible
		partition := extractPartitionFromDeviceID(update.DeviceID)

		// If partition is empty, set it from extracted partition or default
		if update.Partition == "" {
			update.Partition = partition
		}

		// If DeviceID was malformed (no colon) but we have an IP, fix it
		if !strings.Contains(update.DeviceID, ":") && update.IP != "" {
			update.DeviceID = fmt.Sprintf("%s:%s", update.Partition, update.IP)
		}
	}

	if update.Source == "" {
		update.Source = "unknown"
	}

	// Self-reported devices are always available by definition
	if update.Source == models.DiscoverySourceSelfReported {
		update.IsAvailable = true
	}

	if update.Timestamp.IsZero() {
		update.Timestamp = time.Now()
	}

	if update.Confidence == 0 {
		update.Confidence = models.GetSourceConfidence(update.Source)
	}
}

func (r *DeviceRegistry) GetDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error) {
	devices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, nil, []string{deviceID})
	if err != nil {
		return nil, fmt.Errorf("failed to get device %s: %w", deviceID, err)
	}

	if len(devices) == 0 {
		return nil, fmt.Errorf("device %s not found", deviceID)
	}

	return devices[0], nil
}

func (r *DeviceRegistry) GetDevicesByIP(ctx context.Context, ip string) ([]*models.UnifiedDevice, error) {
	devices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, []string{ip}, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to get devices by IP %s: %w", ip, err)
	}

	return devices, nil
}

func (r *DeviceRegistry) ListDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error) {
	return r.db.ListUnifiedDevices(ctx, limit, offset)
}

func (r *DeviceRegistry) GetMergedDevice(ctx context.Context, deviceIDOrIP string) (*models.UnifiedDevice, error) {
	device, err := r.GetDevice(ctx, deviceIDOrIP)
	if err == nil {
		return device, nil
	}

	devices, err := r.GetDevicesByIP(ctx, deviceIDOrIP)
	if err != nil {
		return nil, fmt.Errorf("failed to get device by ID or IP %s: %w", deviceIDOrIP, err)
	}

	if len(devices) == 0 {
		return nil, fmt.Errorf("device %s not found", deviceIDOrIP)
	}

	return devices[0], nil
}

func (r *DeviceRegistry) FindRelatedDevices(ctx context.Context, deviceID string) ([]*models.UnifiedDevice, error) {
	primaryDevice, err := r.GetDevice(ctx, deviceID)
	if err != nil {
		return nil, fmt.Errorf("failed to get primary device %s: %w", deviceID, err)
	}

	relatedDevices, err := r.GetDevicesByIP(ctx, primaryDevice.IP)
	if err != nil {
		return nil, fmt.Errorf("failed to get related devices by IP %s: %w", primaryDevice.IP, err)
	}

	finalList := make([]*models.UnifiedDevice, 0)

	for _, dev := range relatedDevices {
		if dev.DeviceID != deviceID {
			finalList = append(finalList, dev)
		}
	}

	return finalList, nil
}

func extractPartitionFromDeviceID(deviceID string) string {
	parts := strings.Split(deviceID, ":")
	if len(parts) >= 2 {
		return parts[0]
	}

	return defaultPartition
}
