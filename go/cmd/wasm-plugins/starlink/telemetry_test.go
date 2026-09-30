package main

import (
	"net/http"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"github.com/tidwall/gjson"
)

func streamBody(terminalColumns, rows string) string {
	return `{"data":{"columnNamesByDeviceType":{"u":` + terminalColumns + `,` +
		`"r":["DeviceType","UtcTimestampNs","DeviceId","Uptime","PingLatencyMs","Clients"],` +
		`"i":["DeviceType","UtcTimestampNs","DeviceId","AccountNumber","Ipv4"]},` +
		`"values":[` + rows + `]},` +
		`"metadata":{"enums":{"AlertsByDeviceType":{"u":{"53":"actuator_motor_stuck","80":"thermal_shutdown"},"r":{}}}}}`
}

const terminalColumns = `["DeviceType","UtcTimestampNs","DeviceId","DownlinkThroughput","PingLatencyMsAvg","ActiveAlert","RunningSoftwareVersion"]`

func TestDecodeTelemetryStreamMapsByColumnName(t *testing.T) {
	rows := `["u",1700000000000000000,"ut` + testTerminalA + `",42.5,31,[53,80,99],"example-build"],` +
		`["r",1700000000000000000,"` + testRouterA + `",3600,20,7],` +
		`["i",1700000000000000000,"ut` + testTerminalA + `","` + testAccountNumber + `",["192.0.2.10"]]`
	samples, stats := decodeTelemetryStream(gjson.Parse(streamBody(terminalColumns, rows)))

	if stats.Rows != 3 || stats.Invalid != 0 || len(samples) != 2 {
		t.Fatalf("stats %+v samples %d", stats, len(samples))
	}
	ut := samples[0]
	if ut.DeviceRef != "starlink:ut:"+testTerminalA {
		t.Fatalf("telemetry id must converge with inventory id, got %q", ut.DeviceRef)
	}
	if ut.Values["starlink_downlink_throughput"] != 42.5 || ut.Values["starlink_pop_ping_latency"] != 31 {
		t.Fatalf("values = %v", ut.Values)
	}
	if _, leaked := ut.Values["RunningSoftwareVersion"]; leaked || len(ut.Values) != 2 {
		t.Fatalf("non-numeric or unknown columns must not become metrics: %v", ut.Values)
	}
	// 99 is absent from the response's enum table.
	if strings.Join(ut.Alerts, ",") != "actuator_motor_stuck,thermal_shutdown,unknown_alert_99" {
		t.Fatalf("alerts = %v", ut.Alerts)
	}
	// Router columns use the vendor's alternate sample names.
	r := samples[1]
	if r.DeviceRef != routerDeviceID(testRouterA) || r.Values["starlink_router_uptime"] != 3600 ||
		r.Values["starlink_router_internet_ping_latency"] != 20 || r.Values["starlink_router_clients"] != 7 {
		t.Fatalf("router sample = %+v", r)
	}
}

func TestDecodeTelemetryStreamSurvivesColumnReorder(t *testing.T) {
	// The type cell is read from position 0 of each row (the vendor keeps
	// DeviceType first); every other column is matched by name.
	reordered := `["DeviceType","PingLatencyMsAvg","DeviceId","UtcTimestampNs","DownlinkThroughput"]`
	rows := `["u",31,"ut` + testTerminalA + `",1700000000000000000,42.5]`
	samples, _ := decodeTelemetryStream(gjson.Parse(streamBody(reordered, rows)))
	if len(samples) != 1 || samples[0].Values["starlink_downlink_throughput"] != 42.5 ||
		samples[0].Values["starlink_pop_ping_latency"] != 31 {
		t.Fatalf("reordered columns mis-mapped: %+v", samples)
	}
}

func TestDecodeTelemetryStreamRejectsUnidentifiedRows(t *testing.T) {
	rows := `["u",1700000000000000000,"",1,2,[],"x"],["u",0,"ut` + testTerminalA + `",1,2,[],"x"]`
	samples, stats := decodeTelemetryStream(gjson.Parse(streamBody(terminalColumns, rows)))
	if len(samples) != 0 || stats.Invalid != 2 {
		t.Fatalf("rows without device id or timestamp must be invalid: %+v %+v", samples, stats)
	}
}

func TestBuildMetricRecordsAttributesPerDevice(t *testing.T) {
	samples := []telemetrySample{
		{DeviceType: "u", DeviceRef: "starlink:ut:" + testTerminalA, At: 1, Values: map[string]float64{"starlink_uptime": 10}},
		{DeviceType: "u", DeviceRef: "starlink:ut:" + testTerminalA, At: 2, Values: map[string]float64{"starlink_uptime": 25}},
		{DeviceType: "u", DeviceRef: "starlink:ut:" + testTerminalB, At: 2, Values: map[string]float64{"starlink_uptime": 5}},
	}
	records := buildMetricRecords(samples, "starlink-test")
	if len(records) != 2 {
		t.Fatalf("records = %d, want one per device", len(records))
	}
	for _, r := range records {
		if r.PayloadKind != sdk.SignalSchemaPayloadKindServiceRadarMetrics || r.Payload == "" {
			t.Fatalf("record not a metric batch: %+v", r)
		}
	}
}

func TestDrainTelemetryStopsWhenCaughtUpAndEmitsEachBatch(t *testing.T) {
	fullRow := `["u",1700000000000000000,"ut` + testTerminalA + `",1,2,[],"x"]`
	calls := 0
	stream := &sequencedHTTP{t: t, bodies: []string{
		streamBody(terminalColumns, fullRow+","+fullRow), // full batch of 2: keep draining
		streamBody(terminalColumns, fullRow),             // short batch: caught up
	}}
	cfg := mustConfig(t, `{"telemetry_batch_size":2,"telemetry_max_iterations":5}`)
	emitted := 0
	run := drainTelemetry(newAPIClient(stream, cfg), cfg, "starlink-test", func(r []sdk.TelemetryRecord) error {
		calls++
		emitted += len(r)
		return nil
	})
	if run.Err != nil || !run.CaughtUp || run.Iterations != 2 || run.Rows != 3 {
		t.Fatalf("run = %+v", run)
	}
	if calls != 2 || emitted != 2 {
		t.Fatalf("each response must be emitted before the next request: calls %d records %d", calls, emitted)
	}
	if got := stream.requests[0]; got.Method != http.MethodPost || !strings.Contains(string(got.Body), `"batchSize":2`) {
		t.Fatalf("stream request = %+v", got)
	}
}
