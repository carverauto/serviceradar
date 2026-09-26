package simkit

import (
	"strings"
	"testing"
	"time"
)

var t0 = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

func TestHashIsStableAndDelimited(t *testing.T) {
	if Hash(7, "a", "b") != Hash(7, "a", "b") {
		t.Fatal("hash is not deterministic")
	}
	if Hash(7, "ab", "c") == Hash(7, "a", "bc") {
		t.Fatal("parts are not delimited")
	}
	if Hash(7, "a") == Hash(8, "a") {
		t.Fatal("seed does not change the hash")
	}
	for i := 0; i < 1000; i++ {
		if u := Unit(1, Itoa(int64(i))); u < 0 || u >= 1 {
			t.Fatalf("Unit out of range: %v", u)
		}
	}
}

func TestMinterIdentities(t *testing.T) {
	m := Minter{Seed: 42, Namespace: "pack"}
	if got := m.AssetID("ap", 7); got != "ap-0007" {
		t.Fatalf("AssetID = %q", got)
	}
	if m.Serial("ap", 1) != m.Serial("ap", 1) || m.Serial("ap", 1) == m.Serial("ap", 2) {
		t.Fatal("serials must be stable and distinct")
	}
	if len(m.Serial("ap", 1)) != 12 {
		t.Fatalf("serial length = %d", len(m.Serial("ap", 1)))
	}
	local := m.MAC("ap", 1, [3]byte{})
	if !strings.HasPrefix(local, "02:") {
		t.Fatalf("zero OUI must yield a locally administered MAC, got %s", local)
	}
	vendor := m.MAC("ap", 1, [3]byte{0x00, 0x1a, 0x1e})
	if !strings.HasPrefix(vendor, "00:1a:1e:") {
		t.Fatalf("vendor OUI not used: %s", vendor)
	}
}

func TestIPv4(t *testing.T) {
	got, err := IPv4("10.20.0.0/16", 258)
	if err != nil || got != "10.20.1.2" {
		t.Fatalf("IPv4 = %q, %v", got, err)
	}
	if _, err := IPv4("192.0.2.0/24", 255); err == nil {
		t.Fatal("broadcast address must be rejected")
	}
	if _, err := IPv4("192.0.2.0/24", 0); err == nil {
		t.Fatal("network address must be rejected")
	}
}

func TestConsecutiveWindowsTileTheGrid(t *testing.T) {
	interval := 60 * time.Second
	seen := map[int64]int{}
	for i := 1; i <= 30; i++ {
		w := RunWindow(t0.Add(time.Duration(i)*interval+7*time.Second), interval)
		for _, ts := range w.Grid(10 * time.Second) {
			seen[ts.Unix()]++
		}
	}
	for ts, n := range seen {
		if n != 1 {
			t.Fatalf("grid point %d emitted %d times", ts, n)
		}
	}
	if len(seen) != 30*6 {
		t.Fatalf("expected %d grid points, got %d", 30*6, len(seen))
	}
}

func TestCadenceFiresOncePerCadence(t *testing.T) {
	interval := 60 * time.Second
	fired := 0
	for i := 1; i <= 90; i++ {
		if CadenceDue(RunWindow(t0.Add(time.Duration(i)*interval+13*time.Second), interval), 15*time.Minute, 0) {
			fired++
		}
	}
	if fired != 6 {
		t.Fatalf("15m cadence fired %d times in 90m", fired)
	}
}

func TestCounterIsMonotonicAndStateless(t *testing.T) {
	c := Counter{Base: 125, Swing: 0.9, PeriodS: 3600, PhaseS: 17, Epoch: t0}
	prev := c.At(t0)
	for s := 1; s < 3*24*3600; s += 37 {
		v := c.At(t0.Add(time.Duration(s) * time.Second))
		if v < prev {
			t.Fatalf("counter decreased at %ds: %v < %v", s, v, prev)
		}
		prev = v
	}
	at := t0.Add(5 * time.Hour)
	if c.At(at) != c.At(at) {
		t.Fatal("counter is not a pure function of time")
	}
}

