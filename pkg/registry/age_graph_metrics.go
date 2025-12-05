package registry

import (
	"context"
	"runtime"
	"sync"
	"sync/atomic"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/metric"
)

const (
	ageMeterName                    = "serviceradar.age_graph"
	metricAgeWritesSuccessName      = "age_graph_writes_success_total"
	metricAgeWritesFailureName      = "age_graph_writes_failure_total"
	metricAgeQueueDepthName         = "age_graph_queue_depth"
	metricAgeQueueCapName           = "age_graph_queue_capacity"
	metricAgeDroppedBackpressure    = "age_graph_dropped_backpressure_total"
	metricAgeDroppedMemoryPressure  = "age_graph_dropped_memory_pressure_total"
	metricAgeDroppedCircuitOpen     = "age_graph_dropped_circuit_open_total"
	metricAgeHeapAllocBytes         = "age_graph_heap_alloc_bytes"
	metricAgeHeapInuseBytes         = "age_graph_heap_inuse_bytes"
	metricAgeCircuitState           = "age_graph_circuit_state"
)

type ageGraphMetrics struct {
	success               atomic.Uint64
	failure               atomic.Uint64
	droppedBackpressure   atomic.Uint64
	droppedMemoryPressure atomic.Uint64
	droppedCircuitOpen    atomic.Uint64
}

//nolint:gochecknoglobals,unused // metrics are process-wide; keep registration to prevent GC
var (
	ageMetricsOnce sync.Once
	ageMetrics     = &ageGraphMetrics{}
	ageQueueDepth  atomic.Int64
	ageQueueCap    atomic.Int64
	ageCircuitState atomic.Int64 // 0=closed, 1=open, 2=half-open
	ageGauges      struct {
		success               metric.Int64ObservableGauge
		failure               metric.Int64ObservableGauge
		queueDepth            metric.Int64ObservableGauge
		queueCapacity         metric.Int64ObservableGauge
		droppedBackpressure   metric.Int64ObservableGauge
		droppedMemoryPressure metric.Int64ObservableGauge
		droppedCircuitOpen    metric.Int64ObservableGauge
		heapAllocBytes        metric.Int64ObservableGauge
		heapInuseBytes        metric.Int64ObservableGauge
		circuitState          metric.Int64ObservableGauge
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
	ageGauges.droppedBackpressure, err = meter.Int64ObservableGauge(
		metricAgeDroppedBackpressure,
		metric.WithDescription("Total batches dropped due to queue backpressure"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	ageGauges.droppedMemoryPressure, err = meter.Int64ObservableGauge(
		metricAgeDroppedMemoryPressure,
		metric.WithDescription("Total batches dropped due to memory pressure"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	ageGauges.droppedCircuitOpen, err = meter.Int64ObservableGauge(
		metricAgeDroppedCircuitOpen,
		metric.WithDescription("Total batches dropped due to circuit breaker open"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	ageGauges.heapAllocBytes, err = meter.Int64ObservableGauge(
		metricAgeHeapAllocBytes,
		metric.WithDescription("Go heap allocation in bytes"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	ageGauges.heapInuseBytes, err = meter.Int64ObservableGauge(
		metricAgeHeapInuseBytes,
		metric.WithDescription("Go heap in-use bytes"),
	)
	if err != nil {
		otel.Handle(err)
		return
	}
	ageGauges.circuitState, err = meter.Int64ObservableGauge(
		metricAgeCircuitState,
		metric.WithDescription("Circuit breaker state: 0=closed, 1=open, 2=half-open"),
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
		observer.ObserveInt64(ageGauges.droppedBackpressure, int64(ageMetrics.droppedBackpressure.Load()))
		observer.ObserveInt64(ageGauges.droppedMemoryPressure, int64(ageMetrics.droppedMemoryPressure.Load()))
		observer.ObserveInt64(ageGauges.droppedCircuitOpen, int64(ageMetrics.droppedCircuitOpen.Load()))
		observer.ObserveInt64(ageGauges.circuitState, ageCircuitState.Load())

		// Read Go runtime memory stats
		var memStats runtime.MemStats
		runtime.ReadMemStats(&memStats)
		observer.ObserveInt64(ageGauges.heapAllocBytes, int64(memStats.HeapAlloc))
		observer.ObserveInt64(ageGauges.heapInuseBytes, int64(memStats.HeapInuse))

		return nil
	},
		ageGauges.success,
		ageGauges.failure,
		ageGauges.queueDepth,
		ageGauges.queueCapacity,
		ageGauges.droppedBackpressure,
		ageGauges.droppedMemoryPressure,
		ageGauges.droppedCircuitOpen,
		ageGauges.heapAllocBytes,
		ageGauges.heapInuseBytes,
		ageGauges.circuitState,
	)
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

func recordAgeDroppedBackpressure() {
	ageMetricsOnce.Do(initAgeMetrics)
	ageMetrics.droppedBackpressure.Add(1)
}

func recordAgeDroppedMemoryPressure() {
	ageMetricsOnce.Do(initAgeMetrics)
	ageMetrics.droppedMemoryPressure.Add(1)
}

func recordAgeDroppedCircuitOpen() {
	ageMetricsOnce.Do(initAgeMetrics)
	ageMetrics.droppedCircuitOpen.Add(1)
}

func setAgeCircuitState(state int64) {
	ageMetricsOnce.Do(initAgeMetrics)
	ageCircuitState.Store(state)
}

func currentAgeCircuitState() int64 {
	return ageCircuitState.Load()
}

// currentHeapAllocBytes returns the current Go heap allocation in bytes.
func currentHeapAllocBytes() uint64 {
	var memStats runtime.MemStats
	runtime.ReadMemStats(&memStats)
	return memStats.HeapAlloc
}
