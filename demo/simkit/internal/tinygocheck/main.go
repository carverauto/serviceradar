// Command tinygocheck exists only to prove that simkit compiles for wasip1
// with the same TinyGo toolchain and flags demo plugins use. It exercises the
// library's surface so the compiler type-checks and links all of it.
package main

import (
	"time"

	"github.com/carverauto/serviceradar/demo/simkit"
)

func main() {
	now := time.Now().UTC()
	s := simkit.Schedule{
		Seed:    1,
		Enabled: true,
		Assets:  []string{"a-0001"},
		Faults: []simkit.FaultSpec{{
			Kind: "k", Targets: []string{"a-*"}, PeriodS: 600, DurationS: 60,
			Overlays: []simkit.Overlay{{Metric: "m", Mode: "add", Value: 1}},
		}},
	}
	if err := s.Validate(); err != nil {
		panic(err)
	}
	ctx := simkit.ObserveContext{Now: now, Interval: time.Minute}
	w := ctx.Window()
	var b simkit.Batch
	for _, ts := range w.Grid(10 * time.Second) {
		active := s.ActiveAt(ts, ctx.Overrides)
		v := simkit.Wave{Mean: 1, Amplitude: 1, PeriodS: 60, Noise: 1}.At(1, "a-0001", ts)
		v = simkit.ApplyOverlays("a-0001", "m", v, ts, active)
		c := simkit.Counter{Base: 1, Swing: 0.5, PeriodS: 60}.At(ts)
		b.Metrics = append(b.Metrics, simkit.Metric{Name: "m", AssetID: "a-0001", Value: v + c, Time: ts})
	}
	for _, tr := range s.Transitions(w, nil) {
		b.Events = append(b.Events, simkit.TransitionEvent(tr))
	}
	b.Metrics = append(b.Metrics, s.StatusMetrics(now, nil)...)
	if simkit.CadenceDue(w, 15*time.Minute, 0) {
		ip, _ := simkit.IPv4("10.0.0.0/24", 1)
		m := simkit.Minter{Seed: 1}
		b.Devices = append(b.Devices, simkit.Device{AssetID: m.AssetID("a", 1), IP: ip, MAC: m.MAC("a", 1, [3]byte{}), Serial: m.Serial("a", 1)})
	}
	_ = s.CheckInjection("k", "a-0001", now, now.Add(time.Minute), nil)
	_ = b.MetricChunks(simkit.MaxTelemetryBatch)
	println(len(b.Metrics), len(b.Events), len(b.Devices))
}
