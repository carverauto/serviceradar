package trivysidecar

import (
	"fmt"
	"io"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Metrics tracks operational counters for sidecar behavior.
type Metrics struct {
	publishedTotal      atomic.Int64
	publishFailures     atomic.Int64
	deduplicatedTotal   atomic.Int64
	droppedTotal        atomic.Int64
	watchRestartsTotal  atomic.Int64
	skippedKindsTotal   atomic.Int64
	watchingKindsGauge  atomic.Int64
	lastPublishUnixNano atomic.Int64

	mu              sync.RWMutex
	publishedByKind map[string]int64
	failedByKind    map[string]int64
}

func NewMetrics() *Metrics {
	return &Metrics{
		publishedByKind: make(map[string]int64),
		failedByKind:    make(map[string]int64),
	}
}

func (m *Metrics) IncPublished(kind string) {
	m.publishedTotal.Add(1)
	m.lastPublishUnixNano.Store(time.Now().UTC().UnixNano())

	m.mu.Lock()
	defer m.mu.Unlock()
	m.publishedByKind[kind]++
}

func (m *Metrics) IncPublishFailure(kind string) {
	m.publishFailures.Add(1)
	m.mu.Lock()
	defer m.mu.Unlock()
	m.failedByKind[kind]++
}

func (m *Metrics) IncDeduplicated() {
	m.deduplicatedTotal.Add(1)
}

func (m *Metrics) IncDropped() {
	m.droppedTotal.Add(1)
}

func (m *Metrics) IncWatchRestart() {
	m.watchRestartsTotal.Add(1)
}

func (m *Metrics) AddSkippedKinds(count int) {
	if count <= 0 {
		return
	}
	m.skippedKindsTotal.Add(int64(count))
}

func (m *Metrics) SetWatchingKinds(count int) {
	m.watchingKindsGauge.Store(int64(count))
}

func (m *Metrics) LastPublishTime() time.Time {
	value := m.lastPublishUnixNano.Load()
	if value <= 0 {
		return time.Time{}
	}

	return time.Unix(0, value).UTC()
}

func (m *Metrics) WritePrometheus(w io.Writer, publisherConnected bool) {
	if w == nil {
		return
	}

	connectionValue := 0
	if publisherConnected {
		connectionValue = 1
	}

	_, _ = fmt.Fprintf(w, "# HELP trivy_sidecar_published_total Total messages successfully published.\n")
	_, _ = fmt.Fprintf(w, "# TYPE trivy_sidecar_published_total counter\n")
	_, _ = fmt.Fprintf(w, "trivy_sidecar_published_total %d\n", m.publishedTotal.Load())

	_, _ = fmt.Fprintf(w, "# HELP trivy_sidecar_publish_failures_total Total messages that failed to publish.\n")
	_, _ = fmt.Fprintf(w, "# TYPE trivy_sidecar_publish_failures_total counter\n")
	_, _ = fmt.Fprintf(w, "trivy_sidecar_publish_failures_total %d\n", m.publishFailures.Load())

	_, _ = fmt.Fprintf(w, "# HELP trivy_sidecar_deduplicated_total Total duplicated revisions skipped.\n")
	_, _ = fmt.Fprintf(w, "# TYPE trivy_sidecar_deduplicated_total counter\n")
	_, _ = fmt.Fprintf(w, "trivy_sidecar_deduplicated_total %d\n", m.deduplicatedTotal.Load())

	_, _ = fmt.Fprintf(w, "# HELP trivy_sidecar_dropped_total Total reports dropped due to invalid payload or retry exhaustion.\n")
	_, _ = fmt.Fprintf(w, "# TYPE trivy_sidecar_dropped_total counter\n")
	_, _ = fmt.Fprintf(w, "trivy_sidecar_dropped_total %d\n", m.droppedTotal.Load())

	_, _ = fmt.Fprintf(w, "# HELP trivy_sidecar_watch_restarts_total Total informer watch restarts due to watch errors.\n")
	_, _ = fmt.Fprintf(w, "# TYPE trivy_sidecar_watch_restarts_total counter\n")
	_, _ = fmt.Fprintf(w, "trivy_sidecar_watch_restarts_total %d\n", m.watchRestartsTotal.Load())

	_, _ = fmt.Fprintf(w, "# HELP trivy_sidecar_skipped_kinds_total Total unsupported or unavailable report kinds skipped at startup.\n")
	_, _ = fmt.Fprintf(w, "# TYPE trivy_sidecar_skipped_kinds_total counter\n")
	_, _ = fmt.Fprintf(w, "trivy_sidecar_skipped_kinds_total %d\n", m.skippedKindsTotal.Load())

	_, _ = fmt.Fprintf(w, "# HELP trivy_sidecar_watching_kinds Number of report kinds currently watched.\n")
	_, _ = fmt.Fprintf(w, "# TYPE trivy_sidecar_watching_kinds gauge\n")
	_, _ = fmt.Fprintf(w, "trivy_sidecar_watching_kinds %d\n", m.watchingKindsGauge.Load())

	_, _ = fmt.Fprintf(w, "# HELP trivy_sidecar_nats_connected Whether sidecar currently reports a connected NATS client.\n")
	_, _ = fmt.Fprintf(w, "# TYPE trivy_sidecar_nats_connected gauge\n")
	_, _ = fmt.Fprintf(w, "trivy_sidecar_nats_connected %d\n", connectionValue)

	if lastPublish := m.LastPublishTime(); !lastPublish.IsZero() {
		_, _ = fmt.Fprintf(w, "# HELP trivy_sidecar_last_publish_unix_timestamp Last successful publish as unix seconds.\n")
		_, _ = fmt.Fprintf(w, "# TYPE trivy_sidecar_last_publish_unix_timestamp gauge\n")
		_, _ = fmt.Fprintf(w, "trivy_sidecar_last_publish_unix_timestamp %d\n", lastPublish.Unix())
	}

	m.writeByKind(w)
}

func (m *Metrics) writeByKind(w io.Writer) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	kinds := make([]string, 0, len(m.publishedByKind)+len(m.failedByKind))
	seen := map[string]struct{}{}

	for kind := range m.publishedByKind {
		seen[kind] = struct{}{}
		kinds = append(kinds, kind)
	}
	for kind := range m.failedByKind {
		if _, ok := seen[kind]; ok {
			continue
		}
		kinds = append(kinds, kind)
	}

	sort.Strings(kinds)

	_, _ = fmt.Fprintf(w, "# HELP trivy_sidecar_published_by_kind_total Total messages published per report kind.\n")
	_, _ = fmt.Fprintf(w, "# TYPE trivy_sidecar_published_by_kind_total counter\n")
	for _, kind := range kinds {
		_, _ = fmt.Fprintf(
			w,
			"trivy_sidecar_published_by_kind_total{kind=\"%s\"} %d\n",
			escapePrometheusLabel(kind),
			m.publishedByKind[kind],
		)
	}

	_, _ = fmt.Fprintf(w, "# HELP trivy_sidecar_publish_failures_by_kind_total Total publish failures per report kind.\n")
	_, _ = fmt.Fprintf(w, "# TYPE trivy_sidecar_publish_failures_by_kind_total counter\n")
	for _, kind := range kinds {
		_, _ = fmt.Fprintf(
			w,
			"trivy_sidecar_publish_failures_by_kind_total{kind=\"%s\"} %d\n",
			escapePrometheusLabel(kind),
			m.failedByKind[kind],
		)
	}
}

func escapePrometheusLabel(input string) string {
	replacer := strings.NewReplacer(`\\`, `\\\\`, `"`, `\\"`, "\n", "\\n")
	return replacer.Replace(input)
}
