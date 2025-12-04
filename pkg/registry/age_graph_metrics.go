package registry

import (
	"context"
	"sync"
	"sync/atomic"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/metric"
)

const (
	ageMeterName               = "serviceradar.age_graph"
	metricAgeWritesSuccessName = "age_graph_writes_success_total"
	metricAgeWritesFailureName = "age_graph_writes_failure_total"
	metricAgeQueueDepthName    = "age_graph_queue_depth"
	metricAgeQueueCapName      = "age_graph_queue_capacity"
)

type ageGraphMetrics struct {
	success atomic.Uint64
	failure atomic.Uint64
}

//nolint:gochecknoglobals,unused // metrics are process-wide; keep registration to prevent GC
var (
	ageMetricsOnce sync.Once
	ageMetrics     = &ageGraphMetrics{}
	ageQueueDepth  atomic.Int64
	ageQueueCap    atomic.Int64
	ageGauges      struct {
		success       metric.Int64ObservableGauge
		failure       metric.Int64ObservableGauge
		queueDepth    metric.Int64ObservableGauge
		queueCapacity metric.Int64ObservableGauge
	}
	ageMetricsRegistration metric.Registration // keep handle to avoid GC
)

func initAgeMetrics() {
	meter := otel.Meter(ageMeterName)

	var err error
	ageGauges.success, err = meter.Int64ObservableGauge(
		metricAgeWritesSuccessName,
		metric.WithDescription("Total successful AGE graph write batches"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	ageGauges.failure, err = meter.Int64ObservableGauge(
		metricAgeWritesFailureName,
		metric.WithDescription("Total failed AGE graph write batches"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	ageGauges.queueDepth, err = meter.Int64ObservableGauge(
		metricAgeQueueDepthName,
		metric.WithDescription("Current queued AGE graph batches"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	ageGauges.queueCapacity, err = meter.Int64ObservableGauge(
		metricAgeQueueCapName,
		metric.WithDescription("Configured AGE graph queue capacity"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}

	reg, err := meter.RegisterCallback(func(ctx context.Context, observer metric.Observer) error {
		observer.ObserveInt64(ageGauges.success, int64(ageMetrics.success.Load()))
		observer.ObserveInt64(ageGauges.failure, int64(ageMetrics.failure.Load()))
		observer.ObserveInt64(ageGauges.queueDepth, ageQueueDepth.Load())
		observer.ObserveInt64(ageGauges.queueCapacity, ageQueueCap.Load())
		return nil
	}, ageGauges.success, ageGauges.failure, ageGauges.queueDepth, ageGauges.queueCapacity)
	if err != nil {
		otel.Handle(err)
		return
	}
	ageMetricsRegistration = reg
}

func recordAgeGraphSuccess() {
	ageMetricsOnce.Do(initAgeMetrics)
	ageMetrics.success.Add(1)
}

func recordAgeGraphFailure() {
	ageMetricsOnce.Do(initAgeMetrics)
	ageMetrics.failure.Add(1)
}

func incrementAgeQueueDepth(delta int64) {
	ageMetricsOnce.Do(initAgeMetrics)
	ageQueueDepth.Add(delta)
}

func setAgeQueueCapacity(capacity int64) {
	ageMetricsOnce.Do(initAgeMetrics)
	if capacity < 0 {
		capacity = 0
	}
	ageQueueCap.Store(capacity)
}

func currentAgeQueueDepth() int64 {
	return ageQueueDepth.Load()
}

func currentAgeQueueCapacity() int64 {
	return ageQueueCap.Load()
}
