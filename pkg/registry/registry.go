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
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/deviceupdate"
	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	// ErrDeviceNotFound is returned when a device is not found
	ErrDeviceNotFound                 = errors.New("device not found")
	errCNPGQueryUnsupported           = errors.New("cnpg querying is not supported by db.Service")
	errDatabaseNotConfigured          = errors.New("database not configured")
	errIdentityReconciliationDisabled = errors.New("identity reconciliation disabled")
	errSightingNotFound               = errors.New("sighting not found")
	errSightingNotActive              = errors.New("sighting is not active")
	errSightingNotUpdated             = errors.New("sighting not updated")
	errUnableToBuildUpdate            = errors.New("unable to build device update from sighting")
)

const (
	defaultPartition                = "default"
	identitySourceArmis             = "armis_id"
	identitySourceNetbox            = "netbox_id"
	identitySourceMAC               = "mac"
	identitySourceDeviceID          = "device_id"
	integrationTypeNetbox           = "netbox"
	defaultFirstSeenLookupChunkSize = 512
	cnpgIdentifierChunkSize         = 1000
	sweepSightingMergeBatchSize     = 1000
)

// Option configures DeviceRegistry behaviour.
type Option func(*DeviceRegistry)

// DeviceRegistry is the concrete implementation of the registry.Manager.
type DeviceRegistry struct {
	db                       db.Service
	logger                   logger.Logger
	identityPublisher        *identityPublisher
	identityResolver         *identityResolver
	cnpgIdentityResolver     *cnpgIdentityResolver
	deviceIdentityResolver   *DeviceIdentityResolver
	firstSeenLookupChunkSize int
	identityCfg              *models.IdentityReconciliationConfig
	graphWriter              GraphWriter
	reconcileInterval        time.Duration

	mu           sync.RWMutex
	devices      map[string]*DeviceRecord
	devicesByIP  map[string]map[string]*DeviceRecord
	devicesByMAC map[string]map[string]*DeviceRecord
	searchIndex  *TrigramIndex
	capabilities *CapabilityIndex
	matrix       *CapabilityMatrix
}

type cnpgRegistryClient interface {
	UseCNPGReads() bool
	QueryRegistryRows(ctx context.Context, query string, args ...interface{}) (db.Rows, error)
}

// NewDeviceRegistry creates a new, authoritative device registry.
func NewDeviceRegistry(database db.Service, log logger.Logger, opts ...Option) *DeviceRegistry {
	r := &DeviceRegistry{
		db:                       database,
		logger:                   log,
		firstSeenLookupChunkSize: defaultFirstSeenLookupChunkSize,
		devices:                  make(map[string]*DeviceRecord),
		devicesByIP:              make(map[string]map[string]*DeviceRecord),
		devicesByMAC:             make(map[string]map[string]*DeviceRecord),
		searchIndex:              NewTrigramIndex(log),
		capabilities:             NewCapabilityIndex(),
		matrix:                   NewCapabilityMatrix(),
	}
	for _, opt := range opts {
		if opt != nil {
			opt(r)
		}
	}
	return r
}

// WithFirstSeenLookupChunkSize overrides the chunk size used when fetching existing
// first_seen timestamps. Values <= 0 fall back to the default.
func WithFirstSeenLookupChunkSize(size int) Option {
	return func(r *DeviceRegistry) {
		if size > 0 {
			r.firstSeenLookupChunkSize = size
		}
	}
}

// WithGraphWriter wires an optional graph writer (e.g., AGE) for device relationship ingestion.
func WithGraphWriter(writer GraphWriter) Option {
	return func(r *DeviceRegistry) {
		r.graphWriter = writer
	}
}

// WithIdentityReconciliationConfig wires identity reconciliation feature gates and defaults.
func WithIdentityReconciliationConfig(cfg *models.IdentityReconciliationConfig) Option {
	return func(r *DeviceRegistry) {
		r.identityCfg = cfg
	}
}

// WithReconcileInterval configures how often background reconciliation should run.
func WithReconcileInterval(interval time.Duration) Option {
	return func(r *DeviceRegistry) {
		if interval > 0 {
			r.reconcileInterval = interval
		}
	}
}

// ProcessDeviceUpdate is the single entry point for a new device discovery event.
func (r *DeviceRegistry) ProcessDeviceUpdate(ctx context.Context, update *models.DeviceUpdate) error {
	return r.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update})
}

// ProcessBatchDeviceUpdates processes a batch of discovery events (DeviceUpdates).
// It publishes them directly to the device_updates stream for the materialized view.
func (r *DeviceRegistry) ProcessBatchDeviceUpdates(ctx context.Context, updates []*models.DeviceUpdate) error { //nolint:gocyclo
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

	// Normalize and filter out invalid updates (e.g., empty IP)
	valid := make([]*models.DeviceUpdate, 0, len(updates))
	// Batch metrics
	var droppedEmptyIP int
	for _, u := range updates {
		scrubArmisCanonical(u)
		r.normalizeUpdate(u)
		deviceupdate.SanitizeMetadata(u)
		// Allow empty IPs for service components (pollers, agents, checkers)
		// since they're identified by service-aware device IDs
		if u.IP == "" && u.ServiceType == nil {
			r.logger.Warn().Str("device_id", u.DeviceID).Msg("Dropping update with empty IP")
			droppedEmptyIP++
			continue
		}
		valid = append(valid, u)
	}

	if len(valid) == 0 {
		return nil
	}

	if r.identityCfg != nil && r.identityCfg.Enabled {
		var sightings []*models.DeviceUpdate
		var sweepCandidates []*models.DeviceUpdate
		filtered := make([]*models.DeviceUpdate, 0, len(valid))

		for _, u := range valid {
			if u.Source == models.DiscoverySourceSighting {
				filtered = append(filtered, u)
				continue
			}
			if u.Source == models.DiscoverySourceSweep {
				sweepCandidates = append(sweepCandidates, u)
				continue
			}
			if isAuthoritativeServiceUpdate(u) {
				filtered = append(filtered, u)
				continue
			}
			if !hasStrongIdentity(u) {
				sightings = append(sightings, u)
				continue
			}
			filtered = append(filtered, u)
		}

		if len(sweepCandidates) > 0 {
			attached, pending := r.attachSweepSightings(ctx, sweepCandidates)
			if len(attached) > 0 {
				filtered = append(filtered, attached...)
			}
			if len(pending) > 0 {
				sightings = append(sightings, pending...)
			}
		}

		if len(sightings) > 0 {
			if err := r.ingestSightings(ctx, sightings); err != nil {
				r.logger.Warn().Err(err).Int("count", len(sightings)).Msg("Failed to ingest network sightings")
			}
		}

		valid = filtered
		if len(valid) == 0 {
			return nil
		}
	}

	// Resolve device IDs to canonical ServiceRadar UUIDs
	// This ensures devices are identified by stable IDs rather than ephemeral IPs
	if r.deviceIdentityResolver != nil {
		if err := r.deviceIdentityResolver.ResolveDeviceIDs(ctx, valid); err != nil {
			r.logger.Warn().Err(err).Msg("Device identity resolution failed")
		}
	}

	// Hydrate canonical metadata from CNPG (preferred) or KV (legacy fallback)
	if r.cnpgIdentityResolver != nil {
		if err := r.cnpgIdentityResolver.hydrateCanonical(ctx, valid); err != nil {
			r.logger.Warn().Err(err).Msg("CNPG canonical hydration failed")
		}
	} else if r.identityResolver != nil {
		if err := r.identityResolver.hydrateCanonical(ctx, valid); err != nil {
			r.logger.Warn().Err(err).Msg("KV canonical hydration failed")
		}
	}

	// Build identity maps once per batch to avoid per-update DB lookups
	maps, err := r.buildIdentityMaps(ctx, valid)
	if err != nil {
		r.logger.Warn().Err(err).Msg("Failed to build identity maps; proceeding without canonicalization maps")
	}

	// Canonicalize by identity (Armis ID → NetBox ID → MAC) and emit tombstones for old IDs
	canonicalized := make([]*models.DeviceUpdate, 0, len(valid))
	tombstones := make([]*models.DeviceUpdate, 0, 4)
	var canonByArmisID int
	var canonByNetboxID int
	var canonByMAC int
	var canonByDeviceID int
	var tombstoneCount int
	var sweepNoIdentity int

	for _, u := range valid {
		if isAuthoritativeServiceUpdate(u) {
			canonicalized = append(canonicalized, u)
			continue
		}

		origID := u.DeviceID
		canonicalID, via := r.lookupCanonicalFromMaps(u, maps)

		if u.Source == models.DiscoverySourceSweep {
			if !hasStrongIdentity(u) && canonicalID == "" {
				sweepNoIdentity++
			}
		}

		if canonicalID != "" && canonicalID != origID {
			// Rewrite to canonical
			u.DeviceID = canonicalID
			switch via {
			case identitySourceArmis:
				canonByArmisID++
			case identitySourceNetbox:
				canonByNetboxID++
			case identitySourceMAC:
				canonByMAC++
			case identitySourceDeviceID:
				canonByDeviceID++
			}
			// Track current IP as alt for searchability
			if u.Metadata == nil {
				u.Metadata = map[string]string{}
			}
			if u.IP != "" {
				u.Metadata["alt_ip:"+u.IP] = "1"
			}
			// Emit tombstone to hide the old ID in list views
			tombstones = append(tombstones, &models.DeviceUpdate{
				AgentID:     u.AgentID,
				PollerID:    u.PollerID,
				Partition:   u.Partition,
				DeviceID:    origID,
				Source:      u.Source,
				IP:          u.IP,
				Timestamp:   time.Now(),
				IsAvailable: u.IsAvailable,
				Metadata:    map[string]string{"_merged_into": canonicalID},
			})
			tombstoneCount++
		}
		canonicalized = append(canonicalized, u)
	}

	if len(canonicalized) > 0 {
		r.publishIdentityMap(ctx, canonicalized)
	}

	if err := r.annotateFirstSeen(ctx, canonicalized); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to annotate _first_seen metadata")
	}

	droppedStale := 0
	if filtered, dropped, err := r.filterObsoleteUpdates(ctx, canonicalized); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to filter updates against tombstones")
	} else {
		canonicalized = filtered
		droppedStale = dropped
	}

	batch := canonicalized
	if len(tombstones) > 0 {
		batch = append(batch, tombstones...)
	}

	// Wrap the critical section in a transaction to prevent race conditions
	var dbConflicts int
	err = r.db.WithTx(ctx, func(tx db.Service) error {
		// Create a registry instance that uses the transaction-aware DB service
		rTx := *r
		rTx.db = tx

		// Lock the IPs we are about to update to prevent concurrent modifications
		ipsToLock, _ := rTx.collectIPsForConflictCheck(batch)
		if len(ipsToLock) > 0 {
			if err := tx.LockUnifiedDevices(ctx, ipsToLock); err != nil {
				return err
			}
		}

		// Deduplicate batch before publishing
		// This ensures we don't try to create duplicate devices within the same batch
		batch = rTx.deduplicateBatch(batch)

		// Resolve IP conflicts with existing database records
		// This prevents duplicate key constraint violations when a new device has
		// an IP that already belongs to an existing active device
		batch, dbConflicts = rTx.resolveIPConflictsWithDB(ctx, batch)
		
		// Publish directly to the device_updates stream within the transaction
		if err := tx.PublishBatchDeviceUpdates(ctx, batch); err != nil {
			return fmt.Errorf("failed to publish device updates: %w", err)
		}

		return nil
	})

	if err != nil {
		return err
	}

	if dbConflicts > 0 {
		r.logger.Info().
			Int("db_ip_conflicts", dbConflicts).
			Msg("Resolved IP conflicts with existing database records")
	}

	// We use the original canonicalized list for cache update because
	// applyRegistryStore handles the in-memory state. 
	// NOTE: If deduplicateBatch or resolveIPConflictsWithDB converted some updates 
	// to tombstones, the in-memory cache might be slightly out of sync until the 
	// next read, but the DB is consistent. 
	// Ideally, we should use the 'batch' from the Tx, but applyRegistryStore
	// likely expects separate lists. For now, we preserve existing cache behavior 
	// while fixing the DB race condition.
	r.applyRegistryStore(canonicalized, tombstones)

	if r.graphWriter != nil {
		r.graphWriter.WriteGraph(ctx, canonicalized)
	}

	r.logger.Debug().
		Int("incoming_updates", len(updates)).
		Int("valid_updates", len(valid)).
		Int("published_updates", len(batch)).
		Int("dropped_empty_ip", droppedEmptyIP).
		Int("canonicalized_by_armis_id", canonByArmisID).
		Int("canonicalized_by_netbox_id", canonByNetboxID).
		Int("canonicalized_by_mac", canonByMAC).
		Int("canonicalized_by_device_id", canonByDeviceID).
		Int("tombstones_emitted", tombstoneCount).
		Int("dropped_stale_after_delete", droppedStale).
		Int("sweeps_without_identity", sweepNoIdentity).
		Msg("Registry batch processed")

	return nil
}

