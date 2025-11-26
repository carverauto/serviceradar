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
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	// cnpgIdentityCacheTTL is how long resolved identities stay in cache
	cnpgIdentityCacheTTL = 5 * time.Minute
	// cnpgIdentityCacheMaxSize is the maximum number of entries in the cache
	cnpgIdentityCacheMaxSize = 50000
)

// cnpgIdentityResolver resolves device identities using CNPG (unified_devices table)
// instead of the KV store. This eliminates write amplification from the identity publisher.
type cnpgIdentityResolver struct {
	db     db.Service
	logger logger.Logger
	cache  *identityResolverCache
}

// identityResolverCache provides a thread-safe in-memory cache for identity lookups
type identityResolverCache struct {
	mu      sync.RWMutex
	ttl     time.Duration
	maxSize int
	// ipToDeviceID maps IP addresses to canonical device IDs
	ipToDeviceID map[string]identityCacheItem
	// deviceIDToMeta maps device IDs to canonical metadata
	deviceIDToMeta map[string]identityCacheItem
}

type identityCacheItem struct {
	value     interface{}
	expiresAt time.Time
}

func newIdentityResolverCache(ttl time.Duration, maxSize int) *identityResolverCache {
	return &identityResolverCache{
		ttl:            ttl,
		maxSize:        maxSize,
		ipToDeviceID:   make(map[string]identityCacheItem),
		deviceIDToMeta: make(map[string]identityCacheItem),
	}
}

func (c *identityResolverCache) getIPMapping(ip string) (string, bool) {
	c.mu.RLock()
	item, ok := c.ipToDeviceID[ip]
	c.mu.RUnlock()

	if !ok {
		return "", false
	}

	if time.Now().After(item.expiresAt) {
		c.mu.Lock()
		delete(c.ipToDeviceID, ip)
		c.mu.Unlock()
		return "", false
	}

	if deviceID, ok := item.value.(string); ok {
		return deviceID, true
	}
	return "", false
}

func (c *identityResolverCache) setIPMapping(ip, deviceID string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Evict if over capacity (simple strategy: clear oldest 10%)
	if len(c.ipToDeviceID) >= c.maxSize {
		c.evictOldestLocked(c.ipToDeviceID, c.maxSize/10)
	}

	c.ipToDeviceID[ip] = identityCacheItem{
		value:     deviceID,
		expiresAt: time.Now().Add(c.ttl),
	}
}

func (c *identityResolverCache) setDeviceMeta(deviceID string, device *models.UnifiedDevice) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if len(c.deviceIDToMeta) >= c.maxSize {
		c.evictOldestLocked(c.deviceIDToMeta, c.maxSize/10)
	}

	c.deviceIDToMeta[deviceID] = identityCacheItem{
		value:     device,
		expiresAt: time.Now().Add(c.ttl),
	}
}

func (c *identityResolverCache) evictOldestLocked(m map[string]identityCacheItem, count int) {
	// Simple eviction: remove expired entries first, then oldest
	now := time.Now()
	evicted := 0

	for key, item := range m {
		if evicted >= count {
			break
		}
		if now.After(item.expiresAt) {
			delete(m, key)
			evicted++
		}
	}

	// If we haven't evicted enough, just remove random entries
	for key := range m {
		if evicted >= count {
			break
		}
		delete(m, key)
		evicted++
	}
}

// WithCNPGIdentityResolver configures the device registry to use CNPG for identity resolution
// instead of the KV store. This queries unified_devices directly with an in-memory cache.
func WithCNPGIdentityResolver(database db.Service) Option {
	return func(r *DeviceRegistry) {
		if r == nil || database == nil {
			return
		}
		r.cnpgIdentityResolver = &cnpgIdentityResolver{
			db:     database,
			logger: r.logger,
			cache:  newIdentityResolverCache(cnpgIdentityCacheTTL, cnpgIdentityCacheMaxSize),
		}
	}
}

