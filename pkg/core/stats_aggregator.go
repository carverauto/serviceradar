package core

import (
	"context"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/registry"
)

const (
	defaultStatsInterval            = 10 * time.Second
	defaultActiveWindow             = 24 * time.Hour
	defaultPartitionFallback        = "default"
	defaultStatsMismatchLogInterval = time.Minute
)

var defaultTrackedCapabilities = []string{"icmp", "snmp", "sysmon"}

// StatsAlertHandler receives the previous and current snapshot metadata so callers can
// trigger external notifications when anomaly thresholds are crossed (for example,
// when the non-canonical skip count jumps).
type StatsAlertHandler func(ctx context.Context, previousSnapshot *models.DeviceStatsSnapshot, previousMeta models.DeviceStatsMeta, currentSnapshot *models.DeviceStatsSnapshot, currentMeta models.DeviceStatsMeta)

// StatsOption customises the behaviour of the StatsAggregator.
type StatsOption func(*StatsAggregator)

// StatsAggregator maintains a periodically refreshed snapshot of device statistics.
type StatsAggregator struct {
	mu                  sync.RWMutex
	registry            *registry.DeviceRegistry
	logger              logger.Logger
	interval            time.Duration
	activeWindow        time.Duration
	trackedCapabilities []string
	now                 func() time.Time
	current             *models.DeviceStatsSnapshot
	dbService           db.Service
	mismatchLogInterval time.Duration
	lastMismatchLog     time.Time
	lastMeta            models.DeviceStatsMeta
	alertHandler        StatsAlertHandler
}

// NewStatsAggregator constructs a StatsAggregator tied to the provided device registry.
func NewStatsAggregator(reg *registry.DeviceRegistry, log logger.Logger, opts ...StatsOption) *StatsAggregator {
	agg := &StatsAggregator{
		registry:            reg,
		logger:              log,
		interval:            defaultStatsInterval,
		activeWindow:        defaultActiveWindow,
		trackedCapabilities: append([]string(nil), defaultTrackedCapabilities...),
		now:                 time.Now,
		current:             &models.DeviceStatsSnapshot{Timestamp: time.Now().UTC()},
		mismatchLogInterval: defaultStatsMismatchLogInterval,
	}

	for _, opt := range opts {
		if opt != nil {
			opt(agg)
		}
	}

	return agg
}

// WithStatsInterval overrides the refresh cadence.
func WithStatsInterval(interval time.Duration) StatsOption {
	return func(a *StatsAggregator) {
		if interval > 0 {
			a.interval = interval
		}
	}
}

// WithStatsActiveWindow overrides the look-back period for "active" devices.
func WithStatsActiveWindow(window time.Duration) StatsOption {
	return func(a *StatsAggregator) {
		if window > 0 {
			a.activeWindow = window
		}
	}
}

// WithStatsClock injects a deterministic clock (used for tests).
func WithStatsClock(clock func() time.Time) StatsOption {
	return func(a *StatsAggregator) {
		if clock != nil {
			a.now = clock
		}
	}
}

// WithStatsCapabilities sets the capability names that should be counted.
func WithStatsCapabilities(capabilities []string) StatsOption {
	return func(a *StatsAggregator) {
		normalized := make([]string, 0, len(capabilities))
		seen := make(map[string]struct{}, len(capabilities))
		for _, capability := range capabilities {
			cap := strings.ToLower(strings.TrimSpace(capability))
			if cap == "" {
				continue
			}
			if _, ok := seen[cap]; ok {
				continue
			}
			seen[cap] = struct{}{}
			normalized = append(normalized, cap)
		}
		if len(normalized) > 0 {
			a.trackedCapabilities = normalized
		}
	}
}

// WithStatsDB wires a Proton-backed database into the stats aggregator for diagnostics.
func WithStatsDB(database db.Service) StatsOption {
	return func(a *StatsAggregator) {
		a.dbService = database
	}
}

