package core

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultLogDigestPersistenceInterval = time.Minute
)

// LogDigestSource provides snapshots of recent log activity for aggregation.
type LogDigestSource interface {
	Fetch(ctx context.Context, limit int) (*models.LogDigestSnapshot, error)
}

// LogTailer streams critical log records and forwards them to the supplied handler.
type LogTailer interface {
	Stream(ctx context.Context, handler func(models.LogSummary)) error
}

// LogDigestStore persists and restores cached digests for warm restarts.
type LogDigestStore interface {
	Load() (*models.LogDigestSnapshot, error)
	Save(snapshot *models.LogDigestSnapshot) error
}

type logCounterBucket struct {
	minute time.Time
	fatal  int
	err    int
	warn   int
	info   int
	debug  int
	other  int
}

func (b *logCounterBucket) add(severity string) {
	switch severity {
	case "fatal", "critical":
		b.fatal++
	case "error", "err":
		b.err++
	case "warn", "warning":
		b.warn++
	case "info", "information":
		b.info++
	case "debug", "trace":
		b.debug++
	default:
		b.other++
	}
}

// LogDigestAggregator maintains an in-memory digest of recent fatal/error logs and counters.
type LogDigestAggregator struct {
	mu         sync.RWMutex
	recent     []models.LogSummary
	buckets    []logCounterBucket
	counters   *models.LogCounters
	maxEntries int
	logger     logger.Logger
	store      LogDigestStore
}

// NewLogDigestAggregator constructs an aggregator with the provided capacity and optional store.
func NewLogDigestAggregator(maxEntries int, store LogDigestStore, log logger.Logger) *LogDigestAggregator {
	if maxEntries <= 0 {
		maxEntries = 200
	}

	return &LogDigestAggregator{
		recent:     make([]models.LogSummary, 0, maxEntries),
		buckets:    make([]logCounterBucket, 0, 256),
		counters:   &models.LogCounters{},
		maxEntries: maxEntries,
		logger:     log,
		store:      store,
	}
}

// Bootstrap attempts to hydrate the digest from the persisted store, falling back to a DB snapshot.
func (a *LogDigestAggregator) Bootstrap(ctx context.Context, source LogDigestSource) error {
	if restored, err := a.RestoreFromStore(); err != nil {
		return err
	} else if restored {
		return nil
	}

	return a.HydrateFromSource(ctx, source)
}

// RestoreFromStore attempts to hydrate the digest from the persisted store.
func (a *LogDigestAggregator) RestoreFromStore() (bool, error) {
	if a.store == nil {
		return false, nil
	}

	snapshot, err := a.store.Load()
	if err != nil {
		return false, err
	}

	if snapshot == nil {
		return false, nil
	}

	a.ingestSnapshot(snapshot)
	return true, nil
}

// HydrateFromSource loads the digest using the provided source.
func (a *LogDigestAggregator) HydrateFromSource(ctx context.Context, source LogDigestSource) error {
	if source == nil {
		return nil
	}

	snapshot, err := source.Fetch(ctx, a.maxEntries)
	if err != nil {
		return err
	}

	a.ingestSnapshot(snapshot)
	return nil
}

// RunStream starts tailing the given log stream and updates the digest until the context is cancelled.
func (a *LogDigestAggregator) RunStream(ctx context.Context, tailer LogTailer) {
	if tailer == nil {
		a.logger.Warn().Msg("log digest tailer missing; stream will not start")
		return
	}

	backoff := time.Second
	const maxBackoff = 30 * time.Second

	for {
		if ctx.Err() != nil {
			return
		}

		err := tailer.Stream(ctx, a.Apply)
		if err != nil && ctx.Err() == nil {
			a.logger.Warn().Err(err).Dur("backoff", backoff).Msg("log tailer stream failed; retrying")
			timer := time.NewTimer(backoff)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-timer.C:
			}
			if backoff < maxBackoff {
				backoff *= 2
				if backoff > maxBackoff {
					backoff = maxBackoff
				}
			}
			continue
		}

		// Stream exited without error; reset backoff before retrying.
		backoff = time.Second
	}
}

// StartPersistence periodically saves the current snapshot using the configured store.
func (a *LogDigestAggregator) StartPersistence(ctx context.Context, interval time.Duration) {
	if a.store == nil {
		return
	}
	if interval <= 0 {
		interval = defaultLogDigestPersistenceInterval
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			a.persistSnapshot()
			return
		case <-ticker.C:
			a.persistSnapshot()
		}
	}
}

// Apply folds a new log entry into the digest.
func (a *LogDigestAggregator) Apply(entry models.LogSummary) {
	entry.Timestamp = entry.Timestamp.UTC()
	entry.Severity = strings.ToLower(entry.Severity)

	a.mu.Lock()
	defer a.mu.Unlock()

	// Prepend to maintain newest-first ordering.
	a.recent = append([]models.LogSummary{entry}, a.recent...)
	if len(a.recent) > a.maxEntries {
		a.recent = a.recent[:a.maxEntries]
	}

	minute := entry.Timestamp.Truncate(time.Minute)
	if len(a.buckets) > 0 && a.buckets[len(a.buckets)-1].minute.Equal(minute) {
		a.buckets[len(a.buckets)-1].add(entry.Severity)
	} else {
		bucket := logCounterBucket{minute: minute}
		bucket.add(entry.Severity)
		a.buckets = append(a.buckets, bucket)
	}

	a.pruneBucketsLocked(entry.Timestamp)
	a.updateCountersLocked(time.Now().UTC())
}

