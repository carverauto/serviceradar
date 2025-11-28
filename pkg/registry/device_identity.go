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
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/google/uuid"
)

const (
	// identityResolverCacheTTL is how long resolved identities stay in cache
	identityResolverCacheTTL = 5 * time.Minute
	// identityResolverCacheMaxSize is the maximum number of entries in the cache
	identityResolverCacheMaxSize = 100000

	// Strong identifier types (these can merge devices)
	StrongIdentifierMAC    = "mac"
	StrongIdentifierArmis  = "armis_device_id"
	StrongIdentifierNetbox = "netbox_device_id"

	// Weak identifier types (these create new devices if no strong match)
	WeakIdentifierIP = "ip"
)

// DeviceIdentityResolver resolves device updates to canonical ServiceRadar device IDs.
// It uses a hierarchy of identifiers:
//   - Strong identifiers (MAC, Armis ID, NetBox ID) can merge devices
//   - Weak identifiers (IP) only match if no strong identifiers conflict
//
// When a new device is discovered with no matching identifiers, a new ServiceRadar
// UUID is generated as the canonical device ID.
type DeviceIdentityResolver struct {
	db     db.Service
	logger logger.Logger
	cache  *deviceIdentityCache
}

// deviceIdentityCache provides thread-safe caching for identity lookups
type deviceIdentityCache struct {
	mu      sync.RWMutex
	ttl     time.Duration
	maxSize int

	// Maps strong identifiers to canonical device IDs
	// Key format: "<type>:<value>" e.g., "mac:AA:BB:CC:DD:EE:FF"
	identifierToDeviceID map[string]deviceIdentityCacheEntry

	// Maps IP addresses to canonical device IDs (weak identifier)
	ipToDeviceID map[string]deviceIdentityCacheEntry
}

type deviceIdentityCacheEntry struct {
	deviceID  string
	expiresAt time.Time
}

// NewDeviceIdentityResolver creates a new identity resolver
func NewDeviceIdentityResolver(database db.Service, log logger.Logger) *DeviceIdentityResolver {
	return &DeviceIdentityResolver{
		db:     database,
		logger: log,
		cache: &deviceIdentityCache{
			ttl:                  identityResolverCacheTTL,
			maxSize:              identityResolverCacheMaxSize,
			identifierToDeviceID: make(map[string]deviceIdentityCacheEntry),
			ipToDeviceID:         make(map[string]deviceIdentityCacheEntry),
		},
	}
}

// ResolveDeviceID resolves a device update to a canonical ServiceRadar device ID.
// If an existing device matches the update's identifiers, it returns that device's ID.
// Otherwise, it generates a new ServiceRadar UUID.
//
// Resolution priority:
//  1. Skip service component IDs (serviceradar:poller:*, serviceradar:agent:*)
//  2. Strong identifiers (MAC, Armis ID, NetBox ID) - can merge devices
//  3. Existing device_id if it's already a ServiceRadar UUID
//  4. Weak identifier (IP) - only if no strong identifiers present
//  5. Generate new UUID (for empty IDs or legacy partition:IP format IDs)
func (r *DeviceIdentityResolver) ResolveDeviceID(ctx context.Context, update *models.DeviceUpdate) (string, error) {
	if r == nil || r.db == nil {
		// Fallback to existing behavior if resolver not configured
		return update.DeviceID, nil
	}

	// Skip service component IDs - they use a different identity scheme
	if isServiceDeviceID(update.DeviceID) {
		return update.DeviceID, nil
	}

	// Extract identifiers from update
	identifiers := r.extractIdentifiers(update)
	hasStrongIdentifier := len(identifiers.StrongIDKeys) > 0

	// Check cache first for strong identifiers
	if deviceID := r.checkCacheForStrongIdentifiers(identifiers); deviceID != "" {
		return deviceID, nil
	}

	// Prefer strong identifier matches even when IP differs
	if matches, err := r.findExistingDevicesByStrongIdentifiers(ctx,
		[]*models.DeviceUpdate{update},
		map[*models.DeviceUpdate]*deviceIdentifiers{update: identifiers},
	); err == nil {
		if deviceID := matches[update]; deviceID != "" {
			r.cacheIdentifierMappings(identifiers, deviceID)
			return deviceID, nil
		}
	} else if r.logger != nil {
		r.logger.Debug().Err(err).Msg("Failed strong-identifier lookup")
	}

	// Query database for existing devices matching our identifiers
	existingDeviceID := r.findExistingDevice(ctx, identifiers)
	if existingDeviceID != "" {
		// Cache the mapping for future lookups
		r.cacheIdentifierMappings(identifiers, existingDeviceID)
		return existingDeviceID, nil
	}

	// Check if the update already has a ServiceRadar UUID
	if isServiceRadarUUID(update.DeviceID) {
		r.cacheIdentifierMappings(identifiers, update.DeviceID)
		return update.DeviceID, nil
	}

	// Check cache for weak identifier (IP) when no strong identifiers are present.
	if !hasStrongIdentifier {
		for _, ip := range identifiers.IPs {
			if deviceID := r.cache.getIPMapping(ip); deviceID != "" {
				return deviceID, nil
			}
		}
	}

	// Generate new ServiceRadar UUID for:
	// - Empty device IDs
	// - Legacy partition:IP format IDs (e.g., "default:10.1.2.3")
	newDeviceID := generateServiceRadarDeviceID(update)
	r.cacheIdentifierMappings(identifiers, newDeviceID)

	if r.logger != nil {
		r.logger.Debug().
			Str("new_device_id", newDeviceID).
			Str("old_device_id", update.DeviceID).
			Str("ip", update.IP).
			Str("source", string(update.Source)).
			Msg("Generated new ServiceRadar device ID")
	}

	return newDeviceID, nil
}

