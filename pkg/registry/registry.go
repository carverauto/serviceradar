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
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/deviceupdate"
	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	// ErrDeviceNotFound is returned when a device is not found
	ErrDeviceNotFound = errors.New("device not found")
)

const (
	defaultPartition                = "default"
	identitySourceArmis             = "armis_id"
	identitySourceNetbox            = "netbox_id"
	identitySourceMAC               = "mac"
	identitySourceDeviceID          = "device_id"
	integrationTypeNetbox           = "netbox"
	defaultFirstSeenLookupChunkSize = 512
)

// Option configures DeviceRegistry behaviour.
type Option func(*DeviceRegistry)

// DeviceRegistry is the concrete implementation of the registry.Manager.
type DeviceRegistry struct {
	db                       db.Service
	logger                   logger.Logger
	identityPublisher        *identityPublisher
	identityResolver         *identityResolver
	firstSeenLookupChunkSize int
}

// NewDeviceRegistry creates a new, authoritative device registry.
func NewDeviceRegistry(database db.Service, log logger.Logger, opts ...Option) *DeviceRegistry {
	r := &DeviceRegistry{
		db:                       database,
		logger:                   log,
		firstSeenLookupChunkSize: defaultFirstSeenLookupChunkSize,
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

	// Normalize and filter out invalid updates (e.g., empty IP)
	valid := make([]*models.DeviceUpdate, 0, len(updates))
	// Batch metrics
	var droppedEmptyIP int
	for _, u := range updates {
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

	// Hydrate canonical metadata via KV if available
	if r.identityResolver != nil {
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

	// Publish directly to the device_updates stream
	if err := r.db.PublishBatchDeviceUpdates(ctx, batch); err != nil {
		return fmt.Errorf("failed to publish device updates: %w", err)
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
	if update.Metadata != nil {
		if canonical := strings.TrimSpace(update.Metadata["canonical_device_id"]); canonical != "" {
			return canonical
		}
	}
	deviceID := strings.TrimSpace(update.DeviceID)
	if deviceID != "" {
		return deviceID
	}
	if update.Partition != "" && update.IP != "" {
		return fmt.Sprintf("%s:%s", strings.TrimSpace(update.Partition), strings.TrimSpace(update.IP))
	}
	return strings.TrimSpace(update.IP)
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

func (r *DeviceRegistry) resolveArmisIDs(ctx context.Context, ids []string, out map[string]string) error {
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
	buildQuery := func(list string) string {
		return fmt.Sprintf(`SELECT device_id, ip, _tp_time
              FROM table(unified_devices)
              WHERE ip IN (%s)
                AND (has(map_keys(metadata),'armis_device_id')
                     OR (has(map_keys(metadata),'integration_type') AND metadata['integration_type']='%s')
                     OR (mac IS NOT NULL AND mac != ''))
              ORDER BY _tp_time DESC`, list, integrationTypeNetbox)
	}
	extract := func(row map[string]any) (string, string) {
		ip, _ := row["ip"].(string)
		dev, _ := row["device_id"].(string)
		return ip, dev
	}
	return r.resolveIdentifiers(ctx, ips, out, buildQuery, extract)
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

	chunkSize := r.firstSeenLookupChunkSize
	if chunkSize <= 0 {
		chunkSize = len(deviceIDs)
	}

	for start := 0; start < len(deviceIDs); start += chunkSize {
		end := start + chunkSize
		if end > len(deviceIDs) {
			end = len(deviceIDs)
		}

		devices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, nil, deviceIDs[start:end])
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

func (r *DeviceRegistry) GetDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error) {
	devices, err := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, nil, []string{deviceID})
	if err != nil {
		return nil, fmt.Errorf("failed to get device %s: %w", deviceID, err)
	}

	if len(devices) == 0 {
		return nil, fmt.Errorf("%w: %s", ErrDeviceNotFound, deviceID)
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
		return nil, fmt.Errorf("%w: %s", ErrDeviceNotFound, deviceIDOrIP)
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
