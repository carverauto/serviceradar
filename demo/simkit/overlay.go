package simkit

import "time"

// Overlay describes how an active fault changes one metric on its target.
// Mode is "set" (replace), "add" (offset) or "scale" (multiply). RampS eases
// the effect in from the fault's start so values do not jump.
type Overlay struct {
	Metric string  `json:"metric"`
	Mode   string  `json:"mode"`
	Value  float64 `json:"value"`
	RampS  int64   `json:"ramp_s"`
}

// ApplyOverlays returns base adjusted by every active fault on the asset that
// carries an overlay for the metric.
func ApplyOverlays(asset, metric string, base float64, t time.Time, active []Fault) float64 {
	v := base
	for _, f := range active {
		if f.Target != asset || !f.Active(t) {
			continue
		}
		for _, o := range f.Overlays {
			if o.Metric != metric {
				continue
			}
			k := 1.0
			if o.RampS > 0 {
				k = t.Sub(f.Start).Seconds() / float64(o.RampS)
				if k > 1 {
					k = 1
				}
			}
			switch o.Mode {
			case "set":
				v = v + (o.Value-v)*k
			case "add":
				v += o.Value * k
			case "scale":
				v *= 1 + (o.Value-1)*k
			}
		}
	}
	return v
}

// FaultActive reports whether any active fault of the kind targets the asset.
func FaultActive(asset, kind string, t time.Time, active []Fault) bool {
	for _, f := range active {
		if f.Target == asset && f.Kind == kind && f.Active(t) {
			return true
		}
	}
	return false
}
