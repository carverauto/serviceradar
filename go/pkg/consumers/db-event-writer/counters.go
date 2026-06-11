package dbeventwriter

import "sync/atomic"

// Per-signal pipeline accounting (refactor-otel-signal-correlation, D7):
// received = rows parsed from inbound messages, written = rows inserted into
// CNPG, rejected = malformed messages or rows dropped by id normalization.
// There is no Prometheus plumbing in this consumer, so the counters are
// process-local atomics surfaced through AgentService.GetStatus.

type signalCounters struct {
	received atomic.Int64
	written  atomic.Int64
	rejected atomic.Int64
}

func (c *signalCounters) snapshot() map[string]int64 {
	return map[string]int64{
		"received": c.received.Load(),
		"written":  c.written.Load(),
		"rejected": c.rejected.Load(),
	}
}

//nolint:gochecknoglobals // process-wide pipeline counters; survive processor rebuilds
var (
	traceCounters  signalCounters
	logCounters    signalCounters
	metricCounters signalCounters

	// otelIDRejected counts ids that failed canonical normalization
	// (garbage that is neither raw bytes, hex, double-hex, nor base64).
	otelIDRejected atomic.Int64
)

// signalCountersSnapshot returns the current per-signal pipeline counters
// for inclusion in health/status output.
func signalCountersSnapshot() map[string]interface{} {
	return map[string]interface{}{
		"traces":           traceCounters.snapshot(),
		"logs":             logCounters.snapshot(),
		"metrics":          metricCounters.snapshot(),
		"otel_id_rejected": otelIDRejected.Load(),
	}
}