// WithStatsAlertHandler wires a callback that fires after every snapshot refresh so
// callers can surface anomalies through external alerting hooks.
func WithStatsAlertHandler(handler StatsAlertHandler) StatsOption {
	return func(a *StatsAggregator) {
		a.alertHandler = handler
	}
}

// Run starts the periodic refresh loop until the context is cancelled.
func (a *StatsAggregator) Run(ctx context.Context) {
	a.Refresh(ctx)

	ticker := time.NewTicker(a.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			a.Refresh(ctx)
		}
	}
}

// Refresh recomputes the snapshot immediately.
func (a *StatsAggregator) Refresh(ctx context.Context) {
	snapshot, meta := a.computeSnapshot(ctx)

	var previous *models.DeviceStatsSnapshot
	var previousMeta models.DeviceStatsMeta

	a.mu.Lock()
	previous = a.current
	previousMeta = a.lastMeta
	a.current = snapshot
	a.lastMeta = meta
	a.mu.Unlock()

	a.logSnapshotRefresh(previous, previousMeta, snapshot, meta)
	recordStatsMetrics(meta, snapshot)
	a.invokeAlertHandler(ctx, previous, previousMeta, snapshot, meta)
}

// Snapshot returns a defensive copy of the latest cached statistics.
func (a *StatsAggregator) Snapshot() *models.DeviceStatsSnapshot {
	a.mu.RLock()
	defer a.mu.RUnlock()

	return cloneDeviceStatsSnapshot(a.current)
}

// Meta returns the bookkeeping information associated with the latest snapshot.
func (a *StatsAggregator) Meta() models.DeviceStatsMeta {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.lastMeta
}

func (a *StatsAggregator) invokeAlertHandler(ctx context.Context, previousSnapshot *models.DeviceStatsSnapshot, previousMeta models.DeviceStatsMeta, currentSnapshot *models.DeviceStatsSnapshot, currentMeta models.DeviceStatsMeta) {
	if a.alertHandler == nil {
		return
	}

	// Best-effort alerting; avoid panics if handler misbehaves.
	defer func() {
		if r := recover(); r != nil {
			if a.logger != nil {
				a.logger.Error().Interface("panic", r).Msg("Stats alert handler panicked")
			}
		}
	}()

	a.alertHandler(ctx, previousSnapshot, previousMeta, currentSnapshot, currentMeta)
}

func (a *StatsAggregator) computeSnapshot(ctx context.Context) (*models.DeviceStatsSnapshot, models.DeviceStatsMeta) {
	now := a.now().UTC()
	snapshot := &models.DeviceStatsSnapshot{Timestamp: now}
	meta := models.DeviceStatsMeta{}

	reg := a.registry
	if reg == nil {
		return snapshot, meta
	}

	records := reg.SnapshotRecords()
	meta.RawRecords = len(records)
	if len(records) == 0 {
		return snapshot, meta
	}

	selected := a.selectCanonicalRecords(records, &meta)
	selected, protonTotal := a.reconcileWithProton(ctx, selected, &meta)
	if protonTotal > 0 {
		meta.RawRecords = int(protonTotal)
	} else {
		meta.RawRecords = len(selected)
	}
	if len(selected) == 0 {
		return snapshot, meta
	}

	countable := filterCountableRecords(selected, &meta)
	if len(countable) == 0 {
		meta.ProcessedRecords = 0
		return snapshot, meta
	}
	meta.ProcessedRecords = len(countable)

	capabilitySets := a.buildCapabilitySets(ctx)
	activeThreshold := now.Add(-a.activeWindow)
	partitions := make(map[string]*models.PartitionStats)

	for _, record := range countable {
		snapshot.TotalDevices++

		partitionID := partitionFromDeviceIDLocal(record.DeviceID)
		if partitionID == "" {
			partitionID = defaultPartitionFallback
		}
		stats := partitions[partitionID]
		if stats == nil {
			stats = &models.PartitionStats{PartitionID: partitionID}
			partitions[partitionID] = stats
		}
		stats.DeviceCount++

		if record.IsAvailable {
			snapshot.AvailableDevices++
			stats.AvailableCount++
		}

		if !record.LastSeen.IsZero() && record.LastSeen.After(activeThreshold) {
			snapshot.ActiveDevices++
			stats.ActiveCount++
		}

		collectorID := ""
		if record.CollectorAgentID != nil {
			collectorID = *record.CollectorAgentID
		} else if record.Metadata != nil {
			collectorID = record.Metadata["collector_agent_id"]
		}

		if hasAnyCapability(capabilitySets, record.DeviceID) ||
			len(record.Capabilities) > 0 ||
			strings.TrimSpace(collectorID) != "" {
			snapshot.DevicesWithCollectors++
		}

		if hasCapability(capabilitySets["icmp"], record.DeviceID) {
			snapshot.DevicesWithICMP++
		}
		if hasCapability(capabilitySets["snmp"], record.DeviceID) {
			snapshot.DevicesWithSNMP++
		}
		if hasCapability(capabilitySets["sysmon"], record.DeviceID) {
			snapshot.DevicesWithSysmon++
		}
	}

	snapshot.UnavailableDevices = snapshot.TotalDevices - snapshot.AvailableDevices
	snapshot.Partitions = buildPartitionStats(partitions)

	a.maybeReportDiscrepancy(ctx, records, snapshot.TotalDevices, protonTotal)

	return snapshot, meta
}

