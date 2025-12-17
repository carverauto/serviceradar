package core

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// identityRow holds a single unified_devices row with the identity key extracted.
type identityRow struct {
	deviceID string
	key      string // identity key (armis_id or netbox_id)
	kind     identitymap.Kind
	ts       time.Time
	ip       string
	metadata map[string]string
}

// BackfillOptions controls how historical identity reconciliation is executed.
type BackfillOptions struct {
	DryRun bool
}

func cloneMetadata(src map[string]string) map[string]string {
	if len(src) == 0 {
		return map[string]string{}
	}

	dst := make(map[string]string, len(src))
	for k, v := range src {
		dst[k] = v
	}

	return dst
}

func (r identityRow) toDeviceUpdate() *models.DeviceUpdate {
	if r.deviceID == "" {
		return nil
	}

	meta := cloneMetadata(r.metadata)

	update := &models.DeviceUpdate{
		DeviceID:    r.deviceID,
		IP:          r.ip,
		Partition:   partitionFromDeviceID(r.deviceID),
		Source:      models.DiscoverySourceIntegration,
		Timestamp:   r.ts,
		Metadata:    meta,
		IsAvailable: true,
	}

	return update
}

type identityBackfillStats struct {
	totalCandidates int
	totalGroups     int
	totalTombstones int
}

func processIdentityRows(
	rows []identityRow,
	opts BackfillOptions,
	emit func(*models.DeviceUpdate) error,
	log logger.Logger,
	stats *identityBackfillStats,
) error {
	if len(rows) == 0 {
		return nil
	}

	stats.totalCandidates += len(rows)

	groups := make(map[string][]identityRow)
	for _, row := range rows {
		if row.key == "" || row.deviceID == "" {
			continue
		}
		groups[row.key] = append(groups[row.key], row)
	}

	for key, members := range groups {
		if len(members) <= 1 {
			continue
		}

		stats.totalGroups++

		canonical := members[0]
		for _, candidate := range members[1:] {
			if candidate.ts.After(canonical.ts) {
				canonical = candidate
			}
		}

		for _, member := range members {
			if member.deviceID == canonical.deviceID {
				continue
			}

			stats.totalTombstones++

			tombstone := &models.DeviceUpdate{
				DeviceID:    member.deviceID,
				Partition:   partitionFromDeviceID(member.deviceID),
				IP:          member.ip,
				Source:      models.DiscoverySourceIntegration,
				Timestamp:   time.Now(),
				IsAvailable: false,
				Metadata:    map[string]string{"_merged_into": canonical.deviceID},
			}

			log.Info().
				Str("identity_key", key).
				Str("from_id", member.deviceID).
				Str("to_id", canonical.deviceID).
				Msg("Backfill: tombstoning duplicate device")

			if err := emit(tombstone); err != nil {
				return err
			}
		}
	}

	return nil
}

// BackfillIdentityTombstones scans unified_devices for duplicate device_ids that share
// a strong identity (Armis ID or NetBox ID) and emits tombstones to merge duplicates
// into the canonical device (most recent by timestamp).
//
//nolint:gocognit,funlen // historical backfill logic remains complex
func BackfillIdentityTombstones(ctx context.Context, database db.Service, log logger.Logger, opts BackfillOptions) error {
	const chunkSize = 500
	tombBatch := make([]*models.DeviceUpdate, 0, chunkSize)
	stats := identityBackfillStats{}

	emit := func(update *models.DeviceUpdate) error {
		if update == nil {
			return nil
		}
		if opts.DryRun {
			return nil
		}

		tombBatch = append(tombBatch, update)
		if len(tombBatch) < chunkSize {
			return nil
		}

		if err := database.PublishBatchDeviceUpdates(ctx, tombBatch); err != nil {
			return fmt.Errorf("publish tombstones: %w", err)
		}

		tombBatch = tombBatch[:0]
		return nil
	}

	process := func(rows []identityRow) error {
		return processIdentityRows(rows, opts, emit, log, &stats)
	}

	armisRows, err := queryIdentityRows(ctx, database, `
        SELECT device_id, ip, metadata, metadata['armis_device_id'] AS key, _tp_time
        FROM table(unified_devices)
        WHERE has(map_keys(metadata), 'armis_device_id')
          AND NOT has(map_keys(metadata), '_merged_into')`, identitymap.KindArmisID)
	if err != nil {
		return err
	}

	if err := process(armisRows); err != nil {
		return err
	}

	netboxRows, err := queryIdentityRows(ctx, database, `
        SELECT device_id, ip, metadata,
               if(has(map_keys(metadata),'integration_id'), metadata['integration_id'], metadata['netbox_device_id']) AS key,
               _tp_time
        FROM table(unified_devices)
        WHERE has(map_keys(metadata), 'integration_type') AND metadata['integration_type'] = 'netbox'
          AND (has(map_keys(metadata),'integration_id') OR has(map_keys(metadata),'netbox_device_id'))
          AND NOT has(map_keys(metadata), '_merged_into')`, identitymap.KindNetboxID)
	if err != nil {
		return err
	}

	if err := process(netboxRows); err != nil {
		return err
	}

	if len(tombBatch) > 0 {
		if err := database.PublishBatchDeviceUpdates(ctx, tombBatch); err != nil {
			return fmt.Errorf("publish tombstones: %w", err)
		}
	}

	if opts.DryRun {
		log.Info().
			Bool("dry_run", true).
			Int("candidate_rows", stats.totalCandidates).
			Int("duplicate_groups", stats.totalGroups).
			Int("tombstones_would_emit", stats.totalTombstones).
			Msg("Identity backfill DRY-RUN completed")

		return nil
	}

	log.Info().
		Int("candidate_rows", stats.totalCandidates).
		Int("duplicate_groups", stats.totalGroups).
		Int("tombstones_emitted", stats.totalTombstones).
		Msg("Identity backfill completed")

	return nil
}