func TestWaveIsDeterministic(t *testing.T) {
	w := Wave{Mean: 40, Amplitude: 5, PeriodS: 600, Noise: 1.5, NoiseStep: 30}
	at := t0.Add(1234 * time.Second)
	if w.At(1, "ap-0001", at) != w.At(1, "ap-0001", at) {
		t.Fatal("wave is not deterministic")
	}
	if w.At(1, "ap-0001", at) == w.At(1, "ap-0002", at) {
		t.Fatal("noise should differ per entity")
	}
}

func testSchedule() *Schedule {
	return &Schedule{
		Seed:    99,
		Enabled: true,
		Assets:  []string{"ap-0001", "ap-0002", "ap-0003", "ctl-0001"},
		Faults: []FaultSpec{
			{Kind: "channel_saturation", Title: "Channel saturation", Severity: "high", Targets: []string{"ap-*"},
				PeriodS: 600, DurationS: 240, JitterS: 60,
				Overlays: []Overlay{{Metric: "util_pct", Mode: "set", Value: 95, RampS: 30}}},
			{Kind: "controller_partition", Title: "Controller partition", Severity: "critical", Targets: []string{"ctl-0001"},
				PeriodS: 2700, PhaseS: 300, DurationS: 180},
		},
	}
}

func TestScheduleValidate(t *testing.T) {
	if err := testSchedule().Validate(); err != nil {
		t.Fatal(err)
	}
	bad := testSchedule()
	bad.Faults[0].JitterS = 400
	if bad.Validate() == nil {
		t.Fatal("duration+jitter beyond period must be rejected")
	}
	dup := testSchedule()
	dup.Faults[1].Kind = "channel_saturation"
	if dup.Validate() == nil {
		t.Fatal("duplicate kinds must be rejected")
	}
}

func TestWeekOfScheduleCoverageAndPairing(t *testing.T) {
	s := testSchedule()
	from, to := t0, t0.Add(7*24*time.Hour)
	if gaps := s.CoverageGaps(from, to, 30*time.Second, 10*time.Minute); len(gaps) > 0 {
		t.Fatalf("%d coverage gaps, first at %v (next in %v)", len(gaps), gaps[0].At, gaps[0].NextFrom)
	}

	open := map[string]time.Time{}
	lastEnd := map[string]time.Time{}
	interval := 60 * time.Second
	for now := from.Add(interval); !now.After(to); now = now.Add(interval) {
		for _, tr := range s.Transitions(RunWindow(now, interval), nil) {
			key := tr.Fault.Kind + "|" + tr.Fault.Target
			if tr.Opening {
				if _, dup := open[tr.Fault.ID]; dup {
					t.Fatalf("fault %s opened twice", tr.Fault.ID)
				}
				if tr.At.Before(lastEnd[key]) {
					t.Fatalf("fault %s overlaps the previous %s", tr.Fault.ID, key)
				}
				open[tr.Fault.ID] = tr.At
				continue
			}
			if _, ok := open[tr.Fault.ID]; !ok && tr.At.After(from.Add(time.Hour)) {
				t.Fatalf("fault %s resolved without opening", tr.Fault.ID)
			}
			delete(open, tr.Fault.ID)
			lastEnd[key] = tr.At
		}
	}
	for id, at := range open {
		if at.Before(to.Add(-time.Hour)) {
			t.Fatalf("fault %s opened at %v never resolved", id, at)
		}
	}
}

func TestDisabledScheduleProducesNothing(t *testing.T) {
	s := testSchedule()
	s.Enabled = false
	if len(s.ScheduledAt(t0.Add(time.Hour))) != 0 || len(s.Transitions(RunWindow(t0.Add(time.Hour), time.Hour), nil)) != 0 {
		t.Fatal("disabled schedule must not produce faults")
	}
	if _, ok := s.NextStart(t0); ok {
		t.Fatal("disabled schedule has no next start")
	}
}