// ResolveDeviceIDs resolves a batch of device updates to canonical device IDs.
// This is more efficient than calling ResolveDeviceID for each update.
func (r *DeviceIdentityResolver) ResolveDeviceIDs(ctx context.Context, updates []*models.DeviceUpdate) error {
	if r == nil || r.db == nil || len(updates) == 0 {
		return nil
	}

	// Collect all identifiers that need resolution
	uncachedUpdates := make([]*models.DeviceUpdate, 0, len(updates))
	updateIdentifiers := make(map[*models.DeviceUpdate]*deviceIdentifiers)

	for _, update := range updates {
		if update == nil {
			continue
		}

		// Skip service component IDs - they use a different identity scheme
		if isServiceDeviceID(update.DeviceID) {
			continue
		}

		identifiers := r.extractIdentifiers(update)
		hasStrongIdentifier := len(identifiers.StrongIDKeys) > 0
		updateIdentifiers[update] = identifiers

		// Check cache first
		if deviceID := r.checkCacheForStrongIdentifiers(identifiers); deviceID != "" {
			update.DeviceID = deviceID
			continue
		}

		// Check weak identifier cache when no strong identifiers are present
		if !hasStrongIdentifier && len(identifiers.IPs) > 0 {
			for _, ip := range identifiers.IPs {
				if deviceID := r.cache.getIPMapping(ip); deviceID != "" {
					update.DeviceID = deviceID
					goto nextUpdate
				}
			}
		}

		uncachedUpdates = append(uncachedUpdates, update)

	nextUpdate:
	}

	if len(uncachedUpdates) == 0 {
		return nil
	}

	// Prefer strong identifier matches before falling back to IP-based lookups
	strongMatches, err := r.findExistingDevicesByStrongIdentifiers(ctx, uncachedUpdates, updateIdentifiers)
	if err != nil && r.logger != nil {
		r.logger.Warn().Err(err).Msg("Failed to resolve devices by strong identifiers")
	}

	// Batch query database for existing devices
	existingMappings, err := r.batchFindExistingDevices(ctx, uncachedUpdates, updateIdentifiers)
	if err != nil && r.logger != nil {
		r.logger.Warn().Err(err).Msg("Failed to batch find existing devices")
	}

	// Apply mappings and generate new IDs for unresolved updates
	var generatedCount int
	var existingMatchCount int
	var strongMatchCount int
	var alreadyUUIDCount int
	batchStrongAssignments := make(map[string]string)

	for _, update := range uncachedUpdates {
		identifiers := updateIdentifiers[update]
		oldID := update.DeviceID

		// Check if we found an existing device
		if deviceID, ok := strongMatches[update]; ok && deviceID != "" {
			update.DeviceID = deviceID
			r.cacheIdentifierMappings(identifiers, deviceID)
			recordBatchStrongAssignment(identifiers.StrongIDKeys, deviceID, batchStrongAssignments)
			strongMatchCount++
			continue
		}

		if deviceID, ok := existingMappings[update]; ok && deviceID != "" {
			update.DeviceID = deviceID
			r.cacheIdentifierMappings(identifiers, deviceID)
			recordBatchStrongAssignment(identifiers.StrongIDKeys, deviceID, batchStrongAssignments)
			existingMatchCount++
			continue
		}

		// Honor batch-level strong identifier assignments to keep churned IPs together.
		if deviceID := findBatchStrongAssignment(identifiers.StrongIDKeys, batchStrongAssignments); deviceID != "" {
			update.DeviceID = deviceID
			r.cacheIdentifierMappings(identifiers, deviceID)
			strongMatchCount++
			continue
		}

		// Check if already a ServiceRadar UUID
		if isServiceRadarUUID(update.DeviceID) {
			r.cacheIdentifierMappings(identifiers, update.DeviceID)
			alreadyUUIDCount++
			continue
		}

		// Generate new ServiceRadar UUID for:
		// - Empty device IDs
		// - Legacy partition:IP format IDs (e.g., "default:10.1.2.3")
		newDeviceID := generateServiceRadarDeviceID(update)
		update.DeviceID = newDeviceID
		r.cacheIdentifierMappings(identifiers, newDeviceID)
		recordBatchStrongAssignment(identifiers.StrongIDKeys, newDeviceID, batchStrongAssignments)
		generatedCount++

		if r.logger != nil && generatedCount <= 5 {
			r.logger.Debug().
				Str("new_device_id", newDeviceID).
				Str("old_device_id", oldID).
				Str("ip", update.IP).
				Str("source", string(update.Source)).
				Msg("Generated new ServiceRadar device ID")
		}
	}

	if r.logger != nil && len(uncachedUpdates) > 0 {
		r.logger.Info().
			Int("uncached_updates", len(uncachedUpdates)).
			Int("generated_new_ids", generatedCount).
			Int("existing_matches", existingMatchCount).
			Int("strong_identifier_matches", strongMatchCount).
			Int("already_uuid", alreadyUUIDCount).
			Msg("Device identity resolution completed")
	}

	return nil
}

