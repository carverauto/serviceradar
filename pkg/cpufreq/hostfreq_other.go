//go:build !darwin

package cpufreq

import (
	"context"
	"time"
)

func collectViaHostfreq(context.Context, time.Duration) (*Snapshot, error) {
	return nil, ErrFrequencyUnavailable
}