func (a *StatsAggregator) buildCapabilitySets(ctx context.Context) map[string]map[string]struct{} {
	result := make(map[string]map[string]struct{}, len(a.trackedCapabilities))
	if a.registry == nil {
		return result
	}

	for _, capability := range a.trackedCapabilities {
		ids := a.registry.ListDevicesWithCapability(ctx, capability)
		if len(ids) == 0 {
			result[capability] = make(map[string]struct{})
			continue
		}
		set := make(map[string]struct{}, len(ids))
		for _, id := range ids {
			if trimmed := strings.TrimSpace(id); trimmed != "" {
				set[trimmed] = struct{}{}
			}
		}
		result[capability] = set
	}

	return result
}

func buildPartitionStats(partitions map[string]*models.PartitionStats) []models.PartitionStats {
	if len(partitions) == 0 {
		return nil
	}

	out := make([]models.PartitionStats, 0, len(partitions))
	for _, stats := range partitions {
		if stats == nil {
			continue
		}
		out = append(out, *stats)
	}

	sort.Slice(out, func(i, j int) bool {
		return out[i].PartitionID < out[j].PartitionID
	})

	return out
}

func isServiceComponentRecord(record *registry.DeviceRecord) bool {
	if record == nil {
		return false
	}

	if models.IsServiceDevice(record.DeviceID) {
		return true
	}

	if len(record.Metadata) == 0 {
		return false
	}

	componentType := strings.ToLower(strings.TrimSpace(record.Metadata["component_type"]))
	switch componentType {
	case "poller", "agent", "checker":
		return true
	default:
		return false
	}
}

func hasCapability(set map[string]struct{}, deviceID string) bool {
	if len(set) == 0 {
		return false
	}
	_, ok := set[strings.TrimSpace(deviceID)]
	return ok
}

func hasAnyCapability(sets map[string]map[string]struct{}, deviceID string) bool {
	if len(sets) == 0 {
		return false
	}

	for _, set := range sets {
		if hasCapability(set, deviceID) {
			return true
		}
	}

	return false
}

func isTombstonedRecord(record *registry.DeviceRecord) bool {
	if record == nil || len(record.Metadata) == 0 {
		return false
	}

	for _, key := range []string{"_deleted", "deleted"} {
		if value, ok := record.Metadata[key]; ok && strings.EqualFold(strings.TrimSpace(value), "true") {
			return true
		}
	}

	if value, ok := record.Metadata["_merged_into"]; ok {
		target := strings.TrimSpace(value)
		if target != "" && !strings.EqualFold(target, strings.TrimSpace(record.DeviceID)) {
			return true
		}
	}

	return false
}

