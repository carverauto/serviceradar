package simkit

import "time"

// Window is the half-open interval (Start, End] a plugin run is responsible
// for. Consecutive runs with the same interval tile time without overlap, so
// samples, events and cadence ticks are emitted exactly once.
type Window struct {
	Start time.Time
	End   time.Time
}

// RunWindow returns the window a run at now covers for the given interval.
func RunWindow(now time.Time, interval time.Duration) Window {
	return Window{Start: now.Add(-interval), End: now}
}

// Contains reports whether t lies in (Start, End].
func (w Window) Contains(t time.Time) bool {
	return t.After(w.Start) && !t.After(w.End)
}

// Grid returns the instants inside the window that are whole multiples of
// step since the Unix epoch. It is how a run back-fills fine-resolution samples
// for the time since the previous run.
func (w Window) Grid(step time.Duration) []time.Time {
	if step <= 0 || !w.End.After(w.Start) {
		return nil
	}
	s := int64(step)
	first := floorDiv(w.Start.UnixNano(), s)*s + s
	var out []time.Time
	for n := first; n <= w.End.UnixNano(); n += s {
		out = append(out, time.Unix(0, n).UTC())
	}
	return out
}

// CadenceDue reports whether a cadence boundary (a whole multiple of cadence
// since the epoch, shifted by offset) falls inside the window. Plugins use it
// to emit slow-changing records such as inventory on a fixed cadence without
// remembering when they last did.
func CadenceDue(w Window, cadence, offset time.Duration) bool {
	if cadence <= 0 {
		return true
	}
	c := int64(cadence)
	start := w.Start.UnixNano() - int64(offset)
	end := w.End.UnixNano() - int64(offset)
	return floorDiv(end, c) > floorDiv(start, c)
}

func floorDiv(a, b int64) int64 {
	q := a / b
	if (a%b != 0) && ((a < 0) != (b < 0)) {
		q--
	}
	return q
}

func floorMod(a, b int64) int64 {
	return a - floorDiv(a, b)*b
}
