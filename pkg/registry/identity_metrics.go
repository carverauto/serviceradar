package registry

import (
	"context"
	"sync"
	"sync/atomic"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/metric"
)

const (
	identityMeterName                  = "serviceradar.identity"
	metricPromotedLastRunName          = "identity_promotions_last_batch"
	metricEligibleAutoLastRunName      = "identity_promotions_eligible_auto_last_batch"
	metricShadowReadyLastRunName       = "identity_promotions_shadow_ready_last_batch"
	metricBlockedPolicyLastRunName     = "identity_promotions_blocked_policy_last_batch"
	metricPromotionRunAgeMsName        = "identity_promotion_run_age_ms"
	metricPromotionRunTimestampName    = "identity_promotion_run_timestamp_ms"
	metricPromotionShadowOnlyRunName   = "identity_promotion_shadow_only_last_batch"
	metricPromotionAttemptsLastRunName = "identity_promotions_attempted_last_batch"
	metricDriftCurrentDevicesName      = "identity_cardinality_current"
	metricDriftBaselineDevicesName     = "identity_cardinality_baseline"
	metricDriftPercentName             = "identity_cardinality_drift_percent"
	metricDriftBlockedName             = "identity_cardinality_blocked"
	metricSweepMergesLastRunName       = "identity_sweep_merges_last_batch"
	metricBatchIPCollisionsTotalName   = "device_batch_ip_collisions_total"
)

// identityMetricsObservatory stores the latest promotion reconciliation measurements.
type identityMetricsObservatory struct {
	promotedLastRun       atomic.Int64
	eligibleAutoLastRun   atomic.Int64
	shadowReadyLastRun    atomic.Int64
	blockedPolicyLastRun  atomic.Int64
	shadowOnlyLastRun     atomic.Int64
	attemptedLastRun      atomic.Int64
	runTimestampMs        atomic.Int64
	runAgeMs              atomic.Int64
	driftCurrentDevices   atomic.Int64
	driftBaselineDevices  atomic.Int64
	driftPercent          atomic.Int64
	driftBlocked          atomic.Int64
	sweepMergesLastRun    atomic.Int64
	batchIPCollisionsTotal atomic.Int64
}

var (
	//nolint:gochecknoglobals // metric observers are shared singletons
	identityMetricsOnce sync.Once
	//nolint:gochecknoglobals // metric observers are shared singletons
	identityMetricsData = &identityMetricsObservatory{}
	//nolint:gochecknoglobals // metric observers are shared singletons
	identityMetricsGauges struct {
		promotedLastRun        metric.Int64ObservableGauge
		eligibleAutoLastRun    metric.Int64ObservableGauge
		shadowReadyLastRun     metric.Int64ObservableGauge
		blockedPolicyLastRun   metric.Int64ObservableGauge
		shadowOnlyLastRun      metric.Int64ObservableGauge
		attemptedLastRun       metric.Int64ObservableGauge
		runTimestampMs         metric.Int64ObservableGauge
		runAgeMs               metric.Int64ObservableGauge
		driftCurrentDevices    metric.Int64ObservableGauge
		driftBaselineDevices   metric.Int64ObservableGauge
		driftPercent           metric.Int64ObservableGauge
		driftBlocked           metric.Int64ObservableGauge
		sweepMergesLastRun     metric.Int64ObservableGauge
		batchIPCollisionsTotal metric.Int64ObservableGauge
	}
	identityMetricsRegistration metric.Registration //nolint:unused,gochecknoglobals // kept to retain callback
)

