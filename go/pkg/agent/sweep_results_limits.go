package agent

import (
	"os"
	"strconv"
)

const (
	defaultSweepResultsMaxChunkBytes = 1024 * 1024
	defaultSweepResultsMaxHosts      = 1000
	minSweepResultsMaxChunkBytes     = 64 * 1024
	minSweepResultsMaxHosts          = 100

	// defaultSweepMetricBatchMaxBytes bounds the encoded size of each sweep
	// MetricBatch the agent emits, so no single batch approaches the NATS
	// server max_payload (1 MiB by default). The gateway still splits anything
	// that slips through; this bound keeps the common path in one message.
	defaultSweepMetricBatchMaxBytes = 768 * 1024
	minSweepMetricBatchMaxBytes     = 64 * 1024
)

func sweepResultsChunkLimits() (int, int) {
	maxBytes := envInt("SWEEP_RESULTS_MAX_CHUNK_BYTES", defaultSweepResultsMaxChunkBytes)
	maxHosts := envInt("SWEEP_RESULTS_MAX_HOSTS_PER_CHUNK", defaultSweepResultsMaxHosts)

	if maxBytes < minSweepResultsMaxChunkBytes {
		maxBytes = minSweepResultsMaxChunkBytes
	}

	if maxHosts < minSweepResultsMaxHosts {
		maxHosts = minSweepResultsMaxHosts
	}

	return maxBytes, maxHosts
}

func sweepMetricBatchMaxBytes() int {
	maxBytes := envInt("SWEEP_METRICS_MAX_BATCH_BYTES", defaultSweepMetricBatchMaxBytes)

	if maxBytes < minSweepMetricBatchMaxBytes {
		maxBytes = minSweepMetricBatchMaxBytes
	}

	return maxBytes
}

func envInt(key string, fallback int) int {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback
	}

	value, err := strconv.Atoi(raw)
	if err != nil || value <= 0 {
		return fallback
	}

	return value
}