func filterCountableRecords(records []*registry.DeviceRecord, meta *models.DeviceStatsMeta) []*registry.DeviceRecord {
	if len(records) == 0 {
		return nil
	}

	countable := make([]*registry.DeviceRecord, 0, len(records))
	for _, record := range records {
		if shouldCountRecord(record) {
			countable = append(countable, record)
			continue
		}
		if meta != nil {
			meta.SkippedSweepOnlyRecords++
		}
	}
	return countable
}

func shouldCountRecord(record *registry.DeviceRecord) bool {
	if record == nil {
		return false
	}
	if !isSweepOnlyRecord(record) {
		return true
	}
	return recordHasStrongIdentity(record)
}

func isSweepOnlyRecord(record *registry.DeviceRecord) bool {
	if record == nil || len(record.DiscoverySources) == 0 {
		return false
	}
	for _, source := range record.DiscoverySources {
		if !strings.EqualFold(strings.TrimSpace(source), string(models.DiscoverySourceSweep)) {
			return false
		}
	}
	return true
}

func recordHasStrongIdentity(record *registry.DeviceRecord) bool {
	if record == nil {
		return false
	}

	if record.MAC != nil && strings.TrimSpace(*record.MAC) != "" {
		return true
	}

	if metadata := record.Metadata; metadata != nil {
		for _, key := range []string{"armis_device_id", "integration_id", "netbox_device_id"} {
			if value := strings.TrimSpace(metadata[key]); value != "" {
				return true
			}
		}
		if canonical := strings.TrimSpace(metadata["canonical_device_id"]); canonical != "" {
			if !strings.EqualFold(canonical, strings.TrimSpace(record.DeviceID)) {
				return true
			}
		}
	}

	return false
}

func isCanonicalRecord(record *registry.DeviceRecord) bool {
	if record == nil {
		return false
	}
	if len(record.Metadata) == 0 {
		return false
	}

	canonicalID := strings.TrimSpace(record.Metadata["canonical_device_id"])
	if canonicalID == "" {
		return false
	}

	deviceID := strings.TrimSpace(record.DeviceID)
	if deviceID == "" {
		return false
	}

	return strings.EqualFold(canonicalID, deviceID)
}

type canonicalEntry struct {
	record    *registry.DeviceRecord
	canonical bool
}

func (a *StatsAggregator) selectCanonicalRecords(records []*registry.DeviceRecord, meta *models.DeviceStatsMeta) []*registry.DeviceRecord {
	if len(records) == 0 {
		return nil
	}

	canonical := make(map[string]canonicalEntry)
	fallback := make(map[string]*registry.DeviceRecord)

	for _, record := range records {
		if record == nil {
			meta.SkippedNilRecords++
			continue
		}
		if isTombstonedRecord(record) {
			meta.SkippedTombstonedRecords++
			continue
		}
		if isServiceComponentRecord(record) {
			meta.SkippedServiceComponents++
			continue
		}

		deviceID := strings.TrimSpace(record.DeviceID)
		canonicalID := canonicalDeviceID(record)

		key := canonicalID
		if key == "" {
			key = deviceID
		}
		key = strings.TrimSpace(key)
		if key == "" {
			meta.SkippedNonCanonical++
			continue
		}

		normalizedKey := strings.ToLower(key)

		if canonicalID != "" && strings.EqualFold(canonicalID, deviceID) {
			if entry, ok := canonical[normalizedKey]; ok {
				if entry.canonical {
					if shouldReplaceRecord(entry.record, record) {
						canonical[normalizedKey] = canonicalEntry{record: record, canonical: true}
					} else {
						meta.SkippedNonCanonical++
					}
				} else {
					canonical[normalizedKey] = canonicalEntry{record: record, canonical: true}
				}
			} else {
				canonical[normalizedKey] = canonicalEntry{record: record, canonical: true}
			}
			continue
		}

		if entry, ok := canonical[normalizedKey]; ok {
			if entry.canonical {
				meta.SkippedNonCanonical++
			} else if shouldReplaceRecord(entry.record, record) {
				canonical[normalizedKey] = canonicalEntry{record: record, canonical: false}
			} else {
				meta.SkippedNonCanonical++
			}
			continue
		}

		if existing, ok := fallback[normalizedKey]; ok {
			if shouldReplaceRecord(existing, record) {
				fallback[normalizedKey] = record
			}
			meta.SkippedNonCanonical++
			continue
		}

		fallback[normalizedKey] = record
	}

	for key, record := range fallback {
		if _, ok := canonical[key]; ok {
			meta.SkippedNonCanonical++
			continue
		}
		canonical[key] = canonicalEntry{record: record, canonical: false}
		meta.InferredCanonicalFallback++
	}

	if len(canonical) == 0 {
		return nil
	}

	selected := make([]*registry.DeviceRecord, 0, len(canonical))
	for _, entry := range canonical {
		if entry.record != nil {
			selected = append(selected, entry.record)
		}
	}

	return selected
}

