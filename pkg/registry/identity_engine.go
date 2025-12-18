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

// Package registry implements the Device Identity and Reconciliation Engine (DIRE).
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
	// IdentityEngineCacheTTL is how long resolved identities stay in cache
	IdentityEngineCacheTTL = 5 * time.Minute
	// IdentityEngineCacheMaxSize is the maximum number of entries in the cache
	IdentityEngineCacheMaxSize = 100000

	// Strong identifier types in priority order (higher priority wins)
	IdentifierTypeArmis       = "armis_device_id"
	IdentifierTypeIntegration = "integration_id"
	IdentifierTypeNetbox      = "netbox_device_id"
	IdentifierTypeMAC         = "mac"

	// Weak identifier (only used when no strong identifiers present)
	IdentifierTypeIP = "ip"
)

// StrongIdentifierPriority defines the priority order for strong identifiers.
// Lower index = higher priority.
//
//nolint:gochecknoglobals // shared configuration constant
var StrongIdentifierPriority = []string{
	IdentifierTypeArmis,
	IdentifierTypeIntegration,
	IdentifierTypeNetbox,
	IdentifierTypeMAC,
}

// IdentityEngine is the single source of truth for device identity resolution.
// It consolidates the four previous resolver systems into one unified engine.
//
// Resolution priority:
//  1. Strong identifiers (armis_device_id > integration_id > netbox_device_id > mac)
//     -> Hash to deterministic sr: UUID
//  2. Existing sr: UUID in update
//     -> Preserve as-is
//  3. IP-only (no strong identifier)
//     -> Lookup existing device by IP, or generate new sr: UUID
//
// The engine relies on the database's unique constraint on device_identifiers
// to prevent duplicate devices. No IP uniqueness constraint - IP is just a
// mutable attribute, not an identity anchor.
type IdentityEngine struct {
	db     db.Service
	logger logger.Logger
	cache  *identityEngineCache
}

// identityEngineCache provides thread-safe caching for identity lookups
type identityEngineCache struct {
	mu      sync.RWMutex
	ttl     time.Duration
	maxSize int

	// Maps strong identifiers to device IDs
	// Key format: "<partition>:<type>:<value>" e.g., "default:armis_device_id:12345"
	strongIDToDeviceID map[string]engineCacheEntry

	// Maps IP addresses to device IDs (weak identifier, lower priority)
	ipToDeviceID map[string]engineCacheEntry
}

type engineCacheEntry struct {
	deviceID  string
	expiresAt time.Time
}

// NewIdentityEngine creates a new unified identity engine
func NewIdentityEngine(database db.Service, log logger.Logger) *IdentityEngine {
	return &IdentityEngine{
		db:     database,
		logger: log,
		cache: &identityEngineCache{
			ttl:                IdentityEngineCacheTTL,
			maxSize:            IdentityEngineCacheMaxSize,
			strongIDToDeviceID: make(map[string]engineCacheEntry),
			ipToDeviceID:       make(map[string]engineCacheEntry),
		},
	}
}

// StrongIdentifiers holds extracted strong identifiers from a device update
type StrongIdentifiers struct {
	ArmisID       string
	IntegrationID string
	NetboxID      string
	MAC           string
	IP            string
	Partition     string

	// CacheKeys are the pre-computed cache keys for strong identifiers
	CacheKeys []string
}

// HasStrongIdentifier returns true if any strong identifier is present
func (s *StrongIdentifiers) HasStrongIdentifier() bool {
	return s.ArmisID != "" || s.IntegrationID != "" || s.NetboxID != "" || s.MAC != ""
}

// HighestPriorityIdentifier returns the identifier type and value with highest priority
func (s *StrongIdentifiers) HighestPriorityIdentifier() (idType, idValue string) {
	if s.ArmisID != "" {
		return IdentifierTypeArmis, s.ArmisID
	}
	if s.IntegrationID != "" {
		return IdentifierTypeIntegration, s.IntegrationID
	}
	if s.NetboxID != "" {
		return IdentifierTypeNetbox, s.NetboxID
	}
	if s.MAC != "" {
		return IdentifierTypeMAC, s.MAC
	}
	return "", ""
}