// deviceIdentifiers holds extracted identifiers from a device update
type deviceIdentifiers struct {
	MAC          string
	ArmisID      string
	NetboxID     string
	IP           string
	IPs          []string
	ExistingID   string
	StrongIDKeys []string // Cache keys for strong identifiers
}

// extractIdentifiers extracts all identifiers from a device update
func (r *DeviceIdentityResolver) extractIdentifiers(update *models.DeviceUpdate) *deviceIdentifiers {
	ids := &deviceIdentifiers{
		IP:         strings.TrimSpace(update.IP),
		ExistingID: strings.TrimSpace(update.DeviceID),
	}

	if update.MAC != nil {
		ids.MAC = normalizeMAC(*update.MAC)
	}

	if update.Metadata != nil {
		if armisID := strings.TrimSpace(update.Metadata["armis_device_id"]); armisID != "" {
			ids.ArmisID = armisID
		}
		if netboxID := strings.TrimSpace(update.Metadata["netbox_device_id"]); netboxID != "" {
			ids.NetboxID = netboxID
		}
		// Also check integration_id for netbox type
		if update.Metadata["integration_type"] == "netbox" {
			if intID := strings.TrimSpace(update.Metadata["integration_id"]); intID != "" {
				ids.NetboxID = intID
			}
		}
	}

	// Collect known IPs (primary plus alternates from metadata)
	if ids.IP != "" {
		ids.IPs = append(ids.IPs, ids.IP)
	}
	if update.Metadata != nil {
		if primary := strings.TrimSpace(update.Metadata["primary_ip"]); primary != "" {
			ids.IPs = append(ids.IPs, primary)
		}
		if all := strings.TrimSpace(update.Metadata["all_ips"]); all != "" {
			for _, raw := range strings.Split(all, ",") {
				if ip := strings.TrimSpace(raw); ip != "" {
					ids.IPs = append(ids.IPs, ip)
				}
			}
		}
	}
	ids.IPs = dedupePreserveOrder(ids.IPs)

	// Build strong ID cache keys
	if ids.MAC != "" {
		ids.StrongIDKeys = append(ids.StrongIDKeys, StrongIdentifierMAC+":"+ids.MAC)
	}
	if ids.ArmisID != "" {
		ids.StrongIDKeys = append(ids.StrongIDKeys, StrongIdentifierArmis+":"+ids.ArmisID)
	}
	if ids.NetboxID != "" {
		ids.StrongIDKeys = append(ids.StrongIDKeys, StrongIdentifierNetbox+":"+ids.NetboxID)
	}

	return ids
}