// deduplicateBatch removes duplicate updates for the same IP within a batch.
// It enforces IP uniqueness to prevent duplicate key constraint violations on
// idx_unified_devices_ip_unique_active. When multiple devices share the same IP,
// the first device becomes canonical and subsequent devices become tombstones.
func (r *DeviceRegistry) deduplicateBatch(updates []*models.DeviceUpdate) []*models.DeviceUpdate {
	if len(updates) <= 1 {
		return updates
	}

	// Track ALL devices by IP to enforce uniqueness constraint.
	// The first device seen for each IP becomes canonical; subsequent devices become tombstones.
	seenByIP := make(map[string]*models.DeviceUpdate)
	result := make([]*models.DeviceUpdate, 0, len(updates))
	tombstones := make([]*models.DeviceUpdate, 0)
	var ipCollisions int

	for _, update := range updates {
		// Skip updates without IP or with service component IDs (they use device_id identity)
		if update.IP == "" || isServiceDeviceID(update.DeviceID) {
			result = append(result, update)
			continue
		}

		// Skip updates that are already tombstones (have _merged_into set)
		if update.Metadata != nil {
			if mergedInto := update.Metadata["_merged_into"]; mergedInto != "" && mergedInto != update.DeviceID {
				result = append(result, update)
				continue
			}
		}

		        if existing, ok := seenByIP[update.IP]; ok {
		            // Check for strong identity mismatch (IP churn)
		            _, existingID := getStrongIdentity(existing)
		            _, updateID := getStrongIdentity(update)
		
		            // If the new update has a strong identity, and it doesn't match the existing one
		            // (either because existing is different strong ID, OR existing is weak/empty),
		            // we treat it as IP churn and split to prevent corruption.
		            if updateID != "" && existingID != updateID {
		                // Different strong identities sharing same IP -> churn.
		                // Do NOT merge. The new update takes the IP.
		                // We must clear the IP from the previous update in this batch to avoid constraint violation.
		
		                r.logger.Info().
		                    Str("ip", update.IP).
		                    Str("old_device", existing.DeviceID).
		                    Str("new_device", update.DeviceID).
		                    Str("old_identity", existingID).
		                    Str("new_identity", updateID).
		                    Msg("IP reassignment detected in batch (strong identity mismatch)")
		
		                // Clear IP from existing (old) update
		                existing.IP = "0.0.0.0" 
		                if existing.Metadata == nil {
		                    existing.Metadata = map[string]string{}
		                }
		                existing.Metadata["_ip_cleared_due_to_churn"] = "true"
		
		                // Update map to point to the new owner
		                seenByIP[update.IP] = update
		                result = append(result, update)
		                continue
		            }
		
		            // IP collision detected - convert this update to a tombstone			ipCollisions++

			r.logger.Debug().
				Str("ip", update.IP).
				Str("canonical_device_id", existing.DeviceID).
				Str("tombstoned_device_id", update.DeviceID).
				Msg("IP collision in batch - converting to tombstone")

			// Merge metadata from the tombstoned device into the canonical device
			// This preserves identity markers (armis_id, netbox_id, etc.)
			r.mergeUpdateMetadata(existing, update)

			// Create tombstone pointing to the canonical device
			tombstone := &models.DeviceUpdate{
				AgentID:     update.AgentID,
				PollerID:    update.PollerID,
				Partition:   update.Partition,
				DeviceID:    update.DeviceID,
				Source:      update.Source,
				IP:          update.IP,
				Timestamp:   update.Timestamp,
				IsAvailable: update.IsAvailable,
				Metadata:    map[string]string{"_merged_into": existing.DeviceID},
			}
			tombstones = append(tombstones, tombstone)
			continue
		}

		seenByIP[update.IP] = update
		result = append(result, update)
	}

	// Record metric for IP collisions
	if ipCollisions > 0 {
		recordBatchIPCollisionMetrics(ipCollisions)
		r.logger.Info().
			Int("ip_collisions", ipCollisions).
			Int("tombstones_created", len(tombstones)).
			Msg("Resolved IP collisions in batch by creating tombstones")
	}

	// Append tombstones after canonical devices to ensure targets exist first
	result = append(result, tombstones...)

	return result
}

// shouldSkipIPConflictCheck returns true if the update should bypass IP conflict checking
func shouldSkipIPConflictCheck(update *models.DeviceUpdate) bool {
	if update.IP == "" || isServiceDeviceID(update.DeviceID) {
		return true
	}
	if update.Metadata != nil {
		if mergedInto := update.Metadata["_merged_into"]; mergedInto != "" && mergedInto != update.DeviceID {
			return true
		}
	}
	return false
}

// createIPClearUpdate creates an update that clears the IP from a device due to IP churn
func createIPClearUpdate(deviceID string, softDelete bool) *models.DeviceUpdate {
	u := &models.DeviceUpdate{
		DeviceID:    deviceID,
		IP:          "0.0.0.0", // Set to 0.0.0.0 for history log
		Timestamp:   time.Now(),
		Source:      models.DiscoverySourceServiceRadar,
		IsAvailable: false,
		Metadata: map[string]string{
			"_ip_cleared_due_to_churn": "true",
		},
	}
	if softDelete {
		u.Metadata["_deleted"] = "true" // Soft-delete to remove from unique index
	}
	return u
}

// createTombstoneUpdate creates a tombstone update pointing to the target device
func createTombstoneUpdate(update *models.DeviceUpdate, targetDeviceID string) *models.DeviceUpdate {
	tombstone := &models.DeviceUpdate{
		AgentID:     update.AgentID,
		PollerID:    update.PollerID,
		Partition:   update.Partition,
		DeviceID:    update.DeviceID,
		Source:      update.Source,
		IP:          update.IP,
		Timestamp:   update.Timestamp,
		IsAvailable: update.IsAvailable,
		Metadata:    map[string]string{"_merged_into": targetDeviceID},
	}
	if update.Metadata != nil {
		for k, v := range update.Metadata {
			if k != "_merged_into" {
				tombstone.Metadata[k] = v
			}
		}
	}
	return tombstone
}

// createMergeUpdate creates an update to merge metadata into an existing device
func createMergeUpdate(update *models.DeviceUpdate, targetDeviceID string) *models.DeviceUpdate {
	return &models.DeviceUpdate{
		AgentID:     update.AgentID,
		PollerID:    update.PollerID,
		Partition:   update.Partition,
		DeviceID:    targetDeviceID,
		Source:      update.Source,
		IP:          update.IP,
		MAC:         update.MAC,
		Hostname:    update.Hostname,
		Timestamp:   update.Timestamp,
		IsAvailable: update.IsAvailable,
		Metadata:    update.Metadata,
	}
}

// resolveIPConflictsWithDB checks the batch against existing database records
// and converts devices to tombstones if their IP already belongs to an existing
// active device with a different device_id. This prevents duplicate key constraint
// violations on idx_unified_devices_ip_unique_active.
func (r *DeviceRegistry) resolveIPConflictsWithDB(ctx context.Context, batch []*models.DeviceUpdate) ([]*models.DeviceUpdate, int) {
	if len(batch) == 0 {
		return batch, 0
	}

	ips, ipToUpdates := r.collectIPsForConflictCheck(batch)
	if len(ips) == 0 {
		return batch, 0
	}

	existingByIP := make(map[string]string)
	if err := r.resolveIPsToCanonical(ctx, ips, existingByIP); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to query existing IPs for conflict resolution")
		return batch, 0
	}

	existingDevicesMap := r.fetchConflictingDevices(ctx, existingByIP, ipToUpdates)

	return r.processDBConflicts(batch, existingByIP, existingDevicesMap)
}

// collectIPsForConflictCheck collects IPs from updates that need conflict checking
func (r *DeviceRegistry) collectIPsForConflictCheck(batch []*models.DeviceUpdate) ([]string, map[string][]*models.DeviceUpdate) {
	ips := make([]string, 0, len(batch))
	ipToUpdates := make(map[string][]*models.DeviceUpdate)

	for _, update := range batch {
		if shouldSkipIPConflictCheck(update) {
			continue
		}
		ips = append(ips, update.IP)
		ipToUpdates[update.IP] = append(ipToUpdates[update.IP], update)
	}
	return ips, ipToUpdates
}

// fetchConflictingDevices fetches full device records for devices that may conflict
func (r *DeviceRegistry) fetchConflictingDevices(ctx context.Context, existingByIP map[string]string, ipToUpdates map[string][]*models.DeviceUpdate) map[string]*models.UnifiedDevice {
	existingDevicesMap := make(map[string]*models.UnifiedDevice)
	conflictingIDs := make([]string, 0, len(existingByIP))

	for ip, id := range existingByIP {
		if updates, ok := ipToUpdates[ip]; ok {
			for _, u := range updates {
				if u.DeviceID != id {
					conflictingIDs = append(conflictingIDs, id)
					break
				}
			}
		}
	}

	if len(conflictingIDs) > 0 {
		devs, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, nil, conflictingIDs)
		if err != nil {
			r.logger.Warn().Err(err).Msg("Failed to fetch conflicting devices for identity check")
		} else {
			for _, d := range devs {
				existingDevicesMap[d.DeviceID] = d
			}
		}
	}
	return existingDevicesMap
}

// processDBConflicts processes batch updates against existing DB records
func (r *DeviceRegistry) processDBConflicts(batch []*models.DeviceUpdate, existingByIP map[string]string, existingDevicesMap map[string]*models.UnifiedDevice) ([]*models.DeviceUpdate, int) {
	var conflicts int
	result := make([]*models.DeviceUpdate, 0, len(batch))
	clears := make([]*models.DeviceUpdate, 0)
	tombstones := make([]*models.DeviceUpdate, 0)

	// Track devices updated in this batch to avoid soft-deleting them
	updatedDevices := make(map[string]bool, len(batch))
	for _, u := range batch {
		if u.DeviceID != "" {
			updatedDevices[u.DeviceID] = true
		}
	}

	for _, update := range batch {
		if shouldSkipIPConflictCheck(update) {
			result = append(result, update)
			continue
		}

		existingDeviceID, exists := existingByIP[update.IP]
		if !exists || existingDeviceID == update.DeviceID {
			result = append(result, update)
			continue
		}

		// Check for strong identity mismatch
		if r.handleIdentityMismatch(update, existingDeviceID, existingDevicesMap, updatedDevices, &clears, &result) {
			continue
		}

		// No identity mismatch - create tombstone
		conflicts++
		r.logger.Debug().
			Str("ip", update.IP).
			Str("existing_device_id", existingDeviceID).
			Str("conflicting_device_id", update.DeviceID).
			Msg("IP conflict with existing database record - converting to tombstone")

		tombstones = append(tombstones, createTombstoneUpdate(update, existingDeviceID))
		result = append(result, createMergeUpdate(update, existingDeviceID))
	}

	if conflicts > 0 {
		recordBatchIPCollisionMetrics(conflicts)
	}

	// Prepend clears to ensure IPs are freed before being reassigned
	finalResult := make([]*models.DeviceUpdate, 0, len(clears)+len(result)+len(tombstones))
	finalResult = append(finalResult, clears...)
	finalResult = append(finalResult, result...)
	finalResult = append(finalResult, tombstones...)

	return finalResult, conflicts
}

