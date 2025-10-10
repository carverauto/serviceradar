package identitymap

import (
	"context"
	"sync"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
)

const (
	meterName            = "serviceradar.identitymap"
	metricKVPublishTotal = "identitymap_kv_publish_total"
	metricKVConflict     = "identitymap_conflict_total"
	metricLookupLatency  = "identitymap_lookup_latency_seconds"
)

var (
	// instrumentation handles are cached globally to avoid re-registering OTEL instruments on every call.
	//nolint:gochecknoglobals // metrics instruments are shared across the process intentionally
	meterOnce sync.Once
	//nolint:gochecknoglobals // metrics instruments are shared across the process intentionally
	publishCounter metric.Int64Counter
	//nolint:gochecknoglobals // metrics instruments are shared across the process intentionally
	conflictCounter metric.Int64Counter
	//nolint:gochecknoglobals // metrics instruments are shared across the process intentionally
	lookupHistogram metric.Float64Histogram
)

func initMeter() {
	meter := otel.Meter(meterName)

	counter, err := meter.Int64Counter(
		metricKVPublishTotal,
		metric.WithDescription("Total KV identity map publish operations"),
	)
	if err != nil {
		otel.Handle(err)
	}
	publishCounter = counter

	conflict, err := meter.Int64Counter(
		metricKVConflict,
		metric.WithDescription("Total KV identity map conflicts or retry exhaustion events"),
	)
	if err != nil {
		otel.Handle(err)
	}
	conflictCounter = conflict

	hist, err := meter.Float64Histogram(
		metricLookupLatency,
		metric.WithDescription("Latency for canonical identity lookups"),
		metric.WithUnit("s"),
	)
	if err != nil {
		otel.Handle(err)
	}
	lookupHistogram = hist
}

// RecordKVPublish increments the publish counter for KV writes.
func RecordKVPublish(ctx context.Context, count int, outcome string) {
	if count == 0 {
		return
	}

	meterOnce.Do(initMeter)
	if publishCounter == nil {
		return
	}

	publishCounter.Add(ctx, int64(count), metric.WithAttributes(attribute.String("outcome", outcome)))
}

// RecordKVConflict increments the conflict counter for CAS contention or retry exhaustion scenarios.
func RecordKVConflict(ctx context.Context, reason string) {
	meterOnce.Do(initMeter)
	if conflictCounter == nil {
		return
	}

	conflictCounter.Add(ctx, 1, metric.WithAttributes(attribute.String("reason", reason)))
}

// RecordLookupLatency captures the duration of canonical lookup requests.
func RecordLookupLatency(ctx context.Context, duration time.Duration, resolvedVia string, found bool) {
	meterOnce.Do(initMeter)
	if lookupHistogram == nil {
		return
	}

	lookupHistogram.Record(
		ctx,
		duration.Seconds(),
		metric.WithAttributes(
			attribute.String("resolved_via", resolvedVia),
			attribute.Bool("found", found),
		),
	)
}