func deviceMatchesStrongIdentifiers(device *models.UnifiedDevice, ids *deviceIdentifiers) bool {
	if device == nil || ids == nil {
		return false
	}

	if ids.MAC != "" && device.MAC != nil && normalizeMAC(device.MAC.Value) == ids.MAC {
		return true
	}

	meta := map[string]string{}
	if device.Metadata != nil && device.Metadata.Value != nil {
		meta = device.Metadata.Value
	}

	if ids.ArmisID != "" && strings.TrimSpace(meta["armis_device_id"]) == ids.ArmisID {
		return true
	}

	if ids.NetboxID != "" {
		if strings.TrimSpace(meta["integration_id"]) == ids.NetboxID {
			return true
		}
		if strings.TrimSpace(meta["netbox_device_id"]) == ids.NetboxID {
			return true
		}
	}

	return false
}

func unifiedDeviceHasStrongIdentifiers(device *models.UnifiedDevice) bool {
	if device == nil {
		return false
	}

	if device.MAC != nil && strings.TrimSpace(device.MAC.Value) != "" {
		return true
	}

	if device.Metadata == nil || device.Metadata.Value == nil {
		return false
	}

	meta := device.Metadata.Value
	for _, key := range []string{"armis_device_id", "integration_id", "netbox_device_id", "canonical_device_id"} {
		if strings.TrimSpace(meta[key]) != "" {
			return true
		}
	}

	return false
}

// checkCacheForStrongIdentifiers checks the cache for any strong identifier match
func (r *DeviceIdentityResolver) checkCacheForStrongIdentifiers(ids *deviceIdentifiers) string {
	for _, key := range ids.StrongIDKeys {
		if deviceID := r.cache.getStrongIdentifier(key); deviceID != "" {
			return deviceID
		}
	}
	return ""
}

// findExistingDevice queries the database to find an existing device matching the identifiers.
// IMPORTANT: Only returns devices that already have ServiceRadar UUIDs.
// Legacy partition:IP format devices are NOT returned - they will get new ServiceRadar UUIDs.
func (r *DeviceIdentityResolver) findExistingDevice(ctx context.Context, ids *deviceIdentifiers) string {
	hasStrongIdentifier := len(ids.StrongIDKeys) > 0
	if len(ids.IPs) == 0 && ids.IP != "" {
		ids.IPs = []string{ids.IP}
	}

	// Query by IP to get devices that might match
	// The unified_devices table includes MAC in the response
	if len(ids.IPs) > 0 {
		devices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, ids.IPs, nil)
		if err == nil && len(devices) > 0 {
			// Priority 1: Strong identifier match (MAC)
			if ids.MAC != "" {
				for _, device := range devices {
					// Skip legacy IDs - they need migration
					if isLegacyIPBasedID(device.DeviceID) {
						continue
					}
					if device.MAC != nil && normalizeMAC(device.MAC.Value) == ids.MAC {
						return device.DeviceID
					}
				}
			}

			// Priority 2: Strong identifier match (Armis ID)
			if ids.ArmisID != "" {
				for _, device := range devices {
					// Skip legacy IDs - they need migration
					if isLegacyIPBasedID(device.DeviceID) {
						continue
					}
					if device.Metadata != nil && device.Metadata.Value != nil {
						if device.Metadata.Value["armis_device_id"] == ids.ArmisID {
							return device.DeviceID
						}
					}
				}
			}

			for _, device := range devices {
				// Skip legacy IDs - they need migration
				if isLegacyIPBasedID(device.DeviceID) {
					continue
				}

				if hasStrongIdentifier {
					if deviceMatchesStrongIdentifiers(device, ids) {
						return device.DeviceID
					}
					if unifiedDeviceHasStrongIdentifiers(device) {
						continue
					}
					return device.DeviceID
				}

				return device.DeviceID
			}
		}
	}

	return ""
}