// handleIdentityMismatch checks for strong identity mismatch and handles IP churn
// Returns true if identity mismatch was detected and handled
func (r *DeviceRegistry) handleIdentityMismatch(
	update *models.DeviceUpdate,
	existingDeviceID string,
	existingDevicesMap map[string]*models.UnifiedDevice,
	updatedDevices map[string]bool,
	clears *[]*models.DeviceUpdate,
	result *[]*models.DeviceUpdate,
) bool {
	existingDev, ok := existingDevicesMap[existingDeviceID]
	if !ok {
		return false
	}

	existingType, existingID := getStrongIdentityFromDevice(existingDev)
	updateType, updateID := getStrongIdentity(update)

	// If update is weak (no ID), or IDs match, it's not a mismatch -> Merge.
	// If update is strong (ID present) and existing is either different strong or weak, it's a mismatch -> Split.
	if updateID == "" || existingID == updateID {
		return false
	}

	r.logger.Info().
		Str("ip", update.IP).
		Str("old_device", existingDeviceID).
		Str("new_device", update.DeviceID).
		Str("old_identity_type", existingType).
		Str("old_identity", existingID).
		Str("new_identity_type", updateType).
		Str("new_identity", updateID).
		Msg("IP reassignment detected against DB (strong identity mismatch)")

	// Only soft-delete if the device is NOT being updated in this batch
	shouldSoftDelete := !updatedDevices[existingDeviceID]
	*clears = append(*clears, createIPClearUpdate(existingDeviceID, shouldSoftDelete))
	*result = append(*result, update)
	return true
}

func (r *DeviceRegistry) attachSweepSightings(ctx context.Context, sweeps []*models.DeviceUpdate) ([]*models.DeviceUpdate, []*models.DeviceUpdate) {
	if len(sweeps) == 0 {
		return nil, nil
	}

	ips := make([]string, 0, len(sweeps))
	for _, s := range sweeps {
		if s == nil {
			continue
		}
		if ip := strings.TrimSpace(s.IP); ip != "" {
			ips = append(ips, ip)
		}
	}

	resolved := make(map[string]string, len(ips))
	if err := r.resolveIPsToCanonical(ctx, ips, resolved); err != nil {
		r.logger.Warn().Err(err).Int("count", len(ips)).Msg("Failed to resolve sweep IPs for canonical merge")
	}

	attached := make([]*models.DeviceUpdate, 0, len(sweeps))
	pending := make([]*models.DeviceUpdate, 0, len(sweeps))
	merged := 0

	for _, s := range sweeps {
		if s == nil {
			continue
		}

		canonical := strings.TrimSpace(resolved[strings.TrimSpace(s.IP)])
		if canonical == "" {
			pending = append(pending, s)
			continue
		}

		if s.Metadata == nil {
			s.Metadata = map[string]string{}
		}
		s.Metadata["canonical_device_id"] = canonical
		s.DeviceID = canonical
		attached = append(attached, s)
		merged++
	}

	if merged > 0 {
		r.logger.Info().
			Int("merged", merged).
			Int("pending", len(pending)).
			Msg("Merged sweep updates into canonical devices by IP")
	}

	return attached, pending
}

type sightingStore interface {
	StoreNetworkSightings(ctx context.Context, sightings []*models.NetworkSighting) error
}

func (r *DeviceRegistry) ingestSightings(ctx context.Context, updates []*models.DeviceUpdate) error {
	if len(updates) == 0 {
		return nil
	}

	store, ok := r.db.(sightingStore)
	if !ok {
		return nil
	}

	sightings := make([]*models.NetworkSighting, 0, len(updates))

	for _, u := range updates {
		if u == nil {
			continue
		}

		ts := u.Timestamp
		if ts.IsZero() {
			ts = time.Now()
		}

		ttl := r.resolveSightingTTL(u, ts)

		sighting := &models.NetworkSighting{
			Partition:    u.Partition,
			IP:           strings.TrimSpace(u.IP),
			Source:       u.Source,
			Status:       models.SightingStatusActive,
			FirstSeen:    ts,
			LastSeen:     ts,
			TTLExpiresAt: ttl,
			Metadata:     copySightingMetadata(u),
		}
		sightings = append(sightings, sighting)
	}

	if len(sightings) == 0 {
		return nil
	}

	return store.StoreNetworkSightings(ctx, sightings)
}

func (r *DeviceRegistry) resolveSightingTTL(update *models.DeviceUpdate, ts time.Time) *time.Time {
	if r.identityCfg == nil || r.identityCfg.Reaper.Profiles == nil {
		return nil
	}

	profileName := "default"
	if update != nil && update.Metadata != nil {
		if cls := strings.TrimSpace(update.Metadata["subnet_class"]); cls != "" {
			profileName = cls
		} else if cls := strings.TrimSpace(update.Metadata["subnet_profile"]); cls != "" {
			profileName = cls
		}
	}

	profile, ok := r.identityCfg.Reaper.Profiles[profileName]
	if !ok {
		profile = r.identityCfg.Reaper.Profiles["default"]
	}

	if profile.TTL <= 0 {
		return nil
	}

	expiry := ts.Add(time.Duration(profile.TTL))
	return &expiry
}

func copySightingMetadata(u *models.DeviceUpdate) map[string]string {
	if u == nil {
		return nil
	}

	meta := make(map[string]string)
	for k, v := range u.Metadata {
		meta[k] = v
	}

	if u.Hostname != nil && strings.TrimSpace(*u.Hostname) != "" {
		meta["hostname"] = strings.TrimSpace(*u.Hostname)
	}

	if u.MAC != nil && strings.TrimSpace(*u.MAC) != "" {
		meta["mac"] = strings.TrimSpace(*u.MAC)
	}

	if u.ServiceType != nil {
		meta["service_type"] = string(*u.ServiceType)
	}

	meta["is_available"] = strconv.FormatBool(u.IsAvailable)

	return meta
}

func parseAvailabilityFromMetadata(meta map[string]string) bool {
	if len(meta) == 0 {
		return false
	}

	raw := strings.TrimSpace(meta["is_available"])
	if raw == "" {
		return false
	}

	parsed, err := strconv.ParseBool(raw)
	if err != nil {
		return false
	}

	return parsed
}

// buildUpdateFromNetworkSighting normalizes a stored sighting into a DeviceUpdate for promotion.
func buildUpdateFromNetworkSighting(s *models.NetworkSighting) *models.DeviceUpdate {
	if s == nil {
		return nil
	}

	meta := make(map[string]string)
	for k, v := range s.Metadata {
		meta[k] = v
	}

	meta["_promoted_sighting"] = "true"
	meta["sighting_id"] = s.SightingID

	var (
		hostname *string
		mac      *string
	)

	if h := strings.TrimSpace(meta["hostname"]); h != "" {
		hostname = &h
	}
	if m := strings.TrimSpace(meta["mac"]); m != "" {
		mac = &m
	}

	return &models.DeviceUpdate{
		DeviceID:    "",
		IP:          s.IP,
		Partition:   s.Partition,
		Source:      models.DiscoverySourceSighting,
		Timestamp:   s.LastSeen,
		Hostname:    hostname,
		MAC:         mac,
		Metadata:    meta,
		IsAvailable: false,
	}
}

func (r *DeviceRegistry) mergeSweepSightingsByIP(ctx context.Context, batchSize int) (int, error) {
	if r.identityCfg == nil || !r.identityCfg.Enabled {
		return 0, nil
	}
	if r.db == nil {
		return 0, errDatabaseNotConfigured
	}
	if batchSize <= 0 {
		batchSize = sweepSightingMergeBatchSize
	}

	var merged int
	idsToMark := make([]string, 0)
	events := make([]*models.SightingEvent, 0)

	offset := 0

	for {
		sightings, err := r.db.ListActiveSightings(ctx, "", batchSize, offset)
		if err != nil {
			return merged, fmt.Errorf("list active sightings: %w", err)
		}
		if len(sightings) == 0 {
			break
		}

		sweeps := make([]*models.NetworkSighting, 0, len(sightings))
		for _, s := range sightings {
			if s == nil || s.Source != models.DiscoverySourceSweep || s.Status != models.SightingStatusActive {
				continue
			}
			sweeps = append(sweeps, s)
		}

		if len(sweeps) > 0 {
			ips := make([]string, 0, len(sweeps))
			for _, s := range sweeps {
				if ip := strings.TrimSpace(s.IP); ip != "" {
					ips = append(ips, ip)
				}
			}

			resolved := make(map[string]string, len(ips))
			if err := r.resolveIPsToCanonical(ctx, ips, resolved); err != nil {
				r.logger.Warn().Err(err).Int("count", len(ips)).Msg("Failed to resolve sweep sightings for canonical merge")
			}

			updates := make([]*models.DeviceUpdate, 0, len(sweeps))
			idsBatch := make([]string, 0, len(sweeps))
			eventsBatch := make([]*models.SightingEvent, 0, len(sweeps))
			now := time.Now()

			for _, s := range sweeps {
				canonical := strings.TrimSpace(resolved[strings.TrimSpace(s.IP)])
				if canonical == "" {
					continue
				}

				update := buildUpdateFromNetworkSighting(s)
				if update == nil {
					continue
				}

				if update.Metadata == nil {
					update.Metadata = map[string]string{}
				}
				delete(update.Metadata, "_promoted_sighting")
				update.Metadata["canonical_device_id"] = canonical
				update.Source = models.DiscoverySourceSweep
				update.DeviceID = canonical
				update.IsAvailable = parseAvailabilityFromMetadata(update.Metadata)

				updates = append(updates, update)
				idsBatch = append(idsBatch, s.SightingID)
				eventsBatch = append(eventsBatch, &models.SightingEvent{
					SightingID: s.SightingID,
					DeviceID:   canonical,
					EventType:  "merged",
					Actor:      "system",
					Details: map[string]string{
						"ip":        s.IP,
						"partition": s.Partition,
						"source":    string(s.Source),
					},
					CreatedAt: now,
				})
			}

			if len(updates) > 0 {
				if err := r.ProcessBatchDeviceUpdates(ctx, updates); err != nil {
					return merged, fmt.Errorf("process merged sweep sightings: %w", err)
				}
				merged += len(updates)
				idsToMark = append(idsToMark, idsBatch...)
				events = append(events, eventsBatch...)
			}
		}

		if len(sightings) < batchSize {
			break
		}
		offset += batchSize
	}

	if merged == 0 {
		recordSweepMergeMetrics(0, time.Now())
		return 0, nil
	}

	if err := r.markSightingsPromotedChunked(ctx, idsToMark); err != nil {
		return merged, fmt.Errorf("mark sweep sightings promoted: %w", err)
	}

	if len(events) > 0 {
		if err := r.db.InsertSightingEvents(ctx, events); err != nil {
			r.logger.Warn().Err(err).Msg("Failed to record sweep sighting merge events")
		}
	}

	recordSweepMergeMetrics(merged, time.Now())

	r.logger.Info().
		Int("merged_sweep_sightings", merged).
		Msg("Merged sweep sightings into canonical devices")

	return merged, nil
}