// ExtractStrongIdentifiers extracts all identifiers from a device update
func (e *IdentityEngine) ExtractStrongIdentifiers(update *models.DeviceUpdate) *StrongIdentifiers {
	ids := &StrongIdentifiers{
		IP:        strings.TrimSpace(update.IP),
		Partition: strings.TrimSpace(update.Partition),
	}

	if ids.Partition == "" {
		ids.Partition = defaultPartition
	}

	// Extract MAC
	if update.MAC != nil {
		ids.MAC = NormalizeMAC(*update.MAC)
	}

	// Extract from metadata
	if update.Metadata != nil {
		if armisID := strings.TrimSpace(update.Metadata["armis_device_id"]); armisID != "" {
			ids.ArmisID = armisID
		}
		if netboxID := strings.TrimSpace(update.Metadata["netbox_device_id"]); netboxID != "" {
			ids.NetboxID = netboxID
		}
		// Check integration_id for netbox type
		if update.Metadata["integration_type"] == "netbox" {
			if intID := strings.TrimSpace(update.Metadata["integration_id"]); intID != "" {
				ids.IntegrationID = intID
			}
		} else if intID := strings.TrimSpace(update.Metadata["integration_id"]); intID != "" {
			// Non-netbox integration ID (e.g., armis)
			ids.IntegrationID = intID
		}
	}

	// Build cache keys for strong identifiers
	if ids.ArmisID != "" {
		ids.CacheKeys = append(ids.CacheKeys, strongIdentifierCacheKey(ids.Partition, IdentifierTypeArmis, ids.ArmisID))
	}
	if ids.IntegrationID != "" {
		ids.CacheKeys = append(ids.CacheKeys, strongIdentifierCacheKey(ids.Partition, IdentifierTypeIntegration, ids.IntegrationID))
	}
	if ids.NetboxID != "" {
		ids.CacheKeys = append(ids.CacheKeys, strongIdentifierCacheKey(ids.Partition, IdentifierTypeNetbox, ids.NetboxID))
	}
	if ids.MAC != "" {
		ids.CacheKeys = append(ids.CacheKeys, strongIdentifierCacheKey(ids.Partition, IdentifierTypeMAC, ids.MAC))
	}

	return ids
}

func strongIdentifierCacheKey(partition, idType, idValue string) string {
	partition = strings.TrimSpace(partition)
	if partition == "" {
		partition = defaultPartition
	}
	return partition + ":" + idType + ":" + strings.TrimSpace(idValue)
}

// ResolveDeviceID resolves a device update to a canonical ServiceRadar device ID.
//
// If an existing device matches the update's strong identifiers, it returns that device's ID.
// Otherwise, it generates a new deterministic ServiceRadar UUID based on the identifiers.
//
// Resolution priority:
//  1. Skip service component IDs (serviceradar:poller:*, serviceradar:agent:*)
//  2. Strong identifiers (Armis ID > Integration ID > NetBox ID > MAC) -> deterministic sr: UUID
//  3. Existing sr: device_id if present -> preserve
//  4. IP-only fallback -> lookup or generate
func (e *IdentityEngine) ResolveDeviceID(ctx context.Context, update *models.DeviceUpdate) (string, error) {
	if e == nil || e.db == nil {
		return update.DeviceID, nil
	}

	// Skip service component IDs - they use a different identity scheme
	if IsServiceDeviceID(update.DeviceID) {
		return update.DeviceID, nil
	}

	ids := e.ExtractStrongIdentifiers(update)

	// Step 1: Check cache for strong identifier match
	if deviceID := e.checkCacheForStrongIdentifiers(ids); deviceID != "" {
		return deviceID, nil
	}

	// Step 2: Query device_identifiers table for strong identifier match
	if ids.HasStrongIdentifier() {
		if deviceID := e.lookupByStrongIdentifiers(ctx, ids); deviceID != "" {
			e.cacheIdentifierMappings(ids, deviceID)
			return deviceID, nil
		}
	}

	// Step 3: If update already has a ServiceRadar UUID, preserve it
	if IsServiceRadarUUID(update.DeviceID) {
		e.cacheIdentifierMappings(ids, update.DeviceID)
		return update.DeviceID, nil
	}

	// Step 4: For IP-only devices, check cache and DB
	if !ids.HasStrongIdentifier() && ids.IP != "" {
		if deviceID := e.cache.getIPMapping(ids.IP); deviceID != "" {
			return deviceID, nil
		}
		if deviceID, err := e.lookupByIP(ctx, ids.IP); err == nil && deviceID != "" {
			e.cacheIdentifierMappings(ids, deviceID)
			return deviceID, nil
		}
	}

	// Step 5: Generate new deterministic ServiceRadar UUID
	newDeviceID := e.GenerateDeterministicDeviceID(ids)
	e.cacheIdentifierMappings(ids, newDeviceID)

	if e.logger != nil {
		e.logger.Debug().
			Str("new_device_id", newDeviceID).
			Str("old_device_id", update.DeviceID).
			Str("ip", update.IP).
			Str("source", string(update.Source)).
			Bool("has_strong_id", ids.HasStrongIdentifier()).
			Msg("Generated new ServiceRadar device ID")
	}

	return newDeviceID, nil
}

