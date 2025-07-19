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
	"log"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultPartition = "default"
)

// DeviceRegistry is the concrete implementation of the registry.Manager.
type DeviceRegistry struct {
	db db.Service
}

// NewDeviceRegistry creates a new, authoritative device registry.
func NewDeviceRegistry(database db.Service) *DeviceRegistry {
	return &DeviceRegistry{
		db: database,
	}
}

// ProcessDeviceUpdate is the single entry point for a new device discovery event.
func (r *DeviceRegistry) ProcessDeviceUpdate(ctx context.Context, update *models.DeviceUpdate) error {
	return r.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update})
}

// ProcessBatchDeviceUpdates processes a batch of discovery events (DeviceUpdates).
// It converts them to the SweepResult format required by the database's materialized view.
func (r *DeviceRegistry) ProcessBatchDeviceUpdates(ctx context.Context, updates []*models.DeviceUpdate) error {
	if len(updates) == 0 {
		return nil
	}

	processingStart := time.Now()
	defer func() {
		log.Printf("ProcessBatchDeviceUpdates completed in %v for %d updates", time.Since(processingStart), len(updates))
	}()

	// Convert the modern DeviceUpdate model to the legacy SweepResult model
	// because the materialized view is powered by the `sweep_results` stream.
	results := make([]*models.SweepResult, len(updates))

	for i, u := range updates {
		// Normalize first to ensure DeviceID is correct before creating the SweepResult
		r.normalizeUpdate(u)

		hostname := ""
		if u.Hostname != nil {
			hostname = *u.Hostname
		}

		mac := ""
		if u.MAC != nil {
			mac = *u.MAC
		}

		results[i] = &models.SweepResult{
			DeviceID:        u.DeviceID,
			IP:              u.IP,
			Partition:       extractPartitionFromDeviceID(u.DeviceID),
			DiscoverySource: string(u.Source),
			AgentID:         u.AgentID,
			PollerID:        u.PollerID,
			Timestamp:       u.Timestamp,
			Available:       u.IsAvailable,
			Hostname:        &hostname,
			MAC:             &mac,
			Metadata:        u.Metadata,
		}
	}

	// Publish the results to the `sweep_results` stream, which the MV consumes.
	if err := r.db.PublishBatchSweepResults(ctx, results); err != nil {
		return fmt.Errorf("failed to publish device updates as sweep results: %w", err)
	}

	log.Printf("Successfully processed and published %d device updates.", len(updates))

	return nil
}

// ProcessBatchSweepResults now directly calls the database method. It is the
// responsibility of callers to ensure the SweepResult is properly formed.
func (r *DeviceRegistry) ProcessBatchSweepResults(ctx context.Context, results []*models.SweepResult) error {
	if len(results) == 0 {
		return nil
	}

	// For legacy callers, we still normalize before publishing.
	for _, res := range results {
		// A simple normalization for SweepResult
		if res.Partition == "" {
			res.Partition = extractPartitionFromDeviceID(res.DeviceID)
		}

		if res.DeviceID == "" && res.IP != "" {
			res.DeviceID = fmt.Sprintf("%s:%s", res.Partition, res.IP)
		}
	}

	return r.db.PublishBatchSweepResults(ctx, results)
}

// normalizeUpdate ensures a DeviceUpdate has the minimum required information.
func (*DeviceRegistry) normalizeUpdate(update *models.DeviceUpdate) {
	if update.IP == "" {
		log.Printf("Skipping update with no IP address")
		return // Or handle error
	}

	// If DeviceID is completely empty, generate one from Partition and IP
	if update.DeviceID == "" {
		if update.Partition == "" {
			update.Partition = defaultPartition
		}

		update.DeviceID = fmt.Sprintf("%s:%s", update.Partition, update.IP)

		log.Printf("Generated DeviceID %s for update with empty DeviceID", update.DeviceID)
	} else {
		// Extract partition from DeviceID if possible, otherwise default it
		partition := extractPartitionFromDeviceID(update.DeviceID)
		if partition == defaultPartition && update.IP != "" {
			// If DeviceID was not properly formatted, fix it
			update.DeviceID = fmt.Sprintf("%s:%s", partition, update.IP)
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