// batchFindExistingDevices queries the database for existing devices matching a batch of updates.
// IMPORTANT: This now only returns matches for devices that already have ServiceRadar UUIDs.
// Legacy partition:IP format IDs are NOT returned - those devices will get new ServiceRadar UUIDs.
// Allows IP fallback only when no strong identifiers are present (useful when the existing device was created by sweep data).
func (r *DeviceIdentityResolver) batchFindExistingDevices(
	ctx context.Context,
	updates []*models.DeviceUpdate,
	updateIdentifiers map[*models.DeviceUpdate]*deviceIdentifiers,
) (map[*models.DeviceUpdate]string, error) {
	result := make(map[*models.DeviceUpdate]string)

	// Collect all MACs and IPs for batch query
	macs := make([]string, 0, len(updates))
	ips := make([]string, 0, len(updates))
	macToUpdate := make(map[string][]*models.DeviceUpdate)
	ipToUpdate := make(map[string][]*models.DeviceUpdate)

	for _, update := range updates {
		ids := updateIdentifiers[update]
		if ids.MAC != "" {
			if _, exists := macToUpdate[ids.MAC]; !exists {
				macs = append(macs, ids.MAC)
			}
			macToUpdate[ids.MAC] = append(macToUpdate[ids.MAC], update)
		}
		for _, ip := range ids.IPs {
			if ip == "" {
				continue
			}
			if _, exists := ipToUpdate[ip]; !exists {
				ips = append(ips, ip)
			}
			ipToUpdate[ip] = append(ipToUpdate[ip], update)
		}
	}

	// Batch query by IPs (includes MAC in the returned devices)
	if len(ips) > 0 || len(macs) > 0 {
		devices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, ips, nil)
		if err != nil {
			return result, fmt.Errorf("batch query failed: %w", err)
		}

		// Build lookup maps from results (only include devices with ServiceRadar UUIDs)
		deviceByMAC := make(map[string]*models.UnifiedDevice)
		deviceByIP := make(map[string]*models.UnifiedDevice)

		for _, device := range devices {
			if device == nil {
				continue
			}
			// Skip devices with legacy partition:IP format IDs
			// These will be migrated to ServiceRadar UUIDs
			if isLegacyIPBasedID(device.DeviceID) {
				continue
			}
			if device.MAC != nil && device.MAC.Value != "" {
				mac := normalizeMAC(device.MAC.Value)
				deviceByMAC[mac] = device
			}
			if device.IP != "" {
				deviceByIP[device.IP] = device
			}
		}

		// Match updates to existing devices (prioritize MAC over IP)
		for _, update := range updates {
			ids := updateIdentifiers[update]
			hasStrongIdentifier := len(ids.StrongIDKeys) > 0

			// Try MAC match first (strong identifier)
			if ids.MAC != "" {
				if device := deviceByMAC[ids.MAC]; device != nil {
					result[update] = device.DeviceID
					continue
				}
			}

			if len(ids.IPs) > 0 {
				for _, ip := range ids.IPs {
					device := deviceByIP[ip]
					if device == nil {
						continue
					}

					if hasStrongIdentifier {
						if deviceMatchesStrongIdentifiers(device, ids) {
							result[update] = device.DeviceID
							break
						}
						if !unifiedDeviceHasStrongIdentifiers(device) {
							result[update] = device.DeviceID
							break
						}
						continue
					}

					result[update] = device.DeviceID
					break
				}
			}
		}
	}

	return result, nil
}

// findExistingDevicesByStrongIdentifiers resolves device IDs using strong identifiers only (MAC, Armis ID, NetBox ID).
// This allows merges even when IPs change or differ between sources.
func (r *DeviceIdentityResolver) findExistingDevicesByStrongIdentifiers(
	ctx context.Context,
	updates []*models.DeviceUpdate,
	updateIdentifiers map[*models.DeviceUpdate]*deviceIdentifiers,
) (map[*models.DeviceUpdate]string, error) {
	matches := make(map[*models.DeviceUpdate]string)
	if r == nil || r.db == nil || len(updates) == 0 {
		return matches, nil
	}

	macSet := make(map[string]struct{})
	armisSet := make(map[string]struct{})
	netboxSet := make(map[string]struct{})

	for _, update := range updates {
		ids := updateIdentifiers[update]
		if ids == nil {
			continue
		}
		if ids.MAC != "" {
			macSet[ids.MAC] = struct{}{}
		}
		if ids.ArmisID != "" {
			armisSet[ids.ArmisID] = struct{}{}
		}
		if ids.NetboxID != "" {
			netboxSet[ids.NetboxID] = struct{}{}
		}
	}

	identifierToDevice := make(map[string]string)

	if len(macSet) > 0 {
		if macMatches, err := r.queryDeviceIDsByMAC(ctx, setToList(macSet)); err != nil {
			return matches, err
		} else {
			for mac, deviceID := range macMatches {
				identifierToDevice[StrongIdentifierMAC+":"+mac] = deviceID
			}
		}
	}

	if len(armisSet) > 0 {
		if armisMatches, err := r.queryDeviceIDsByArmisID(ctx, setToList(armisSet)); err != nil {
			return matches, err
		} else {
			for armisID, deviceID := range armisMatches {
				identifierToDevice[StrongIdentifierArmis+":"+armisID] = deviceID
			}
		}
	}

	if len(netboxSet) > 0 {
		if netboxMatches, err := r.queryDeviceIDsByNetboxID(ctx, setToList(netboxSet)); err != nil {
			return matches, err
		} else {
			for netboxID, deviceID := range netboxMatches {
				identifierToDevice[StrongIdentifierNetbox+":"+netboxID] = deviceID
			}
		}
	}

	for _, update := range updates {
		ids := updateIdentifiers[update]
		if ids == nil {
			continue
		}

		if ids.MAC != "" {
			if deviceID := identifierToDevice[StrongIdentifierMAC+":"+ids.MAC]; deviceID != "" {
				matches[update] = deviceID
				continue
			}
		}

		if ids.ArmisID != "" {
			if deviceID := identifierToDevice[StrongIdentifierArmis+":"+ids.ArmisID]; deviceID != "" {
				matches[update] = deviceID
				continue
			}
		}

		if ids.NetboxID != "" {
			if deviceID := identifierToDevice[StrongIdentifierNetbox+":"+ids.NetboxID]; deviceID != "" {
				matches[update] = deviceID
			}
		}
	}

	return matches, nil
}