func initIdentityMetrics() {
	meter := otel.Meter(identityMeterName)

	var err error
	identityMetricsGauges.promotedLastRun, err = meter.Int64ObservableGauge(
		metricPromotedLastRunName,
		metric.WithDescription("Number of sightings promoted in the latest reconciliation batch"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	identityMetricsGauges.eligibleAutoLastRun, err = meter.Int64ObservableGauge(
		metricEligibleAutoLastRunName,
		metric.WithDescription("Number of sightings eligible for auto-promotion in the latest reconciliation batch"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	identityMetricsGauges.shadowReadyLastRun, err = meter.Int64ObservableGauge(
		metricShadowReadyLastRunName,
		metric.WithDescription("Number of policy-ready sightings when shadow mode is enabled"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	identityMetricsGauges.blockedPolicyLastRun, err = meter.Int64ObservableGauge(
		metricBlockedPolicyLastRunName,
		metric.WithDescription("Number of sightings blocked by promotion policy in the latest batch"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	identityMetricsGauges.shadowOnlyLastRun, err = meter.Int64ObservableGauge(
		metricPromotionShadowOnlyRunName,
		metric.WithDescription("Number of sightings evaluated while in shadow-only mode"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	identityMetricsGauges.attemptedLastRun, err = meter.Int64ObservableGauge(
		metricPromotionAttemptsLastRunName,
		metric.WithDescription("Total sightings examined during the latest promotion run"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	identityMetricsGauges.runTimestampMs, err = meter.Int64ObservableGauge(
		metricPromotionRunTimestampName,
		metric.WithDescription("Unix epoch milliseconds of the latest promotion reconciliation run"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	identityMetricsGauges.runAgeMs, err = meter.Int64ObservableGauge(
		metricPromotionRunAgeMsName,
		metric.WithDescription("Age in milliseconds of the latest promotion reconciliation run"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	identityMetricsGauges.driftCurrentDevices, err = meter.Int64ObservableGauge(
		metricDriftCurrentDevicesName,
		metric.WithDescription("Current unified device count used for identity drift detection"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	identityMetricsGauges.driftBaselineDevices, err = meter.Int64ObservableGauge(
		metricDriftBaselineDevicesName,
		metric.WithDescription("Baseline device count configured for identity drift detection"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	identityMetricsGauges.driftPercent, err = meter.Int64ObservableGauge(
		metricDriftPercentName,
		metric.WithDescription("Percentage drift from baseline (positive means over baseline)"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	identityMetricsGauges.driftBlocked, err = meter.Int64ObservableGauge(
		metricDriftBlockedName,
		metric.WithDescription("1 when promotion is blocked due to identity cardinality drift, otherwise 0"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	identityMetricsGauges.sweepMergesLastRun, err = meter.Int64ObservableGauge(
		metricSweepMergesLastRunName,
		metric.WithDescription("Number of sweep sightings merged directly into canonical devices in the latest batch"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	identityMetricsGauges.batchIPCollisionsTotal, err = meter.Int64ObservableGauge(
		metricBatchIPCollisionsTotalName,
		metric.WithDescription("Total IP collisions resolved by creating tombstones in batch deduplication"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	registration, err := meter.RegisterCallback(func(ctx context.Context, observer metric.Observer) error {
		observer.ObserveInt64(identityMetricsGauges.promotedLastRun, identityMetricsData.promotedLastRun.Load())
		observer.ObserveInt64(identityMetricsGauges.eligibleAutoLastRun, identityMetricsData.eligibleAutoLastRun.Load())
		observer.ObserveInt64(identityMetricsGauges.shadowReadyLastRun, identityMetricsData.shadowReadyLastRun.Load())
		observer.ObserveInt64(identityMetricsGauges.blockedPolicyLastRun, identityMetricsData.blockedPolicyLastRun.Load())
		observer.ObserveInt64(identityMetricsGauges.shadowOnlyLastRun, identityMetricsData.shadowOnlyLastRun.Load())
		observer.ObserveInt64(identityMetricsGauges.attemptedLastRun, identityMetricsData.attemptedLastRun.Load())
		observer.ObserveInt64(identityMetricsGauges.runTimestampMs, identityMetricsData.runTimestampMs.Load())
		observer.ObserveInt64(identityMetricsGauges.runAgeMs, identityMetricsData.runAgeMs.Load())
		observer.ObserveInt64(identityMetricsGauges.driftCurrentDevices, identityMetricsData.driftCurrentDevices.Load())
		observer.ObserveInt64(identityMetricsGauges.driftBaselineDevices, identityMetricsData.driftBaselineDevices.Load())
		observer.ObserveInt64(identityMetricsGauges.driftPercent, identityMetricsData.driftPercent.Load())
		observer.ObserveInt64(identityMetricsGauges.driftBlocked, identityMetricsData.driftBlocked.Load())
		observer.ObserveInt64(identityMetricsGauges.sweepMergesLastRun, identityMetricsData.sweepMergesLastRun.Load())
		observer.ObserveInt64(identityMetricsGauges.batchIPCollisionsTotal, identityMetricsData.batchIPCollisionsTotal.Load())
		return nil
	},
		identityMetricsGauges.promotedLastRun,
		identityMetricsGauges.eligibleAutoLastRun,
		identityMetricsGauges.shadowReadyLastRun,
		identityMetricsGauges.blockedPolicyLastRun,
		identityMetricsGauges.shadowOnlyLastRun,
		identityMetricsGauges.attemptedLastRun,
		identityMetricsGauges.runTimestampMs,
		identityMetricsGauges.runAgeMs,
		identityMetricsGauges.driftCurrentDevices,
		identityMetricsGauges.driftBaselineDevices,
		identityMetricsGauges.driftPercent,
		identityMetricsGauges.driftBlocked,
		identityMetricsGauges.sweepMergesLastRun,
		identityMetricsGauges.batchIPCollisionsTotal,
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	identityMetricsRegistration = registration
}

// recordIdentityPromotionMetrics updates gauges for the latest promotion reconciliation pass.
func recordIdentityPromotionMetrics(attempted, promoted, eligibleAuto, shadowReady, blockedPolicy int, shadowMode bool, runTime time.Time) {
	identityMetricsOnce.Do(initIdentityMetrics)

	identityMetricsData.attemptedLastRun.Store(int64(attempted))
	identityMetricsData.promotedLastRun.Store(int64(promoted))
	identityMetricsData.eligibleAutoLastRun.Store(int64(eligibleAuto))
	identityMetricsData.shadowReadyLastRun.Store(int64(shadowReady))
	identityMetricsData.blockedPolicyLastRun.Store(int64(blockedPolicy))
	if shadowMode {
		identityMetricsData.shadowOnlyLastRun.Store(int64(attempted))
	} else {
		identityMetricsData.shadowOnlyLastRun.Store(0)
	}

	timestampMs := runTime.UnixMilli()
	identityMetricsData.runTimestampMs.Store(timestampMs)

	age := time.Since(runTime)
	if age < 0 {
		age = 0
	}
	identityMetricsData.runAgeMs.Store(age.Milliseconds())
}

// recordIdentityDriftMetrics captures cardinality drift metrics and whether promotion is blocked.
func recordIdentityDriftMetrics(current, baseline int64, tolerancePercent int, blocked bool) {
	identityMetricsOnce.Do(initIdentityMetrics)

	identityMetricsData.driftCurrentDevices.Store(current)
	identityMetricsData.driftBaselineDevices.Store(baseline)

	var percent int64
	if baseline > 0 {
		percent = ((current - baseline) * 100) / baseline
	}
	identityMetricsData.driftPercent.Store(percent)

	if blocked {
		identityMetricsData.driftBlocked.Store(1)
	} else {
		identityMetricsData.driftBlocked.Store(0)
	}

	// Preserve tolerance as a baseline in the percent gauge when baseline is zero to avoid division by zero; zero indicates disabled.
	if baseline == 0 && tolerancePercent > 0 {
		identityMetricsData.driftPercent.Store(int64(tolerancePercent))
	}
}

// recordSweepMergeMetrics tracks sweep sighting merges into canonical devices.
func recordSweepMergeMetrics(merged int, runTime time.Time) {
	identityMetricsOnce.Do(initIdentityMetrics)

	identityMetricsData.sweepMergesLastRun.Store(int64(merged))

	timestampMs := runTime.UnixMilli()
	identityMetricsData.runTimestampMs.Store(timestampMs)

	age := time.Since(runTime)
	if age < 0 {
		age = 0
	}
	identityMetricsData.runAgeMs.Store(age.Milliseconds())
}
