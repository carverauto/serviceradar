//go:build !linux

package cpufreq

import (
	"context"
	"time"
)

func sampleFrequencyWithPerf(context.Context, int, time.Duration) (float64, error) {
	return 0, ErrFrequencyUnavailable
}
