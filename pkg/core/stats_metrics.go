package core

import (
	"context"
	"sync"
	"sync/atomic"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/metric"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	statsMeterName                = "serviceradar.core.device_stats"
	metricRawRecordsName          = "core_device_stats_raw_records"
	metricProcessedRecordsName    = "core_device_stats_processed_records"
	metricSkippedNonCanonicalName = "core_device_stats_skipped_non_canonical"
	metricInferredCanonicalName   = "core_device_stats_inferred_canonical"
	metricSkippedComponentsName   = "core_device_stats_skipped_service_components"
	metricSkippedTombstonedName   = "core_device_stats_skipped_tombstoned"
	metricSnapshotAgeName         = "core_device_stats_snapshot_age_ms"
	metricSkippedSweepOnlyName    = "core_device_stats_skipped_sweep_only"
)

var (
	//nolint:gochecknoglobals // metric observers are shared singletons
	statsMetricsOnce sync.Once
	//nolint:gochecknoglobals // metric observers are shared singletons
	statsMetricsData = &statsMetricsObservatory{}
	//nolint:gochecknoglobals // metric observers are shared singletons
	statsMetricsGauges struct {
		rawRecords          metric.Int64ObservableGauge
		processedRecords    metric.Int64ObservableGauge
		skippedNonCanonical metric.Int64ObservableGauge
		inferredCanonical   metric.Int64ObservableGauge
		skippedComponents   metric.Int64ObservableGauge
		skippedTombstoned   metric.Int64ObservableGauge
		skippedSweepOnly    metric.Int64ObservableGauge
		snapshotAgeMs       metric.Int64ObservableGauge
	}
	statsMetricsRegistration metric.Registration //nolint:unused,gochecknoglobals // reference retained to keep callback registered
)

type statsMetricsObservatory struct {
	rawRecords          atomic.Int64
	processedRecords    atomic.Int64
	skippedNonCanonical atomic.Int64
	inferredCanonical   atomic.Int64
	skippedComponents   atomic.Int64
	skippedTombstoned   atomic.Int64
	skippedSweepOnly    atomic.Int64
	snapshotAgeMs       atomic.Int64
}

func initStatsMetrics() {
	meter := otel.Meter(statsMeterName)

	var err error
	statsMetricsGauges.rawRecords, err = meter.Int64ObservableGauge(
		metricRawRecordsName,
		metric.WithDescription("Latest raw registry record count observed by the stats aggregator"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	statsMetricsGauges.processedRecords, err = meter.Int64ObservableGauge(
		metricProcessedRecordsName,
		metric.WithDescription("Latest processed canonical record count emitted by the stats aggregator"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	statsMetricsGauges.skippedNonCanonical, err = meter.Int64ObservableGauge(
		metricSkippedNonCanonicalName,
		metric.WithDescription("Latest count of non-canonical registry records filtered from the stats snapshot"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	statsMetricsGauges.inferredCanonical, err = meter.Int64ObservableGauge(
		metricInferredCanonicalName,
		metric.WithDescription("Latest count of registry records treated as canonical via fallback"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	statsMetricsGauges.skippedComponents, err = meter.Int64ObservableGauge(
		metricSkippedComponentsName,
		metric.WithDescription("Latest count of ServiceRadar component device records filtered from the stats snapshot"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	statsMetricsGauges.skippedTombstoned, err = meter.Int64ObservableGauge(
		metricSkippedTombstonedName,
		metric.WithDescription("Latest count of tombstoned or merged device aliases filtered from the stats snapshot"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	statsMetricsGauges.skippedSweepOnly, err = meter.Int64ObservableGauge(
		metricSkippedSweepOnlyName,
		metric.WithDescription("Latest count of sweep-only registry records filtered from the stats snapshot"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	statsMetricsGauges.snapshotAgeMs, err = meter.Int64ObservableGauge(
		metricSnapshotAgeName,
		metric.WithDescription("Age in milliseconds of the latest device stats snapshot"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	registration, err := meter.RegisterCallback(func(ctx context.Context, observer metric.Observer) error {
		observer.ObserveInt64(statsMetricsGauges.rawRecords, statsMetricsData.rawRecords.Load())
		observer.ObserveInt64(statsMetricsGauges.processedRecords, statsMetricsData.processedRecords.Load())
		observer.ObserveInt64(statsMetricsGauges.skippedNonCanonical, statsMetricsData.skippedNonCanonical.Load())
		observer.ObserveInt64(statsMetricsGauges.inferredCanonical, statsMetricsData.inferredCanonical.Load())
		observer.ObserveInt64(statsMetricsGauges.skippedComponents, statsMetricsData.skippedComponents.Load())
		observer.ObserveInt64(statsMetricsGauges.skippedTombstoned, statsMetricsData.skippedTombstoned.Load())
		observer.ObserveInt64(statsMetricsGauges.skippedSweepOnly, statsMetricsData.skippedSweepOnly.Load())
		observer.ObserveInt64(statsMetricsGauges.snapshotAgeMs, statsMetricsData.snapshotAgeMs.Load())
		return nil
	},
		statsMetricsGauges.rawRecords,
		statsMetricsGauges.processedRecords,
		statsMetricsGauges.skippedNonCanonical,
		statsMetricsGauges.inferredCanonical,
		statsMetricsGauges.skippedComponents,
		statsMetricsGauges.skippedTombstoned,
		statsMetricsGauges.skippedSweepOnly,
		statsMetricsGauges.snapshotAgeMs,
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	statsMetricsRegistration = registration
}

func recordStatsMetrics(meta models.DeviceStatsMeta, snapshot *models.DeviceStatsSnapshot) {
	statsMetricsOnce.Do(initStatsMetrics)

	statsMetricsData.rawRecords.Store(int64(meta.RawRecords))
	statsMetricsData.processedRecords.Store(int64(meta.ProcessedRecords))
	statsMetricsData.skippedNonCanonical.Store(int64(meta.SkippedNonCanonical))
	statsMetricsData.inferredCanonical.Store(int64(meta.InferredCanonicalFallback))
	statsMetricsData.skippedComponents.Store(int64(meta.SkippedServiceComponents))
	statsMetricsData.skippedTombstoned.Store(int64(meta.SkippedTombstonedRecords))
	statsMetricsData.skippedSweepOnly.Store(int64(meta.SkippedSweepOnlyRecords))

	var ageMs int64
	if snapshot != nil && !snapshot.Timestamp.IsZero() {
		age := time.Since(snapshot.Timestamp)
		if age < 0 {
			age = 0
		}
		ageMs = age.Milliseconds()
	} else {
		ageMs = 0
	}
	statsMetricsData.snapshotAgeMs.Store(ageMs)
}
