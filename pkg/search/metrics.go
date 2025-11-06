package search

import (
	"context"
	"strings"
	"sync"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
)

const (
	searchMeterName            = "serviceradar.search"
	metricRegistryLatencyName  = "search_registry_duration_seconds"
	metricSRQLLatencyName      = "search_srql_duration_seconds"
	metricPlannerFallbackTotal = "search_planner_fallback_total"
)

var (
	searchMetricsOnce sync.Once

	registryLatency metric.Float64Histogram
	srqlLatency     metric.Float64Histogram
	fallbackCounter metric.Int64Counter
)

func initSearchMetrics() {
	meter := otel.Meter(searchMeterName)

	if hist, err := meter.Float64Histogram(
		metricRegistryLatencyName,
		metric.WithDescription("Latency for registry-backed device searches"),
		metric.WithUnit("s"),
	); err != nil {
		otel.Handle(err)
	} else {
		registryLatency = hist
	}

	if hist, err := meter.Float64Histogram(
		metricSRQLLatencyName,
		metric.WithDescription("Latency for SRQL-backed device searches"),
		metric.WithUnit("s"),
	); err != nil {
		otel.Handle(err)
	} else {
		srqlLatency = hist
	}

	if counter, err := meter.Int64Counter(
		metricPlannerFallbackTotal,
		metric.WithDescription("Total planner fallbacks to SRQL when registry cannot satisfy a query"),
	); err != nil {
		otel.Handle(err)
	} else {
		fallbackCounter = counter
	}
}

func recordRegistryLatency(ctx context.Context, duration time.Duration, mode Mode, status string, results int) {
	searchMetricsOnce.Do(initSearchMetrics)
	if registryLatency == nil {
		return
	}

	if duration < 0 {
		duration = 0
	}

	registryLatency.Record(
		ctx,
		duration.Seconds(),
		metric.WithAttributes(
			attribute.String("mode", string(normalizeMode(mode))),
			attribute.String("status", normalizeStatus(status)),
			attribute.String("result_state", classifyResultSize(results)),
		),
	)
}

func recordSRQLLatency(ctx context.Context, duration time.Duration, mode Mode, status string, results int) {
	searchMetricsOnce.Do(initSearchMetrics)
	if srqlLatency == nil {
		return
	}

	if duration < 0 {
		duration = 0
	}

	srqlLatency.Record(
		ctx,
		duration.Seconds(),
		metric.WithAttributes(
			attribute.String("mode", string(normalizeMode(mode))),
			attribute.String("status", normalizeStatus(status)),
			attribute.String("result_state", classifyResultSize(results)),
		),
	)
}

func recordPlannerFallback(ctx context.Context, reason string, mode Mode) {
	searchMetricsOnce.Do(initSearchMetrics)
	if fallbackCounter == nil {
		return
	}

	reason = strings.TrimSpace(strings.ToLower(reason))
	if reason == "" {
		reason = "unknown"
	}

	fallbackCounter.Add(
		ctx,
		1,
		metric.WithAttributes(
			attribute.String("reason", reason),
			attribute.String("mode", string(normalizeMode(mode))),
		),
	)
}

func normalizeMode(mode Mode) Mode {
	switch mode {
	case ModeRegistryOnly, ModeSRQLOnly:
		return mode
	default:
		return ModeAuto
	}
}

func normalizeStatus(status string) string {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "error", "failure", "failed":
		return "error"
	default:
		return "success"
	}
}

func classifyResultSize(count int) string {
	switch {
	case count <= 0:
		return "empty"
	case count < 10:
		return "lt10"
	case count < 50:
		return "lt50"
	case count < 100:
		return "lt100"
	default:
		return "gte100"
	}
}