func (r *DeviceRegistry) markSightingsPromotedChunked(ctx context.Context, ids []string) error {
	if len(ids) == 0 {
		return nil
	}

	const chunkSize = 1000

	for start := 0; start < len(ids); start += chunkSize {
		end := start + chunkSize
		if end > len(ids) {
			end = len(ids)
		}

		if _, err := r.db.MarkSightingsPromoted(ctx, ids[start:end]); err != nil {
			return err
		}
	}

	return nil
}

// ReconcileSightings promotes eligible network sightings into device updates based on policy.
func (r *DeviceRegistry) ReconcileSightings(ctx context.Context) error {
	if r.identityCfg == nil || !r.identityCfg.Enabled {
		return nil
	}

	if merged, err := r.mergeSweepSightingsByIP(ctx, sweepSightingMergeBatchSize); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to merge sweep sightings by IP")
	} else if merged > 0 {
		r.logger.Debug().
			Int("merged_sweep_sightings", merged).
			Msg("Merged sweep sightings before promotion pass")
	}

	promoCfg := r.identityCfg.Promotion
	if !promoCfg.Enabled && !promoCfg.ShadowMode {
		return nil
	}

	if blocked := r.blockPromotionForCardinalityDrift(ctx); blocked {
		return nil
	}

	now := time.Now()
	cutoff := now.Add(-time.Duration(promoCfg.MinPersistence))
	sightings, err := r.db.ListPromotableSightings(ctx, cutoff)
	if err != nil {
		return fmt.Errorf("list promotable sightings: %w", err)
	}

	if len(sightings) == 0 {
		recordIdentityPromotionMetrics(0, 0, 0, 0, 0, promoCfg.ShadowMode, now)
		return nil
	}

	promotable := make([]*models.NetworkSighting, 0, len(sightings))
	var shadowReady int
	var eligibleAuto int
	var blockedPolicy int

	for _, s := range sightings {
		status := r.promotionStatusForSighting(now, s)
		s.Promotion = status
		if status == nil || !status.MeetsPolicy {
			blockedPolicy++
			continue
		}

		if promoCfg.ShadowMode {
			shadowReady++
			continue
		}

		if !status.Eligible {
			continue
		}

		eligibleAuto++
		promotable = append(promotable, s)
	}

	if len(promotable) == 0 {
		recordIdentityPromotionMetrics(len(sightings), 0, eligibleAuto, shadowReady, blockedPolicy, promoCfg.ShadowMode, now)
		if promoCfg.ShadowMode && shadowReady > 0 {
			r.logger.Info().
				Int("shadow_ready", shadowReady).
				Int("blocked_policy", blockedPolicy).
				Msg("Identity reconciliation promotion shadow summary")
		}
		return nil
	}

	if promoCfg.ShadowMode {
		recordIdentityPromotionMetrics(len(sightings), 0, eligibleAuto, shadowReady, blockedPolicy, true, now)
		r.logger.Info().
			Int("promotable_shadow", shadowReady).
			Int("blocked_policy", blockedPolicy).
			Msg("Identity reconciliation promotion shadow pass")
		return nil
	}

	updates := make([]*models.DeviceUpdate, 0, len(promotable))
	var identifiers []*models.DeviceIdentifier
	events := make([]*models.SightingEvent, 0, len(promotable))
	promotedPartitions := make(map[string]int)

	for _, s := range promotable {
		update := buildUpdateFromNetworkSighting(s)
		if update == nil {
			continue
		}

		updates = append(updates, update)
		promotedPartitions[update.Partition]++
	}

	if err := r.ProcessBatchDeviceUpdates(ctx, updates); err != nil {
		return fmt.Errorf("process promoted sightings: %w", err)
	}

	ids := make([]string, 0, len(promotable))
	for _, s := range promotable {
		ids = append(ids, s.SightingID)
	}

	for _, u := range updates {
		if u.DeviceID == "" {
			continue
		}

		identifiers = append(identifiers, buildIdentifiersFromUpdate(u, now)...)
		events = append(events, &models.SightingEvent{
			SightingID: u.Metadata["sighting_id"],
			DeviceID:   u.DeviceID,
			EventType:  "promoted",
			Actor:      "system",
			Details: map[string]string{
				"ip":        u.IP,
				"partition": u.Partition,
				"source":    string(u.Source),
			},
			CreatedAt: now,
		})
	}

	if _, err := r.db.MarkSightingsPromoted(ctx, ids); err != nil {
		return fmt.Errorf("mark sightings promoted: %w", err)
	}

	if len(identifiers) > 0 {
		if err := r.db.UpsertDeviceIdentifiers(ctx, identifiers); err != nil {
			r.logger.Warn().Err(err).Msg("Failed to upsert device identifiers for promoted sightings")
		}
	}

	if len(events) > 0 {
		if err := r.db.InsertSightingEvents(ctx, events); err != nil {
			r.logger.Warn().Err(err).Msg("Failed to record sighting promotion events")
		}
	}

	recordIdentityPromotionMetrics(len(sightings), len(promotable), eligibleAuto, shadowReady, blockedPolicy, false, now)

	r.logger.Info().
		Int("promoted", len(promotable)).
		Int("eligible_auto", eligibleAuto).
		Int("shadow_ready", shadowReady).
		Int("blocked_policy", blockedPolicy).
		Msg("Promoted network sightings to unified devices")

	return nil
}

// PromoteSighting manually promotes a single sighting, bypassing policy gating.
func (r *DeviceRegistry) PromoteSighting(ctx context.Context, sightingID, actor string) (*models.DeviceUpdate, error) {
	if r.db == nil {
		return nil, errDatabaseNotConfigured
	}
	if r.identityCfg == nil || !r.identityCfg.Enabled {
		return nil, errIdentityReconciliationDisabled
	}

	sighting, err := r.db.GetNetworkSighting(ctx, sightingID)
	if err != nil {
		return nil, err
	}
	if sighting == nil {
		return nil, errSightingNotFound
	}
	if sighting.Status != models.SightingStatusActive {
		return nil, fmt.Errorf("%w: %s", errSightingNotActive, sighting.SightingID)
	}

	update := buildUpdateFromNetworkSighting(sighting)
	if update == nil {
		return nil, errUnableToBuildUpdate
	}

	if err := r.ProcessBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update}); err != nil {
		return nil, fmt.Errorf("promote sighting: %w", err)
	}

	if _, err := r.db.MarkSightingsPromoted(ctx, []string{sighting.SightingID}); err != nil {
		return nil, fmt.Errorf("mark sighting promoted: %w", err)
	}

	now := time.Now()
	if update.DeviceID != "" {
		if err := r.db.UpsertDeviceIdentifiers(ctx, buildIdentifiersFromUpdate(update, now)); err != nil {
			r.logger.Warn().Err(err).Msg("Failed to upsert device identifiers for manual promotion")
		}
	}

	promotedBy := strings.TrimSpace(actor)
	if promotedBy == "" {
		promotedBy = "system"
	}

	event := &models.SightingEvent{
		SightingID: sighting.SightingID,
		DeviceID:   update.DeviceID,
		EventType:  "promoted",
		Actor:      promotedBy,
		Details: map[string]string{
			"ip":        sighting.IP,
			"partition": sighting.Partition,
			"mode":      "manual",
		},
		CreatedAt: now,
	}

	if err := r.db.InsertSightingEvents(ctx, []*models.SightingEvent{event}); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to record manual promotion event")
	}

	return update, nil
}

// DismissSighting marks a sighting dismissed and records an audit event.
func (r *DeviceRegistry) DismissSighting(ctx context.Context, sightingID, actor, reason string) error {
	if r.db == nil {
		return errDatabaseNotConfigured
	}
	if r.identityCfg == nil || !r.identityCfg.Enabled {
		return errIdentityReconciliationDisabled
	}

	sighting, err := r.db.GetNetworkSighting(ctx, sightingID)
	if err != nil {
		return err
	}
	if sighting == nil {
		return errSightingNotFound
	}
	if sighting.Status != models.SightingStatusActive {
		return fmt.Errorf("%w: %s", errSightingNotActive, sighting.SightingID)
	}

	affected, err := r.db.UpdateSightingStatus(ctx, sighting.SightingID, models.SightingStatusDismissed)
	if err != nil {
		return err
	}
	if affected == 0 {
		return fmt.Errorf("%w: %s", errSightingNotUpdated, sighting.SightingID)
	}

	dismissedBy := strings.TrimSpace(actor)
	if dismissedBy == "" {
		dismissedBy = "system"
	}

	details := map[string]string{
		"ip":        sighting.IP,
		"partition": sighting.Partition,
		"mode":      "manual",
		"action":    "dismissed",
	}
	if trimmed := strings.TrimSpace(reason); trimmed != "" {
		details["reason"] = trimmed
	}

	event := &models.SightingEvent{
		SightingID: sighting.SightingID,
		EventType:  "dismissed",
		Actor:      dismissedBy,
		Details:    details,
		CreatedAt:  time.Now(),
	}

	if err := r.db.InsertSightingEvents(ctx, []*models.SightingEvent{event}); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to record dismissal event")
	}

	return nil
}

// ListSightingEvents returns audit entries for a sighting.
func (r *DeviceRegistry) ListSightingEvents(ctx context.Context, sightingID string, limit int) ([]*models.SightingEvent, error) {
	if r.db == nil {
		return nil, errDatabaseNotConfigured
	}
	return r.db.ListSightingEvents(ctx, sightingID, limit)
}

// ListSightings returns active sightings for the given partition.
func (r *DeviceRegistry) ListSightings(ctx context.Context, partition string, limit, offset int) ([]*models.NetworkSighting, error) {
	if r.db == nil {
		return nil, errDatabaseNotConfigured
	}
	sightings, err := r.db.ListActiveSightings(ctx, partition, limit, offset)
	if err != nil {
		return nil, err
	}

	now := time.Now()
	for _, s := range sightings {
		s.Promotion = r.promotionStatusForSighting(now, s)
	}

	return sightings, nil
}

// CountSightings returns the total active sightings.
func (r *DeviceRegistry) CountSightings(ctx context.Context, partition string) (int64, error) {
	if r.db == nil {
		return 0, errDatabaseNotConfigured
	}
	return r.db.CountActiveSightings(ctx, partition)
}

func (r *DeviceRegistry) blockPromotionForCardinalityDrift(ctx context.Context) bool {
	if r.db == nil || r.identityCfg == nil {
		return false
	}

	drift := r.identityCfg.Drift
	if drift.BaselineDevices <= 0 {
		recordIdentityDriftMetrics(0, 0, drift.TolerancePercent, false)
		return false
	}

	current, err := r.db.CountUnifiedDevices(ctx)
	if err != nil {
		r.logger.Warn().Err(err).Msg("Failed to count devices for identity drift check")
		recordIdentityDriftMetrics(0, int64(drift.BaselineDevices), drift.TolerancePercent, false)
		return false
	}

	baseline := int64(drift.BaselineDevices)
	limit := baseline
	if drift.TolerancePercent > 0 {
		limit = baseline + (baseline*int64(drift.TolerancePercent))/100
	}

	blocked := drift.PauseOnDrift && current > limit
	recordIdentityDriftMetrics(current, baseline, drift.TolerancePercent, blocked)

	if blocked {
		r.logger.Warn().
			Int64("device_count", current).
			Int64("baseline_devices", baseline).
			Int("tolerance_percent", drift.TolerancePercent).
			Msg("Identity reconciliation promotion paused due to cardinality drift")
	} else if drift.AlertOnDrift && current > limit {
		r.logger.Info().
			Int64("device_count", current).
			Int64("baseline_devices", baseline).
			Int("tolerance_percent", drift.TolerancePercent).
			Msg("Identity reconciliation device count exceeds baseline tolerance")
	}

	return blocked
}

