package core

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
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
	DryRun     bool
	SeedKVOnly bool
	Namespace  string
}

func (o BackfillOptions) namespaceOrDefault() string {
	ns := strings.TrimSpace(o.Namespace)
	if ns == "" {
		ns = identitymap.DefaultNamespace
	}
	return ns
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

type kvSeeder struct {
	client    identityKVClient
	namespace string
	log       logger.Logger
}

func newKVSeeder(client identityKVClient, namespace string, log logger.Logger) *kvSeeder {
	if client == nil {
		return nil
	}

	ns := strings.TrimSpace(namespace)
	if ns == "" {
		ns = identitymap.DefaultNamespace
	}

	return &kvSeeder{client: client, namespace: ns, log: log}
}

func (s *kvSeeder) seedRecord(ctx context.Context, record *identitymap.Record, keys []identitymap.Key, dryRun bool) (map[identitymap.Key]bool, error) {
	if s == nil || s.client == nil || record == nil || len(keys) == 0 {
		return nil, nil
	}

	payload, err := identitymap.MarshalRecord(record)
	if err != nil {
		return nil, err
	}

	matched := make(map[identitymap.Key]bool, len(keys))
	var seedErr error

	for _, key := range keys {
		keyPath := key.KeyPath(s.namespace)

		resp, err := s.client.Get(ctx, &proto.GetRequest{Key: keyPath})
		if err != nil {
			seedErr = errors.Join(seedErr, fmt.Errorf("kv get %s: %w", keyPath, err))
			continue
		}

		if !resp.GetFound() || len(resp.GetValue()) == 0 {
			matched[key] = false

			if dryRun {
				identitymap.RecordKVPublish(ctx, 1, "dry_run")
				continue
			}

			if _, err := s.client.PutIfAbsent(ctx, &proto.PutRequest{Key: keyPath, Value: payload}); err != nil {
				code := status.Code(err)
				if code == codes.Aborted || code == codes.AlreadyExists {
					identitymap.RecordKVConflict(ctx, code.String())
					if s.log != nil {
						s.log.Debug().Str("key", keyPath).Str("reason", code.String()).Msg("Backfill KV create encountered conflict")
					}
				}
				seedErr = errors.Join(seedErr, fmt.Errorf("kv put %s: %w", keyPath, err))
				continue
			}

			identitymap.RecordKVPublish(ctx, 1, "created")
			if s.log != nil {
				s.log.Debug().Str("key", keyPath).Msg("Backfill created canonical identity entry in KV")
			}

			continue
		}

		existing, err := identitymap.UnmarshalRecord(resp.GetValue())
		if err != nil {
			seedErr = errors.Join(seedErr, fmt.Errorf("kv unmarshal %s: %w", keyPath, err))
			continue
		}

		if existing.CanonicalDeviceID == record.CanonicalDeviceID && existing.MetadataHash == record.MetadataHash {
			matched[key] = true
			identitymap.RecordKVPublish(ctx, 1, "unchanged")
			continue
		}

		matched[key] = false

		if dryRun {
			identitymap.RecordKVPublish(ctx, 1, "dry_run")
			continue
		}

		if _, err := s.client.Update(ctx, &proto.UpdateRequest{Key: keyPath, Value: payload, Revision: resp.GetRevision()}); err != nil {
			code := status.Code(err)
			if code == codes.Aborted || code == codes.AlreadyExists {
				identitymap.RecordKVConflict(ctx, code.String())
				if s.log != nil {
					s.log.Debug().Str("key", keyPath).Str("reason", code.String()).Msg("Backfill KV update encountered conflict")
				}
			}
			seedErr = errors.Join(seedErr, fmt.Errorf("kv update %s: %w", keyPath, err))
			continue
		}

		identitymap.RecordKVPublish(ctx, 1, "updated")
		if s.log != nil {
			s.log.Debug().Str("key", keyPath).Msg("Backfill updated canonical identity entry in KV")
		}
	}

	return matched, seedErr
}

func buildIdentityRecord(update *models.DeviceUpdate) *identitymap.Record {
	if update == nil {
		return nil
	}

	return &identitymap.Record{
		CanonicalDeviceID: update.DeviceID,
		Partition:         update.Partition,
		MetadataHash:      identitymap.HashMetadata(update.Metadata),
		UpdatedAt:         time.Now().UTC(),
		Attributes:        buildIdentityAttributes(update),
	}
}

func buildIdentityAttributes(update *models.DeviceUpdate) map[string]string {
	if update == nil {
		return nil
	}

	attrs := map[string]string{}

	if update.IP != "" {
		attrs["ip"] = update.IP
	}

	if update.Partition != "" {
		attrs["partition"] = update.Partition
	}

	if update.Hostname != nil {
		if name := strings.TrimSpace(*update.Hostname); name != "" {
			attrs["hostname"] = name
		}
	}

	if src := strings.TrimSpace(string(update.Source)); src != "" {
		attrs["source"] = src
	}

	if len(attrs) == 0 {
		return nil
	}

	return attrs
}

// BackfillIdentityTombstones scans unified_devices for duplicate device_ids that share
// a strong identity (Armis ID or NetBox ID) and reconciles them against the canonical
// identity map. When the KV already points at the canonical device the tombstone is
// skipped, making the job idempotent. Optionally the job can perform KV seeding only.
//
//nolint:gocognit,funlen // historical backfill logic remains complex
func BackfillIdentityTombstones(ctx context.Context, database db.Service, kvClient identityKVClient, log logger.Logger, opts BackfillOptions) error {
	namespace := opts.namespaceOrDefault()
	seeder := newKVSeeder(kvClient, namespace, log)

	totalCandidates := 0
	totalGroups := 0
	totalTombstones := 0
	skippedByKV := 0

	const chunkSize = 500
	tombBatch := make([]*models.DeviceUpdate, 0, chunkSize)

	emit := func(update *models.DeviceUpdate) error {
		if update == nil {
			return nil
		}
		if opts.DryRun || opts.SeedKVOnly {
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
		if len(rows) == 0 {
			return nil
		}

		totalCandidates += len(rows)

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

			totalGroups++

			canonical := members[0]
			for _, candidate := range members[1:] {
				if candidate.ts.After(canonical.ts) {
					canonical = candidate
				}
			}

			canonicalUpdate := canonical.toDeviceUpdate()
			record := buildIdentityRecord(canonicalUpdate)

			var matches map[identitymap.Key]bool
			if seeder != nil && record != nil {
				seedMatches, seedErr := seeder.seedRecord(ctx, record, identitymap.BuildKeys(canonicalUpdate), opts.DryRun)
				if seedErr != nil {
					log.Warn().
						Err(seedErr).
						Str("identity_key", key).
						Msg("Backfill: failed to seed canonical identity in KV")
				}
				matches = seedMatches
			}

			for _, member := range members {
				if member.deviceID == canonical.deviceID {
					continue
				}

				skip := opts.SeedKVOnly
				if !skip && matches != nil {
					targetKey := identitymap.Key{Kind: canonical.kind, Value: key}
					if matched, ok := matches[targetKey]; ok && matched {
						skippedByKV++
						skip = true
					}
				}

				if skip {
					continue
				}

				totalTombstones++

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
			Int("candidate_rows", totalCandidates).
			Int("duplicate_groups", totalGroups).
			Int("tombstones_would_emit", totalTombstones).
			Int("kv_identity_skipped", skippedByKV).
			Msg("Identity backfill DRY-RUN completed")

		return nil
	}

	if opts.SeedKVOnly {
		log.Info().
			Int("candidate_rows", totalCandidates).
			Int("duplicate_groups", totalGroups).
			Int("kv_identity_skipped", skippedByKV).
			Msg("Identity backfill completed with KV seeding only")
		return nil
	}

	log.Info().
		Int("candidate_rows", totalCandidates).
		Int("duplicate_groups", totalGroups).
		Int("tombstones_emitted", totalTombstones).
		Int("kv_identity_skipped", skippedByKV).
		Msg("Identity backfill completed")

	return nil
}

// BackfillIPAliasTombstones finds sweep-only device_ids by IP for canonical identity devices
// (Armis/NetBox) and reconciles them, optionally seeding the canonical identity map for the
// partition:ip keys. Like BackfillIdentityTombstones, it skips tombstones when the KV already
// reflects the canonical device, making the workflow idempotent.
//
//nolint:gocognit,gocyclo,funlen // legacy backfill logic remains complex
func BackfillIPAliasTombstones(ctx context.Context, database db.Service, kvClient identityKVClient, log logger.Logger, opts BackfillOptions) error {
	namespace := opts.namespaceOrDefault()
	seeder := newKVSeeder(kvClient, namespace, log)

	type canonical struct {
		deviceID  string
		partition string
		ip        string
		meta      map[string]string
	}

	buildCanonicalUpdate := func(c canonical) *models.DeviceUpdate {
		if c.deviceID == "" {
			return nil
		}

		return &models.DeviceUpdate{
			DeviceID:  c.deviceID,
			Partition: c.partition,
			IP:        c.ip,
			Source:    models.DiscoverySourceIntegration,
			Metadata:  cloneMetadata(c.meta),
		}
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
		if opts.DryRun || opts.SeedKVOnly {
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
	skippedByKV := 0

	for canon, targets := range canonToTargets {
		part := partitionFromDeviceID(canon)

		info, ok := canonDetails[canon]
		if !ok {
			info = canonical{deviceID: canon, partition: part}
		}

		update := buildCanonicalUpdate(info)
		if update == nil {
			continue
		}

		record := buildIdentityRecord(update)
		if seeder != nil && record != nil {
			if _, seedErr := seeder.seedRecord(ctx, record, identitymap.BuildKeys(update), opts.DryRun); seedErr != nil {
				log.Warn().
					Err(seedErr).
					Str("canonical_device", canon).
					Msg("IP backfill: failed to seed canonical identity keys")
			}
		}

		for _, t := range targets {
			if _, ok := existing[t]; !ok {
				continue
			}
			// Build tombstone
			aliasKey := identitymap.Key{Kind: identitymap.KindPartitionIP, Value: t}
			aliasMatched := false

			if seeder != nil && record != nil {
				if matches, seedErr := seeder.seedRecord(ctx, record, []identitymap.Key{aliasKey}, opts.DryRun); seedErr != nil {
					log.Warn().
						Err(seedErr).
						Str("alias_device", t).
						Str("canonical_device", canon).
						Msg("IP backfill: failed to seed partition-ip identity")
				} else if matches != nil && matches[aliasKey] {
					aliasMatched = true
				}
			}

			skip := opts.SeedKVOnly || aliasMatched
			if skip {
				if aliasMatched {
					skippedByKV++
				}
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
			Int("kv_identity_skipped", skippedByKV).
			Msg("IP backfill DRY-RUN completed")
		return nil
	}

	if len(tombstones) > 0 {
		if opts.SeedKVOnly {
			tombstones = tombstones[:0]
		} else if err := database.PublishBatchDeviceUpdates(ctx, tombstones); err != nil {
			return fmt.Errorf("publish ip tombstones: %w", err)
		}
	}

	if opts.SeedKVOnly {
		log.Info().
			Int("kv_identity_skipped", skippedByKV).
			Msg("IP backfill completed with KV seeding only")
		return nil
	}

	log.Info().
		Int("ip_alias_tombstones_emitted", emitted).
		Int("kv_identity_skipped", skippedByKV).
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
