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
)

// identityMetricsObservatory stores the latest promotion reconciliation measurements.
type identityMetricsObservatory struct {
	promotedLastRun      atomic.Int64
	eligibleAutoLastRun  atomic.Int64
	shadowReadyLastRun   atomic.Int64
	blockedPolicyLastRun atomic.Int64
	shadowOnlyLastRun    atomic.Int64
	attemptedLastRun     atomic.Int64
	runTimestampMs       atomic.Int64
	runAgeMs             atomic.Int64
}

var (
	//nolint:gochecknoglobals // metric observers are shared singletons
	identityMetricsOnce sync.Once
	//nolint:gochecknoglobals // metric observers are shared singletons
	identityMetricsData = &identityMetricsObservatory{}
	//nolint:gochecknoglobals // metric observers are shared singletons
	identityMetricsGauges struct {
		promotedLastRun      metric.Int64ObservableGauge
		eligibleAutoLastRun  metric.Int64ObservableGauge
		shadowReadyLastRun   metric.Int64ObservableGauge
		blockedPolicyLastRun metric.Int64ObservableGauge
		shadowOnlyLastRun    metric.Int64ObservableGauge
		attemptedLastRun     metric.Int64ObservableGauge
		runTimestampMs       metric.Int64ObservableGauge
		runAgeMs             metric.Int64ObservableGauge
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

	registration, err := meter.RegisterCallback(func(ctx context.Context, observer metric.Observer) error {
		observer.ObserveInt64(identityMetricsGauges.promotedLastRun, identityMetricsData.promotedLastRun.Load())
		observer.ObserveInt64(identityMetricsGauges.eligibleAutoLastRun, identityMetricsData.eligibleAutoLastRun.Load())
		observer.ObserveInt64(identityMetricsGauges.shadowReadyLastRun, identityMetricsData.shadowReadyLastRun.Load())
		observer.ObserveInt64(identityMetricsGauges.blockedPolicyLastRun, identityMetricsData.blockedPolicyLastRun.Load())
		observer.ObserveInt64(identityMetricsGauges.shadowOnlyLastRun, identityMetricsData.shadowOnlyLastRun.Load())
		observer.ObserveInt64(identityMetricsGauges.attemptedLastRun, identityMetricsData.attemptedLastRun.Load())
		observer.ObserveInt64(identityMetricsGauges.runTimestampMs, identityMetricsData.runTimestampMs.Load())
		observer.ObserveInt64(identityMetricsGauges.runAgeMs, identityMetricsData.runAgeMs.Load())
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
