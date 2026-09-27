package simkit

import "time"

// ObserveContext is what a run knows: the current time, its interval, and any
// active or just-expired overrides the platform delivered.
type ObserveContext struct {
	Now       time.Time
	Interval  time.Duration
	Overrides []Override
}

// Window returns the run window for the context.
func (c ObserveContext) Window() Window { return RunWindow(c.Now, c.Interval) }

// Observation is one device-native reading: register values, controller API
// fields, telemetry frames. A simulated source and a real one produce the same
// observations for the same kind of device.
type Observation struct {
	AssetID string             `json:"asset_id"`
	Kind    string             `json:"kind"`
	Time    time.Time          `json:"time"`
	Fields  map[string]float64 `json:"fields,omitempty"`
	Attrs   map[string]string  `json:"attrs,omitempty"`
}

// Source produces observations for a run. The simulator is one Source; a
// customer deployment supplies a real one that talks to devices through the
// host proxy.
type Source interface {
	Observe(ctx ObserveContext) ([]Observation, error)
}

// Normalizer maps observations to product contracts. It is shared by
// simulated and real sources, which is what makes the source swappable.
type Normalizer interface {
	Normalize(ctx ObserveContext, obs []Observation) (Batch, error)
}

// Collect runs a source and normalizer for one context.
func Collect(src Source, n Normalizer, ctx ObserveContext) (Batch, error) {
	obs, err := src.Observe(ctx)
	if err != nil {
		return Batch{}, err
	}
	return n.Normalize(ctx, obs)
}