// ResolveDeviceIDs resolves a batch of device updates to canonical device IDs.
// This is more efficient than calling ResolveDeviceID for each update.
func (e *IdentityEngine) ResolveDeviceIDs(ctx context.Context, updates []*models.DeviceUpdate) error {
	if e == nil || e.db == nil || len(updates) == 0 {
		return nil
	}

	// Collect identifiers for all updates
	uncachedUpdates := make([]*models.DeviceUpdate, 0, len(updates))
	updateIdentifiers := make(map[*models.DeviceUpdate]*StrongIdentifiers)
	batchStrongAssignments := make(map[string]string)

	for _, update := range updates {
		if update == nil {
			continue
		}

		// Skip service component IDs
		if IsServiceDeviceID(update.DeviceID) {
			continue
		}

		ids := e.ExtractStrongIdentifiers(update)
		updateIdentifiers[update] = ids

		// Check cache first
		if deviceID := e.checkCacheForStrongIdentifiers(ids); deviceID != "" {
			update.DeviceID = deviceID
			continue
		}

		// Check IP cache if no strong identifiers
		if !ids.HasStrongIdentifier() && ids.IP != "" {
			if deviceID := e.cache.getIPMapping(ids.IP); deviceID != "" {
				update.DeviceID = deviceID
				continue
			}
		}

		uncachedUpdates = append(uncachedUpdates, update)
	}

	if len(uncachedUpdates) == 0 {
		return nil
	}

	// Batch query for strong identifiers
	strongMatches := e.batchLookupByStrongIdentifiers(ctx, uncachedUpdates, updateIdentifiers)

	// Process results
	var generatedCount, existingCount, strongCount int

	for _, update := range uncachedUpdates {
		ids := updateIdentifiers[update]
		oldID := update.DeviceID

		// Check strong identifier matches
		if deviceID, ok := strongMatches[update]; ok && deviceID != "" {
			update.DeviceID = deviceID
			e.cacheIdentifierMappings(ids, deviceID)
			recordBatchStrongAssignment(ids.CacheKeys, deviceID, batchStrongAssignments)
			strongCount++
			continue
		}

		// Check batch-level strong assignments (for consistency within batch)
		if deviceID := findBatchStrongAssignment(ids.CacheKeys, batchStrongAssignments); deviceID != "" {
			update.DeviceID = deviceID
			e.cacheIdentifierMappings(ids, deviceID)
			strongCount++
			continue
		}

		// Preserve existing ServiceRadar UUID
		if IsServiceRadarUUID(update.DeviceID) {
			e.cacheIdentifierMappings(ids, update.DeviceID)
			existingCount++
			continue
		}

		// Generate new deterministic UUID
		newDeviceID := e.GenerateDeterministicDeviceID(ids)
		update.DeviceID = newDeviceID
		e.cacheIdentifierMappings(ids, newDeviceID)
		recordBatchStrongAssignment(ids.CacheKeys, newDeviceID, batchStrongAssignments)
		generatedCount++

		if e.logger != nil && generatedCount <= 5 {
			e.logger.Debug().
				Str("new_device_id", newDeviceID).
				Str("old_device_id", oldID).
				Str("ip", update.IP).
				Msg("Generated new ServiceRadar device ID")
		}
	}

	if e.logger != nil && len(uncachedUpdates) > 0 {
		e.logger.Info().
			Int("uncached_updates", len(uncachedUpdates)).
			Int("generated_new_ids", generatedCount).
			Int("existing_preserved", existingCount).
			Int("strong_matches", strongCount).
			Msg("Device identity resolution completed")
	}

	return nil
}

