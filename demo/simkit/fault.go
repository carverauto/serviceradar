package simkit

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

// FaultSpec declares one recurring fault in a scenario pack. Each period
// (a "cycle") holds at most one instance: it starts at the cycle start plus the
// phase plus a seeded jitter, lasts Duration, and lands on one target chosen
// from Targets for that cycle, so faults rotate over the fleet.
type FaultSpec struct {
	Kind      string    `json:"kind"`
	Title     string    `json:"title"`
	Severity  string    `json:"severity"`
	Targets   []string  `json:"targets"`
	PeriodS   int64     `json:"period_s"`
	PhaseS    int64     `json:"phase_s"`
	DurationS int64     `json:"duration_s"`
	JitterS   int64     `json:"jitter_s"`
	Overlays  []Overlay `json:"overlays"`
}

// Schedule evaluates a pack's faults. Assets is the universe that target
// selectors resolve against.
type Schedule struct {
	Seed    uint64      `json:"seed"`
	Enabled bool        `json:"enabled"`
	Faults  []FaultSpec `json:"faults"`
	Assets  []string    `json:"-"`
}

// Fault is one concrete fault instance, scheduled or injected.
type Fault struct {
	ID       string
	Kind     string
	Title    string
	Severity string
	Target   string
	Start    time.Time
	End      time.Time
	Injected bool
	Overlays []Overlay
}

// Active reports whether the fault covers t, i.e. t is in [Start, End).
func (f Fault) Active(t time.Time) bool {
	return !t.Before(f.Start) && t.Before(f.End)
}

// Override is a presenter-injected fault delivered to a run by the platform.
// It stays delivered after End until a run that received it succeeds, so the
// run that sees it expired emits the resolving transition.
type Override struct {
	ID     string    `json:"id"`
	Kind   string    `json:"kind"`
	Target string    `json:"target"`
	Start  time.Time `json:"start"`
	End    time.Time `json:"end"`
}

// Transition is a fault opening or resolving at a point in time.
type Transition struct {
	Fault   Fault
	Opening bool
	At      time.Time
}

// ErrOverlap is returned when an injection would overlap another fault of the
// same kind on the same target.
var ErrOverlap = errors.New("simkit: fault window overlaps an existing fault of the same kind on the target")

// Validate checks that the schedule can keep its guarantees: positive
// periods and durations, Duration+Jitter within the period (so instances of
// one kind never overlap), unique kinds and selectors that match assets.
func (s *Schedule) Validate() error {
	seen := map[string]bool{}
	for i, f := range s.Faults {
		switch {
		case f.Kind == "":
			return fmt.Errorf("fault %d: kind is required", i)
		case seen[f.Kind]:
			return fmt.Errorf("fault %q: kind declared twice", f.Kind)
		case f.PeriodS <= 0 || f.DurationS <= 0:
			return fmt.Errorf("fault %q: period and duration must be positive", f.Kind)
		case f.JitterS < 0:
			return fmt.Errorf("fault %q: jitter must not be negative", f.Kind)
		case f.DurationS+f.JitterS > f.PeriodS:
			return fmt.Errorf("fault %q: duration+jitter exceeds period", f.Kind)
		case len(s.resolve(f.Targets)) == 0:
			return fmt.Errorf("fault %q: targets match no asset", f.Kind)
		}
		seen[f.Kind] = true
	}
	return nil
}

// resolve expands selectors: an exact asset id, or a prefix ending in "*".
func (s *Schedule) resolve(selectors []string) []string {
	var out []string
	for _, a := range s.Assets {
		for _, sel := range selectors {
			if sel == a || (strings.HasSuffix(sel, "*") && strings.HasPrefix(a, strings.TrimSuffix(sel, "*"))) {
				out = append(out, a)
				break
			}
		}
	}
	return out
}

func (s *Schedule) spec(kind string) (FaultSpec, bool) {
	for _, f := range s.Faults {
		if f.Kind == kind {
			return f, true
		}
	}
	return FaultSpec{}, false
}

// instance returns the fault for a spec in a given cycle.
func (s *Schedule) instance(f FaultSpec, cycle int64) (Fault, bool) {
	targets := s.resolve(f.Targets)
	if len(targets) == 0 {
		return Fault{}, false
	}
	cyc := Itoa(cycle)
	jitter := int64(0)
	if f.JitterS > 0 {
		jitter = int64(Hash(s.Seed, "fault-jitter", f.Kind, cyc) % uint64(f.JitterS+1))
	}
	startS := cycle*f.PeriodS + f.PhaseS + jitter
	target := targets[Hash(s.Seed, "fault-target", f.Kind, cyc)%uint64(len(targets))]
	start := time.Unix(startS, 0).UTC()
	return Fault{
		ID:       f.Kind + "@" + target + "#" + cyc,
		Kind:     f.Kind,
		Title:    f.Title,
		Severity: f.Severity,
		Target:   target,
		Start:    start,
		End:      start.Add(time.Duration(f.DurationS) * time.Second),
		Overlays: f.Overlays,
	}, true
}

