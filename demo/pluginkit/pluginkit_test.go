package pluginkit

import (
	"testing"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"github.com/carverauto/serviceradar/demo/simkit"
)

func testTime() time.Time { return time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC) }

func f64(v float64) *float64 { return &v }

func TestBuildRequiresSource(t *testing.T) {
	if _, err := Build(simkit.Batch{}, Options{}); err == nil {
		t.Fatal("Build without Source succeeded")
	}
}

func TestDevicesBecomeDeviceDiscovery(t *testing.T) {
	out, err := Build(simkit.Batch{Devices: []simkit.Device{{
		AssetID: "sensor-a", Kind: "env_sensor", Hostname: "sensor-a.sample.test",
		IP: "10.40.0.10", Serial: "SN-1", Model: "ENV-100", Site: "site-1",
		Lat: f64(41.5), Lon: f64(-93.6), Labels: map[string]string{"zone": "north"},
	}}}, Options{Source: "demo-test"})
	if err != nil {
		t.Fatal(err)
	}
	if out.Discovery == nil || out.Discovery.Source != "demo-test" || len(out.Discovery.Devices) != 1 {
		t.Fatalf("discovery = %+v", out.Discovery)
	}
	d := out.Discovery.Devices[0]
	if d.Serial != "SN-1" || d.Type != "env_sensor" || d.Labels[AttrAssetID] != "sensor-a" || d.Labels["zone"] != "north" {
		t.Fatalf("device = %+v", d)
	}
	if d.Location == nil || d.Location.Latitude != 41.5 || d.Location.SiteCode != "site-1" {
		t.Fatalf("location = %+v", d.Location)
	}
	r := sdk.NewResult()
	out.Apply(r)
	if len(r.DeviceDiscovery) != 1 || r.DeviceDiscovery[0].Schema != sdk.DeviceDiscoverySchemaV1 {
		t.Fatalf("result discovery = %+v", r.DeviceDiscovery)
	}
}

func TestNoDevicesNoDiscovery(t *testing.T) {
	out, err := Build(simkit.Batch{}, Options{Source: "demo-test"})
	if err != nil {
		t.Fatal(err)
	}
	if out.Discovery != nil {
		t.Fatalf("empty batch produced discovery %+v", out.Discovery)
	}
}

func TestFaultTransitionsBecomeMatchableEvents(t *testing.T) {
	t0 := testTime()
	open := simkit.Event{ID: "overheat@sensor-a#1/opened", AssetID: "sensor-a", Kind: "overheat",
		Title: "Sensor over temperature", Severity: "high", Opening: true, FaultID: "overheat@sensor-a#1", Time: t0}
	closed := open
	closed.ID, closed.Opening, closed.Time = "overheat@sensor-a#1/resolved", false, t0.Add(3*time.Minute)

	out, err := Build(simkit.Batch{Events: []simkit.Event{open, closed}}, Options{Source: "demo-test"})
	if err != nil {
		t.Fatal(err)
	}
	if len(out.Events) != 2 {
		t.Fatalf("events = %d", len(out.Events))
	}
	o, c := out.Events[0], out.Events[1]
	if o.ID != open.ID || !o.Time.Equal(t0) || o.LogName != DefaultLogName || o.LogProvider != "plugin:demo-test" {
		t.Fatalf("opening event = %+v", o)
	}
	if o.Unmapped[AttrFaultState] != FaultStateOpen || o.Unmapped[AttrAssetID] != "sensor-a" ||
		o.Unmapped[AttrFaultKind] != "overheat" || o.Unmapped[AttrFaultID] != "overheat@sensor-a#1" {
		t.Fatalf("opening attributes = %+v", o.Unmapped)
	}
	if o.SeverityID <= c.SeverityID {
		t.Fatalf("opening severity %d not above resolving severity %d", o.SeverityID, c.SeverityID)
	}
	if c.Unmapped[AttrFaultState] != FaultStateResolved || c.Unmapped[AttrFaultID] != o.Unmapped[AttrFaultID] {
		t.Fatalf("resolving attributes = %+v", c.Unmapped)
	}
	for _, ev := range []sdk.OCSFEvent{o, c} {
		for _, key := range []string{AttrAssetID, AttrFaultState, AttrFaultKind, AttrFaultID} {
			if ev.Metadata[key] != ev.Unmapped[key] {
				t.Fatalf("metadata[%s] = %v, want %v (live event summaries read metadata)", key, ev.Metadata[key], ev.Unmapped[key])
			}
		}
	}
}

