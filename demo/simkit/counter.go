package simkit

import (
	"math"
	"time"
)

// Counter is a monotonic counter whose value is a closed-form integral of a
// periodic rate, r(t) = Base * (1 + Swing*sin(2*pi*(t+phase)/period)). With
// Swing below 1 the rate never goes negative, so the value never decreases,
// and because it is computed from t alone it survives restarts and needs no
// stored state.
type Counter struct {
	Base    float64   `json:"base_per_s"`
	Swing   float64   `json:"swing"`
	PeriodS int64     `json:"period_s"`
	PhaseS  int64     `json:"phase_s"`
	Epoch   time.Time `json:"-"`
	Offset  float64   `json:"offset"`
}

// At returns the counter value at t. Times before Epoch return Offset.
func (c Counter) At(t time.Time) float64 {
	if !t.After(c.Epoch) {
		return c.Offset
	}
	elapsed := t.Sub(c.Epoch).Seconds()
	v := c.Base * elapsed
	swing := c.Swing
	if swing >= 1 {
		swing = 0.999
	}
	if swing > 0 && c.PeriodS > 0 {
		omega := 2 * math.Pi / float64(c.PeriodS)
		now := math.Cos(2 * math.Pi * cyclePos(t, c.PeriodS, c.PhaseS))
		then := math.Cos(2 * math.Pi * cyclePos(c.Epoch, c.PeriodS, c.PhaseS))
		v -= c.Base * swing / omega * (now - then)
	}
	return c.Offset + math.Floor(v)
}