func canonicalDeviceID(record *registry.DeviceRecord) string {
	if record == nil || len(record.Metadata) == 0 {
		return ""
	}
	return strings.TrimSpace(record.Metadata["canonical_device_id"])
}

func shouldReplaceRecord(existing, candidate *registry.DeviceRecord) bool {
	if candidate == nil {
		return false
	}
	if existing == nil {
		return true
	}

	existingLastSeen := existing.LastSeen
	candidateLastSeen := candidate.LastSeen

	if existingLastSeen.IsZero() && !candidateLastSeen.IsZero() {
		return true
	}
	if !existingLastSeen.IsZero() && candidateLastSeen.IsZero() {
		return false
	}
	if candidateLastSeen.After(existingLastSeen) {
		return true
	}
	if candidateLastSeen.Before(existingLastSeen) {
		return false
	}

	if candidate.IsAvailable && !existing.IsAvailable {
		return true
	}
	if !candidate.IsAvailable && existing.IsAvailable {
		return false
	}

	existingID := strings.TrimSpace(existing.DeviceID)
	candidateID := strings.TrimSpace(candidate.DeviceID)
	return strings.Compare(candidateID, existingID) < 0
}

func cloneDeviceStatsSnapshot(src *models.DeviceStatsSnapshot) *models.DeviceStatsSnapshot {
	if src == nil {
		return nil
	}

	dst := *src
	if len(src.Partitions) > 0 {
		dst.Partitions = make([]models.PartitionStats, len(src.Partitions))
		copy(dst.Partitions, src.Partitions)
	}
	return &dst
}

