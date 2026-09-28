package simkit

import (
	"math"
	"time"
)

// Wave is a periodic gauge with seeded, smooth noise.
type Wave struct {
	Mean      float64 `json:"mean"`
	Amplitude float64 `json:"amplitude"`
	PeriodS   int64   `json:"period_s"`
	PhaseS    int64   `json:"phase_s"`
	Noise     float64 `json:"noise"`
	NoiseStep int64   `json:"noise_step_s"`
}

// At evaluates the wave for one entity at t.
func (w Wave) At(seed uint64, key string, t time.Time) float64 {
	v := w.Mean
	if w.PeriodS > 0 && w.Amplitude != 0 {
		v += w.Amplitude * math.Sin(2*math.Pi*cyclePos(t, w.PeriodS, w.PhaseS))
	}
	if w.Noise != 0 {
		step := w.NoiseStep
		if step <= 0 {
			step = 60
		}
		v += w.Noise * ValueNoise(seed, key, t, step)
	}
	return v
}

// ValueNoise is smooth noise in [-1, 1]: seeded lattice values every step
// seconds, cosine-interpolated in between.
func ValueNoise(seed uint64, key string, t time.Time, stepS int64) float64 {
	if stepS <= 0 {
		stepS = 1
	}
	ns := t.UnixNano()
	step := stepS * int64(time.Second)
	cell := floorDiv(ns, step)
	frac := float64(ns-cell*step) / float64(step)
	a := Signed(seed, "noise", key, Itoa(cell))
	b := Signed(seed, "noise", key, Itoa(cell+1))
	mix := (1 - math.Cos(frac*math.Pi)) / 2
	return a*(1-mix) + b*mix
}

// cyclePos returns the position of t within a period, in [0, 1), computed with
// integer arithmetic so precision does not decay with the size of Unix time.
func cyclePos(t time.Time, periodS, phaseS int64) float64 {
	p := periodS * int64(time.Second)
	n := floorMod(t.UnixNano()+phaseS*int64(time.Second), p)
	return float64(n) / float64(p)
}
