package core

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// identityRow holds a single unified_devices row with the identity key extracted.
type identityRow struct {
	deviceID string
	key      string // identity key (armis_id or netbox_id)
	ts       time.Time
	ip       string
}

// BackfillIdentityTombstones scans unified_devices for duplicate device_ids that share
// a strong identity (Armis ID or NetBox ID) and emits tombstones for non-canonical IDs.
// Canonical selection is the most recent (_tp_time) device row per identity key.
//
//nolint:gocognit,gocyclo,funlen // Complex legacy backfill logic
func BackfillIdentityTombstones(ctx context.Context, database db.Service, log logger.Logger, dryRun bool) error {
	totalCandidates := 0
	totalGroups := 0
	totalTombstones := 0

	// Helper executes a query, groups by key fn, and returns tombstones.
	buildTombstones := func(rows []identityRow) []*models.DeviceUpdate {
		// group by identity key
		groups := make(map[string][]identityRow)

		for _, r := range rows {
			if r.key == "" || r.deviceID == "" {
				continue
			}

			groups[r.key] = append(groups[r.key], r)
		}

		var updates []*models.DeviceUpdate

		for key, members := range groups {
			if len(members) <= 1 {
				continue
			}

			totalGroups++

			// pick canonical by latest timestamp
			canonical := members[0]
			for _, m := range members[1:] {
				if m.ts.After(canonical.ts) {
					canonical = m
				}
			}

			for _, m := range members {
				if m.deviceID == canonical.deviceID {
					continue
				}

				part := partitionFromDeviceID(m.deviceID)
				updates = append(updates, &models.DeviceUpdate{
					DeviceID:    m.deviceID,
					Partition:   part,
					IP:          m.ip,
					Source:      models.DiscoverySourceIntegration,
					Timestamp:   time.Now(),
					IsAvailable: false,
					Metadata:    map[string]string{"_merged_into": canonical.deviceID},
				})
				totalTombstones++

				log.Info().
					Str("identity_key", key).
					Str("from_id", m.deviceID).
					Str("to_id", canonical.deviceID).
					Msg("Backfill: tombstoning duplicate device")
			}
		}

		return updates
	}

	publishBatch := func(batch []*models.DeviceUpdate) error {
		if len(batch) == 0 {
			return nil
		}

		if dryRun {
			log.Info().Int("tombstones_would_emit", len(batch)).Msg("DRY-RUN: skipping publish of tombstone batch")
			return nil
		}

		const chunk = 500

		for i := 0; i < len(batch); i += chunk {
			end := i + chunk
			if end > len(batch) {
				end = len(batch)
			}

			if err := database.PublishBatchDeviceUpdates(ctx, batch[i:end]); err != nil {
				return fmt.Errorf("publish tombstones: %w", err)
			}
		}

		return nil
	}

	// 1) Armis ID groups
	armisRows, err := queryIdentityRows(ctx, database, `
        SELECT device_id, ip, metadata['armis_device_id'] AS key, _tp_time
        FROM table(unified_devices)
        WHERE has(map_keys(metadata), 'armis_device_id')
          AND NOT has(map_keys(metadata), '_merged_into')`)
	if err != nil {
		return err
	}

	totalCandidates += len(armisRows)

	if errBatch := publishBatch(buildTombstones(armisRows)); errBatch != nil {
		return errBatch
	}

	// 2) NetBox ID groups
	netboxRows, err := queryIdentityRows(ctx, database, `
        SELECT device_id, ip,
               if(has(map_keys(metadata),'integration_id'), metadata['integration_id'], metadata['netbox_device_id']) AS key,
               _tp_time
        FROM table(unified_devices)
        WHERE has(map_keys(metadata), 'integration_type') AND metadata['integration_type'] = 'netbox'
          AND (has(map_keys(metadata),'integration_id') OR has(map_keys(metadata),'netbox_device_id'))
          AND NOT has(map_keys(metadata), '_merged_into')`)
	if err != nil {
		return err
	}

	totalCandidates += len(netboxRows)

	if err := publishBatch(buildTombstones(netboxRows)); err != nil {
		return err
	}

	if dryRun {
		log.Info().
			Bool("dry_run", true).
			Int("candidate_rows", totalCandidates).
			Int("duplicate_groups", totalGroups).
			Int("tombstones_would_emit", totalTombstones).
			Msg("Identity backfill DRY-RUN completed")

		return nil
	}

	log.Info().
		Int("candidate_rows", totalCandidates).
		Int("duplicate_groups", totalGroups).
		Int("tombstones_emitted", totalTombstones).
		Msg("Identity backfill completed")

	return nil
}

// BackfillIPAliasTombstones finds sweep-only device_ids by IP for canonical identity devices
// (Armis/NetBox) and emits tombstones for those partition:ip device_ids to merge into the canonical.
// This captures duplicates created before identity-based canonicalization was enabled.
//
//nolint:gocognit,gocyclo,funlen // Complex legacy backfill logic
func BackfillIPAliasTombstones(ctx context.Context, database db.Service, log logger.Logger, dryRun bool) error {
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

	const chunk = 1000

	for i := 0; i < len(allTargets); i += chunk {
		end := i + chunk
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

	var would int

	for canon, targets := range canonToTargets {
		part := partitionFromDeviceID(canon)

		for _, t := range targets {
			if _, ok := existing[t]; !ok {
				continue
			}
			// Build tombstone
			tombstones = append(tombstones, &models.DeviceUpdate{
				DeviceID:    t,
				Partition:   part,
				Source:      models.DiscoverySourceIntegration,
				Timestamp:   time.Now(),
				IsAvailable: false,
				Metadata:    map[string]string{"_merged_into": canon},
			})
			would++
			// Flush periodically to avoid large memory
			if len(tombstones) >= 1000 && !dryRun {
				if err := database.PublishBatchDeviceUpdates(ctx, tombstones); err != nil {
					return fmt.Errorf("publish ip tombstones: %w", err)
				}

				tombstones = tombstones[:0]
			}
		}
	}

	if dryRun {
		log.Info().Int("ip_alias_tombstones_would_emit", would).Msg("IP backfill DRY-RUN completed")
		return nil
	}

	if len(tombstones) > 0 {
		if err := database.PublishBatchDeviceUpdates(ctx, tombstones); err != nil {
			return fmt.Errorf("publish ip tombstones: %w", err)
		}
	}

	log.Info().Int("ip_alias_tombstones_emitted", would).Msg("IP backfill completed")

	return nil
}
func queryIdentityRows(ctx context.Context, database db.Service, sql string) ([]identityRow, error) {
	results, err := database.ExecuteQuery(ctx, sql)
	if err != nil {
		return nil, fmt.Errorf("identity query failed: %w", err)
	}

	rows := make([]identityRow, 0, len(results))

	for _, r := range results {
		rd := identityRow{}
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