func (a *StatsAggregator) logSnapshotRefresh(previous *models.DeviceStatsSnapshot, previousMeta models.DeviceStatsMeta, current *models.DeviceStatsSnapshot, meta models.DeviceStatsMeta) {
	if a.logger == nil || current == nil {
		return
	}

	metaChanged := meta.RawRecords != previousMeta.RawRecords ||
		meta.ProcessedRecords != previousMeta.ProcessedRecords ||
		meta.SkippedNilRecords != previousMeta.SkippedNilRecords ||
		meta.SkippedTombstonedRecords != previousMeta.SkippedTombstonedRecords ||
		meta.SkippedServiceComponents != previousMeta.SkippedServiceComponents ||
		meta.SkippedNonCanonical != previousMeta.SkippedNonCanonical ||
		meta.SkippedSweepOnlyRecords != previousMeta.SkippedSweepOnlyRecords ||
		meta.InferredCanonicalFallback != previousMeta.InferredCanonicalFallback

	if previous != nil &&
		previous.TotalDevices == current.TotalDevices &&
		previous.AvailableDevices == current.AvailableDevices &&
		previous.UnavailableDevices == current.UnavailableDevices &&
		current.TotalDevices != 0 &&
		!metaChanged {
		return
	}

	event := a.logger.Info().
		Str("component", "stats_aggregator").
		Time("timestamp", current.Timestamp).
		Int("total_devices", current.TotalDevices).
		Int("available_devices", current.AvailableDevices).
		Int("unavailable_devices", current.UnavailableDevices).
		Int("active_devices", current.ActiveDevices).
		Int("raw_records", meta.RawRecords).
		Int("processed_records", meta.ProcessedRecords).
		Int("skipped_nil_records", meta.SkippedNilRecords).
		Int("skipped_tombstoned_records", meta.SkippedTombstonedRecords).
		Int("skipped_service_components", meta.SkippedServiceComponents).
		Int("skipped_non_canonical_records", meta.SkippedNonCanonical).
		Int("skipped_sweep_only_records", meta.SkippedSweepOnlyRecords).
		Int("inferred_canonical_records", meta.InferredCanonicalFallback)

	if previous != nil {
		event = event.
			Int("prev_total_devices", previous.TotalDevices).
			Int("prev_available_devices", previous.AvailableDevices).
			Int("prev_unavailable_devices", previous.UnavailableDevices).
			Int("delta_total_devices", current.TotalDevices-previous.TotalDevices).
			Int("delta_available_devices", current.AvailableDevices-previous.AvailableDevices).
			Int("delta_unavailable_devices", current.UnavailableDevices-previous.UnavailableDevices)
	} else {
		event = event.Bool("initial_snapshot", true)
	}

	if current.TotalDevices == 0 {
		event = event.Bool("zero_total_devices", true)
	}

	event.Msg("Device stats snapshot refreshed")

	if meta.SkippedNonCanonical > 0 && meta.SkippedNonCanonical != previousMeta.SkippedNonCanonical {
		warn := a.logger.Warn().
			Str("component", "stats_aggregator").
			Int("skipped_non_canonical_records", meta.SkippedNonCanonical).
			Int("previous_skipped_non_canonical_records", previousMeta.SkippedNonCanonical).
			Int("raw_records", meta.RawRecords).
			Int("processed_records", meta.ProcessedRecords).
			Int("inferred_canonical_records", meta.InferredCanonicalFallback)

		if current != nil {
			warn = warn.
				Int("total_devices", current.TotalDevices).
				Time("snapshot_timestamp", current.Timestamp)
		}

		warn.Msg("Non-canonical device records filtered during stats aggregation")
	}

	if meta.SkippedSweepOnlyRecords > 0 && meta.SkippedSweepOnlyRecords != previousMeta.SkippedSweepOnlyRecords {
		warn := a.logger.Warn().
			Str("component", "stats_aggregator").
			Int("skipped_sweep_only_records", meta.SkippedSweepOnlyRecords).
			Int("previous_skipped_sweep_only_records", previousMeta.SkippedSweepOnlyRecords).
			Int("raw_records", meta.RawRecords).
			Int("processed_records", meta.ProcessedRecords)

		if current != nil {
			warn = warn.
				Int("total_devices", current.TotalDevices).
				Time("snapshot_timestamp", current.Timestamp)
		}

		warn.Msg("Sweep-only device records filtered during stats aggregation")
	}
}