func buildIdentifiersFromUpdate(u *models.DeviceUpdate, now time.Time) []*models.DeviceIdentifier {
	var ids []*models.DeviceIdentifier

	addID := func(idType, value, confidence string) {
		value = strings.TrimSpace(value)
		if value == "" {
			return
		}
		ids = append(ids, &models.DeviceIdentifier{
			DeviceID:   u.DeviceID,
			IDType:     idType,
			IDValue:    value,
			Confidence: confidence,
			Source:     string(u.Source),
			FirstSeen:  now,
			LastSeen:   now,
			Metadata:   map[string]string{"partition": u.Partition},
		})
	}

	addID("ip", u.IP, "weak")

	if u.MAC != nil {
		for _, mac := range parseMACList(*u.MAC) {
			addID("mac", mac, "strong")
		}
	}

	if u.Hostname != nil && strings.TrimSpace(*u.Hostname) != "" {
		addID("hostname", *u.Hostname, "medium")
	}

	if fp := strings.TrimSpace(u.Metadata["fingerprint_hash"]); fp != "" {
		addID("fingerprint_hash", fp, "medium")
	}
	if fpID := strings.TrimSpace(u.Metadata["fingerprint_id"]); fpID != "" {
		addID("fingerprint_id", fpID, "medium")
	}

	return ids
}

// mergeUpdateMetadata merges metadata from source update into target update
func (r *DeviceRegistry) mergeUpdateMetadata(target, source *models.DeviceUpdate) {
	if source.Metadata == nil {
		return
	}
	if target.Metadata == nil {
		target.Metadata = make(map[string]string)
	}

	for k, v := range source.Metadata {
		if _, exists := target.Metadata[k]; !exists {
			target.Metadata[k] = v
		}
	}

	// Also merge strong identifiers if present in source but missing in target
	if source.MAC != nil && (target.MAC == nil || *target.MAC == "") {
		target.MAC = source.MAC
	}
}

// SetCollectorCapabilities stores or updates the collector capability record for a device.
func (r *DeviceRegistry) SetCollectorCapabilities(_ context.Context, capability *models.CollectorCapability) {
	if capability == nil {
		return
	}
	if r.capabilities == nil {
		r.capabilities = NewCapabilityIndex()
	}
	r.capabilities.Set(capability)
}

// GetCollectorCapabilities returns the collector capability record for a device if present.
func (r *DeviceRegistry) GetCollectorCapabilities(_ context.Context, deviceID string) (*models.CollectorCapability, bool) {
	if r.capabilities == nil {
		return nil, false
	}
	return r.capabilities.Get(deviceID)
}

// HasDeviceCapability reports whether the device exposes the specified capability.
func (r *DeviceRegistry) HasDeviceCapability(_ context.Context, deviceID, capability string) bool {
	if r.capabilities == nil {
		return false
	}
	return r.capabilities.HasCapability(deviceID, capability)
}

// ListDevicesWithCapability lists devices that expose the requested capability.
func (r *DeviceRegistry) ListDevicesWithCapability(_ context.Context, capability string) []string {
	if r.capabilities == nil {
		return nil
	}
	return r.capabilities.ListDevicesWithCapability(capability)
}

// SetDeviceCapabilitySnapshot records the latest snapshot for a device capability tuple.
func (r *DeviceRegistry) SetDeviceCapabilitySnapshot(_ context.Context, snapshot *models.DeviceCapabilitySnapshot) {
	if snapshot == nil {
		return
	}
	if r.matrix == nil {
		r.matrix = NewCapabilityMatrix()
	}
	r.matrix.Set(snapshot)
}

// ListDeviceCapabilitySnapshots returns the capability snapshots tracked for a device.
func (r *DeviceRegistry) ListDeviceCapabilitySnapshots(_ context.Context, deviceID string) []*models.DeviceCapabilitySnapshot {
	if r.matrix == nil {
		return nil
	}
	return r.matrix.ListForDevice(deviceID)
}

// identityMaps holds batch-resolved mappings from identity → canonical device_id
type identityMaps struct {
	armis  map[string]string
	netbx  map[string]string
	mac    map[string]string
	ip     map[string]string
	device map[string]string
}

func (r *DeviceRegistry) buildIdentityMaps(ctx context.Context, updates []*models.DeviceUpdate) (*identityMaps, error) {
	m := &identityMaps{
		armis:  map[string]string{},
		netbx:  map[string]string{},
		mac:    map[string]string{},
		ip:     map[string]string{},
		device: map[string]string{},
	}

	// Collect unique identities
	armisSet := make(map[string]struct{})
	netboxSet := make(map[string]struct{})
	macSet := make(map[string]struct{})
	ipSet := make(map[string]struct{})
	deviceSet := make(map[string]struct{})

	for _, u := range updates {
		if u.Metadata != nil {
			if del, ok := u.Metadata["_deleted"]; ok && strings.EqualFold(del, "true") {
				continue
			}
			if _, ok := u.Metadata["_merged_into"]; ok {
				continue
			}
			if id := u.Metadata["armis_device_id"]; id != "" {
				armisSet[id] = struct{}{}
			}
			if typ := u.Metadata["integration_type"]; typ == integrationTypeNetbox {
				if id := u.Metadata["integration_id"]; id != "" {
					netboxSet[id] = struct{}{}
				}
				if id := u.Metadata["netbox_device_id"]; id != "" {
					netboxSet[id] = struct{}{}
				}
			}
			if alias := strings.TrimSpace(u.Metadata["_alias_last_seen_service_id"]); alias != "" {
				deviceSet[alias] = struct{}{}
			}
			for key := range u.Metadata {
				if strings.HasPrefix(key, "service_alias:") {
					if alias := strings.TrimSpace(strings.TrimPrefix(key, "service_alias:")); alias != "" {
						deviceSet[alias] = struct{}{}
					}
				}
			}
		}
		if u.MAC != nil && *u.MAC != "" {
			for _, mac := range parseMACList(*u.MAC) {
				macSet[mac] = struct{}{}
			}
		}
		if u.IP != "" {
			ipSet[u.IP] = struct{}{}
		}
		if trimmed := strings.TrimSpace(u.DeviceID); trimmed != "" {
			deviceSet[trimmed] = struct{}{}
		}
	}

	// Helper to convert set to slice
	toList := func(set map[string]struct{}) []string {
		out := make([]string, 0, len(set))
		for k := range set {
			out = append(out, k)
		}
		return out
	}

	// Resolve in chunks
	if err := r.resolveArmisIDs(ctx, toList(armisSet), m.armis); err != nil {
		return m, err
	}
	if err := r.resolveNetboxIDs(ctx, toList(netboxSet), m.netbx); err != nil {
		return m, err
	}
	if err := r.resolveMACs(ctx, toList(macSet), m.mac); err != nil {
		return m, err
	}
	if err := r.resolveIPsToCanonical(ctx, toList(ipSet), m.ip); err != nil {
		return m, err
	}
	for _, id := range toList(deviceSet) {
		setIfMissing(m.device, id, id)
	}
	seedIdentityMapsFromBatch(updates, m)
	return m, nil
}

func seedIdentityMapsFromBatch(updates []*models.DeviceUpdate, m *identityMaps) {
	if len(updates) == 0 || m == nil {
		return
	}
	for _, update := range updates {
		if update == nil {
			continue
		}
		canonical := canonicalIDCandidate(update)
		if canonical == "" {
			continue
		}
		strongIdentity := hasStrongIdentity(update)
		for _, key := range identitymap.BuildKeys(update) {
			switch key.Kind {
			case identitymap.KindDeviceID:
				setIfMissing(m.device, key.Value, canonical)
			case identitymap.KindArmisID:
				setIfMissing(m.armis, key.Value, canonical)
			case identitymap.KindNetboxID:
				setIfMissing(m.netbx, key.Value, canonical)
			case identitymap.KindMAC:
				setIfMissing(m.mac, key.Value, canonical)
			case identitymap.KindIP, identitymap.KindPartitionIP:
				if !strongIdentity {
					continue
				}
				setIfMissing(m.ip, key.Value, canonical)
			}
		}
	}
}

func canonicalIDCandidate(update *models.DeviceUpdate) string {
	if update == nil {
		return ""
	}

	// If this update carries an Armis strong ID, ignore any provided canonical_device_id
	// to avoid collapsing distinct Armis devices that happen to share a canonical hint.
	if update.Metadata != nil && strings.TrimSpace(update.Metadata["armis_device_id"]) != "" {
		// Fall through to DeviceID handling below.
	} else if update.Metadata != nil {
		if canonical := strings.TrimSpace(update.Metadata["canonical_device_id"]); canonical != "" {
			// Skip legacy partition:IP format IDs - they should be migrated to ServiceRadar UUIDs
			if !isLegacyIPBasedID(canonical) {
				return canonical
			}
		}
	}

	// Check canonical_device_id from metadata, but skip legacy partition:IP format IDs
	// Use the current DeviceID, but skip legacy partition:IP format IDs
	deviceID := strings.TrimSpace(update.DeviceID)
	if deviceID != "" && !isLegacyIPBasedID(deviceID) {
		return deviceID
	}

	// For legacy IDs or empty IDs, return empty to signal that a new UUID is needed
	// Don't fall back to partition:IP format
	return ""
}

func setIfMissing(dst map[string]string, key, value string) {
	if dst == nil {
		return
	}
	key = strings.TrimSpace(key)
	value = strings.TrimSpace(value)
	if key == "" || value == "" {
		return
	}
	if _, exists := dst[key]; !exists {
		dst[key] = value
	}
}

func (r *DeviceRegistry) resolveIdentifiers(
	ctx context.Context,
	values []string,
	out map[string]string,
	buildQuery func(string) string,
	extract func(map[string]any) (string, string),
) error {
	if len(values) == 0 {
		return nil
	}
	const chunk = 1000
	for i := 0; i < len(values); i += chunk {
		end := i + chunk
		if end > len(values) {
			end = len(values)
		}
		list := quoteList(values[i:end])
		rows, err := r.db.ExecuteQuery(ctx, buildQuery(list))
		if err != nil {
			return err
		}
		for _, row := range rows {
			key, dev := extract(row)
			if key == "" || dev == "" {
				continue
			}
			if _, exists := out[key]; !exists {
				out[key] = dev
			}
		}
	}
	return nil
}

func (r *DeviceRegistry) resolveArmisIDsCNPG(ctx context.Context, ids []string, out map[string]string) error {
	const query = `
SELECT metadata->>'armis_device_id' AS id, device_id
FROM unified_devices
WHERE metadata ? 'armis_device_id'
  AND metadata->>'armis_device_id' = ANY($1)
ORDER BY updated_at DESC`

	return r.resolveIdentifiersCNPG(ctx, ids, query, nil, out)
}

func (r *DeviceRegistry) resolveNetboxIDsCNPG(ctx context.Context, ids []string, out map[string]string) error {
	const query = `
SELECT COALESCE(metadata->>'integration_id', metadata->>'netbox_device_id') AS id,
       device_id
FROM unified_devices
WHERE metadata->>'integration_type' = $1
  AND (
        (metadata ? 'integration_id' AND metadata->>'integration_id' = ANY($2))
     OR (metadata ? 'netbox_device_id' AND metadata->>'netbox_device_id' = ANY($2))
      )
ORDER BY updated_at DESC`

	argBuilder := func(chunk []string) []interface{} {
		return []interface{}{integrationTypeNetbox, chunk}
	}

	return r.resolveIdentifiersCNPG(ctx, ids, query, argBuilder, out)
}

func (r *DeviceRegistry) resolveMACsCNPG(ctx context.Context, macs []string, out map[string]string) error {
	const query = `
SELECT mac, device_id
FROM unified_devices
WHERE mac = ANY($1)
ORDER BY updated_at DESC`

	return r.resolveIdentifiersCNPG(ctx, macs, query, nil, out)
}