func (f FaultSpec) cycleOf(t time.Time) int64 {
	return floorDiv(t.Unix()-f.PhaseS, f.PeriodS)
}

// ScheduledAt returns the scheduled faults active at t.
func (s *Schedule) ScheduledAt(t time.Time) []Fault {
	if !s.Enabled {
		return nil
	}
	var out []Fault
	for _, f := range s.Faults {
		if inst, ok := s.instance(f, f.cycleOf(t)); ok && inst.Active(t) {
			out = append(out, inst)
		}
	}
	return out
}

// ActiveAt returns scheduled faults plus any unexpired overrides active at t.
func (s *Schedule) ActiveAt(t time.Time, overrides []Override) []Fault {
	out := s.ScheduledAt(t)
	for _, o := range overrides {
		if f, ok := s.fromOverride(o); ok && f.Active(t) {
			out = append(out, f)
		}
	}
	sortFaults(out)
	return out
}

func (s *Schedule) fromOverride(o Override) (Fault, bool) {
	spec, ok := s.spec(o.Kind)
	if !ok {
		return Fault{}, false
	}
	return Fault{
		ID:       o.ID,
		Kind:     o.Kind,
		Title:    spec.Title,
		Severity: spec.Severity,
		Target:   o.Target,
		Start:    o.Start,
		End:      o.End,
		Injected: true,
		Overlays: spec.Overlays,
	}, true
}

// NextStart returns the earliest scheduled fault starting after t.
func (s *Schedule) NextStart(t time.Time) (Fault, bool) {
	if !s.Enabled {
		return Fault{}, false
	}
	var best Fault
	found := false
	for _, f := range s.Faults {
		c := f.cycleOf(t)
		for _, cycle := range []int64{c, c + 1} {
			inst, ok := s.instance(f, cycle)
			if ok && inst.Start.After(t) && (!found || inst.Start.Before(best.Start)) {
				best, found = inst, true
			}
		}
	}
	return best, found
}

// Transitions returns the scheduled openings and resolvings inside the
// window, plus the resolving transition of every override that has expired by
// the end of the window. Override openings are emitted by the injection
// action, not by runs. Resolving transitions carry the override id, so a
// repeat after a failed run is recognisable as the same event.
func (s *Schedule) Transitions(w Window, overrides []Override) []Transition {
	var out []Transition
	if s.Enabled {
		for _, f := range s.Faults {
			first := f.cycleOf(w.Start) - 1
			last := f.cycleOf(w.End)
			for cycle := first; cycle <= last; cycle++ {
				inst, ok := s.instance(f, cycle)
				if !ok {
					continue
				}
				if w.Contains(inst.Start) {
					out = append(out, Transition{Fault: inst, Opening: true, At: inst.Start})
				}
				if w.Contains(inst.End) {
					out = append(out, Transition{Fault: inst, Opening: false, At: inst.End})
				}
			}
		}
	}
	for _, o := range overrides {
		if f, ok := s.fromOverride(o); ok && !o.End.After(w.End) {
			out = append(out, Transition{Fault: f, Opening: false, At: o.End})
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if !out[i].At.Equal(out[j].At) {
			return out[i].At.Before(out[j].At)
		}
		return out[i].Fault.ID < out[j].Fault.ID
	})
	return out
}

// CheckInjection rejects an injected fault whose window overlaps any
// scheduled window or active override of the same kind on the same target.
// Scheduled faults are never suppressed; injections yield to them.
func (s *Schedule) CheckInjection(kind, target string, start, end time.Time, overrides []Override) error {
	spec, ok := s.spec(kind)
	if !ok {
		return fmt.Errorf("simkit: unknown fault kind %q", kind)
	}
	if !end.After(start) {
		return errors.New("simkit: injection must end after it starts")
	}
	for _, o := range overrides {
		if o.Kind == kind && o.Target == target && o.Start.Before(end) && start.Before(o.End) {
			return ErrOverlap
		}
	}
	if !s.Enabled {
		return nil
	}
	for cycle := spec.cycleOf(start) - 1; cycle <= spec.cycleOf(end); cycle++ {
		inst, ok := s.instance(spec, cycle)
		if ok && inst.Target == target && inst.Start.Before(end) && start.Before(inst.End) {
			return ErrOverlap
		}
	}
	return nil
}

func sortFaults(fs []Fault) {
	sort.SliceStable(fs, func(i, j int) bool { return fs[i].ID < fs[j].ID })
}
