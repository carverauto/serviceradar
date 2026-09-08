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
