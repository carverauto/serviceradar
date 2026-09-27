// hello-sim is the smallest demo plugin: simkit's sample pack (three
// environmental sensors, steady metrics and one recurring overheat fault)
// behind the standard Source/Normalizer boundary, emitted through pluginkit.
// It proves the demo build, bundle, sign and publish path end to end.
package main

import (
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"github.com/carverauto/serviceradar/demo/pluginkit"
	"github.com/carverauto/serviceradar/demo/simkit"
	"github.com/carverauto/serviceradar/demo/simkit/examples/sample"
)

// PluginID matches plugin.yaml.
const PluginID = "demo-hello-sim"

// Config is the assignment's params.
type Config struct {
	// Pack overrides the sample scenario; omitted fields keep their defaults.
	Pack *sample.Pack `json:"pack,omitempty"`
	// IntervalSeconds is the assignment interval; each run backfills samples
	// for the window since the previous run.
	IntervalSeconds int `json:"interval_seconds,omitempty"`
}

func (c Config) pack() sample.Pack {
	if c.Pack == nil {
		return sample.DefaultPack()
	}
	return *c.Pack
}

func (c Config) interval() time.Duration {
	if c.IntervalSeconds <= 0 {
		return time.Minute
	}
	return time.Duration(c.IntervalSeconds) * time.Second
}

var metricSpecs = map[string]pluginkit.MetricSpec{
	"temp_c":                 {Type: pluginkit.MetricTypeGauge, Unit: "celsius"},
	"rx_packets":             {Type: pluginkit.MetricTypeCounter, Unit: "packets"},
	simkit.MetricFaultActive: {Type: pluginkit.MetricTypeGauge, Unit: "faults"},
	simkit.MetricFaultNextAt: {Type: pluginkit.MetricTypeGauge, Unit: "unix_s"},
}

// collect runs one plugin run at now without touching the host.
func collect(cfg Config, now time.Time) (simkit.Batch, pluginkit.Output, error) {
	sim, err := sample.New(cfg.pack())
	if err != nil {
		return simkit.Batch{}, pluginkit.Output{}, err
	}
	ips := map[string]string{}
	for _, d := range sim.Inventory() {
		ips[d.AssetID] = d.IP
	}
	ctx := simkit.ObserveContext{Now: now.UTC(), Interval: cfg.interval()}
	batch, err := simkit.Collect(sim, sample.Normalizer{Sim: sim}, ctx)
	if err != nil {
		return simkit.Batch{}, pluginkit.Output{}, err
	}
	out, err := pluginkit.Build(batch, pluginkit.Options{
		Source: PluginID,
		Specs:  metricSpecs,
		ResourceFor: func(asset string) sdk.MetricResource {
			return sdk.MetricResource{TargetDeviceIP: ips[asset]}
		},
	})
	return batch, out, err
}