func (r *DeviceRegistry) resolveIPsToCanonicalCNPG(ctx context.Context, ips []string, out map[string]string) error {
	const query = `
SELECT DISTINCT ON (ip) ip, device_id
FROM unified_devices
WHERE ip = ANY($1)
  AND (
        metadata ? 'armis_device_id'
     OR (metadata ? 'integration_type' AND metadata->>'integration_type' = $2)
     OR (mac IS NOT NULL AND mac <> '')
      )
  AND COALESCE(lower(metadata->>'_deleted'),'false') <> 'true'
  AND COALESCE(lower(metadata->>'deleted'),'false') <> 'true'
ORDER BY ip, last_seen DESC`

	argBuilder := func(chunk []string) []interface{} {
		return []interface{}{chunk, integrationTypeNetbox}
	}

	return r.resolveIdentifiersCNPG(ctx, ips, query, argBuilder, out)
}

func (r *DeviceRegistry) resolveIdentifiersCNPG(
	ctx context.Context,
	values []string,
	query string,
	argBuilder func([]string) []interface{},
	out map[string]string,
) error {
	if len(values) == 0 {
		return nil
	}

	for start := 0; start < len(values); start += cnpgIdentifierChunkSize {
		end := start + cnpgIdentifierChunkSize
		if end > len(values) {
			end = len(values)
		}

		chunk := filterIdentifierValues(values[start:end])
		if len(chunk) == 0 {
			continue
		}

		args := []interface{}{chunk}
		if argBuilder != nil {
			args = argBuilder(chunk)
		}

		rows, err := r.queryCNPGRows(ctx, query, args...)
		if err != nil {
			return err
		}

		if err := r.scanIdentifierRows(rows, out); err != nil {
			return err
		}
	}

	return nil
}

func (r *DeviceRegistry) scanIdentifierRows(rows db.Rows, out map[string]string) error {
	if rows == nil {
		return nil
	}
	defer func() { _ = rows.Close() }()

	if out == nil {
		return rows.Err()
	}

	for rows.Next() {
		var key, deviceID string
		if err := rows.Scan(&key, &deviceID); err != nil {
			return err
		}

		key = strings.TrimSpace(key)
		deviceID = strings.TrimSpace(deviceID)
		if key == "" || deviceID == "" {
			continue
		}

		// Skip legacy partition:IP format IDs - they should be migrated to ServiceRadar UUIDs
		if isLegacyIPBasedID(deviceID) {
			continue
		}

		if _, exists := out[key]; !exists {
			out[key] = deviceID
		}
	}

	return rows.Err()
}

func (r *DeviceRegistry) useCNPGReads() bool {
	client, ok := r.db.(cnpgRegistryClient)
	if !ok {
		return false
	}

	return client.UseCNPGReads()
}

func (r *DeviceRegistry) queryCNPGRows(ctx context.Context, query string, args ...interface{}) (db.Rows, error) {
	client, ok := r.db.(cnpgRegistryClient)
	if !ok {
		return nil, errCNPGQueryUnsupported
	}

	return client.QueryRegistryRows(ctx, query, args...)
}

func filterIdentifierValues(values []string) []string {
	out := make([]string, 0, len(values))
	for _, v := range values {
		if trimmed := strings.TrimSpace(v); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

func (r *DeviceRegistry) resolveArmisIDs(ctx context.Context, ids []string, out map[string]string) error {
	if r.useCNPGReads() {
		return r.resolveArmisIDsCNPG(ctx, ids, out)
	}

	buildQuery := func(list string) string {
		return fmt.Sprintf(`SELECT device_id, metadata['armis_device_id'] AS id, _tp_time
              FROM table(unified_devices)
              WHERE has(map_keys(metadata), 'armis_device_id')
                AND metadata['armis_device_id'] IN (%s)
              ORDER BY _tp_time DESC`, list)
	}
	extract := func(row map[string]any) (string, string) {
		idVal, _ := row["id"].(string)
		dev, _ := row["device_id"].(string)
		return idVal, dev
	}
	return r.resolveIdentifiers(ctx, ids, out, buildQuery, extract)
}

func (r *DeviceRegistry) resolveNetboxIDs(ctx context.Context, ids []string, out map[string]string) error {
	if r.useCNPGReads() {
		return r.resolveNetboxIDsCNPG(ctx, ids, out)
	}

	buildQuery := func(list string) string {
		return fmt.Sprintf(`SELECT device_id,
                     if(has(map_keys(metadata),'integration_id'), metadata['integration_id'], metadata['netbox_device_id']) AS id,
                     _tp_time
              FROM table(unified_devices)
              WHERE has(map_keys(metadata), 'integration_type') AND metadata['integration_type'] = '%s'
                AND ((has(map_keys(metadata), 'integration_id') AND metadata['integration_id'] IN (%s))
                  OR (has(map_keys(metadata), 'netbox_device_id') AND metadata['netbox_device_id'] IN (%s)))
              ORDER BY _tp_time DESC`, integrationTypeNetbox, list, list)
	}
	extract := func(row map[string]any) (string, string) {
		idVal, _ := row["id"].(string)
		dev, _ := row["device_id"].(string)
		return idVal, dev
	}
	return r.resolveIdentifiers(ctx, ids, out, buildQuery, extract)
}

func (r *DeviceRegistry) resolveMACs(ctx context.Context, macs []string, out map[string]string) error {
	if r.useCNPGReads() {
		return r.resolveMACsCNPG(ctx, macs, out)
	}

	buildQuery := func(list string) string {
		return fmt.Sprintf(`SELECT device_id, mac AS id, _tp_time
              FROM table(unified_devices)
              WHERE mac IN (%s)
              ORDER BY _tp_time DESC`, list)
	}
	extract := func(row map[string]any) (string, string) {
		idVal, _ := row["id"].(string)
		dev, _ := row["device_id"].(string)
		return idVal, dev
	}
	return r.resolveIdentifiers(ctx, macs, out, buildQuery, extract)
}

// resolveIPsToCanonical maps IPs to canonical device_ids where the device has a strong identity
func (r *DeviceRegistry) resolveIPsToCanonical(ctx context.Context, ips []string, out map[string]string) error {
	if len(ips) == 0 {
		return nil
	}

	unresolved := make(map[string]struct{}, len(ips))
	for _, raw := range ips {
		ip := strings.TrimSpace(raw)
		if ip == "" {
			continue
		}
		if out != nil {
			if _, exists := out[ip]; exists {
				continue
			}
		}
		unresolved[ip] = struct{}{}
	}

	if len(unresolved) == 0 {
		return nil
	}

	// Resolve IPs using CNPG (preferred) or KV (legacy fallback)
	var resolveErr error
	candidates := make([]string, 0, len(unresolved))
	for ip := range unresolved {
		candidates = append(candidates, ip)
	}

	var resolved map[string]string
	if r.cnpgIdentityResolver != nil {
		resolved, resolveErr = r.cnpgIdentityResolver.resolveCanonicalIPs(ctx, candidates)
	} else if r.identityResolver != nil {
		resolved, resolveErr = r.identityResolver.resolveCanonicalIPs(ctx, candidates)
	}

	// Add initial results to out. We allow tombstones/merged devices here
	// because we'll resolve the chains at the very end.
	for ip, deviceID := range resolved {
		ip = strings.TrimSpace(ip)
		deviceID = strings.TrimSpace(deviceID)
		if ip == "" || deviceID == "" {
			continue
		}
		// Skip legacy partition:IP format IDs - they should be migrated to ServiceRadar UUIDs
		if isLegacyIPBasedID(deviceID) {
			continue
		}
		if out != nil {
			if _, exists := out[ip]; !exists {
				out[ip] = deviceID
			}
		}
		delete(unresolved, ip)
	}

	// If we still have unresolved IPs, try fallback methods
	if len(unresolved) > 0 {
		fallbackIPs := make([]string, 0, len(unresolved))
		for ip := range unresolved {
			fallbackIPs = append(fallbackIPs, ip)
		}

		if r.useCNPGReads() {
			cnpgErr := r.resolveIPsToCanonicalCNPG(ctx, fallbackIPs, out)
			resolveErr = errors.Join(resolveErr, cnpgErr)
		} else {
			buildQuery := func(list string) string {
				return fmt.Sprintf(`SELECT
                ip,
                arg_max(device_id, _tp_time) AS device_id
              FROM table(unified_devices)
              WHERE ip IN (%s)
                AND (has(map_keys(metadata),'armis_device_id')
                     OR (has(map_keys(metadata),'integration_type') AND metadata['integration_type']='%s')
                     OR (mac IS NOT NULL AND mac != ''))
              GROUP BY ip`, list, integrationTypeNetbox)
			}
			extract := func(row map[string]any) (string, string) {
				ip, _ := row["ip"].(string)
				dev, _ := row["device_id"].(string)
				return ip, dev
			}

			fallbackErr := r.resolveIdentifiers(ctx, fallbackIPs, out, buildQuery, extract)
			resolveErr = errors.Join(resolveErr, fallbackErr)
		}
	}

	// Finally, resolve any merged devices in the result set to their canonical targets
	if len(out) > 0 {
		resolvedChains := r.resolveCanonicalIPMappings(ctx, out)
		// Update out with resolved canonical IDs, removing any that couldn't be resolved (e.g. deleted)
		for ip := range out {
			if canonical, ok := resolvedChains[ip]; ok && canonical != "" {
				out[ip] = canonical
			} else {
				delete(out, ip)
			}
		}
	}

	return resolveErr
}

func (r *DeviceRegistry) resolveCanonicalIPMappings(ctx context.Context, mappings map[string]string) map[string]string {
	if len(mappings) == 0 || r.db == nil {
		return mappings
	}

	ids := make([]string, 0, len(mappings))
	seen := make(map[string]struct{})
	for _, id := range mappings {
		if id != "" {
			if _, ok := seen[id]; !ok {
				ids = append(ids, id)
				seen[id] = struct{}{}
			}
		}
	}

	resolvedChains := r.resolveMergeChains(ctx, ids)

	result := make(map[string]string)
	for ip, id := range mappings {
		if canonical, ok := resolvedChains[id]; ok && canonical != "" {
			result[ip] = canonical
		}
	}

	return result
}

func (r *DeviceRegistry) resolveMergeChains(ctx context.Context, ids []string) map[string]string {
	if len(ids) == 0 {
		return nil
	}

	// pending: IDs we need to look up
	pending := make(map[string]struct{})
	for _, id := range ids {
		if id != "" {
			pending[id] = struct{}{}
		}
	}

	// loaded: IDs we have fetched from DB
	loaded := make(map[string]*models.UnifiedDevice)

	// Loop to fetch chains (max depth 5 to prevent infinite loops/excessive queries)
	for i := 0; i < 5; i++ {
		if len(pending) == 0 {
			break
		}

		// Convert pending set to slice
		batch := make([]string, 0, len(pending))
		for id := range pending {
			batch = append(batch, id)
		}

		// Clear pending for next iteration
		pending = make(map[string]struct{})

		// Fetch from DB
		devices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, nil, batch)
		if err != nil {
			r.logger.Warn().Err(err).Msg("Failed to fetch devices for chain resolution")
			// Stop here, process what we have
			break
		}

		for _, dev := range devices {
			loaded[dev.DeviceID] = dev

			// If merged, add target to pending if not already loaded
			if dev.Metadata != nil {
				if merged := strings.TrimSpace(dev.Metadata.Value["_merged_into"]); merged != "" && merged != dev.DeviceID {
					if _, have := loaded[merged]; !have {
						pending[merged] = struct{}{}
					}
				}
			}
		}
	}

	// Build final map
	results := make(map[string]string)

	for _, startID := range ids {
		currID := startID
		visited := map[string]struct{}{}

		// Follow chain
		for {
			if _, seen := visited[currID]; seen {
				// Cycle detected! Abort chain.
				currID = ""
				break
			}
			visited[currID] = struct{}{}

			dev, ok := loaded[currID]
			if !ok {
				// Missing device in chain (deleted or not found)
				// If it's the startID, we treat it as missing.
				currID = ""
				break
			}

			if isCanonicalUnifiedDevice(dev) {
				// Found it!
				break
			}

			// It's merged or deleted
			if dev.Metadata != nil && strings.EqualFold(dev.Metadata.Value["_deleted"], "true") {
				currID = "" // Deleted
				break
			}

			merged := ""
			if dev.Metadata != nil {
				merged = strings.TrimSpace(dev.Metadata.Value["_merged_into"])
			}

			if merged != "" && merged != currID {
				currID = merged // Advance
			} else {
				// Not canonical, not deleted, no merge target? Invalid state.
				currID = ""
				break
			}
		}

		if currID != "" {
			results[startID] = currID
		}
	}

	return results
}

func (r *DeviceRegistry) lookupCanonicalFromMaps(u *models.DeviceUpdate, maps *identityMaps) (string, string) {
	if maps == nil {
		return "", ""
	}
	if trimmedID := strings.TrimSpace(u.DeviceID); trimmedID != "" {
		if dev, ok := maps.device[trimmedID]; ok {
			if canonical := strings.TrimSpace(dev); canonical != "" && canonical != trimmedID {
				return canonical, identitySourceDeviceID
			}
		}
	}
	if u.Metadata != nil {
		if del, ok := u.Metadata["_deleted"]; ok && strings.EqualFold(del, "true") {
			return "", ""
		}
		if _, ok := u.Metadata["_merged_into"]; ok {
			return "", ""
		}
		if id := u.Metadata["armis_device_id"]; id != "" {
			if dev, ok := maps.armis[id]; ok {
				return dev, identitySourceArmis
			}
		}
		if typ := u.Metadata["integration_type"]; typ == integrationTypeNetbox {
			if id := u.Metadata["integration_id"]; id != "" {
				if dev, ok := maps.netbx[id]; ok {
					return dev, identitySourceNetbox
				}
			}
			if id := u.Metadata["netbox_device_id"]; id != "" {
				if dev, ok := maps.netbx[id]; ok {
					return dev, identitySourceNetbox
				}
			}
		}
	}
	if u.MAC != nil && *u.MAC != "" {
		if dev, ok := maps.mac[*u.MAC]; ok {
			return dev, identitySourceMAC
		}
	}
	if u.IP != "" {
		if dev, ok := maps.ip[u.IP]; ok {
			return dev, "ip"
		}
	}
	return "", ""
}

func quoteList(vals []string) string {
	if len(vals) == 0 {
		return "''"
	}
	b := strings.Builder{}
	for i, v := range vals {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString("'")
		b.WriteString(strings.ReplaceAll(v, "'", "''"))
		b.WriteString("'")
	}
	return b.String()
}

var macRe = regexp.MustCompile(`(?i)[0-9a-f]{2}(?::[0-9a-f]{2}){5}`)

// parseMACList extracts individual MAC addresses from a possibly comma/space-separated string.
func parseMACList(s string) []string {
	// If it already looks like a single MAC, return it
	if macRe.MatchString(s) && !strings.Contains(s, ",") {
		return []string{strings.ToUpper(macRe.FindString(s))}
	}
	// Extract all MAC-like tokens
	matches := macRe.FindAllString(s, -1)
	out := make([]string, 0, len(matches))
	seen := make(map[string]struct{})
	for _, m := range matches {
		mac := strings.ToUpper(m)
		if _, ok := seen[mac]; ok {
			continue
		}
		seen[mac] = struct{}{}
		out = append(out, mac)
	}
	return out
}

func (r *DeviceRegistry) annotateFirstSeen(ctx context.Context, updates []*models.DeviceUpdate) error {
	if len(updates) == 0 {
		return nil
	}

	deviceIDs := collectDeviceIDs(updates)
	if len(deviceIDs) == 0 {
		return nil
	}

	existing, err := r.fetchExistingFirstSeen(ctx, deviceIDs)
	if err != nil {
		return err
	}

	firstSeen := computeBatchFirstSeen(updates, existing)
	applyFirstSeenMetadata(updates, firstSeen)
	return nil
}

func collectDeviceIDs(updates []*models.DeviceUpdate) []string {
	if len(updates) == 0 {
		return nil
	}

	idSet := make(map[string]struct{}, len(updates))
	for _, update := range updates {
		if update == nil || update.DeviceID == "" {
			continue
		}
		idSet[update.DeviceID] = struct{}{}
	}

	if len(idSet) == 0 {
		return nil
	}

	deviceIDs := make([]string, 0, len(idSet))
	for id := range idSet {
		deviceIDs = append(deviceIDs, id)
	}
	return deviceIDs
}

func (r *DeviceRegistry) fetchExistingFirstSeen(ctx context.Context, deviceIDs []string) (map[string]time.Time, error) {
	result := make(map[string]time.Time, len(deviceIDs))
	if len(deviceIDs) == 0 {
		return result, nil
	}

	missing := make([]string, 0, len(deviceIDs))

	for _, rawID := range deviceIDs {
		id := strings.TrimSpace(rawID)
		if id == "" {
			continue
		}
		if ts, ok := r.lookupFirstSeenTimestamp(id); ok {
			result[id] = ts
			continue
		}
		missing = append(missing, id)
	}

	if len(missing) == 0 || r.db == nil {
		return result, nil
	}

	chunkSize := r.firstSeenLookupChunkSize
	if chunkSize <= 0 {
		chunkSize = len(missing)
	}

	for start := 0; start < len(missing); start += chunkSize {
		end := start + chunkSize
		if end > len(missing) {
			end = len(missing)
		}

		devices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, nil, missing[start:end])
		if err != nil {
			return nil, fmt.Errorf("lookup existing devices: %w", err)
		}

		for _, device := range devices {
			if device != nil && device.DeviceID != "" && !device.FirstSeen.IsZero() {
				result[device.DeviceID] = device.FirstSeen.UTC()
			}
		}
	}

	return result, nil
}

