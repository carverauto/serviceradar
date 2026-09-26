// Package sample is the smallest complete simkit pack: three environmental
// sensors with a temperature gauge, a packet counter and one recurring
// overheat fault. It exists to prove the pattern every demo follows -- a
// simulated Source, a shared Normalizer, the source contract test and
// simulator-generated dashboard fixtures -- and as a template for real packs.
package sample

import (
	"time"

	"github.com/carverauto/serviceradar/demo/simkit"
)

// Pack is the scenario configuration a plugin assignment would carry.
type Pack struct {
	Seed        uint64          `json:"seed"`
	Sensors     int             `json:"sensors"`
	Prefix      string          `json:"prefix"`
	SampleStepS int64           `json:"sample_step_s"`
	InventoryS  int64           `json:"inventory_cadence_s"`
	Schedule    simkit.Schedule `json:"schedule"`
}

// PackEpoch is when the simulated fleet was "installed"; counters start here.
var PackEpoch = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

// DefaultPack returns the sample scenario.
func DefaultPack() Pack {
	return Pack{
		Seed:        20260926,
		Sensors:     3,
		Prefix:      "10.40.0.0/24",
		SampleStepS: 10,
		InventoryS:  900,
		Schedule: simkit.Schedule{
			Seed:    20260926,
			Enabled: true,
			Faults: []simkit.FaultSpec{{
				Kind:      "overheat",
				Title:     "Sensor over temperature",
				Severity:  "high",
				Targets:   []string{"sensor-*"},
				PeriodS:   480,
				DurationS: 180,
				JitterS:   60,
				Overlays:  []simkit.Overlay{{Metric: "temp_c", Mode: "add", Value: 18, RampS: 45}},
			}},
		},
	}
}

// Sim is the simulated Source for the pack.
type Sim struct {
	pack     Pack
	minter   simkit.Minter
	assets   []string
	schedule simkit.Schedule
	temp     simkit.Wave
	packets  simkit.Counter
}

// New builds the simulator and validates its schedule.
func New(p Pack) (*Sim, error) {
	s := &Sim{
		pack:    p,
		minter:  simkit.Minter{Seed: p.Seed, Namespace: "sample"},
		temp:    simkit.Wave{Mean: 24, Amplitude: 3, PeriodS: 86400, Noise: 0.8, NoiseStep: 120},
		packets: simkit.Counter{Base: 40, Swing: 0.5, PeriodS: 3600, Epoch: PackEpoch},
	}
	for i := 1; i <= p.Sensors; i++ {
		s.assets = append(s.assets, s.minter.AssetID("sensor", i))
	}
	s.schedule = p.Schedule
	s.schedule.Assets = s.assets
	if err := s.schedule.Validate(); err != nil {
		return nil, err
	}
	return s, nil
}

// Schedule exposes the resolved fault schedule.
func (s *Sim) Schedule() *simkit.Schedule { return &s.schedule }

// Observe returns device-native readings: one per sensor per grid instant,
// shaped like what a real sensor gateway reports.
func (s *Sim) Observe(ctx simkit.ObserveContext) ([]simkit.Observation, error) {
	var out []simkit.Observation
	for _, ts := range ctx.Window().Grid(time.Duration(s.pack.SampleStepS) * time.Second) {
		active := s.schedule.ActiveAt(ts, ctx.Overrides)
		for _, id := range s.assets {
			temp := simkit.ApplyOverlays(id, "temp_c", s.temp.At(s.pack.Seed, id, ts), ts, active)
			out = append(out, simkit.Observation{
				AssetID: id,
				Kind:    "env_sensor",
				Time:    ts,
				Fields: map[string]float64{
					"temp_c":     round1(temp),
					"rx_packets": s.packets.At(ts) + float64(simkit.Hash(s.pack.Seed, "pkt-offset", id)%10000),
				},
			})
		}
	}
	return out, nil
}

// Normalizer maps sensor readings, inventory and fault transitions onto
// product contracts. A real sensor gateway source would reuse it unchanged.
type Normalizer struct{ Sim *Sim }

// Normalize implements simkit.Normalizer.
func (n Normalizer) Normalize(ctx simkit.ObserveContext, obs []simkit.Observation) (simkit.Batch, error) {
	var b simkit.Batch
	w := ctx.Window()
	if simkit.CadenceDue(w, time.Duration(n.Sim.pack.InventoryS)*time.Second, 0) {
		b.Devices = n.Sim.inventory()
	}
	for _, o := range obs {
		for _, name := range []string{"temp_c", "rx_packets"} {
			if v, ok := o.Fields[name]; ok {
				b.Metrics = append(b.Metrics, simkit.Metric{Name: name, AssetID: o.AssetID, Value: v, Time: o.Time})
			}
		}
	}
	b.Metrics = append(b.Metrics, n.Sim.schedule.StatusMetrics(ctx.Now, ctx.Overrides)...)
	for _, tr := range n.Sim.schedule.Transitions(w, ctx.Overrides) {
		b.Events = append(b.Events, simkit.TransitionEvent(tr))
	}
	return b, nil
}

func (s *Sim) inventory() []simkit.Device {
	out := make([]simkit.Device, 0, len(s.assets))
	for i, id := range s.assets {
		ip, _ := simkit.IPv4(s.pack.Prefix, uint32(10+i))
		lat := 41.0 + 0.01*float64(i)
		lon := -93.0 - 0.01*float64(i)
		out = append(out, simkit.Device{
			AssetID:  id,
			Kind:     "env_sensor",
			Name:     "Sensor " + id,
			Hostname: id + ".sample.test",
			IP:       ip,
			MAC:      s.minter.MAC("sensor", i+1, [3]byte{}),
			Serial:   s.minter.Serial("sensor", i+1),
			Model:    "ENV-100",
			Site:     "sample-site",
			Lat:      &lat,
			Lon:      &lon,
		})
	}
	return out
}

func round1(v float64) float64 {
	if v < 0 {
		return float64(int64(v*10-0.5)) / 10
	}
	return float64(int64(v*10+0.5)) / 10
}