func TestMetricsGroupPerSeriesAndChunk(t *testing.T) {
	t0 := testTime()
	var ms []simkit.Metric
	for _, asset := range []string{"a", "b", "c"} {
		for i := 0; i < 3; i++ {
			ms = append(ms,
				simkit.Metric{Name: "temp_c", AssetID: asset, Value: 20 + float64(i), Time: t0.Add(time.Duration(i) * 10 * time.Second)},
				simkit.Metric{Name: "rx_packets", AssetID: asset, Value: 100 + float64(i), Time: t0.Add(time.Duration(i) * 10 * time.Second)},
			)
		}
	}
	ms = append(ms,
		simkit.Metric{Name: simkit.MetricFaultActive, Value: 0, Time: t0},
		simkit.Metric{Name: simkit.MetricFaultActive, Value: 2, Time: t0.Add(time.Minute)},
	)
	var resourceCalls int
	out, err := Build(simkit.Batch{Metrics: ms}, Options{
		Source:     "demo-test",
		MaxRecords: 3,
		Specs:      map[string]MetricSpec{"rx_packets": {Type: MetricTypeCounter, Unit: "packets"}},
		ResourceFor: func(asset string) sdk.MetricResource {
			resourceCalls++
			return sdk.MetricResource{TargetDeviceIP: "10.0.0." + asset}
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	// 3 assets x 2 names + 1 fleet series = 7 records, at most 3 per batch.
	var records int
	for _, b := range out.Telemetry {
		if len(b.Records) > 3 {
			t.Fatalf("batch of %d records exceeds MaxRecords", len(b.Records))
		}
		records += len(b.Records)
		for _, r := range b.Records {
			if r.PayloadKind != sdk.SignalSchemaPayloadKindServiceRadarMetrics || r.Payload == "" {
				t.Fatalf("record = %+v", r)
			}
		}
	}
	if records != 7 || len(out.Telemetry) != 3 {
		t.Fatalf("records=%d batches=%d, want 7 in 3", records, len(out.Telemetry))
	}
	if resourceCalls != 6 {
		t.Fatalf("ResourceFor called %d times, want once per asset series (6)", resourceCalls)
	}
	if out.ActiveFaults != 2 {
		t.Fatalf("ActiveFaults = %d, want the latest value 2", out.ActiveFaults)
	}
	if r := out.Result(simkit.Batch{Metrics: ms}); r.Status != sdk.StatusWarning {
		t.Fatalf("status with active fault = %s", r.Status)
	}
}

func TestMetricRecordIDsAreStable(t *testing.T) {
	t0 := testTime()
	ms := []simkit.Metric{{Name: "temp_c", AssetID: "a", Value: 1, Time: t0}}
	first, _ := Build(simkit.Batch{Metrics: ms}, Options{Source: "demo-test"})
	second, _ := Build(simkit.Batch{Metrics: ms}, Options{Source: "demo-test"})
	if first.Telemetry[0].Records[0].EventID != second.Telemetry[0].Records[0].EventID {
		t.Fatal("same series and time produced different event ids")
	}
	if first.Telemetry[0].Records[0].Payload != second.Telemetry[0].Records[0].Payload {
		t.Fatal("same series and time produced different payload bytes")
	}
	if first.Telemetry[0].Records[0].EventTimeUnixNano != t0.UnixNano() {
		t.Fatal("record event time is not the last sample time")
	}
}

func TestResultOKWithoutActiveFault(t *testing.T) {
	t0 := testTime()
	out, _ := Build(simkit.Batch{Metrics: []simkit.Metric{{Name: simkit.MetricFaultActive, Value: 0, Time: t0}}}, Options{Source: "demo-test"})
	if r := out.Result(simkit.Batch{}); r.Status != sdk.StatusOK {
		t.Fatalf("status = %s", r.Status)
	}
}