// BackfillIPAliasTombstones finds sweep-only device_ids by IP for canonical identity devices
// (Armis/NetBox) and emits tombstones to merge them into the canonical device.
//
//nolint:gocognit,gocyclo,funlen // legacy backfill logic remains complex
func BackfillIPAliasTombstones(ctx context.Context, database db.Service, log logger.Logger, opts BackfillOptions) error {
	type canonical struct {
		deviceID  string
		partition string
		ip        string
		meta      map[string]string
	}

	// 1) Fetch canonical devices that have strong identity
	rows, err := database.ExecuteQuery(ctx, `
        SELECT device_id, ip, metadata, _tp_time
        FROM table(unified_devices)
        WHERE (has(map_keys(metadata),'armis_device_id')
               OR (has(map_keys(metadata),'integration_type') AND metadata['integration_type']='netbox'))
          AND NOT has(map_keys(metadata),'_merged_into')
        ORDER BY _tp_time DESC`)
	if err != nil {
		return fmt.Errorf("query canonical devices failed: %w", err)
	}

	// 2) Build canonical list with partitions and IP sets
	cands := make([]canonical, 0, len(rows))

	for _, r := range rows {
		dev, _ := r["device_id"].(string)
		if dev == "" {
			continue
		}

		ip, _ := r["ip"].(string)
		part := partitionFromDeviceID(dev)

		var meta map[string]string

		switch m := r["metadata"].(type) {
		case map[string]string:
			meta = m
		case map[string]interface{}:
			meta = make(map[string]string, len(m))

			for k, v := range m {
				if s, ok := v.(string); ok {
					meta[k] = s
				}
			}
		default:
			meta = map[string]string{}
		}

		cands = append(cands, canonical{deviceID: dev, partition: part, ip: ip, meta: meta})
	}

	canonDetails := make(map[string]canonical, len(cands))
	for _, c := range cands {
		canonDetails[c.deviceID] = c
	}

	// 3) Build a set of target duplicate device_ids per canonical
	// and verify existence to avoid creating tombstones for non-existent IDs
	var allTargets []string

	canonToTargets := make(map[string][]string)

	for _, c := range cands {
		ipSet := make(map[string]struct{})
		if c.ip != "" {
			ipSet[c.ip] = struct{}{}
		}
		// Parse all_ips comma-separated
		if s, ok := c.meta["all_ips"]; ok && s != "" {
			for _, tok := range strings.Split(s, ",") {
				t := strings.TrimSpace(tok)
				if t != "" {
					ipSet[t] = struct{}{}
				}
			}
		}
		// Parse alt_ip: keys
		for k := range c.meta {
			if strings.HasPrefix(k, "alt_ip:") {
				ip := strings.TrimPrefix(k, "alt_ip:")
				if ip != "" {
					ipSet[ip] = struct{}{}
				}
			}
		}
		// Build device_ids
		for ip := range ipSet {
			id := c.partition + ":" + ip
			if id == c.deviceID {
				continue
			}

			canonToTargets[c.deviceID] = append(canonToTargets[c.deviceID], id)
			allTargets = append(allTargets, id)
		}
	}

	if len(allTargets) == 0 {
		log.Info().Msg("IP backfill: no alias targets found")
		return nil
	}

	// 4) Check which target device_ids actually exist and are not already merged
	existing := make(map[string]struct{})

	const targetChunk = 1000

	for i := 0; i < len(allTargets); i += targetChunk {
		end := i + targetChunk
		if end > len(allTargets) {
			end = len(allTargets)
		}

		list := quoteList(allTargets[i:end])
		q := `SELECT device_id FROM table(unified_devices)
              WHERE device_id IN (` + list + `)
                AND NOT has(map_keys(metadata),'_merged_into')
              ORDER BY _tp_time DESC`

		res, err := database.ExecuteQuery(ctx, q)
		if err != nil {
			return fmt.Errorf("query existing targets failed: %w", err)
		}

		for _, r := range res {
			if dev, ok := r["device_id"].(string); ok && dev != "" {
				existing[dev] = struct{}{}
			}
		}
	}

	// 5) Emit tombstones for existing, non-canonical target IDs
	var tombstones []*models.DeviceUpdate

	const tombstoneChunk = 1000

	emit := func(update *models.DeviceUpdate) error {
		if update == nil {
			return nil
		}
		if opts.DryRun {
			return nil
		}

		tombstones = append(tombstones, update)
		if len(tombstones) < tombstoneChunk {
			return nil
		}

		if err := database.PublishBatchDeviceUpdates(ctx, tombstones); err != nil {
			return fmt.Errorf("publish ip tombstones: %w", err)
		}
		tombstones = tombstones[:0]
		return nil
	}

	var emitted int

	for canon, targets := range canonToTargets {
		part := partitionFromDeviceID(canon)

		for _, t := range targets {
			if _, ok := existing[t]; !ok {
				continue
			}

			emitted++
			tombstone := &models.DeviceUpdate{
				DeviceID:    t,
				Partition:   part,
				Source:      models.DiscoverySourceIntegration,
				Timestamp:   time.Now(),
				IsAvailable: false,
				Metadata:    map[string]string{"_merged_into": canon},
			}

			if err := emit(tombstone); err != nil {
				return err
			}
		}
	}

	if opts.DryRun {
		log.Info().
			Int("ip_alias_tombstones_would_emit", emitted).
			Msg("IP backfill DRY-RUN completed")
		return nil
	}

	if len(tombstones) > 0 {
		if err := database.PublishBatchDeviceUpdates(ctx, tombstones); err != nil {
			return fmt.Errorf("publish ip tombstones: %w", err)
		}
	}

	log.Info().
		Int("ip_alias_tombstones_emitted", emitted).
		Msg("IP backfill completed")

	return nil
}

