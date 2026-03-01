package cpufreq

import (
	"context"
	"testing"
	"time"

	"github.com/shirou/gopsutil/v3/cpu"
)

func withCounts(fn func(context.Context, bool) (int, error)) option {
	return func(d *collectorDeps) {
		d.countsWithContext = fn
	}
}

func withInfo(fn func(context.Context) ([]cpu.InfoStat, error)) option {
	return func(d *collectorDeps) {
		d.infoWithContext = fn
	}
}

func withReadSysfs(fn func(int) (float64, bool)) option {
	return func(d *collectorDeps) {
		d.readSysfs = fn
	}
}

func withSample(fn func(context.Context, int, time.Duration) (float64, error)) option {
	return func(d *collectorDeps) {
		d.sampleFrequency = fn
	}
}

func withHostfreqCollector(fn func(context.Context, time.Duration) (*Snapshot, error)) option {
	return func(d *collectorDeps) {
		d.hostfreqCollector = fn
	}
}

func TestCollectPerfFallback(t *testing.T) {
	t.Parallel()

	snapshot, err := collect(
		context.Background(),
		50*time.Millisecond,
		withCounts(func(context.Context, bool) (int, error) {
			return 2, nil
		}),
		withInfo(func(context.Context) ([]cpu.InfoStat, error) {
			return nil, nil
		}),
		withReadSysfs(func(int) (float64, bool) {
			return 0, false
		}),
		withSample(func(context.Context, int, time.Duration) (float64, error) {
			return 2_400_000_000, nil
		}),
		withHostfreqCollector(func(context.Context, time.Duration) (*Snapshot, error) {
			return nil, ErrFrequencyUnavailable
		}),
	)
	if err != nil {
		t.Fatalf("collect returned error: %v", err)
	}

	if len(snapshot.Cores) != 2 {
		t.Fatalf("expected 2 cores, got %d", len(snapshot.Cores))
	}

	for idx, core := range snapshot.Cores {
		if core.CoreID != idx {
			t.Errorf("core %d has unexpected CoreID %d", idx, core.CoreID)
		}
		if core.FrequencyHz != 2_400_000_000 {
			t.Errorf("expected perf frequency for core %d, got %f", idx, core.FrequencyHz)
		}
		if core.Source != FrequencySourcePerf {
			t.Errorf("expected perf source for core %d, got %s", idx, core.Source)
		}
	}
}

func TestCollectUsesProcFallback(t *testing.T) {
	t.Parallel()

	snapshot, err := collect(
		context.Background(),
		defaultSampleWindow,
		withCounts(func(context.Context, bool) (int, error) {
			return 2, nil
		}),
		withInfo(func(context.Context) ([]cpu.InfoStat, error) {
			return []cpu.InfoStat{
				{CPU: 0, Mhz: 1500},
				{CPU: 1, Mhz: 2000},
			}, nil
		}),
		withReadSysfs(func(int) (float64, bool) {
			return 0, false
		}),
		withHostfreqCollector(func(context.Context, time.Duration) (*Snapshot, error) {
			return nil, ErrFrequencyUnavailable
		}),
	)
	if err != nil {
		t.Fatalf("collect returned error: %v", err)
	}

	if len(snapshot.Cores) != 2 {
		t.Fatalf("expected 2 cores, got %d", len(snapshot.Cores))
	}

	expected := []struct {
		freq   float64
		source string
	}{
		{1_500_000_000, FrequencySourceProcCPU},
		{2_000_000_000, FrequencySourceProcCPU},
	}

	for idx, core := range snapshot.Cores {
		if core.Source != expected[idx].source {
			t.Errorf("core %d expected source %s, got %s", idx, expected[idx].source, core.Source)
		}
		if core.FrequencyHz != expected[idx].freq {
			t.Errorf("core %d expected freq %f, got %f", idx, expected[idx].freq, core.FrequencyHz)
		}
	}
}
