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

	a.mu.Lock()
	previous = a.current
	a.current = snapshot
	a.lastMeta = meta
	a.mu.Unlock()

	a.logSnapshotRefresh(previous, snapshot, meta)
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

	capabilitySets := a.buildCapabilitySets(ctx)
	activeThreshold := now.Add(-a.activeWindow)
	partitions := make(map[string]*models.PartitionStats)

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
		if !isCanonicalRecord(record) {
			meta.SkippedNonCanonical++
			continue
		}

		snapshot.TotalDevices++
		meta.ProcessedRecords++

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

	a.maybeReportDiscrepancy(ctx, records, snapshot.TotalDevices)

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

func (a *StatsAggregator) logSnapshotRefresh(previous, current *models.DeviceStatsSnapshot, meta models.DeviceStatsMeta) {
	if a.logger == nil || current == nil {
		return
	}

	if previous != nil &&
		previous.TotalDevices == current.TotalDevices &&
		previous.AvailableDevices == current.AvailableDevices &&
		previous.UnavailableDevices == current.UnavailableDevices &&
		current.TotalDevices != 0 {
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
		Int("skipped_non_canonical_records", meta.SkippedNonCanonical)

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
}

func (a *StatsAggregator) maybeReportDiscrepancy(ctx context.Context, records []*registry.DeviceRecord, registryTotal int) {
	if a.dbService == nil || a.registry == nil {
		return
	}

	protonTotal, err := a.dbService.CountUnifiedDevices(ctx)
	if err != nil {
		a.logger.Warn().Err(err).Msg("Failed to count Proton devices during stats diagnostics")
		return
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

	event := a.logger.Warn().
		Int("registry_devices", registryTotal).
		Int64("proton_devices", protonTotal)

	if len(missingIDs) > 0 {
		event = event.Strs("missing_device_ids", missingIDs)
	}
	if sampleErr != nil {
		event = event.Err(sampleErr)
	}

	event.Msg("Device registry stats mismatch detected")
	a.lastMismatchLog = a.now()
}
