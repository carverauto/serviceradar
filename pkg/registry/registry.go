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
	defaultPartition      = "default"
	identitySourceArmis   = "armis_id"
	identitySourceNetbox  = "netbox_id"
	identitySourceMAC     = "mac"
	integrationTypeNetbox = "netbox"
)

// Option configures DeviceRegistry behaviour.
type Option func(*DeviceRegistry)

// DeviceRegistry is the concrete implementation of the registry.Manager.
type DeviceRegistry struct {
	db                db.Service
	logger            logger.Logger
	identityPublisher *identityPublisher
	identityResolver  *identityResolver
}

// NewDeviceRegistry creates a new, authoritative device registry.
func NewDeviceRegistry(database db.Service, log logger.Logger, opts ...Option) *DeviceRegistry {
	r := &DeviceRegistry{
		db:     database,
		logger: log,
	}
	for _, opt := range opts {
		if opt != nil {
			opt(r)
		}
	}
	return r
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
		if u.IP == "" {
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
	var tombstoneCount int
	var skippedSweepNoIdentity int

	for _, u := range valid {
		origID := u.DeviceID
		canonicalID, via := r.lookupCanonicalFromMaps(u, maps)

		if u.Source == models.DiscoverySourceSweep {
			if !hasStrongIdentity(u) && canonicalID == "" {
				skippedSweepNoIdentity++
				continue
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

	batch := canonicalized
	if len(tombstones) > 0 {
		batch = append(batch, tombstones...)
	}

	// Publish directly to the device_updates stream
	if err := r.db.PublishBatchDeviceUpdates(ctx, batch); err != nil {
		return fmt.Errorf("failed to publish device updates: %w", err)
	}

	r.logger.Info().
		Int("incoming_updates", len(updates)).
		Int("valid_updates", len(valid)).
		Int("published_updates", len(batch)).
		Int("dropped_empty_ip", droppedEmptyIP).
		Int("canonicalized_by_armis_id", canonByArmisID).
		Int("canonicalized_by_netbox_id", canonByNetboxID).
		Int("canonicalized_by_mac", canonByMAC).
		Int("tombstones_emitted", tombstoneCount).
		Int("skipped_sweep_no_identity", skippedSweepNoIdentity).
		Msg("Registry batch processed")

	return nil
}

// identityMaps holds batch-resolved mappings from identity → canonical device_id
type identityMaps struct {
	armis map[string]string
	netbx map[string]string
	mac   map[string]string
	ip    map[string]string
}

func (r *DeviceRegistry) buildIdentityMaps(ctx context.Context, updates []*models.DeviceUpdate) (*identityMaps, error) {
	m := &identityMaps{armis: map[string]string{}, netbx: map[string]string{}, mac: map[string]string{}, ip: map[string]string{}}

	// Collect unique identities
	armisSet := make(map[string]struct{})
	netboxSet := make(map[string]struct{})
	macSet := make(map[string]struct{})
	ipSet := make(map[string]struct{})

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
		}
		if u.MAC != nil && *u.MAC != "" {
			for _, mac := range parseMACList(*u.MAC) {
				macSet[mac] = struct{}{}
			}
		}
		if u.IP != "" {
			ipSet[u.IP] = struct{}{}
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
