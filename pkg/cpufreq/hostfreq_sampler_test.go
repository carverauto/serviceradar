//go:build darwin

package cpufreq

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

var errNoMoreSamples = errors.New("no more samples")

func TestBufferedSamplerLatestReturnsMostRecent(t *testing.T) {
	sampler := newBufferedSampler(10*time.Millisecond, 100*time.Millisecond, 20*time.Millisecond, nil)

	original := &Snapshot{
		Cores: []CoreFrequency{
			{CoreID: 0, FrequencyHz: 1},
		},
	}

	sampler.record(original, time.Now())

	// Mutate original to ensure the cached copy is isolated.
	original.Cores[0].FrequencyHz = 999

	got, ok := sampler.latest()
	if !ok {
		t.Fatal("expected latest snapshot to be available")
	}

	if got.Cores[0].FrequencyHz != 1 {
		t.Fatalf("expected cloned snapshot to preserve original value, got %v", got.Cores[0].FrequencyHz)
	}
}

func TestBufferedSamplerLatestStale(t *testing.T) {
	sampler := newBufferedSampler(10*time.Millisecond, 20*time.Millisecond, 10*time.Millisecond, nil)

	sampler.record(&Snapshot{}, time.Now().Add(-time.Minute))

	if _, ok := sampler.latest(); ok {
		t.Fatal("expected stale snapshot to be discarded")
	}
}

func TestBufferedSamplerCollectOnceUsesCollector(t *testing.T) {
	var collected int32
	snapshots := []*Snapshot{
		{Cores: []CoreFrequency{{CoreID: 0, FrequencyHz: 100}}},
		{Cores: []CoreFrequency{{CoreID: 0, FrequencyHz: 200}}},
	}

	sampler := newBufferedSampler(5*time.Millisecond, 100*time.Millisecond, 10*time.Millisecond, func(ctx context.Context) (*Snapshot, error) {
		index := atomic.AddInt32(&collected, 1) - 1
		if int(index) >= len(snapshots) {
			return nil, errNoMoreSamples
		}
		return snapshots[index], nil
	})

	sampler.collectOnce()
	got, ok := sampler.latest()
	if !ok || got.Cores[0].FrequencyHz != 100 {
		t.Fatalf("expected first snapshot frequency 100, got %+v (ok=%v)", got, ok)
	}

	sampler.collectOnce()
	got, ok = sampler.latest()
	if !ok || got.Cores[0].FrequencyHz != 200 {
		t.Fatalf("expected second snapshot frequency 200, got %+v (ok=%v)", got, ok)
	}
}
