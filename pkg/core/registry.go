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
	"fmt"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"log"
)

// DeviceRegistry is a concrete implementation of DeviceRegistryService
type DeviceRegistry struct {
	db db.Service
}

// NewDeviceRegistry creates a new device registry instance
func NewDeviceRegistry(database db.Service) *DeviceRegistry {
	return &DeviceRegistry{
		db: database,
	}
}

// ProcessSweepResult processes a sweep result using materialized view approach
func (r *DeviceRegistry) ProcessSweepResult(ctx context.Context, result *models.SweepResult) error {
	if result == nil {
		return fmt.Errorf("sweep result is nil")
	}

	log.Printf("Processing sweep result for device %s (IP: %s, Available: %t) using materialized view pipeline",
		result.DeviceID, result.IP, result.Available)

	// Simply publish to sweep_results - the materialized view handles the rest
	return r.db.PublishSweepResult(ctx, result)
}

// ProcessBatchSweepResults processes multiple sweep results using materialized view approach
// Publishes to sweep_results stream and lets the materialized view handle device reconciliation
func (r *DeviceRegistry) ProcessBatchSweepResults(ctx context.Context, results []*models.SweepResult) error {
	if len(results) == 0 {
		return nil
	}

	log.Printf("Processing batch of %d sweep results using materialized view pipeline", len(results))

	// Simply publish to sweep_results - the materialized view handles the rest
	return r.db.PublishBatchSweepResults(ctx, results)
}

// UpdateDevice processes a device update using materialized view approach  
func (r *DeviceRegistry) UpdateDevice(ctx context.Context, update *models.DeviceUpdate) error {
	if update == nil {
		return fmt.Errorf("device update is nil")
	}

	// Convert device update to sweep result
	result := &models.SweepResult{
		DeviceID:        update.DeviceID,
		IP:              update.IP,
		Available:       update.IsAvailable,
		Timestamp:       update.Timestamp,
		DiscoverySource: string(update.Source),
		AgentID:         update.AgentID,
		PollerID:        update.PollerID,
		Metadata:        update.Metadata,
	}

	if update.Hostname != nil {
		result.Hostname = update.Hostname
	}
	if update.MAC != nil {
		result.MAC = update.MAC
	}

	log.Printf("Processing device update for %s using materialized view pipeline", update.DeviceID)

	// Simply publish to sweep_results - the materialized view handles the rest
	return r.db.PublishSweepResult(ctx, result)
}

// GetDevice retrieves a device by ID
func (r *DeviceRegistry) GetDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error) {
	return r.db.GetUnifiedDevice(ctx, deviceID)
}

// GetDevicesByIP retrieves devices by IP address
func (r *DeviceRegistry) GetDevicesByIP(ctx context.Context, ip string) ([]*models.UnifiedDevice, error) {
	return r.db.GetUnifiedDevicesByIP(ctx, ip)
}

// ListDevices lists devices with pagination
func (r *DeviceRegistry) ListDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error) {
	return r.db.ListUnifiedDevices(ctx, limit, offset)
}

// FindCanonicalDevicesByIPs finds canonical devices for a batch of IPs using materialized view approach
// Returns a map of IP -> canonical UnifiedDevice
func (r *DeviceRegistry) FindCanonicalDevicesByIPs(ctx context.Context, ips []string) (map[string]*models.UnifiedDevice, error) {
	if len(ips) == 0 {
		return make(map[string]*models.UnifiedDevice), nil
	}

	// With materialized view approach, we simply query the current device state
	result := make(map[string]*models.UnifiedDevice)
	
	for _, ip := range ips {
		devices, err := r.db.GetUnifiedDevicesByIP(ctx, ip)
		if err != nil || len(devices) == 0 {
			continue // No device found for this IP, skip without warning
		}
		
		// Take the first device (should be unique due to materialized view)
		result[ip] = devices[0]
	}
	
	return result, nil
}
