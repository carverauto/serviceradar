package simkit

import "time"

// Gap is an instant at which no fault is active and none begins within the
// required horizon.
type Gap struct {
	At       time.Time
	NextFrom time.Duration // time until the next start, or -1 when none
}

// CoverageGaps samples the schedule every step between from and to and
// returns the instants that break the "an incident is active or starts within
// horizon" guarantee. A pack's tests call it over a simulated week.
func (s *Schedule) CoverageGaps(from, to time.Time, step, horizon time.Duration) []Gap {
	var gaps []Gap
	for t := from; !t.After(to); t = t.Add(step) {
		if len(s.ScheduledAt(t)) > 0 {
			continue
		}
		next, ok := s.NextStart(t)
		switch {
		case !ok:
			gaps = append(gaps, Gap{At: t, NextFrom: -1})
		case next.Start.Sub(t) > horizon:
			gaps = append(gaps, Gap{At: t, NextFrom: next.Start.Sub(t)})
		}
	}
	return gaps
}