// GenerateDeterministicDeviceID generates a deterministic ServiceRadar device ID
// based on the device's strong identifiers. The same identifiers will always
// produce the same UUID.
//
// Format: sr:<uuid>
// The UUID is derived from SHA-256 hash of the identifiers.
func (e *IdentityEngine) GenerateDeterministicDeviceID(ids *StrongIdentifiers) string {
	h := sha256.New()
	h.Write([]byte("serviceradar-device-v3:"))

	partition := ids.Partition
	if partition == "" {
		partition = "default"
	}

	// Use strong identifiers in priority order for deterministic hash
	var seeds []string
	if ids.ArmisID != "" {
		seeds = append(seeds, "armis:"+ids.ArmisID)
	}
	if ids.IntegrationID != "" {
		seeds = append(seeds, "integration:"+ids.IntegrationID)
	}
	if ids.NetboxID != "" {
		seeds = append(seeds, "netbox:"+ids.NetboxID)
	}
	if ids.MAC != "" {
		seeds = append(seeds, "mac:"+ids.MAC)
	}

	switch {
	case len(seeds) > 0:
		// Strong identifiers present - deterministic hash
		_, _ = fmt.Fprintf(h, "partition:%s:", partition)
		for _, seed := range seeds {
			h.Write([]byte(seed))
		}
	case ids.IP != "":
		// IP-only fallback (weak identifier)
		_, _ = fmt.Fprintf(h, "partition:%s:ip:%s", partition, ids.IP)
	default:
		// No identifiers - random UUID
		return "sr:" + uuid.New().String()
	}

	hashBytes := h.Sum(nil)
	if len(hashBytes) < 16 {
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

// lookupByStrongIdentifiers queries the device_identifiers table for a match
func (e *IdentityEngine) lookupByStrongIdentifiers(ctx context.Context, ids *StrongIdentifiers) string {
	if e == nil || e.db == nil {
		return ""
	}

	// Query in priority order
	for _, idType := range StrongIdentifierPriority {
		var idValue string
		switch idType {
		case IdentifierTypeArmis:
			idValue = ids.ArmisID
		case IdentifierTypeIntegration:
			idValue = ids.IntegrationID
		case IdentifierTypeNetbox:
			idValue = ids.NetboxID
		case IdentifierTypeMAC:
			idValue = ids.MAC
		}

		if idValue == "" {
			continue
		}

		deviceID, err := e.db.GetDeviceIDByIdentifier(ctx, idType, idValue, ids.Partition)
		if err != nil {
			continue // Try next identifier type
		}
		if deviceID != "" {
			return deviceID
		}
	}

	return ""
}

// batchLookupByStrongIdentifiers queries device_identifiers for multiple updates
func (e *IdentityEngine) batchLookupByStrongIdentifiers(
	ctx context.Context,
	updates []*models.DeviceUpdate,
	updateIdentifiers map[*models.DeviceUpdate]*StrongIdentifiers,
) map[*models.DeviceUpdate]string {
	matches := make(map[*models.DeviceUpdate]string)

	if e == nil || e.db == nil || len(updates) == 0 {
		return matches
	}

	updatesByPartition := groupUpdatesByPartition(updates, updateIdentifiers)
	for partition, partitionUpdates := range updatesByPartition {
		partitionMatches := e.batchLookupByStrongIdentifiersForPartition(ctx, partition, partitionUpdates, updateIdentifiers)
		for update, deviceID := range partitionMatches {
			matches[update] = deviceID
		}
	}

	return matches
}

func groupUpdatesByPartition(updates []*models.DeviceUpdate, updateIdentifiers map[*models.DeviceUpdate]*StrongIdentifiers) map[string][]*models.DeviceUpdate {
	updatesByPartition := make(map[string][]*models.DeviceUpdate)
	for _, update := range updates {
		ids := updateIdentifiers[update]
		if ids == nil {
			continue
		}

		partition := strings.TrimSpace(ids.Partition)
		if partition == "" {
			partition = defaultPartition
		}

		updatesByPartition[partition] = append(updatesByPartition[partition], update)
	}
	return updatesByPartition
}

func (e *IdentityEngine) batchLookupByStrongIdentifiersForPartition(
	ctx context.Context,
	partition string,
	updates []*models.DeviceUpdate,
	updateIdentifiers map[*models.DeviceUpdate]*StrongIdentifiers,
) map[*models.DeviceUpdate]string {
	matches := make(map[*models.DeviceUpdate]string)
	if e == nil || e.db == nil || len(updates) == 0 {
		return matches
	}

	identifierSets := collectStrongIdentifierSets(updates, updateIdentifiers)
	identifierToDevice := make(map[string]string)

	for _, entry := range []struct {
		idType string
		values map[string]struct{}
	}{
		{IdentifierTypeArmis, identifierSets.armisIDs},
		{IdentifierTypeIntegration, identifierSets.integrationIDs},
		{IdentifierTypeNetbox, identifierSets.netboxIDs},
		{IdentifierTypeMAC, identifierSets.macs},
	} {
		for key, deviceID := range e.batchLookupIdentifierType(ctx, entry.idType, entry.values, partition) {
			identifierToDevice[key] = deviceID
		}
	}

	for _, update := range updates {
		ids := updateIdentifiers[update]
		if ids == nil {
			continue
		}

		for _, key := range ids.CacheKeys {
			if deviceID := identifierToDevice[key]; deviceID != "" {
				matches[update] = deviceID
				break
			}
		}
	}

	return matches
}

type strongIdentifierSets struct {
	armisIDs       map[string]struct{}
	integrationIDs map[string]struct{}
	netboxIDs      map[string]struct{}
	macs           map[string]struct{}
}

func collectStrongIdentifierSets(
	updates []*models.DeviceUpdate,
	updateIdentifiers map[*models.DeviceUpdate]*StrongIdentifiers,
) strongIdentifierSets {
	sets := strongIdentifierSets{
		armisIDs:       make(map[string]struct{}),
		integrationIDs: make(map[string]struct{}),
		netboxIDs:      make(map[string]struct{}),
		macs:           make(map[string]struct{}),
	}

	for _, update := range updates {
		ids := updateIdentifiers[update]
		if ids == nil {
			continue
		}
		if ids.ArmisID != "" {
			sets.armisIDs[ids.ArmisID] = struct{}{}
		}
		if ids.IntegrationID != "" {
			sets.integrationIDs[ids.IntegrationID] = struct{}{}
		}
		if ids.NetboxID != "" {
			sets.netboxIDs[ids.NetboxID] = struct{}{}
		}
		if ids.MAC != "" {
			sets.macs[ids.MAC] = struct{}{}
		}
	}

	return sets
}

func (e *IdentityEngine) batchLookupIdentifierType(
	ctx context.Context,
	identifierType string,
	identifierValues map[string]struct{},
	partition string,
) map[string]string {
	matches := make(map[string]string)
	if e == nil || e.db == nil || identifierType == "" || len(identifierValues) == 0 {
		return matches
	}

	values := make([]string, 0, len(identifierValues))
	for v := range identifierValues {
		values = append(values, v)
	}

	results, err := e.db.BatchGetDeviceIDsByIdentifier(ctx, identifierType, values, partition)
	if err != nil {
		return matches
	}

	for idValue, deviceID := range results {
		if deviceID == "" {
			continue
		}
		matches[strongIdentifierCacheKey(partition, identifierType, idValue)] = deviceID
	}

	return matches
}

// lookupByIP queries ocsf_devices for a device with the given IP
func (e *IdentityEngine) lookupByIP(ctx context.Context, ip string) (string, error) {
	if e == nil || e.db == nil || ip == "" {
		return "", nil
	}

	devices, err := e.db.GetOCSFDevicesByIPsOrIDs(ctx, []string{ip}, nil)
	if err != nil {
		return "", err
	}

	for _, device := range devices {
		if device == nil {
			continue
		}
		// Only return devices with ServiceRadar UUIDs
		if IsServiceRadarUUID(device.UID) {
			return device.UID, nil
		}
	}

	return "", nil
}

// RegisterDeviceIdentifiers inserts the device's identifiers into the device_identifiers table.
// The database's unique constraint prevents duplicate entries.
func (e *IdentityEngine) RegisterDeviceIdentifiers(ctx context.Context, deviceID string, ids *StrongIdentifiers) error {
	if e == nil || e.db == nil || deviceID == "" {
		return nil
	}

	// Insert each strong identifier using models.DeviceIdentifier
	identifiers := make([]*models.DeviceIdentifier, 0, 4)

	partition := ids.Partition
	if partition == "" {
		partition = "default"
	}

	if ids.ArmisID != "" {
		identifiers = append(identifiers, &models.DeviceIdentifier{
			DeviceID:   deviceID,
			IDType:     IdentifierTypeArmis,
			IDValue:    ids.ArmisID,
			Partition:  partition,
			Confidence: "strong",
		})
	}
	if ids.IntegrationID != "" {
		identifiers = append(identifiers, &models.DeviceIdentifier{
			DeviceID:   deviceID,
			IDType:     IdentifierTypeIntegration,
			IDValue:    ids.IntegrationID,
			Partition:  partition,
			Confidence: "strong",
		})
	}
	if ids.NetboxID != "" {
		identifiers = append(identifiers, &models.DeviceIdentifier{
			DeviceID:   deviceID,
			IDType:     IdentifierTypeNetbox,
			IDValue:    ids.NetboxID,
			Partition:  partition,
			Confidence: "strong",
		})
	}
	if ids.MAC != "" {
		identifiers = append(identifiers, &models.DeviceIdentifier{
			DeviceID:   deviceID,
			IDType:     IdentifierTypeMAC,
			IDValue:    ids.MAC,
			Partition:  partition,
			Confidence: "strong",
		})
	}

	if len(identifiers) == 0 {
		return nil
	}

	return e.db.UpsertDeviceIdentifiers(ctx, identifiers)
}

// Cache methods

func (e *IdentityEngine) checkCacheForStrongIdentifiers(ids *StrongIdentifiers) string {
	for _, key := range ids.CacheKeys {
		if deviceID := e.cache.getStrongIdentifier(key); deviceID != "" {
			return deviceID
		}
	}
	return ""
}

func (e *IdentityEngine) cacheIdentifierMappings(ids *StrongIdentifiers, deviceID string) {
	if deviceID == "" {
		return
	}

	// Cache strong identifiers
	for _, key := range ids.CacheKeys {
		e.cache.setStrongIdentifier(key, deviceID)
	}

	// Cache IP mapping
	if ids.IP != "" {
		e.cache.setIPMapping(ids.IP, deviceID)
	}
}

func (c *identityEngineCache) getStrongIdentifier(key string) string {
	c.mu.RLock()
	entry, ok := c.strongIDToDeviceID[key]
	c.mu.RUnlock()

	if !ok || time.Now().After(entry.expiresAt) {
		return ""
	}
	return entry.deviceID
}

func (c *identityEngineCache) setStrongIdentifier(key, deviceID string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if len(c.strongIDToDeviceID) >= c.maxSize {
		c.evictOldest(c.strongIDToDeviceID, c.maxSize/10)
	}

	c.strongIDToDeviceID[key] = engineCacheEntry{
		deviceID:  deviceID,
		expiresAt: time.Now().Add(c.ttl),
	}
}

func (c *identityEngineCache) getIPMapping(ip string) string {
	c.mu.RLock()
	entry, ok := c.ipToDeviceID[ip]
	c.mu.RUnlock()

	if !ok || time.Now().After(entry.expiresAt) {
		return ""
	}
	return entry.deviceID
}

func (c *identityEngineCache) setIPMapping(ip, deviceID string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if len(c.ipToDeviceID) >= c.maxSize {
		c.evictOldest(c.ipToDeviceID, c.maxSize/10)
	}

	c.ipToDeviceID[ip] = engineCacheEntry{
		deviceID:  deviceID,
		expiresAt: time.Now().Add(c.ttl),
	}
}

func (c *identityEngineCache) evictOldest(m map[string]engineCacheEntry, count int) {
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

// IsServiceRadarUUID checks if a device ID is a ServiceRadar-generated UUID
func IsServiceRadarUUID(deviceID string) bool {
	return strings.HasPrefix(deviceID, "sr:")
}

// IsServiceDeviceID checks if a device ID is for a ServiceRadar service component
func IsServiceDeviceID(deviceID string) bool {
	return strings.HasPrefix(deviceID, "serviceradar:")
}

// NormalizeMAC normalizes a MAC address to uppercase without separators
func NormalizeMAC(mac string) string {
	mac = strings.ToUpper(strings.TrimSpace(mac))
	mac = strings.ReplaceAll(mac, ":", "")
	mac = strings.ReplaceAll(mac, "-", "")
	mac = strings.ReplaceAll(mac, ".", "")
	return mac
}

// WithIdentityEngine configures the device registry to use the unified identity engine
func WithIdentityEngine(database db.Service) Option {
	return func(r *DeviceRegistry) {
		if r == nil || database == nil {
			return
		}
		r.identityEngine = NewIdentityEngine(database, r.logger)
	}
}

// isServiceDeviceID checks if a device ID is for a ServiceRadar service component (unexported)
func isServiceDeviceID(deviceID string) bool {
	return strings.HasPrefix(deviceID, "serviceradar:")
}

// isServiceRadarUUID checks if a device ID is a ServiceRadar-generated UUID (unexported)
func isServiceRadarUUID(deviceID string) bool {
	return strings.HasPrefix(deviceID, "sr:")
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

// findBatchStrongAssignment looks up a device ID from batch-level strong identifier assignments
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

// recordBatchStrongAssignment records device ID assignments for strong identifier keys
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