// cacheIdentifierMappings caches all identifier → deviceID mappings
func (r *DeviceIdentityResolver) cacheIdentifierMappings(ids *deviceIdentifiers, deviceID string) {
	if deviceID == "" {
		return
	}

	// Cache strong identifiers
	for _, key := range ids.StrongIDKeys {
		r.cache.setStrongIdentifier(key, deviceID)
	}

	// Cache IP mapping
	if len(ids.IPs) > 0 {
		for _, ip := range ids.IPs {
			r.cache.setIPMapping(ip, deviceID)
		}
	} else if ids.IP != "" {
		r.cache.setIPMapping(ids.IP, deviceID)
	}
}

func (r *DeviceIdentityResolver) queryDeviceIDsByMAC(ctx context.Context, macs []string) (map[string]string, error) {
	if len(macs) == 0 || r == nil || r.db == nil {
		return nil, nil
	}

	const query = `
SELECT DISTINCT ON (mac) mac, device_id
FROM unified_devices
WHERE mac = ANY($1)
  AND device_id LIKE 'sr:%'
  AND (metadata->>'_merged_into' IS NULL OR metadata->>'_merged_into' = '' OR metadata->>'_merged_into' = device_id)
  AND COALESCE(lower(metadata->>'_deleted'),'false') <> 'true'
  AND COALESCE(lower(metadata->>'deleted'),'false') <> 'true'
ORDER BY mac, last_seen DESC`

	rows, err := r.db.ExecuteQuery(ctx, query, macs)
	if err != nil {
		return nil, err
	}

	result := make(map[string]string, len(rows))
	for _, row := range rows {
		rawMAC, _ := row["mac"].(string)
		deviceID, _ := row["device_id"].(string)
		deviceID = strings.TrimSpace(deviceID)
		if rawMAC == "" || deviceID == "" || isLegacyIPBasedID(deviceID) {
			continue
		}
		result[normalizeMAC(rawMAC)] = deviceID
	}

	return result, nil
}

func (r *DeviceIdentityResolver) queryDeviceIDsByArmisID(ctx context.Context, armisIDs []string) (map[string]string, error) {
	if len(armisIDs) == 0 || r == nil || r.db == nil {
		return nil, nil
	}

	const query = `
SELECT DISTINCT ON (metadata->>'armis_device_id') metadata->>'armis_device_id' AS armis_id, device_id
FROM unified_devices
WHERE metadata ? 'armis_device_id'
  AND metadata->>'armis_device_id' = ANY($1)
  AND device_id LIKE 'sr:%'
  AND (metadata->>'_merged_into' IS NULL OR metadata->>'_merged_into' = '' OR metadata->>'_merged_into' = device_id)
  AND COALESCE(lower(metadata->>'_deleted'),'false') <> 'true'
  AND COALESCE(lower(metadata->>'deleted'),'false') <> 'true'
ORDER BY metadata->>'armis_device_id', last_seen DESC`

	rows, err := r.db.ExecuteQuery(ctx, query, armisIDs)
	if err != nil {
		return nil, err
	}

	result := make(map[string]string, len(rows))
	for _, row := range rows {
		rawID, _ := row["armis_id"].(string)
		deviceID, _ := row["device_id"].(string)
		rawID = strings.TrimSpace(rawID)
		deviceID = strings.TrimSpace(deviceID)
		if rawID == "" || deviceID == "" || isLegacyIPBasedID(deviceID) {
			continue
		}
		result[rawID] = deviceID
	}

	return result, nil
}