func (a *StatsAggregator) maybeReportDiscrepancy(ctx context.Context, records []*registry.DeviceRecord, registryTotal int, protonSnapshot int64) {
	if a.dbService == nil || a.registry == nil {
		return
	}

	protonTotal := protonSnapshot
	var err error
	if protonTotal <= 0 {
		protonTotal, err = a.dbService.CountUnifiedDevices(ctx)
		if err != nil {
			a.logger.Warn().Err(err).Msg("Failed to count Proton devices during stats diagnostics")
			return
		}
	}

	if int64(registryTotal) == protonTotal {
		return
	}

	if !a.lastMismatchLog.IsZero() && a.mismatchLogInterval > 0 && a.now().Before(a.lastMismatchLog.Add(a.mismatchLogInterval)) {
		return
	}

	known := make(map[string]struct{}, len(records))
	for _, record := range records {
		if record == nil {
			continue
		}
		if id := strings.TrimSpace(record.DeviceID); id != "" {
			known[id] = struct{}{}
		}
	}

	missingIDs, sampleErr := a.registry.SampleMissingDeviceIDs(ctx, known, 20)
	excessIDs, excessErr := sampleRegistryExcessIDs(ctx, a.dbService, records, 20)

	event := a.logger.Warn().
		Int("registry_devices", registryTotal).
		Int64("proton_devices", protonTotal)

	if len(missingIDs) > 0 {
		event = event.Strs("missing_device_ids", missingIDs)
	}
	if len(excessIDs) > 0 {
		event = event.Strs("excess_device_ids", excessIDs)
	}
	if sampleErr != nil {
		event = event.Err(sampleErr)
	}
	if excessErr != nil {
		event = event.Err(excessErr)
	}

	event.Msg("Device registry stats mismatch detected")
	a.lastMismatchLog = a.now()
}

func (a *StatsAggregator) reconcileWithProton(ctx context.Context, records []*registry.DeviceRecord, meta *models.DeviceStatsMeta) ([]*registry.DeviceRecord, int64) {
	if len(records) == 0 {
		if meta != nil {
			meta.ProcessedRecords = 0
			meta.InferredCanonicalFallback = 0
		}
		return records, 0
	}

	fallbackCount := countInferredRecords(records)

	if a.dbService == nil {
		if meta != nil {
			meta.InferredCanonicalFallback = fallbackCount
		}
		return records, 0
	}

	protonTotal, err := a.dbService.CountUnifiedDevices(ctx)
	if err != nil {
		if a.logger != nil {
			a.logger.Warn().
				Err(err).
				Msg("Failed to count Proton devices during registry reconciliation")
		}
		if meta != nil {
			meta.InferredCanonicalFallback = fallbackCount
		}
		return records, 0
	}

	excess := len(records) - int(protonTotal)
	if excess <= 0 {
		if meta != nil {
			meta.InferredCanonicalFallback = fallbackCount
		}
		return records, protonTotal
	}

	fallbackRecords := collectInferredRecords(records)
	if len(fallbackRecords) == 0 {
		if a.logger != nil {
			a.logger.Warn().
				Int("registry_records", len(records)).
				Int64("proton_records", protonTotal).
				Msg("Registry exceeds Proton totals but no inferred records available to prune")
		}
		if meta != nil {
			meta.InferredCanonicalFallback = fallbackCount
		}
		return records, protonTotal
	}

	sort.Slice(fallbackRecords, func(i, j int) bool {
		return recordOlder(fallbackRecords[i], fallbackRecords[j])
	})

	removeCount := excess
	if removeCount > len(fallbackRecords) {
		removeCount = len(fallbackRecords)
	}

	if removeCount <= 0 {
		if meta != nil {
			meta.InferredCanonicalFallback = fallbackCount
		}
		return records, protonTotal
	}

	pruneSet := make(map[string]struct{}, removeCount)
	for i := 0; i < removeCount; i++ {
		if fallbackRecords[i] == nil {
			continue
		}
		pruneSet[strings.TrimSpace(fallbackRecords[i].DeviceID)] = struct{}{}
	}

	filtered := make([]*registry.DeviceRecord, 0, len(records)-removeCount)
	remainingFallback := 0
	for _, record := range records {
		if record == nil {
			continue
		}
		if _, drop := pruneSet[strings.TrimSpace(record.DeviceID)]; drop {
			continue
		}
		filtered = append(filtered, record)
		if !isCanonicalRecord(record) {
			remainingFallback++
		}
	}

	if meta != nil {
		meta.InferredCanonicalFallback = remainingFallback
	}

	if a.logger != nil {
		a.logger.Info().
			Str("component", "stats_aggregator").
			Int("pruned_inferred_records", removeCount).
			Int("fallback_remaining", remainingFallback).
			Int("processed_records", len(filtered)).
			Int64("proton_devices", protonTotal).
			Msg("Pruned inferred registry records to reconcile with Proton")
	}

	// If we still have more records than Proton, log a warning but continue.
	if len(filtered) > int(protonTotal) && a.logger != nil {
		a.logger.Warn().
			Str("component", "stats_aggregator").
			Int("processed_records", len(filtered)).
			Int64("proton_devices", protonTotal).
			Msg("Registry still exceeds Proton totals after pruning inferred records")
	}

	return filtered, protonTotal
}