func TestOverridesAndInjectionChecks(t *testing.T) {
	s := testSchedule()
	s.Enabled = false
	o := Override{ID: "inj-1", Kind: "channel_saturation", Target: "ap-0002", Start: t0.Add(time.Minute), End: t0.Add(11 * time.Minute)}
	active := s.ActiveAt(t0.Add(5*time.Minute), []Override{o})
	if len(active) != 1 || !active[0].Injected || active[0].Target != "ap-0002" {
		t.Fatalf("override not active: %+v", active)
	}
	if err := s.CheckInjection("channel_saturation", "ap-0002", t0.Add(10*time.Minute), t0.Add(12*time.Minute), []Override{o}); err != ErrOverlap {
		t.Fatalf("overlapping injection accepted: %v", err)
	}
	if err := s.CheckInjection("channel_saturation", "ap-0003", t0.Add(10*time.Minute), t0.Add(12*time.Minute), []Override{o}); err != nil {
		t.Fatalf("injection on another target rejected: %v", err)
	}
	// The run that sees the override expired emits its resolving transition,
	// and repeats of that run emit the same fault id.
	w := RunWindow(t0.Add(12*time.Minute), time.Minute)
	trs := s.Transitions(w, []Override{o})
	if len(trs) != 1 || trs[0].Opening || trs[0].Fault.ID != "inj-1" {
		t.Fatalf("expected one resolving transition for inj-1, got %+v", trs)
	}

	s.Enabled = true
	f, ok := s.NextStart(t0)
	if !ok {
		t.Fatal("no next start")
	}
	if err := s.CheckInjection(f.Kind, f.Target, f.Start.Add(-time.Minute), f.Start.Add(time.Minute), nil); err != ErrOverlap {
		t.Fatalf("injection overlapping a scheduled window accepted: %v", err)
	}
}

func TestOverlaysRampAndStatusMetrics(t *testing.T) {
	s := testSchedule()
	var f Fault
	for m := 0; m < 60*24; m++ {
		if a := s.ScheduledAt(t0.Add(time.Duration(m) * time.Minute)); len(a) > 0 && a[0].Kind == "channel_saturation" {
			f = a[0]
			break
		}
	}
	if f.ID == "" {
		t.Fatal("no channel_saturation fault in a day")
	}
	active := []Fault{f}
	if v := ApplyOverlays(f.Target, "util_pct", 35, f.Start.Add(15*time.Second), active); v != 65 {
		t.Fatalf("half-ramped overlay = %v, want 65", v)
	}
	if v := ApplyOverlays(f.Target, "util_pct", 35, f.Start.Add(time.Minute), active); v != 95 {
		t.Fatalf("full overlay = %v, want 95", v)
	}
	if v := ApplyOverlays("ctl-0001", "util_pct", 35, f.Start.Add(time.Minute), active); v != 35 {
		t.Fatalf("overlay leaked to another asset: %v", v)
	}

	ms := s.StatusMetrics(f.Start.Add(time.Minute), nil)
	if ms[0].Name != MetricFaultActive || ms[0].Value < 1 {
		t.Fatalf("active metric = %+v", ms[0])
	}
	if len(ms) != 2 || ms[1].Name != MetricFaultNextAt {
		t.Fatalf("next_at metric missing: %+v", ms)
	}
}

func TestMetricChunksRespectCap(t *testing.T) {
	b := Batch{Metrics: make([]Metric, 600)}
	chunks := b.MetricChunks(MaxTelemetryBatch)
	if len(chunks) != 3 || len(chunks[2]) != 88 {
		t.Fatalf("chunks = %d, last = %d", len(chunks), len(chunks[len(chunks)-1]))
	}
}
