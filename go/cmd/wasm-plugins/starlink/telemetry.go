package main

import (
	"net/http"
	"sort"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"github.com/tidwall/gjson"
)

const (
	deviceTypeTerminal = "u"
	deviceTypeRouter   = "r"

	// maxRecordsPerEmit bounds one emit_telemetry call; each record is one
	// device's batch for one stream response.
	maxRecordsPerEmit = 200
)

type metricSpec struct {
	name string
	unit string
}

// terminalMetrics and routerMetrics map vendor column names to metric names.
// Columns are matched by name on every response because the vendor may
// reorder or add them; unknown columns are ignored. Several router columns
// have alternate names in the vendor's own examples, so both are listed.
//
// Declared without initializers so the zero value (nil) is the initial state.
// The TinyGo wasi target compiles to a WASM command whose global heap
// allocations (maps) are initialized inside _start; the agent host calls
// WithStartFunctions() with no arguments to suppress _start (preventing
// proc_exit(0) from closing the module), so package-level map literals are
// never allocated. initMetricMaps(), called from decodeTelemetryStream, fills
// them on the first invocation. Standard Go callers get the same lazy path.
var terminalMetrics map[string]metricSpec
var routerMetrics map[string]metricSpec

func initMetricMaps() {
	if terminalMetrics != nil {
		return
	}
	terminalMetrics = map[string]metricSpec{
		"DownlinkThroughput":                 {"starlink_downlink_throughput", "Mbps"},
		"UplinkThroughput":                   {"starlink_uplink_throughput", "Mbps"},
		"PingDropRateAvg":                    {"starlink_pop_ping_drop_ratio", "ratio"},
		"PingLatencyMsAvg":                   {"starlink_pop_ping_latency", "ms"},
		"ObstructionPercentTime":             {"starlink_obstruction_time", "percent"},
		"SignalQuality":                      {"starlink_signal_quality", "ratio"},
		"Uptime":                             {"starlink_uptime", "s"},
		"SecondsUntilSwupdateRebootPossible": {"starlink_swupdate_reboot_possible_in", "s"},
		"PowerInputVoltage":                  {"starlink_power_input_voltage", "V"},
		"TiltAngleDeg":                       {"starlink_tilt_angle", "deg"},
		"BoresightAzimuthDeg":                {"starlink_boresight_azimuth", "deg"},
		"BoresightElevationDeg":              {"starlink_boresight_elevation", "deg"},
		"EthSpeedMbps":                       {"starlink_eth_speed", "Mbps"},
		"GpsValidSats":                       {"starlink_gps_valid_sats", "count"},
		"GpsLatitude":                        {"starlink_gps_latitude", "deg"},
		"GpsLongitude":                       {"starlink_gps_longitude", "deg"},
		"ObstructionPercentValid":            {"starlink_obstruction_percent_valid", "percent"},
	}
	routerMetrics = map[string]metricSpec{
		"WifiUptimeS":                  {"starlink_router_uptime", "s"},
		"Uptime":                       {"starlink_router_uptime", "s"},
		"InternetPingDropRate":         {"starlink_router_internet_ping_drop_ratio", "ratio"},
		"InternetPingLatencyMs":        {"starlink_router_internet_ping_latency", "ms"},
		"PingLatencyMs":                {"starlink_router_internet_ping_latency", "ms"},
		"WifiPopPingDropRate":          {"starlink_router_pop_ping_drop_ratio", "ratio"},
		"WifiPopPingLatencyMs":         {"starlink_router_pop_ping_latency", "ms"},
		"DishPingDropRate":             {"starlink_router_dish_ping_drop_ratio", "ratio"},
		"DishPingLatencyMs":            {"starlink_router_dish_ping_latency", "ms"},
		"Clients":                      {"starlink_router_clients", "count"},
		"Clients2Ghz":                  {"starlink_router_clients_2ghz", "count"},
		"Clients5Ghz":                  {"starlink_router_clients_5ghz", "count"},
		"ClientsEth":                   {"starlink_router_clients_ethernet", "count"},
		"WifiHopsFromController":       {"starlink_router_mesh_hops", "count"},
		"WanTxBytes":                   {"starlink_router_wan_tx", "bytes"},
		"WanRxBytes":                   {"starlink_router_wan_rx", "bytes"},
		"Clients2GhzSignalStrengthAvg": {"starlink_router_clients_2ghz_rssi_avg", "dBm"},
		"Clients5GhzSignalStrengthAvg": {"starlink_router_clients_5ghz_rssi_avg", "dBm"},
		"Clients2GhzRxRateMbpsAvg":     {"starlink_router_clients_2ghz_rx_rate_avg", "Mbps"},
		"Clients5GhzRxRateMbpsAvg":     {"starlink_router_clients_5ghz_rx_rate_avg", "Mbps"},
		"Clients2GhzTxRateMbpsAvg":     {"starlink_router_clients_2ghz_tx_rate_avg", "Mbps"},
		"Clients5GhzTxRateMbpsAvg":     {"starlink_router_clients_5ghz_tx_rate_avg", "Mbps"},
	}
}

