package k8sinventory

import (
	"fmt"
	"net/http"
	"sync/atomic"
	"time"
)

// Metrics holds simple atomic counters for health/metrics HTTP.
type Metrics struct {
	publishTotal       atomic.Uint64
	publishFailure     atomic.Uint64
	rebuildError       atomic.Uint64
	rebuildSkipped     atomic.Uint64
	endpointCount      atomic.Int64
	hintCount          atomic.Int64
	lastRebuildMs      atomic.Int64
	lastRebuildUnixSec atomic.Int64
}

func NewMetrics() *Metrics { return &Metrics{} }

func (m *Metrics) IncPublish()          { m.publishTotal.Add(1) }
func (m *Metrics) IncPublishFailure()   { m.publishFailure.Add(1) }
func (m *Metrics) IncRebuildError()     { m.rebuildError.Add(1) }
func (m *Metrics) IncRebuildSkipped()   { m.rebuildSkipped.Add(1) }
func (m *Metrics) SetEndpointCount(n int) {
	m.endpointCount.Store(int64(n))
}
func (m *Metrics) SetHintCount(n int) { m.hintCount.Store(int64(n)) }
func (m *Metrics) ObserveRebuild(d time.Duration) {
	m.lastRebuildMs.Store(d.Milliseconds())
	m.lastRebuildUnixSec.Store(time.Now().Unix())
}

// WritePrometheus writes a minimal text exposition format.
func (m *Metrics) WritePrometheus(w http.ResponseWriter) {
	if m == nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	_, _ = fmt.Fprintf(w, "k8s_inventory_publish_total %d\n", m.publishTotal.Load())
	_, _ = fmt.Fprintf(w, "k8s_inventory_publish_failures_total %d\n", m.publishFailure.Load())
	_, _ = fmt.Fprintf(w, "k8s_inventory_rebuild_errors_total %d\n", m.rebuildError.Load())
	_, _ = fmt.Fprintf(w, "k8s_inventory_rebuild_skipped_total %d\n", m.rebuildSkipped.Load())
	_, _ = fmt.Fprintf(w, "k8s_inventory_endpoints %d\n", m.endpointCount.Load())
	_, _ = fmt.Fprintf(w, "k8s_inventory_correlation_hints %d\n", m.hintCount.Load())
	_, _ = fmt.Fprintf(w, "k8s_inventory_last_rebuild_milliseconds %d\n", m.lastRebuildMs.Load())
	_, _ = fmt.Fprintf(w, "k8s_inventory_last_rebuild_unixtime %d\n", m.lastRebuildUnixSec.Load())
}