func queryIdentityRows(ctx context.Context, database db.Service, sql string, kind identitymap.Kind) ([]identityRow, error) {
	results, err := database.ExecuteQuery(ctx, sql)
	if err != nil {
		return nil, fmt.Errorf("identity query failed: %w", err)
	}

	rows := make([]identityRow, 0, len(results))

	for _, r := range results {
		rd := identityRow{kind: kind}
		if v, ok := r["device_id"].(string); ok {
			rd.deviceID = v
		}

		if v, ok := r["ip"].(string); ok {
			rd.ip = v
		}
		// key may be nil if metadata is malformed; skip in builder
		if v, ok := r["key"].(string); ok {
			rd.key = v
		}

		switch meta := r["metadata"].(type) {
		case map[string]string:
			rd.metadata = cloneMetadata(meta)
		case map[string]interface{}:
			converted := make(map[string]string, len(meta))
			for k, v := range meta {
				if s, ok := v.(string); ok {
					converted[k] = s
				}
			}
			rd.metadata = converted
		case nil:
			rd.metadata = map[string]string{}
		default:
			rd.metadata = map[string]string{}
		}

		switch t := r["_tp_time"].(type) {
		case time.Time:
			rd.ts = t
		default:
			rd.ts = time.Now()
		}

		rows = append(rows, rd)
	}

	return rows, nil
}

func partitionFromDeviceID(deviceID string) string {
	parts := strings.Split(deviceID, ":")
	if len(parts) >= 2 {
		return parts[0]
	}

	return "default"
}

// quoteList converts a list of string literals to a safely quoted IN(...) list
func quoteList(vals []string) string {
	if len(vals) == 0 {
		return "''"
	}

	var b strings.Builder

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