// telemetrySample is one decoded stream row.
type telemetrySample struct {
	DeviceType string
	DeviceRef  string // starlink:ut:<id> / starlink:router:<id>
	At         uint64 // unix nanoseconds
	Values     map[string]float64
	Alerts     []string
}

type streamDecodeStats struct {
	Rows    int
	Invalid int
}

// decodeTelemetryStream decodes one columnar stream response. Alert codes are
// mapped only through the enum table carried in the same response: the
// vendor reassigns codes, so a code is meaningless outside its response.
func decodeTelemetryStream(body gjson.Result) ([]telemetrySample, streamDecodeStats) {
	initMetricMaps()
	var stats streamDecodeStats
	columns := map[string][]string{}
	body.Get("data.columnNamesByDeviceType").ForEach(func(key, value gjson.Result) bool {
		var names []string
		for _, n := range value.Array() {
			names = append(names, n.String())
		}
		columns[key.String()] = names
		return true
	})
	alertNames := body.Get("metadata.enums.AlertsByDeviceType")

	var samples []telemetrySample
	for _, row := range body.Get("data.values").Array() {
		stats.Rows++
		cells := row.Array()
		if len(cells) == 0 {
			stats.Invalid++
			continue
		}
		deviceType := cells[0].String()
		names, ok := columns[deviceType]
		if !ok || (deviceType != deviceTypeTerminal && deviceType != deviceTypeRouter) {
			// IpAllocs and unknown device types carry no metrics.
			continue
		}
		sample, ok := decodeRow(deviceType, names, cells, alertNames.Get(deviceType))
		if !ok {
			stats.Invalid++
			continue
		}
		samples = append(samples, sample)
	}
	return samples, stats
}

func decodeRow(deviceType string, names []string, cells []gjson.Result, alertEnum gjson.Result) (telemetrySample, bool) {
	specs := terminalMetrics
	if deviceType == deviceTypeRouter {
		specs = routerMetrics
	}
	sample := telemetrySample{DeviceType: deviceType, Values: map[string]float64{}}

	for i, name := range names {
		if i >= len(cells) {
			break
		}
		cell := cells[i]
		switch name {
		case "DeviceId":
			if deviceType == deviceTypeRouter {
				sample.DeviceRef = routerDeviceID(cell.String())
			} else {
				sample.DeviceRef = terminalDeviceID(cell.String())
			}
		case "UtcTimestampNs":
			sample.At = cell.Uint()
		case "ActiveAlert", "ActiveAlerts":
			for _, code := range cell.Array() {
				name := strings.TrimSpace(alertEnum.Get(code.String()).String())
				if name == "" {
					name = "unknown_alert_" + code.String()
				}
				sample.Alerts = append(sample.Alerts, name)
			}
		default:
			spec, known := specs[name]
			if !known || cell.Type != gjson.Number {
				continue
			}
			sample.Values[spec.name] = cell.Float()
		}
	}
	if sample.DeviceRef == "" || sample.At == 0 {
		return telemetrySample{}, false
	}
	sort.Strings(sample.Alerts)
	return sample, true
}

// metricUnits resolves a metric name's unit from either table.
func metricUnit(name string) string {
	initMetricMaps()
	for _, table := range []map[string]metricSpec{terminalMetrics, routerMetrics} {
		for _, spec := range table {
			if spec.name == name {
				return spec.unit
			}
		}
	}
	return ""
}

// buildMetricRecords groups samples per device into one metric batch each,
// attributed through MetricResource.DeviceID to the same device reference the
// discovery record uses as its integration identifier.
func buildMetricRecords(samples []telemetrySample, instance string) []sdk.TelemetryRecord {
	return buildMetricRecordsFor(samples, instance, cloudPluginID)
}