func (r *DeviceIdentityResolver) queryDeviceIDsByNetboxID(ctx context.Context, netboxIDs []string) (map[string]string, error) {
	if len(netboxIDs) == 0 || r == nil || r.db == nil {
		return nil, nil
	}

	const query = `
SELECT DISTINCT ON (COALESCE(metadata->>'integration_id', metadata->>'netbox_device_id'))
       COALESCE(metadata->>'integration_id', metadata->>'netbox_device_id') AS netbox_id,
       device_id
FROM unified_devices
WHERE metadata->>'integration_type' = 'netbox'
  AND ((metadata ? 'integration_id' AND metadata->>'integration_id' = ANY($1))
    OR (metadata ? 'netbox_device_id' AND metadata->>'netbox_device_id' = ANY($1)))
  AND device_id LIKE 'sr:%'
  AND (metadata->>'_merged_into' IS NULL OR metadata->>'_merged_into' = '' OR metadata->>'_merged_into' = device_id)
  AND COALESCE(lower(metadata->>'_deleted'),'false') <> 'true'
  AND COALESCE(lower(metadata->>'deleted'),'false') <> 'true'
ORDER BY COALESCE(metadata->>'integration_id', metadata->>'netbox_device_id'), last_seen DESC`

	rows, err := r.db.ExecuteQuery(ctx, query, netboxIDs)
	if err != nil {
		return nil, err
	}

	result := make(map[string]string, len(rows))
	for _, row := range rows {
		rawID, _ := row["netbox_id"].(string)
		deviceID, _ := row["device_id"].(string)
		rawID = strings.TrimSpace(rawID)
		deviceID = strings.TrimSpace(deviceID)
		if rawID == "" || deviceID == "" || isLegacyIPBasedID(deviceID) {
			continue
		}
		result[rawID] = deviceID
	}

	return result, nil
}

// Cache methods

func (c *deviceIdentityCache) getStrongIdentifier(key string) string {
	c.mu.RLock()
	entry, ok := c.identifierToDeviceID[key]
	c.mu.RUnlock()

	if !ok || time.Now().After(entry.expiresAt) {
		return ""
	}
	return entry.deviceID
}

func (c *deviceIdentityCache) setStrongIdentifier(key, deviceID string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if len(c.identifierToDeviceID) >= c.maxSize {
		c.evictOldest(c.identifierToDeviceID, c.maxSize/10)
	}

	c.identifierToDeviceID[key] = deviceIdentityCacheEntry{
		deviceID:  deviceID,
		expiresAt: time.Now().Add(c.ttl),
	}
}

func (c *deviceIdentityCache) getIPMapping(ip string) string {
	c.mu.RLock()
	entry, ok := c.ipToDeviceID[ip]
	c.mu.RUnlock()

	if !ok || time.Now().After(entry.expiresAt) {
		return ""
	}
	return entry.deviceID
}

func (c *deviceIdentityCache) setIPMapping(ip, deviceID string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if len(c.ipToDeviceID) >= c.maxSize {
		c.evictOldest(c.ipToDeviceID, c.maxSize/10)
	}

	c.ipToDeviceID[ip] = deviceIdentityCacheEntry{
		deviceID:  deviceID,
		expiresAt: time.Now().Add(c.ttl),
	}
}

func (c *deviceIdentityCache) evictOldest(m map[string]deviceIdentityCacheEntry, count int) {
	now := time.Now()
	evicted := 0

	// Evict expired entries first
	for key, entry := range m {
		if evicted >= count {
			break
		}
		if now.After(entry.expiresAt) {
			delete(m, key)
			evicted++
		}
	}

	// Evict random entries if needed
	for key := range m {
		if evicted >= count {
			break
		}
		delete(m, key)
		evicted++
	}
}

// Helper functions

