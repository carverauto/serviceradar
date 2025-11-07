package core

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

type fakeLogDigestSource struct {
	snapshot *models.LogDigestSnapshot
}

func (f *fakeLogDigestSource) Fetch(_ context.Context, limit int) (*models.LogDigestSnapshot, error) {
	if len(f.snapshot.Entries) > limit {
		copySnapshot := *f.snapshot
		copySnapshot.Entries = copySnapshot.Entries[:limit]
		return &copySnapshot, nil
	}
	return f.snapshot, nil
}

type blockingLogDigestSource struct {
	wait chan struct{}
}

func newBlockingLogDigestSource() *blockingLogDigestSource {
	return &blockingLogDigestSource{
		wait: make(chan struct{}),
	}
}

func (b *blockingLogDigestSource) Fetch(ctx context.Context, _ int) (*models.LogDigestSnapshot, error) {
	if b.wait != nil {
		close(b.wait)
	}
	<-ctx.Done()
	return nil, ctx.Err()
}

func TestLogDigestAggregatorApply(t *testing.T) {
	t.Helper()

	log := logger.NewTestLogger()
	aggregator := NewLogDigestAggregator(5, nil, log)

	now := time.Now().UTC()
	aggregator.Apply(models.LogSummary{
		Timestamp: now.Add(-30 * time.Second),
		Severity:  "FATAL",
		Body:      "fatal failure",
	})
	aggregator.Apply(models.LogSummary{
		Timestamp: now.Add(-10 * time.Second),
		Severity:  "error",
		Body:      "error request",
	})

	latest := aggregator.Latest(10)
	require.Len(t, latest, 2)
	require.Equal(t, "error", latest[0].Severity)
	require.Equal(t, "fatal", latest[1].Severity)

	counters := aggregator.Counters()
	require.NotNil(t, counters)
	require.Equal(t, 2, counters.Window1H.Total)
	require.Equal(t, 1, counters.Window1H.Fatal)
	require.Equal(t, 1, counters.Window1H.Error)

	// Ensure returned slices are defensive copies.
	latest[0].Severity = "mutated"
	stillLatest := aggregator.Latest(10)
	require.Equal(t, "error", stillLatest[0].Severity)
}

func TestLogDigestAggregatorBootstrapFromSource(t *testing.T) {
	t.Helper()

	log := logger.NewTestLogger()
	aggregator := NewLogDigestAggregator(5, nil, log)

	now := time.Now().UTC()
	source := &fakeLogDigestSource{
		snapshot: &models.LogDigestSnapshot{
			Entries: []models.LogSummary{
				{
					Timestamp: now.Add(-2 * time.Minute),
					Severity:  "fatal",
					Body:      "fatal failure",
				},
				{
					Timestamp: now.Add(-1 * time.Minute),
					Severity:  "error",
					Body:      "error request",
				},
			},
			Counters: models.LogCounters{
				UpdatedAt: now,
				Window1H: models.SeverityWindowCounts{
					Total: 2,
					Fatal: 1,
					Error: 1,
				},
				Window24H: models.SeverityWindowCounts{
					Total:   10,
					Fatal:   3,
					Error:   4,
					Warning: 2,
					Info:    1,
				},
			},
		},
	}

	require.NoError(t, aggregator.Bootstrap(context.Background(), source))

	latest := aggregator.Latest(10)
	require.Len(t, latest, 2)
	require.Equal(t, "error", latest[0].Severity)

	counters := aggregator.Counters()
	require.NotNil(t, counters)
	require.Equal(t, 2, counters.Window1H.Total)
	require.Equal(t, 2, counters.Window24H.Total)
	require.Equal(t, 1, counters.Window24H.Fatal)
	require.Equal(t, 1, counters.Window24H.Error)
}

func TestLogDigestAggregatorHydrateTimeout(t *testing.T) {
	t.Helper()

	log := logger.NewTestLogger()
	aggregator := NewLogDigestAggregator(5, nil, log)

	blockingSource := newBlockingLogDigestSource()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	err := aggregator.HydrateFromSource(ctx, blockingSource)
	require.Error(t, err)
	require.ErrorIs(t, err, context.DeadlineExceeded)

	latest := aggregator.Latest(10)
	require.Empty(t, latest)
}

func TestLogDigestAggregatorPersistence(t *testing.T) {
	t.Helper()

	log := logger.NewTestLogger()
	storePath := filepath.Join(t.TempDir(), "digest.json")
	store, err := NewFileLogDigestStore(storePath, log)
	require.NoError(t, err)

	now := time.Now().UTC()

	primary := NewLogDigestAggregator(5, store, log)
	primary.Apply(models.LogSummary{
		Timestamp: now.Add(-15 * time.Second),
		Severity:  "fatal",
		Body:      "fatal failure",
	})
	require.NoError(t, store.Save(primary.Snapshot()))

	restored := NewLogDigestAggregator(5, store, log)
	require.NoError(t, restored.Bootstrap(context.Background(), nil))

	latest := restored.Latest(10)
	require.Len(t, latest, 1)
	require.Equal(t, "fatal", latest[0].Severity)
	require.WithinDuration(t, now.Add(-15*time.Second), latest[0].Timestamp, 2*time.Second)
}