// hydrateCanonical enriches device updates with canonical metadata from CNPG
func (r *cnpgIdentityResolver) hydrateCanonical(ctx context.Context, updates []*models.DeviceUpdate) error {
	if r == nil || r.db == nil || len(updates) == 0 {
		return nil
	}

	// Collect device IDs that need hydration (those with stable identifiers)
	deviceIDs := make([]string, 0, len(updates))
	ips := make([]string, 0, len(updates))

	for _, update := range updates {
		if update == nil {
			continue
		}
		if update.DeviceID != "" {
			deviceIDs = append(deviceIDs, update.DeviceID)
		}
		if update.IP != "" {
			ips = append(ips, update.IP)
		}
	}

	if len(deviceIDs) == 0 && len(ips) == 0 {
		return nil
	}

	// Batch query CNPG for all needed devices
	devices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, ips, deviceIDs)
	if err != nil {
		if r.logger != nil {
			r.logger.Debug().Err(err).Msg("Failed to query unified_devices for canonical hydration")
		}
		return err
	}

	// Build lookup maps
	deviceByID := make(map[string]*models.UnifiedDevice, len(devices))
	deviceByIP := make(map[string]*models.UnifiedDevice, len(devices))

	for _, device := range devices {
		if device == nil {
			continue
		}
		deviceByID[device.DeviceID] = device
		if device.IP != "" {
			deviceByIP[device.IP] = device
		}
		// Update cache
		r.cache.setDeviceMeta(device.DeviceID, device)
		if device.IP != "" {
			r.cache.setIPMapping(device.IP, device.DeviceID)
		}
	}

	// Apply canonical metadata to updates
	hydrated := 0
	for _, update := range updates {
		if update == nil {
			continue
		}

		var device *models.UnifiedDevice

		// Try device ID first, then IP
		if update.DeviceID != "" {
			device = deviceByID[update.DeviceID]
		}
		if device == nil && update.IP != "" {
			device = deviceByIP[update.IP]
		}

		if device == nil {
			continue
		}

		// Apply canonical metadata
		applyCanonicalMetadataFromUnifiedDevice(update, device)
		hydrated++
	}

	if hydrated > 0 && r.logger != nil {
		r.logger.Debug().
			Int("updates_hydrated", hydrated).
			Int("devices_fetched", len(devices)).
			Msg("Applied canonical identifiers from CNPG")
	}

	return nil
}

// resolveCanonicalIPs resolves IP addresses to canonical device IDs using CNPG
func (r *cnpgIdentityResolver) resolveCanonicalIPs(ctx context.Context, ips []string) (map[string]string, error) {
	if r == nil || r.db == nil || len(ips) == 0 {
		return nil, nil
	}

	resolved := make(map[string]string, len(ips))
	uncached := make([]string, 0, len(ips))

	// Check cache first
	for _, ip := range ips {
		ip = strings.TrimSpace(ip)
		if ip == "" {
			continue
		}
		if deviceID, ok := r.cache.getIPMapping(ip); ok {
			resolved[ip] = deviceID
		} else {
			uncached = append(uncached, ip)
		}
	}

	if len(uncached) == 0 {
		return resolved, nil
	}

	// Query CNPG for uncached IPs
	devices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, uncached, nil)
	if err != nil {
		if r.logger != nil {
			r.logger.Debug().Err(err).Int("ips", len(uncached)).Msg("Failed to resolve IPs from CNPG")
		}
		return resolved, err
	}

	// Process results
	for _, device := range devices {
		if device == nil || device.IP == "" || device.DeviceID == "" {
			continue
		}
		resolved[device.IP] = device.DeviceID
		r.cache.setIPMapping(device.IP, device.DeviceID)
		r.cache.setDeviceMeta(device.DeviceID, device)
	}

	return resolved, nil
}

// applyCanonicalMetadataFromUnifiedDevice applies canonical metadata from a unified device to an update
func applyCanonicalMetadataFromUnifiedDevice(update *models.DeviceUpdate, device *models.UnifiedDevice) {
	if update == nil || device == nil {
		return
	}

	// Initialize metadata if needed
	if update.Metadata == nil {
		update.Metadata = make(map[string]string)
	}

	// Set canonical device ID
	if device.DeviceID != "" {
		update.Metadata["canonical_device_id"] = device.DeviceID
	}

	// Set hostname if available and update doesn't have one
	if device.Hostname != nil && device.Hostname.Value != "" {
		if update.Hostname == nil || *update.Hostname == "" {
			hostname := device.Hostname.Value
			update.Hostname = &hostname
		}
		update.Metadata["canonical_hostname"] = device.Hostname.Value
	}

	// Set MAC if available and update doesn't have one
	if device.MAC != nil && device.MAC.Value != "" {
		macUpper := strings.ToUpper(strings.TrimSpace(device.MAC.Value))
		if update.MAC == nil || strings.TrimSpace(*update.MAC) == "" {
			update.MAC = &macUpper
		}
		update.Metadata["mac"] = macUpper
	}

	// Copy metadata fields from unified device
	if device.Metadata != nil && device.Metadata.Value != nil {
		for _, key := range []string{"armis_device_id", "integration_id", "integration_type", "netbox_device_id"} {
			if existing := strings.TrimSpace(update.Metadata[key]); existing != "" {
				continue
			}
			if val, ok := device.Metadata.Value[key]; ok && strings.TrimSpace(val) != "" {
				update.Metadata[key] = strings.TrimSpace(val)
			}
		}
	}
}
