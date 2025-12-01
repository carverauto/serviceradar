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
)

type ageGraphMetrics struct {
	success atomic.Uint64
	failure atomic.Uint64
}

var (
	ageMetricsOnce sync.Once
	ageMetrics     = &ageGraphMetrics{}
	ageGauges      struct {
		success metric.Int64ObservableGauge
		failure metric.Int64ObservableGauge
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

	reg, err := meter.RegisterCallback(func(ctx context.Context, observer metric.Observer) error {
		observer.ObserveInt64(ageGauges.success, int64(ageMetrics.success.Load()))
		observer.ObserveInt64(ageGauges.failure, int64(ageMetrics.failure.Load()))
		return nil
	}, ageGauges.success, ageGauges.failure)
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