func (r *DeviceRegistry) lookupFirstSeenTimestamp(deviceID string) (time.Time, bool) {
	if strings.TrimSpace(deviceID) == "" {
		return time.Time{}, false
	}

	r.mu.RLock()
	defer r.mu.RUnlock()

	record, ok := r.devices[deviceID]
	if !ok || record == nil {
		return time.Time{}, false
	}

	if record.FirstSeen.IsZero() {
		return time.Time{}, false
	}

	return record.FirstSeen.UTC(), true
}

func computeBatchFirstSeen(updates []*models.DeviceUpdate, seed map[string]time.Time) map[string]time.Time {
	result := make(map[string]time.Time, len(seed)+len(updates))
	for id, ts := range seed {
		if ts.IsZero() {
			continue
		}
		result[id] = ts.UTC()
	}

	for _, update := range updates {
		if update == nil || update.DeviceID == "" {
			continue
		}

		earliest := update.Timestamp
		if earliest.IsZero() {
			earliest = time.Now()
		}

		if update.Metadata != nil {
			if ts, ok := parseFirstSeenTimestamp(update.Metadata["_first_seen"]); ok && ts.Before(earliest) {
				earliest = ts
			}
			for _, key := range []string{"first_seen", "integration_first_seen", "armis_first_seen"} {
				if ts, ok := parseFirstSeenTimestamp(update.Metadata[key]); ok && ts.Before(earliest) {
					earliest = ts
				}
			}
		}

		if existing, ok := result[update.DeviceID]; ok && !existing.IsZero() && existing.Before(earliest) {
			earliest = existing
		}

		if current, ok := result[update.DeviceID]; !ok || earliest.Before(current) {
			result[update.DeviceID] = earliest.UTC()
		}
	}

	return result
}

func applyFirstSeenMetadata(updates []*models.DeviceUpdate, firstSeen map[string]time.Time) {
	if len(firstSeen) == 0 {
		return
	}

	for _, update := range updates {
		if update == nil || update.DeviceID == "" {
			continue
		}

		earliest, ok := firstSeen[update.DeviceID]
		if !ok || earliest.IsZero() {
			continue
		}

		if update.Metadata == nil {
			update.Metadata = make(map[string]string)
		}

		update.Metadata["_first_seen"] = earliest.UTC().Format(time.RFC3339Nano)
	}
}

func parseFirstSeenTimestamp(raw string) (time.Time, bool) {
	candidates := normalizeTimestampCandidates(raw)
	if len(candidates) == 0 {
		return time.Time{}, false
	}

	for _, candidate := range candidates {
		for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
			if ts, err := time.Parse(layout, candidate); err == nil {
				return ts.UTC(), true
			}
		}
	}

	for _, candidate := range candidates {
		for _, layout := range []string{
			"2006-01-02 15:04:05.999999",
			"2006-01-02 15:04:05.999",
			"2006-01-02 15:04:05",
		} {
			if ts, err := time.Parse(layout, candidate); err == nil {
				return ts.UTC(), true
			}
		}
	}

	return time.Time{}, false
}

func normalizeTimestampCandidates(raw string) []string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil
	}

	seen := make(map[string]struct{}, 6)
	push := func(candidate string) {
		if candidate == "" {
			return
		}
		if _, ok := seen[candidate]; ok {
			return
		}
		seen[candidate] = struct{}{}
	}

	push(trimmed)

	upper := strings.ToUpper(trimmed)
	if strings.HasSuffix(upper, " UTC") {
		base := strings.TrimSpace(trimmed[:len(trimmed)-4])
		push(base + "Z")
	}

	if len(trimmed) > 10 && trimmed[10] == ' ' {
		push(trimmed[:10] + "T" + trimmed[11:])
	}

	initialCandidates := make([]string, 0, len(seen))
	for candidate := range seen {
		initialCandidates = append(initialCandidates, candidate)
	}

	for _, candidate := range initialCandidates {
		if colonized := insertTimezoneColon(candidate); colonized != candidate {
			push(colonized)
		}

		if len(candidate) > 10 && candidate[10] == ' ' {
			withT := candidate[:10] + "T" + candidate[11:]
			push(withT)
			if colonized := insertTimezoneColon(withT); colonized != withT {
				push(colonized)
			}
		}
	}

	results := make([]string, 0, len(seen))
	for candidate := range seen {
		results = append(results, candidate)
	}

	return results
}

func insertTimezoneColon(ts string) string {
	idx := strings.LastIndexAny(ts, "+-")
	if idx == -1 || idx < len(ts)-5 {
		return ts
	}

	tz := ts[idx:]
	if len(tz) != 5 {
		return ts
	}

	if (tz[0] != '+' && tz[0] != '-') || !allDigits(tz[1:]) {
		return ts
	}

	return ts[:idx] + fmt.Sprintf("%c%s:%s", tz[0], tz[1:3], tz[3:])
}

