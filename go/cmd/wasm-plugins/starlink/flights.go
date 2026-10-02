package main

import (
	"net/http"
	"strconv"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"github.com/tidwall/gjson"
)

// flightMetrics maps the gauge names emitted for aviation terminals to their
// units. Declared nil; initFlightMetrics fills it on first use per the TinyGo
// wasi constraint — package-level map literals are never allocated when _start
// is suppressed.
var flightMetrics map[string]string

func initFlightMetrics() {
	if flightMetrics != nil {
		return
	}
	flightMetrics = map[string]string{
		"starlink_flight_altitude_ft":     "ft",
		"starlink_flight_ground_speed_kn": "kn",
		"starlink_flight_heading_deg":     "deg",
	}
}

// collectFlightStatus fetches current flight status for every aviation terminal
// (i.e. those with a tail number on their service line). Returns gauge metric
// records for the numeric fields and a DeviceDiscovery enrichment with the
// categorical fields (flight phase, airports, in-flight flag). Both are
// best-effort: a fetch failure returns (nil, nil) and does not affect other
// telemetry. Non-aviation terminals are skipped entirely.
func collectFlightStatus(c *apiClient, instance string, now time.Time) ([]sdk.TelemetryRecord, *sdk.DeviceDiscovery) {
	initFlightMetrics()

	// Collect service lines with a tail number.
	slTail := map[string]string{} // service line number → tail number
	_, _ = c.listPages("/service-lines", nil, func(row gjson.Result) {
		slNum := trimmed(row, "serviceLineNumber")
		tail := trimmed(row, "tailNumber")
		if slNum != "" && tail != "" {
			slTail[slNum] = tail
		}
	})
	if len(slTail) == 0 {
		return nil, nil
	}

	// Map tail number → terminal device ID via the user-terminals listing.
	tailToDevID := map[string]string{}
	_, _ = c.listPages("/user-terminals", nil, func(row gjson.Result) {
		terminalID := normalizeTerminalID(row.Get("userTerminalId").String())
		slNum := trimmed(row, "serviceLineNumber")
		if terminalID == "" || slNum == "" {
			return
		}
		if tail, ok := slTail[slNum]; ok {
			tailToDevID[tail] = terminalIDPrefix + terminalID
		}
	})
	if len(tailToDevID) == 0 {
		return nil, nil
	}

	tails := make([]string, 0, len(tailToDevID))
	for tail := range tailToDevID {
		tails = append(tails, tail)
	}

	body := `{"tailNumbers":` + stringsJSON(tails) + `}`
	content, err := c.call(http.MethodPost, "/flights/status", nil, []byte(body), 0)
	if err != nil {
		return nil, nil
	}

	atNano := uint64(now.UnixNano())
	discovery := sdk.NewDeviceDiscovery(sourceName)
	discovery.ObservedAt = now.UTC().Format(time.RFC3339Nano)
	var metricRecords []sdk.TelemetryRecord
	hasDiscovery := false

	content.Get("flightStatuses").ForEach(func(_, item gjson.Result) bool {
		tail := trimmed(item, "tailNumber")
		devID, ok := tailToDevID[tail]
		if !ok || devID == "" {
			return true
		}

		altFt := item.Get("altitudeFeet").Float()
		speedKn := item.Get("groundSpeedKnots").Float()
		headDeg := item.Get("headingDegrees").Float()
		phase := trimmed(item, "flightPhase")
		depart := trimmed(item, "departureAirport")
		arrive := trimmed(item, "arrivalAirport")
		inFlight := item.Get("inFlight").Bool()

		inFlightStr := "false"
		if inFlight {
			inFlightStr = "true"
		}

		metricRecords = append(metricRecords, sdk.NewServiceRadarMetricTelemetryRecordFromBatch(
			"starlink-flight-"+devID+"-"+strconv.FormatUint(atNano, 10),
			sdk.MetricBatch{
				Resource: sdk.MetricResource{
					ServiceName: sourceName,
					ServiceType: "wasm-plugin",
					DeviceID:    devID,
					Attributes: []sdk.MetricStringMapEntry{
						{Key: "plugin_id", Value: cloudPluginID},
						{Key: "source_instance", Value: instance},
						{Key: "tail_number", Value: tail},
					},
				},
				IngestIdentity: sdk.MetricIngestIdentity{
					Source:       "plugin-metrics",
					ProducerID:   cloudPluginID,
					ProducerKind: "wasm-plugin",
				},
				Metrics: []sdk.Metric{
					{Name: "starlink_flight_altitude_ft", Kind: sdk.MetricKindGauge, Unit: "ft",
						Points: []sdk.MetricPoint{{Value: altFt, ObservedAtUnixNano: atNano}}},
					{Name: "starlink_flight_ground_speed_kn", Kind: sdk.MetricKindGauge, Unit: "kn",
						Points: []sdk.MetricPoint{{Value: speedKn, ObservedAtUnixNano: atNano}}},
					{Name: "starlink_flight_heading_deg", Kind: sdk.MetricKindGauge, Unit: "deg",
						Points: []sdk.MetricPoint{{Value: headDeg, ObservedAtUnixNano: atNano}}},
				},
			},
		))

		// Categorical fields as a device discovery enrichment so core can
		// persist them as device metadata alongside the gauge metrics.
		metadata := map[string]any{
			"in_flight":       inFlight,
			"in_flight_str":   inFlightStr,
			"source_instance": instance,
		}
		if phase != "" {
			metadata["flight_phase"] = phase
		}
		if depart != "" {
			metadata["departure_airport"] = depart
		}
		if arrive != "" {
			metadata["arrival_airport"] = arrive
		}
		discovery.AddDevice(sdk.DiscoveredDevice{
			DeviceID: devID,
			Metadata: compactMetadata(metadata),
		})
		hasDiscovery = true
		return true
	})

	if !hasDiscovery {
		return metricRecords, nil
	}
	return metricRecords, discovery
}
