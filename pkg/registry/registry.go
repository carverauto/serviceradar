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
	identityEngine           *IdentityEngine
	firstSeenLookupChunkSize int
	identityCfg              *models.IdentityReconciliationConfig
	graphWriter              GraphWriter
	reconcileInterval        time.Duration
	syncInterval             time.Duration

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
//
// The simplified DIRE (Device Identity and Reconciliation Engine) flow:
//  1. Normalize and filter invalid updates
//  2. Handle service components and network sightings
//  3. Resolve device IDs using IdentityEngine (strong identifiers -> deterministic sr: UUID)
//  4. Register device identifiers (DB unique constraint prevents duplicates)
//  5. Publish updates (no deduplication needed - DB handles uniqueness)
//  6. Update in-memory cache
//
// No IP uniqueness constraint, no tombstones, no soft deletes. The device_identifiers
// table's unique constraint on (identifier_type, identifier_value, partition) ensures
// one device per strong identifier.
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

	// Step 1: Normalize and filter out invalid updates (e.g., empty IP)
	valid := make([]*models.DeviceUpdate, 0, len(updates))
	var droppedEmptyIP int
	for _, u := range updates {
		scrubArmisCanonical(u)
		r.normalizeUpdate(u)
		deviceupdate.SanitizeMetadata(u)
		// Allow empty IPs for service components (gateways, agents, checkers)
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

	// Step 2: Handle service components and network sightings
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

	// Step 3: Resolve device IDs to canonical ServiceRadar UUIDs using the unified IdentityEngine
	if r.identityEngine != nil {
		if err := r.identityEngine.ResolveDeviceIDs(ctx, valid); err != nil {
			r.logger.Warn().Err(err).Msg("Device identity resolution failed")
		}
		ensureCanonicalDeviceIDMetadata(valid)
	}

	// Step 4: Register device identifiers (DB unique constraint prevents duplicates)
	if r.identityEngine != nil {
		for _, u := range valid {
			if isAuthoritativeServiceUpdate(u) {
				continue
			}
			ids := r.identityEngine.ExtractStrongIdentifiers(u)
			if ids.HasStrongIdentifier() {
				if err := r.identityEngine.RegisterDeviceIdentifiers(ctx, u.DeviceID, ids); err != nil {
					r.logger.Warn().Err(err).Str("device_id", u.DeviceID).Msg("Failed to register device identifiers")
				}
			}
		}
	}

	// Annotate first_seen timestamps
	if err := r.annotateFirstSeen(ctx, valid); err != nil {
		r.logger.Warn().Err(err).Msg("Failed to annotate _first_seen metadata")
	}

	// Step 5: Publish updates to the device_updates stream
	// No deduplication or IP conflict resolution needed - the IdentityEngine ensures
	// consistent device IDs based on strong identifiers, and the device_identifiers
	// table's unique constraint prevents duplicate devices.
	if err := r.db.PublishBatchDeviceUpdates(ctx, valid); err != nil {
		return fmt.Errorf("failed to publish device updates: %w", err)
	}

	// Step 6: Update in-memory cache
	r.applyRegistryStore(valid, nil)

	if r.graphWriter != nil {
		r.graphWriter.WriteGraph(ctx, valid)
	}

	r.logger.Debug().
		Int("incoming_updates", len(updates)).
		Int("valid_updates", len(valid)).
		Int("published_updates", len(valid)).
		Int("dropped_empty_ip", droppedEmptyIP).
		Msg("Registry batch processed")

	return nil
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

	profileName := defaultPartition
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

	current, err := r.db.CountOCSFDevices(ctx)
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
SELECT metadata->>'armis_device_id' AS id, uid
FROM ocsf_devices
WHERE metadata ? 'armis_device_id'
  AND metadata->>'armis_device_id' = ANY($1)
ORDER BY modified_time DESC`

	return r.resolveIdentifiersCNPG(ctx, ids, query, nil, out)
}

func (r *DeviceRegistry) resolveIPsToCanonicalCNPG(ctx context.Context, ips []string, out map[string]string) error {
	const query = `
SELECT DISTINCT ON (ip) ip, uid
FROM ocsf_devices
WHERE ip = ANY($1)
  AND (
        metadata ? 'armis_device_id'
     OR (metadata ? 'integration_type' AND metadata->>'integration_type' = $2)
     OR (mac IS NOT NULL AND mac <> '')
      )
  AND COALESCE(lower(metadata->>'_deleted'),'false') <> 'true'
  AND COALESCE(lower(metadata->>'deleted'),'false') <> 'true'
ORDER BY ip, last_seen_time DESC`

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
		return fmt.Sprintf(`SELECT uid, metadata->>'armis_device_id' AS id, modified_time
              FROM ocsf_devices
              WHERE metadata ? 'armis_device_id'
                AND metadata->>'armis_device_id' IN (%s)
              ORDER BY modified_time DESC`, list)
	}
	extract := func(row map[string]any) (string, string) {
		idVal, _ := row["id"].(string)
		dev, _ := row["uid"].(string)
		return idVal, dev
	}
	return r.resolveIdentifiers(ctx, ids, out, buildQuery, extract)
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

	// Resolve IPs using CNPG directly (no longer using separate identity resolvers)
	var resolved map[string]string

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
                uid
              FROM ocsf_devices
              WHERE ip IN (%s)
                AND (metadata ? 'armis_device_id'
                     OR (metadata ? 'integration_type' AND metadata->>'integration_type'='%s')
                     OR (mac IS NOT NULL AND mac != ''))
              ORDER BY modified_time DESC`, list, integrationTypeNetbox)
			}
			extract := func(row map[string]any) (string, string) {
				ip, _ := row["ip"].(string)
				dev, _ := row["uid"].(string)
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

// resolveCanonicalIPMappings returns IP to device ID mappings.
// With the DIRE simplification, there are no tombstones or merge chains to resolve.
// Devices are directly mapped by their identifiers.
func (r *DeviceRegistry) resolveCanonicalIPMappings(_ context.Context, mappings map[string]string) map[string]string {
	return mappings
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

// collectDeviceIDs extracts unique device IDs from a slice of updates
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

		devices, err := r.db.GetOCSFDevicesByIPsOrIDs(ctx, nil, missing[start:end])
		if err != nil {
			return nil, fmt.Errorf("lookup existing devices: %w", err)
		}

		for _, device := range devices {
			if device != nil && device.UID != "" && device.FirstSeenTime != nil && !device.FirstSeenTime.IsZero() {
				result[device.UID] = device.FirstSeenTime.UTC()
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
		// Check if this is a service component (gateway/agent/checker)
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

// ensureCanonicalDeviceIDMetadata sets canonical_device_id metadata to match DeviceID for all updates.
// This is required for the stats aggregator's isCanonicalRecord check to correctly count devices.
func ensureCanonicalDeviceIDMetadata(updates []*models.DeviceUpdate) {
	for _, u := range updates {
		if u == nil || u.DeviceID == "" {
			continue
		}
		if u.Metadata == nil {
			u.Metadata = make(map[string]string)
		}
		u.Metadata["canonical_device_id"] = u.DeviceID
	}
}

func (r *DeviceRegistry) GetDevice(ctx context.Context, deviceID string) (*models.OCSFDevice, error) {
	trimmed := strings.TrimSpace(deviceID)
	if trimmed == "" {
		return nil, fmt.Errorf("%w: %s", ErrDeviceNotFound, deviceID)
	}

	record, ok := r.GetDeviceRecord(trimmed)
	if !ok || record == nil {
		if r.logger != nil {
			r.logger.Debug().
				Str("device_id", trimmed).
				Msg("Device lookup miss in registry")
		}
		return nil, fmt.Errorf("%w: %s", ErrDeviceNotFound, trimmed)
	}

	return OCSFDeviceFromRecord(record), nil
}

func (r *DeviceRegistry) GetDeviceByIDStrict(ctx context.Context, deviceID string) (*models.OCSFDevice, error) {
	return r.GetDevice(ctx, deviceID)
}

func (r *DeviceRegistry) GetDevicesByIP(ctx context.Context, ip string) ([]*models.OCSFDevice, error) {
	records := r.FindDevicesByIP(ip)
	return OCSFDeviceSlice(records), nil
}

func (r *DeviceRegistry) ListDevices(ctx context.Context, limit, offset int) ([]*models.OCSFDevice, error) {
	records := r.snapshotRecords()
	if len(records) == 0 {
		return nil, nil
	}

	sortRecordsByLastSeenDesc(records)

	if offset >= len(records) {
		return []*models.OCSFDevice{}, nil
	}

	end := len(records)
	if limit > 0 && offset+limit < end {
		end = offset + limit
	}

	window := records[offset:end]
	return OCSFDeviceSlice(window), nil
}

// SearchDevices returns devices whose indexed fields contain the query string.
func (r *DeviceRegistry) SearchDevices(query string, limit int) []*models.OCSFDevice {
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

	return OCSFDeviceSlice(matchedRecords)
}

func (r *DeviceRegistry) FindRelatedDevices(ctx context.Context, deviceID string) ([]*models.OCSFDevice, error) {
	primaryRecord, ok := r.GetDeviceRecord(deviceID)
	if !ok || primaryRecord == nil {
		return nil, fmt.Errorf("%w: %s", ErrDeviceNotFound, deviceID)
	}

	relatedRecords := r.FindDevicesByIP(primaryRecord.IP)
	result := make([]*models.OCSFDevice, 0, len(relatedRecords))
	for _, record := range relatedRecords {
		if record.DeviceID == primaryRecord.DeviceID {
			continue
		}
		result = append(result, OCSFDeviceFromRecord(record))
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