// generateServiceRadarDeviceID generates a new ServiceRadar device ID.
// Format: sr:<deterministic-uuid>
// The UUID is deterministic based on the device's identifiers to ensure
// consistency across restarts and multiple resolution attempts.
func generateServiceRadarDeviceID(update *models.DeviceUpdate) string {
	// Create a deterministic seed from available identifiers
	h := sha256.New()
	h.Write([]byte("serviceradar-device-v2:"))

	partition := strings.TrimSpace(update.Partition)
	if partition == "" {
		partition = "default"
	}

	addSeed := func(prefix, value string, seeds *[]string) {
		value = strings.TrimSpace(value)
		if value == "" {
			return
		}
		*seeds = append(*seeds, prefix+":"+value)
	}

	var seeds []string
	if update.Metadata != nil {
		addSeed("armis", update.Metadata["armis_device_id"], &seeds)
		addSeed("integration", update.Metadata["integration_id"], &seeds)
		addSeed("netbox", update.Metadata["netbox_device_id"], &seeds)
	}
	if update.MAC != nil {
		addSeed("mac", normalizeMAC(*update.MAC), &seeds)
	}

	if len(seeds) > 0 {
		_, _ = fmt.Fprintf(h, "partition:%s:", partition)
		for _, seed := range seeds {
			h.Write([]byte(seed))
		}
	} else {
		// Fallback: anchor on IP when no strong identifiers are present.
		ip := strings.TrimSpace(update.IP)
		_, _ = fmt.Fprintf(h, "partition:%s:ip:%s", partition, ip)
	}

	// Add timestamp for uniqueness if no identifiers
	hashBytes := h.Sum(nil)
	if len(hashBytes) < 16 {
		// Fallback to random UUID if hash is too short
		return "sr:" + uuid.New().String()
	}

	// Use first 16 bytes of hash as UUID bytes
	var uuidBytes [16]byte
	copy(uuidBytes[:], hashBytes[:16])

	// Set version (4) and variant (RFC 4122)
	uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x40
	uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80

	return "sr:" + hex.EncodeToString(uuidBytes[:4]) + "-" +
		hex.EncodeToString(uuidBytes[4:6]) + "-" +
		hex.EncodeToString(uuidBytes[6:8]) + "-" +
		hex.EncodeToString(uuidBytes[8:10]) + "-" +
		hex.EncodeToString(uuidBytes[10:16])
}

// isServiceRadarUUID checks if a device ID is a ServiceRadar-generated UUID
func isServiceRadarUUID(deviceID string) bool {
	return strings.HasPrefix(deviceID, "sr:")
}

// isServiceDeviceID checks if a device ID is for a ServiceRadar service component (poller, agent, etc.)
func isServiceDeviceID(deviceID string) bool {
	return strings.HasPrefix(deviceID, "serviceradar:")
}

// isLegacyIPBasedID checks if a device ID looks like a legacy partition:IP format
// These should be converted to ServiceRadar UUIDs
func isLegacyIPBasedID(deviceID string) bool {
	if deviceID == "" {
		return false
	}
	// Skip ServiceRadar UUIDs and service component IDs
	if isServiceRadarUUID(deviceID) || isServiceDeviceID(deviceID) {
		return false
	}
	// Check for partition:IP format (e.g., "default:10.1.2.3")
	parts := strings.SplitN(deviceID, ":", 2)
	if len(parts) != 2 {
		return false
	}
	// Second part should look like an IP address
	ip := parts[1]
	return strings.Count(ip, ".") == 3 || strings.Contains(ip, ":") // IPv4 or IPv6
}

func dedupePreserveOrder(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	out := make([]string, 0, len(values))
	for _, v := range values {
		v = strings.TrimSpace(v)
		if v == "" {
			continue
		}
		if _, ok := seen[v]; ok {
			continue
		}
		seen[v] = struct{}{}
		out = append(out, v)
	}
	return out
}

func setToList(set map[string]struct{}) []string {
	if len(set) == 0 {
		return nil
	}
	out := make([]string, 0, len(set))
	for v := range set {
		out = append(out, v)
	}
	return out
}

func findBatchStrongAssignment(keys []string, assigned map[string]string) string {
	if len(keys) == 0 || len(assigned) == 0 {
		return ""
	}
	for _, k := range keys {
		if deviceID := assigned[k]; deviceID != "" {
			return deviceID
		}
	}
	return ""
}

func recordBatchStrongAssignment(keys []string, deviceID string, assigned map[string]string) {
	if len(keys) == 0 || deviceID == "" || assigned == nil {
		return
	}
	for _, k := range keys {
		if k == "" {
			continue
		}
		if _, exists := assigned[k]; !exists {
			assigned[k] = deviceID
		}
	}
}

// normalizeMAC normalizes a MAC address to uppercase without separators
func normalizeMAC(mac string) string {
	mac = strings.ToUpper(strings.TrimSpace(mac))
	mac = strings.ReplaceAll(mac, ":", "")
	mac = strings.ReplaceAll(mac, "-", "")
	mac = strings.ReplaceAll(mac, ".", "")
	return mac
}

// WithDeviceIdentityResolver configures the device registry to use the new identity resolver
func WithDeviceIdentityResolver(database db.Service) Option {
	return func(r *DeviceRegistry) {
		if r == nil || database == nil {
			return
		}
		r.deviceIdentityResolver = NewDeviceIdentityResolver(database, r.logger)
	}
}