func countInferredRecords(records []*registry.DeviceRecord) int {
	if len(records) == 0 {
		return 0
	}
	var count int
	for _, record := range records {
		if record == nil {
			continue
		}
		if !isCanonicalRecord(record) {
			count++
		}
	}
	return count
}

func collectInferredRecords(records []*registry.DeviceRecord) []*registry.DeviceRecord {
	if len(records) == 0 {
		return nil
	}

	fallback := make([]*registry.DeviceRecord, 0)
	for _, record := range records {
		if record == nil {
			continue
		}
		if !isCanonicalRecord(record) {
			fallback = append(fallback, record)
		}
	}
	return fallback
}

func recordOlder(a, b *registry.DeviceRecord) bool {
	if a == nil && b == nil {
		return false
	}
	if a == nil {
		return false
	}
	if b == nil {
		return true
	}

	aTs := a.LastSeen
	bTs := b.LastSeen

	switch {
	case aTs.IsZero() && bTs.IsZero():
		return strings.Compare(strings.TrimSpace(a.DeviceID), strings.TrimSpace(b.DeviceID)) < 0
	case aTs.IsZero():
		return true
	case bTs.IsZero():
		return false
	case aTs.Equal(bTs):
		return strings.Compare(strings.TrimSpace(a.DeviceID), strings.TrimSpace(b.DeviceID)) < 0
	default:
		return aTs.Before(bTs)
	}
}

func sampleRegistryExcessIDs(
	ctx context.Context,
	dbService db.Service,
	records []*registry.DeviceRecord,
	limit int,
) ([]string, error) {
	if limit <= 0 || dbService == nil || len(records) == 0 {
		return nil, nil
	}

	const chunkSize = 128

	result := make([]string, 0, limit)
	buffer := make([]string, 0, chunkSize)
	seen := make(map[string]struct{}, len(records))

	flush := func() error {
		if len(buffer) == 0 {
			return nil
		}

		devices, err := dbService.GetUnifiedDevicesByIPsOrIDs(ctx, nil, buffer)
		if err != nil {
			return err
		}

		found := make(map[string]struct{}, len(devices))
		for _, device := range devices {
			if device == nil {
				continue
			}
			id := strings.TrimSpace(device.DeviceID)
			if id == "" {
				continue
			}
			found[id] = struct{}{}
		}

		for _, id := range buffer {
			if _, ok := found[id]; ok {
				continue
			}
			result = append(result, id)
			if len(result) >= limit {
				buffer = buffer[:0]
				return nil
			}
		}

		buffer = buffer[:0]
		return nil
	}

	for _, record := range records {
		if len(result) >= limit {
			break
		}
		if record == nil {
			continue
		}

		id := strings.TrimSpace(record.DeviceID)
		if id == "" {
			continue
		}

		if _, duplicate := seen[id]; duplicate {
			continue
		}
		seen[id] = struct{}{}

		buffer = append(buffer, id)
		if len(buffer) >= chunkSize {
			if err := flush(); err != nil {
				return result, err
			}
		}
	}

	if len(result) < limit {
		if err := flush(); err != nil {
			return result, err
		}
	}

	if len(result) > limit {
		result = result[:limit]
	}

	return result, nil
}