func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func (r *DeviceRegistry) filterObsoleteUpdates(ctx context.Context, updates []*models.DeviceUpdate) ([]*models.DeviceUpdate, int, error) {
	if len(updates) == 0 {
		return updates, 0, nil
	}

	deviceIDs := collectDeviceIDs(updates)
	if len(deviceIDs) == 0 {
		return updates, 0, nil
	}

	devices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, nil, deviceIDs)
	if err != nil {
		return updates, 0, fmt.Errorf("lookup tombstoned devices: %w", err)
	}

	lastDeleted := make(map[string]time.Time, len(devices))
	for _, device := range devices {
		if device == nil || device.DeviceID == "" {
			continue
		}
		if device.Metadata == nil || device.Metadata.Value == nil {
			continue
		}
		if deletedAt := extractDeletionTimestamp(device.Metadata.Value); !deletedAt.IsZero() {
			lastDeleted[device.DeviceID] = deletedAt
		}
	}

	if len(lastDeleted) == 0 {
		return updates, 0, nil
	}

	filtered := make([]*models.DeviceUpdate, 0, len(updates))
	var dropped int

	for _, update := range updates {
		if update == nil || update.DeviceID == "" {
			continue
		}
		if shouldBypassDeletionFilter(update) {
			filtered = append(filtered, update)
			continue
		}

		deletedAt, ok := lastDeleted[update.DeviceID]
		if !ok || deletedAt.IsZero() {
			filtered = append(filtered, update)
			continue
		}

		if update.Source == models.DiscoverySourceSelfReported || update.Source == models.DiscoverySourceServiceRadar {
			// Block self-reported updates for tombstoned devices unless the update is fresh,
			// which can happen during re-onboarding when a device comes back online.
			if !update.Timestamp.After(deletedAt) {
				dropped++
				r.logger.Info().
					Str("device_id", update.DeviceID).
					Str("source", string(update.Source)).
					Time("deleted_at", deletedAt).
					Time("update_ts", update.Timestamp).
					Msg("Blocking self-reported update for tombstoned device")
				continue
			}
			// Update is newer than deletion - allow re-onboarding
			r.logger.Info().
				Str("device_id", update.DeviceID).
				Str("source", string(update.Source)).
				Time("deleted_at", deletedAt).
				Time("update_ts", update.Timestamp).
				Msg("Allowing self-reported update for re-onboarding (update is newer than deletion)")
		}

		updateTimestamp := update.Timestamp
		if updateTimestamp.IsZero() {
			updateTimestamp = time.Time{}
		}

		if !updateTimestamp.After(deletedAt) {
			dropped++
			r.logger.Debug().
				Str("device_id", update.DeviceID).
				Time("deleted_at", deletedAt).
				Time("update_ts", updateTimestamp).
				Str("source", string(update.Source)).
				Msg("Dropping stale update for tombstoned device")
			continue
		}

		filtered = append(filtered, update)
	}

	return filtered, dropped, nil
}

func extractDeletionTimestamp(metadata map[string]string) time.Time {
	for _, key := range []string{"_deleted_at", "deleted_at"} {
		val := strings.TrimSpace(metadata[key])
		if val == "" {
			continue
		}
		if ts, ok := parseFirstSeenTimestamp(val); ok {
			return ts
		}
	}
	return time.Time{}
}

func shouldBypassDeletionFilter(update *models.DeviceUpdate) bool {
	if update == nil || update.Metadata == nil {
		return false
	}

	for _, key := range []string{"_deleted", "deleted"} {
		if val, ok := update.Metadata[key]; ok && strings.EqualFold(val, "true") {
			return true
		}
	}

	if _, ok := update.Metadata["_merged_into"]; ok {
		return true
	}

	return false
}

// scrubArmisCanonical removes Armis-provided canonical hints so strong Armis identifiers
// are treated as authoritative even when Armis reuses canonical_device_id across devices.
func scrubArmisCanonical(update *models.DeviceUpdate) {
	if update == nil || update.Metadata == nil {
		return
	}

	if !strings.EqualFold(update.Metadata["integration_type"], "armis") {
		return
	}

	delete(update.Metadata, "canonical_device_id")
	delete(update.Metadata, "canonical_partition")
	delete(update.Metadata, "canonical_metadata_hash")
	delete(update.Metadata, "canonical_revision")

	if update.DeviceID != "" && !isServiceDeviceID(update.DeviceID) {
		update.DeviceID = ""
	}
}

// normalizeUpdate ensures a DeviceUpdate has the minimum required information.
func (r *DeviceRegistry) normalizeUpdate(update *models.DeviceUpdate) {
	if update.IP == "" {
		r.logger.Debug().Msg("Skipping update with no IP address")
		return // Or handle error
	}

	// If DeviceID is completely empty, generate one
	if update.DeviceID == "" {
		// Check if this is a service component (poller/agent/checker)
		if update.ServiceType != nil && update.ServiceID != "" {
			// Generate service-aware device ID: serviceradar:type:id
			update.DeviceID = models.GenerateServiceDeviceID(*update.ServiceType, update.ServiceID)
			update.Partition = models.ServiceDevicePartition
			update.Source = models.DiscoverySourceServiceRadar

			r.logger.Debug().
				Str("device_id", update.DeviceID).
				Str("service_type", string(*update.ServiceType)).
				Str("service_id", update.ServiceID).
				Msg("Generated service device ID")
		} else {
			// Generate network device ID: partition:ip
			if update.Partition == "" {
				update.Partition = defaultPartition
			}

			update.DeviceID = models.GenerateNetworkDeviceID(update.Partition, update.IP)

			r.logger.Debug().
				Str("device_id", update.DeviceID).
				Msg("Generated network device ID")
		}
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

	// Self-reported devices and ServiceRadar components are always available by definition
	if update.Source == models.DiscoverySourceSelfReported || update.Source == models.DiscoverySourceServiceRadar {
		update.IsAvailable = true
	}

	if update.Timestamp.IsZero() {
		update.Timestamp = time.Now()
	}

	if update.Confidence == 0 {
		update.Confidence = models.GetSourceConfidence(update.Source)
	}
}

func hasStrongIdentity(update *models.DeviceUpdate) bool {
	if update == nil {
		return false
	}

	if isAuthoritativeServiceUpdate(update) {
		return true
	}

	if update.Metadata != nil {
		if strings.TrimSpace(update.Metadata["armis_device_id"]) != "" {
			return true
		}
		if strings.TrimSpace(update.Metadata["canonical_device_id"]) != "" {
			return true
		}
		if strings.TrimSpace(update.Metadata["integration_id"]) != "" {
			return true
		}
		if strings.TrimSpace(update.Metadata["netbox_device_id"]) != "" {
			return true
		}
	}
	if update.MAC != nil && strings.TrimSpace(*update.MAC) != "" {
		return true
	}
	return false
}

func isAuthoritativeServiceUpdate(update *models.DeviceUpdate) bool {
	if update == nil {
		return false
	}

	if update.Source == models.DiscoverySourceServiceRadar || update.Source == models.DiscoverySourceSelfReported {
		return true
	}

	if update.ServiceType != nil {
		return true
	}

	return isServiceDeviceID(update.DeviceID)
}

func (r *DeviceRegistry) GetDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error) {
	trimmed := strings.TrimSpace(deviceID)
	if trimmed == "" {
		return nil, fmt.Errorf("%w: %s", ErrDeviceNotFound, deviceID)
	}

	record, ok := r.GetDeviceRecord(trimmed)
	if !ok || record == nil {
		return nil, fmt.Errorf("%w: %s", ErrDeviceNotFound, trimmed)
	}

	return UnifiedDeviceFromRecord(record), nil
}

func (r *DeviceRegistry) GetDevicesByIP(ctx context.Context, ip string) ([]*models.UnifiedDevice, error) {
	records := r.FindDevicesByIP(ip)
	return UnifiedDeviceSlice(records), nil
}

func (r *DeviceRegistry) ListDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error) {
	records := r.snapshotRecords()
	if len(records) == 0 {
		return nil, nil
	}

	sortRecordsByLastSeenDesc(records)

	if offset >= len(records) {
		return []*models.UnifiedDevice{}, nil
	}

	end := len(records)
	if limit > 0 && offset+limit < end {
		end = offset + limit
	}

	window := records[offset:end]
	return UnifiedDeviceSlice(window), nil
}

// SearchDevices returns devices whose indexed fields contain the query string.
func (r *DeviceRegistry) SearchDevices(query string, limit int) []*models.UnifiedDevice {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil
	}

	records := r.snapshotRecords()
	if len(records) == 0 {
		return nil
	}

	var matchedRecords []*DeviceRecord

	scores := make(map[string]int)

	if r.searchIndex != nil {
		matches := r.searchIndex.Search(query)
		if len(matches) > 0 {
			matchedRecords = make([]*DeviceRecord, 0, len(matches))
			for _, match := range matches {
				if record, ok := r.GetDeviceRecord(match.ID); ok && record != nil {
					matchedRecords = append(matchedRecords, record)
					scores[record.DeviceID] = match.Score
				}
			}
		}
	}

	if len(matchedRecords) == 0 {
		// Fallback to linear scan if trigram index missing or no matches.
		lowerQuery := strings.ToLower(query)
		for _, record := range records {
			if strings.Contains(searchTextForRecord(record), lowerQuery) {
				matchedRecords = append(matchedRecords, record)
				scores[record.DeviceID]++
			}
		}
	}

	if len(matchedRecords) == 0 {
		return nil
	}

	lowerQuery := strings.ToLower(query)
	for _, record := range matchedRecords {
		score := scores[record.DeviceID]

		if strings.EqualFold(record.DeviceID, query) {
			score += 10
		}

		switch {
		case strings.EqualFold(record.IP, query):
			score += 8
		case strings.HasPrefix(strings.ToLower(record.IP), lowerQuery):
			score += 4
		case strings.Contains(strings.ToLower(record.IP), lowerQuery):
			score += 2
		}

		if record.Hostname != nil {
			hostLower := strings.ToLower(*record.Hostname)
			switch {
			case hostLower == lowerQuery:
				score += 6
			case strings.HasPrefix(hostLower, lowerQuery):
				score += 3
			case strings.Contains(hostLower, lowerQuery):
				score++
			}
		}

		if record.MAC != nil && strings.EqualFold(*record.MAC, query) {
			score += 5
		}

		scores[record.DeviceID] = score
	}

	sort.Slice(matchedRecords, func(i, j int) bool {
		ri := matchedRecords[i]
		rj := matchedRecords[j]

		scoreI := scores[ri.DeviceID]
		scoreJ := scores[rj.DeviceID]

		if scoreI != scoreJ {
			return scoreI > scoreJ
		}

		if ri.LastSeen.Equal(rj.LastSeen) {
			return ri.DeviceID < rj.DeviceID
		}
		return ri.LastSeen.After(rj.LastSeen)
	})

	if limit > 0 && limit < len(matchedRecords) {
		matchedRecords = matchedRecords[:limit]
	}

	return UnifiedDeviceSlice(matchedRecords)
}

func (r *DeviceRegistry) GetMergedDevice(ctx context.Context, deviceIDOrIP string) (*models.UnifiedDevice, error) {
	if device, err := r.GetDevice(ctx, deviceIDOrIP); err == nil {
		return device, nil
	}

	devices, err := r.GetDevicesByIP(ctx, deviceIDOrIP)
	if err != nil {
		return nil, fmt.Errorf("failed to get device by ID or IP %s: %w", deviceIDOrIP, err)
	}

	if len(devices) == 0 {
		return nil, fmt.Errorf("%w: %s", ErrDeviceNotFound, deviceIDOrIP)
	}

	return devices[0], nil
}

func (r *DeviceRegistry) FindRelatedDevices(ctx context.Context, deviceID string) ([]*models.UnifiedDevice, error) {
	primaryRecord, ok := r.GetDeviceRecord(deviceID)
	if !ok || primaryRecord == nil {
		return nil, fmt.Errorf("%w: %s", ErrDeviceNotFound, deviceID)
	}

	relatedRecords := r.FindDevicesByIP(primaryRecord.IP)
	result := make([]*models.UnifiedDevice, 0, len(relatedRecords))
	for _, record := range relatedRecords {
		if record.DeviceID == primaryRecord.DeviceID {
			continue
		}
		result = append(result, UnifiedDeviceFromRecord(record))
	}

	return result, nil
}

// DeleteLocal removes a device from the in-memory registry without emitting tombstones.
func (r *DeviceRegistry) DeleteLocal(deviceID string) {
	r.DeleteDeviceRecord(deviceID)
}

func extractPartitionFromDeviceID(deviceID string) string {
	parts := strings.Split(deviceID, ":")
	if len(parts) >= 2 {
		return parts[0]
	}

	return defaultPartition
}