func buildMetricRecordsFor(samples []telemetrySample, instance, producerID string) []sdk.TelemetryRecord {
	byDevice := map[string][]telemetrySample{}
	var order []string
	for _, s := range samples {
		if _, ok := byDevice[s.DeviceRef]; !ok {
			order = append(order, s.DeviceRef)
		}
		byDevice[s.DeviceRef] = append(byDevice[s.DeviceRef], s)
	}
	sort.Strings(order)

	records := make([]sdk.TelemetryRecord, 0, len(order))
	for _, ref := range order {
		points := map[string][]sdk.MetricPoint{}
		for _, s := range byDevice[ref] {
			for name, value := range s.Values {
				points[name] = append(points[name], sdk.MetricPoint{Value: value, ObservedAtUnixNano: s.At})
			}
			points["starlink_active_alerts"] = append(points["starlink_active_alerts"],
				sdk.MetricPoint{Value: float64(len(s.Alerts)), ObservedAtUnixNano: s.At})
		}
		names := make([]string, 0, len(points))
		for name := range points {
			names = append(names, name)
		}
		sort.Strings(names)

		metrics := make([]sdk.Metric, 0, len(names))
		for _, name := range names {
			unit := metricUnit(name)
			if name == "starlink_active_alerts" {
				unit = "count"
			}
			metrics = append(metrics, sdk.Metric{
				Name:   name,
				Kind:   sdk.MetricKindGauge,
				Unit:   unit,
				Points: points[name],
			})
		}

		records = append(records, sdk.NewServiceRadarMetricTelemetryRecordFromBatch(
			"starlink-metrics-"+ref+"-"+strconv.FormatUint(byDevice[ref][0].At, 10),
			sdk.MetricBatch{
				Resource: sdk.MetricResource{
					ServiceName: sourceName,
					ServiceType: "wasm-plugin",
					DeviceID:    ref,
					Attributes: []sdk.MetricStringMapEntry{
						{Key: "plugin_id", Value: producerID},
						{Key: "source_instance", Value: instance},
					},
				},
				IngestIdentity: sdk.MetricIngestIdentity{
					Source:       "plugin-metrics",
					ProducerID:   producerID,
					ProducerKind: "wasm-plugin",
				},
				Metrics: metrics,
			},
		))
	}
	return records
}

type telemetryRun struct {
	Iterations int
	Rows       int
	Invalid    int
	Devices    int
	CaughtUp   bool
	Err        error
}

// drainTelemetry reads the stream until it is caught up or the per-run
// iteration budget is spent. The vendor advances its read position on every
// successful response and delivers at most once, so every decoded batch is
// emitted before the next request.
func drainTelemetry(c *apiClient, cfg Config, instance string, emit func([]sdk.TelemetryRecord) error) telemetryRun {
	var run telemetryRun
	devices := map[string]bool{}
	request := []byte(`{"batchSize":` + strconv.Itoa(cfg.TelemetryBatchSize) +
		`,"maxLingerMs":` + strconv.Itoa(cfg.TelemetryMaxLingerMS) + `}`)

	for run.Iterations < cfg.TelemetryMaxIteration {
		body, err := c.call(http.MethodPost, "/telemetry/stream", nil, request, cfg.TimeoutMS)
		if err != nil {
			run.Err = err
			return run
		}
		run.Iterations++

		samples, stats := decodeTelemetryStream(body)
		run.Rows += stats.Rows
		run.Invalid += stats.Invalid
		for _, s := range samples {
			devices[s.DeviceRef] = true
		}
		run.Devices = len(devices)

		records := buildMetricRecords(samples, instance)
		for start := 0; start < len(records); start += maxRecordsPerEmit {
			end := min(start+maxRecordsPerEmit, len(records))
			if err := emit(records[start:end]); err != nil {
				run.Err = &apiError{code: "starlink_telemetry_emit_failed"}
				return run
			}
		}

		if stats.Rows < cfg.TelemetryBatchSize {
			run.CaughtUp = true
			return run
		}
	}
	return run
}

func emitTelemetryRecords(instance string) func([]sdk.TelemetryRecord) error {
	return func(records []sdk.TelemetryRecord) error {
		return sdk.EmitTelemetry(sdk.TelemetryBatch{
			Source:  sdk.TelemetrySource{SourceType: sourceName, SourceInstance: instance},
			Records: records,
		})
	}
}
