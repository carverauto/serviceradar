package core

import (
	"context"
	"sync"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"

	"github.com/carverauto/serviceradar/pkg/models"
)

type capabilityMetricsState struct {
	once    sync.Once
	counter metric.Int64Counter
}

var capabilityMetrics capabilityMetricsState

func recordCapabilityEventMetric(ctx context.Context, event *models.DeviceCapabilityEvent) {
	if event == nil {
		return
	}

	capabilityMetrics.once.Do(func() {
		meter := otel.Meter("serviceradar.core.capabilities")
		counter, err := meter.Int64Counter(
			"serviceradar_core_capability_events_total",
			metric.WithDescription("Total capability events published by the core service"),
		)
		if err != nil {
			return
		}
		capabilityMetrics.counter = counter
	})

	if capabilityMetrics.counter == nil {
		return
	}

	attrs := []attribute.KeyValue{
		attribute.String("capability", event.Capability),
		attribute.String("state", event.State),
	}
	if event.ServiceType != "" {
		attrs = append(attrs, attribute.String("service_type", event.ServiceType))
	}
	if event.RecordedBy != "" {
		attrs = append(attrs, attribute.String("recorded_by", event.RecordedBy))
	}

	capabilityMetrics.counter.Add(ctx, 1, metric.WithAttributes(attrs...))
}
