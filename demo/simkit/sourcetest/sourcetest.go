// Package sourcetest is the contract every demo plugin's Source and
// Normalizer must pass. A real source written for a customer deployment runs
// the same checks, which is what makes the simulator replaceable.
package sourcetest

import (
	"reflect"
	"sort"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/demo/simkit"
	"github.com/carverauto/serviceradar/demo/simkit/guard"
)

// Config names the source under test.
type Config struct {
	Source     simkit.Source
	Normalizer simkit.Normalizer
	// Now is the first run instant; Runs consecutive runs are made from it.
	Now      time.Time
	Interval time.Duration
	Runs     int
	// Simulated sources must be deterministic; real sources set this false.
	Deterministic bool
}

// Run executes the contract.
func Run(t *testing.T, cfg Config) {
	t.Helper()
	if cfg.Interval <= 0 {
		cfg.Interval = time.Minute
	}
	if cfg.Runs <= 0 {
		cfg.Runs = 30
	}

	var batches []simkit.Batch
	for i := 0; i < cfg.Runs; i++ {
		ctx := simkit.ObserveContext{Now: cfg.Now.Add(time.Duration(i) * cfg.Interval), Interval: cfg.Interval}
		obs, err := cfg.Source.Observe(ctx)
		if err != nil {
			t.Fatalf("run %d: Observe: %v", i, err)
		}
		w := ctx.Window()
		for _, o := range obs {
			if o.AssetID == "" {
				t.Fatalf("run %d: observation without asset id: %+v", i, o)
			}
			if !w.Contains(o.Time) {
				t.Fatalf("run %d: observation at %v outside run window (%v, %v]", i, o.Time, w.Start, w.End)
			}
		}
		b, err := cfg.Normalizer.Normalize(ctx, obs)
		if err != nil {
			t.Fatalf("run %d: Normalize: %v", i, err)
		}
		checkBatch(t, i, w, b)
		batches = append(batches, b)

		if cfg.Deterministic {
			again, err := simkit.Collect(cfg.Source, cfg.Normalizer, ctx)
			if err != nil {
				t.Fatalf("run %d: repeat Collect: %v", i, err)
			}
			if !reflect.DeepEqual(b, again) {
				t.Fatalf("run %d: repeated run produced different records", i)
			}
		}
	}

	checkStableInventory(t, batches)
	checkEventPairs(t, batches)
}

func checkBatch(t *testing.T, run int, w simkit.Window, b simkit.Batch) {
	t.Helper()
	for _, m := range b.Metrics {
		if m.Name == "" {
			t.Fatalf("run %d: metric without name", run)
		}
		if !w.Contains(m.Time) {
			t.Fatalf("run %d: metric %s at %v outside run window", run, m.Name, m.Time)
		}
	}
	for _, e := range b.Events {
		if e.ID == "" || e.AssetID == "" || e.Kind == "" {
			t.Fatalf("run %d: incomplete event %+v", run, e)
		}
	}
	vs, err := guard.Check(b)
	if err != nil {
		t.Fatalf("run %d: guard: %v", run, err)
	}
	for _, v := range vs {
		t.Errorf("run %d: %s", run, v)
	}
}

// Every inventory emission must describe the same fleet, so identities are
// stable across runs.
func checkStableInventory(t *testing.T, batches []simkit.Batch) {
	t.Helper()
	var first []string
	for i, b := range batches {
		if len(b.Devices) == 0 {
			continue
		}
		ids := make([]string, 0, len(b.Devices))
		for _, d := range b.Devices {
			ids = append(ids, d.AssetID+"|"+d.Serial)
		}
		sort.Strings(ids)
		if first == nil {
			first = ids
			continue
		}
		if !reflect.DeepEqual(first, ids) {
			t.Fatalf("run %d: inventory identities changed", i)
		}
	}
	if first == nil {
		t.Fatalf("no run emitted inventory; widen Runs or Interval to span the inventory cadence")
	}
}

// Across consecutive runs no transition event may be emitted twice: windows
// tile time, so each opening and resolving belongs to exactly one run.
func checkEventPairs(t *testing.T, batches []simkit.Batch) {
	t.Helper()
	seen := map[string]bool{}
	for _, b := range batches {
		for _, e := range b.Events {
			if e.FaultID == "" {
				continue
			}
			if seen[e.ID] {
				t.Fatalf("event %s emitted twice", e.ID)
			}
			seen[e.ID] = true
		}
	}
}