// Latest returns up to limit recent fatal/error log summaries.
func (a *LogDigestAggregator) Latest(limit int) []models.LogSummary {
	a.mu.RLock()
	defer a.mu.RUnlock()

	if limit <= 0 || limit > len(a.recent) {
		limit = len(a.recent)
	}

	return cloneSummaries(a.recent[:limit], limit)
}

// Counters returns a copy of the current rolling counters.
func (a *LogDigestAggregator) Counters() *models.LogCounters {
	a.mu.Lock()
	defer a.mu.Unlock()

	now := time.Now().UTC()
	a.pruneBucketsLocked(now)
	a.updateCountersLocked(now)

	if a.counters == nil {
		return nil
	}

	copy := *a.counters
	return &copy
}

// Snapshot returns a deep copy of the current digest cache.
func (a *LogDigestAggregator) Snapshot() *models.LogDigestSnapshot {
	a.mu.RLock()
	defer a.mu.RUnlock()

	snapshot := &models.LogDigestSnapshot{
		Entries:  cloneSummaries(a.recent, a.maxEntries),
		Counters: *a.counters,
	}

	return snapshot
}

func (a *LogDigestAggregator) persistSnapshot() {
	if a.store == nil {
		return
	}
	if err := a.store.Save(a.Snapshot()); err != nil {
		a.logger.Warn().Err(err).Msg("failed to persist log digest snapshot")
	}
}

func (a *LogDigestAggregator) ingestSnapshot(snapshot *models.LogDigestSnapshot) {
	if snapshot == nil {
		return
	}

	a.mu.Lock()
	defer a.mu.Unlock()

	a.resetLocked()

	entries := cloneSummaries(snapshot.Entries, a.maxEntries)
	for _, entry := range entries {
		entry.Timestamp = entry.Timestamp.UTC()
		entry.Severity = strings.ToLower(entry.Severity)
		a.recent = append([]models.LogSummary{entry}, a.recent...)
		minute := entry.Timestamp.Truncate(time.Minute)
		if len(a.buckets) > 0 && a.buckets[len(a.buckets)-1].minute.Equal(minute) {
			a.buckets[len(a.buckets)-1].add(entry.Severity)
		} else {
			bucket := logCounterBucket{minute: minute}
			bucket.add(entry.Severity)
			a.buckets = append(a.buckets, bucket)
		}
	}

	a.updateCountersLocked(time.Now().UTC())
	if snapshot.Counters.UpdatedAt.IsZero() {
		return
	}
	countersCopy := snapshot.Counters
	a.counters = &countersCopy
}

func (a *LogDigestAggregator) resetLocked() {
	a.recent = make([]models.LogSummary, 0, a.maxEntries)
	a.buckets = a.buckets[:0]
	a.counters = &models.LogCounters{}
}

func (a *LogDigestAggregator) pruneBucketsLocked(reference time.Time) {
	if len(a.buckets) == 0 {
		return
	}

	cutoff := reference.Add(-24 * time.Hour)
	idx := 0
	for idx < len(a.buckets) {
		if a.buckets[idx].minute.Add(time.Minute).Before(cutoff) {
			idx++
			continue
		}
		break
	}
	if idx > 0 {
		copy(a.buckets, a.buckets[idx:])
		a.buckets = a.buckets[:len(a.buckets)-idx]
	}
}

func (a *LogDigestAggregator) updateCountersLocked(now time.Time) {
	window1h := a.computeWindowCountsLocked(now, time.Hour)
	window24h := a.computeWindowCountsLocked(now, 24*time.Hour)

	a.counters = &models.LogCounters{
		UpdatedAt: now,
		Window1H:  window1h,
		Window24H: window24h,
	}
}

func (a *LogDigestAggregator) computeWindowCountsLocked(now time.Time, window time.Duration) models.SeverityWindowCounts {
	var counts models.SeverityWindowCounts
	cutoff := now.Add(-window)

	for _, bucket := range a.buckets {
		end := bucket.minute.Add(time.Minute)
		if end.Before(cutoff) {
			continue
		}
		if bucket.minute.After(now) {
			continue
		}

		counts.Fatal += bucket.fatal
		counts.Error += bucket.err
		counts.Warning += bucket.warn
		counts.Info += bucket.info
		counts.Debug += bucket.debug
		counts.Other += bucket.other
	}

	counts.Total = counts.Fatal + counts.Error + counts.Warning + counts.Info + counts.Debug + counts.Other
	return counts
}

func cloneSummaries(entries []models.LogSummary, limit int) []models.LogSummary {
	if len(entries) == 0 {
		return []models.LogSummary{}
	}

	capped := entries
	if l := len(entries); l > limit {
		capped = entries[:limit]
	}

	out := make([]models.LogSummary, len(capped))
	copy(out, capped)

	return out
}
