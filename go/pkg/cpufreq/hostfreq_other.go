//go:build !darwin

package cpufreq

import (
	"context"
	"time"
)

func collectViaHostfreq(context.Context, time.Duration) (*Snapshot, error) {
	return nil, ErrFrequencyUnavailable
}

func StartHostfreqSampler(context.Context) error { return nil }
func StopHostfreqSampler()                       {}
