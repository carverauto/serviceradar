package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"github.com/tidwall/gjson"
)

// Device-local collection (the starlink-local package). An agent on the
// terminal's LAN reads vendor-documented diagnostics from the dish and router
// gRPC service and, when configured, the router's HTTPS diagnostics endpoint.
// Results are keyed to the vendor device ID the device reports about itself,
// never to its LAN address, which is the same at every site.

const (
	deviceHandleMethod = "/SpaceX.API.Device.Device/Handle"

	// Request.get_diagnostics and the Response members it selects.
	fieldRequestGetDiagnostics      = 6000
	fieldResponseWifiGetDiagnostics = 6000
	fieldResponseDishGetDiagnostics = 6001

	defaultLocalTimeoutMS = 5000
	maxLocalTargets       = 16
)

type localTarget struct {
	Kind string // "dish" or "router"
	Host string
	Port int
}

type localConfig struct {
	Targets              []localTarget
	RouterDiagnosticsURL string
	TimeoutMS            int
}

func parseLocalConfig(raw []byte) (localConfig, error) {
	root := gjson.ParseBytes(raw)
	for _, key := range forbiddenConfigKeys {
		if root.Get(key).Exists() {
			return localConfig{}, errConfigSecret
		}
	}
	cfg := localConfig{
		RouterDiagnosticsURL: strings.TrimSpace(root.Get("router_diagnostics_url").String()),
		TimeoutMS:            boundedInt(root.Get("timeout_ms"), defaultLocalTimeoutMS, 1000, 30000),
	}
	for _, t := range root.Get("targets").Array() {
		target := localTarget{
			Kind: strings.ToLower(strings.TrimSpace(t.Get("kind").String())),
			Host: strings.TrimSpace(t.Get("host").String()),
			Port: int(t.Get("port").Int()),
		}
		if (target.Kind != "dish" && target.Kind != "router") || target.Host == "" || target.Port < 1 || target.Port > 65535 {
			return localConfig{}, errors.New("starlink_local_target_invalid")
		}
		cfg.Targets = append(cfg.Targets, target)
	}
	if len(cfg.Targets) > maxLocalTargets {
		return localConfig{}, errors.New("starlink_local_too_many_targets")
	}
	if cfg.RouterDiagnosticsURL != "" {
		u, err := url.Parse(cfg.RouterDiagnosticsURL)
		if err != nil || u.Scheme != "https" || u.Host == "" {
			return localConfig{}, errors.New("starlink_local_router_url_invalid")
		}
	}
	if len(cfg.Targets) == 0 && cfg.RouterDiagnosticsURL == "" {
		return localConfig{}, errors.New("starlink_local_no_targets")
	}
	return cfg, nil
}

// grpcDoer is the SDK gRPC client surface; tests swap in a fake.
type grpcDoer interface {
	Unary(ctx context.Context, req sdk.GRPCRequest) (*sdk.GRPCResponse, error)
}

// localDiagnostics is one device's decoded diagnostics.
type localDiagnostics struct {
	DeviceRef       string
	Kind            string // user_terminal or router
	SoftwareVersion string
	HardwareVersion string
	Alerts          []string
	Metrics         map[string]float64
}

// Local alert names reuse the cloud names where the condition is the same,
// so an alert rule grouped by device and alert name sees one incident when
// both paths report it.
var localAlertNames = map[string]string{
	"motors_stuck":                  "actuator_motor_stuck",
	"mast_not_near_vertical":        "mast_not_vertical",
	"dish_thermal_shutdown":         "thermal_shutdown",
	"dish_thermal_throttle":         "thermal_throttling",
	"power_supply_thermal_throttle": "psu_otp_throttling",
	"software_install_pending":      "software_update_reboot_pending",
	"dishIsHeating":                 "dish_is_heating",
	"dishThermalThrottle":           "thermal_throttling",
	"dishThermalShutdown":           "thermal_shutdown",
	"powerSupplyThermalThrottle":    "psu_otp_throttling",
	"motorsStuck":                   "actuator_motor_stuck",
	"mastNotNearVertical":           "mast_not_vertical",
	"slowEthernetSpeeds":            "slow_ethernet_speeds",
	"softwareInstallPending":        "software_update_reboot_pending",
	"movingTooFastForPolicy":        "moving_too_fast_for_policy",
}

func localAlertName(raw string) string {
	if name, ok := localAlertNames[raw]; ok {
		return name
	}
	if strings.ContainsAny(raw, "ABCDEFGHIJKLMNOPQRSTUVWXYZ") {
		return snakeCase(raw)
	}
	return raw
}

// dishAlertFields are DishGetDiagnosticsResponse.Alerts members by field number.
var dishAlertFields = map[uint64]string{
	1: "dish_is_heating", 2: "dish_thermal_throttle", 3: "dish_thermal_shutdown",
	4: "power_supply_thermal_throttle", 5: "motors_stuck", 6: "mast_not_near_vertical",
	7: "slow_ethernet_speeds", 8: "software_install_pending", 9: "moving_too_fast_for_policy",
	10: "obstructed",
}

// disablementNames are DishGetDiagnosticsResponse.DisablementCode values;
// UNKNOWN (0) and OKAY (1) are not alerts.
var disablementNames = map[uint64]string{
	2: "no_active_account", 3: "too_far_from_service_address", 4: "in_ocean", 6: "blocked_country",
	7: "data_overage_sandbox_policy", 8: "cell_is_disabled", 10: "roam_restricted",
	11: "unknown_location", 12: "account_disabled", 13: "unsupported_version", 14: "moving_too_fast_for_policy",
}

func decodeDiagnosticsResponse(msg []byte) (localDiagnostics, error) {
	fields, err := protoFields(msg)
	if err != nil {
		return localDiagnostics{}, err
	}
	for _, f := range fields {
		if f.wire != wireBytes {
			continue
		}
		switch f.num {
		case fieldResponseDishGetDiagnostics:
			return decodeDishDiagnostics(f.bytes)
		case fieldResponseWifiGetDiagnostics:
			return decodeWifiDiagnostics(f.bytes)
		}
	}
	return localDiagnostics{}, errors.New("starlink_local_no_diagnostics")
}

func decodeDishDiagnostics(msg []byte) (localDiagnostics, error) {
	fields, err := protoFields(msg)
	if err != nil {
		return localDiagnostics{}, err
	}
	d := localDiagnostics{Kind: "user_terminal", Metrics: map[string]float64{}}
	for _, f := range fields {
		switch {
		case f.num == 1 && f.wire == wireBytes:
			d.DeviceRef = terminalDeviceID(string(f.bytes))
		case f.num == 2 && f.wire == wireBytes:
			d.HardwareVersion = string(f.bytes)
		case f.num == 3 && f.wire == wireBytes:
			d.SoftwareVersion = string(f.bytes)
		case f.num == 5 && f.wire == wireBytes:
			alerts, err := protoFields(f.bytes)
			if err != nil {
				return localDiagnostics{}, err
			}
			for _, a := range alerts {
				if name, ok := dishAlertFields[a.num]; ok && a.wire == wireVarint && a.bool() {
					d.Alerts = append(d.Alerts, localAlertName(name))
				}
			}
		case f.num == 6 && f.wire == wireVarint:
			if name, ok := disablementNames[f.value]; ok {
				d.Alerts = append(d.Alerts, "disabled_"+name)
			}
		case f.num == 7 && f.wire == wireVarint:
			// TestResult: 0 no result, 1 passed, 2 failed.
			if f.value == 2 {
				d.Alerts = append(d.Alerts, "hardware_self_test_failed")
			}
			if f.value != 0 {
				d.Metrics["starlink_local_self_test_passed"] = boolFloat(f.value == 1)
			}
		case f.num == 9 && f.wire == wireBytes:
			decodeAlignment(f.bytes, d.Metrics)
		case f.num == 10 && f.wire == wireVarint:
			d.Metrics["starlink_local_stowed"] = boolFloat(f.bool())
		case f.num == 14 && f.wire == wireVarint:
			d.Metrics["starlink_local_overage_rate_limited"] = boolFloat(f.bool())
		}
	}
	if d.DeviceRef == "" {
		return localDiagnostics{}, errors.New("starlink_local_device_unidentified")
	}
	sort.Strings(d.Alerts)
	return d, nil
}

func decodeAlignment(msg []byte, metrics map[string]float64) {
	fields, err := protoFields(msg)
	if err != nil {
		return
	}
	values := map[uint64]float64{}
	for _, f := range fields {
		if f.wire == wireFixed32 {
			values[f.num] = float64(f.float32())
		}
	}
	// Alignment error: how far the dish points from where it should.
	if az, ok := values[1]; ok {
		if want, ok := values[3]; ok {
			metrics["starlink_local_azimuth_error_deg"] = angleDelta(want, az)
		}
	}
	if el, ok := values[2]; ok {
		if want, ok := values[4]; ok {
			metrics["starlink_local_elevation_error_deg"] = want - el
		}
	}
}

func angleDelta(want, got float64) float64 {
	d := want - got
	for d > 180 {
		d -= 360
	}
	for d < -180 {
		d += 360
	}
	return d
}

func decodeWifiDiagnostics(msg []byte) (localDiagnostics, error) {
	fields, err := protoFields(msg)
	if err != nil {
		return localDiagnostics{}, err
	}
	d := localDiagnostics{Kind: "router", Metrics: map[string]float64{}}
	var eth, c2, c5 float64
	for _, f := range fields {
		switch {
		case f.num == 1 && f.wire == wireBytes:
			d.DeviceRef = routerDeviceID(string(f.bytes))
		case f.num == 2 && f.wire == wireBytes:
			d.HardwareVersion = string(f.bytes)
		case f.num == 3 && f.wire == wireBytes:
			d.SoftwareVersion = string(f.bytes)
		case f.num == 4 && f.wire == wireBytes:
			network, err := protoFields(f.bytes)
			if err != nil {
				return localDiagnostics{}, err
			}
			for _, n := range network {
				switch {
				case n.num == 10 && n.wire == wireVarint:
					eth += float64(n.value)
				case n.num == 11 && n.wire == wireVarint:
					c2 += float64(n.value)
				case n.num == 12 && n.wire == wireVarint:
					c5 += float64(n.value)
				}
			}
		}
	}
	if d.DeviceRef == "" {
		return localDiagnostics{}, errors.New("starlink_local_device_unidentified")
	}
	d.Metrics["starlink_router_clients_ethernet"] = eth
	d.Metrics["starlink_router_clients_2ghz"] = c2
	d.Metrics["starlink_router_clients_5ghz"] = c5
	return d, nil
}

// decodeRouterHTTPSDiagnostics reads the router's HTTPS diagnostics JSON,
// which reports both the router and the dish behind it.
// The router section is intentionally ignored: it carries no vendor device ID,
// so there is no stable identifier to attribute its alerts to.
func decodeRouterHTTPSDiagnostics(body []byte) []localDiagnostics {
	root := gjson.ParseBytes(body)
	var out []localDiagnostics
	if dish := root.Get("dish"); dish.IsObject() {
		d := localDiagnostics{
			DeviceRef:       terminalDeviceID(dish.Get("id").String()),
			Kind:            "user_terminal",
			SoftwareVersion: dish.Get("softwareVersion").String(),
			HardwareVersion: dish.Get("hardwareVersion").String(),
			Metrics:         map[string]float64{},
		}
		dish.Get("alerts").ForEach(func(k, v gjson.Result) bool {
			if v.Type == gjson.True {
				d.Alerts = append(d.Alerts, localAlertName(k.String()))
			}
			return true
		})
		if code := strings.TrimSpace(dish.Get("disablementCode").String()); code != "" &&
			!strings.EqualFold(code, "okay") && !strings.EqualFold(code, "unknown") {
			d.Alerts = append(d.Alerts, "disabled_"+snakeCase(code))
		}
		if strings.EqualFold(dish.Get("hardwareSelfTest").String(), "failed") {
			d.Alerts = append(d.Alerts, "hardware_self_test_failed")
		}
		if d.DeviceRef != "" {
			sort.Strings(d.Alerts)
			out = append(out, d)
		}
	}
	return out
}

func boolFloat(v bool) float64 {
	if v {
		return 1
	}
	return 0
}

type localRun struct {
	Devices []localDiagnostics
	Errors  []string
}

func collectLocal(cfg localConfig, grpc grpcDoer, httpc httpDoer) localRun {
	var run localRun
	request := protoAppendEmptyMessage(nil, fieldRequestGetDiagnostics)
	for _, t := range cfg.Targets {
		resp, err := grpc.Unary(context.Background(), sdk.GRPCRequest{
			TargetHost: t.Host,
			TargetPort: t.Port,
			Method:     deviceHandleMethod,
			Message:    request,
			TimeoutMS:  cfg.TimeoutMS,
			Transport:  sdk.GRPCTransportH2C,
		})
		if err != nil {
			run.Errors = append(run.Errors, t.Kind+"_diagnostics_unreachable")
			continue
		}
		d, err := decodeDiagnosticsResponse(resp.Message)
		if err != nil {
			run.Errors = append(run.Errors, t.Kind+"_diagnostics_undecodable")
			continue
		}
		run.Devices = append(run.Devices, d)
	}
	if cfg.RouterDiagnosticsURL != "" {
		resp, err := httpc.Do(sdk.HTTPRequest{
			Method:    http.MethodGet,
			URL:       cfg.RouterDiagnosticsURL,
			Headers:   map[string]string{"Accept": "application/json"},
			TimeoutMS: cfg.TimeoutMS,
		})
		switch {
		case err != nil || resp == nil:
			run.Errors = append(run.Errors, "router_https_diagnostics_unreachable")
		case resp.Status != http.StatusOK:
			run.Errors = append(run.Errors, "router_https_diagnostics_http_"+strconv.Itoa(resp.Status))
		default:
			run.Devices = append(run.Devices, decodeRouterHTTPSDiagnostics(resp.Body)...)
		}
	}
	return run
}

// localAlertScope names one condition scope per assignment; the agent keeps
// debounce state per assignment, so the name only needs to be stable.
const localAlertScope = sourceName + ":local:alerts"

// buildLocalRecords emits metrics and scoped alert events. The scope is
// complete only when every configured source answered, so a device that
// could not be reached never has its alerts cleared.
func buildLocalRecords(run localRun, complete bool) []sdk.TelemetryRecord {
	var samples []telemetrySample
	var alerts alertSnapshot
	alerts.Complete = complete
	now := uint64(time.Now().UTC().UnixNano())
	for _, d := range run.Devices {
		samples = append(samples, telemetrySample{DeviceRef: d.DeviceRef, At: now, Values: d.Metrics})
		alerts.Devices = append(alerts.Devices, deviceAlerts{DeviceRef: d.DeviceRef, Kind: d.Kind, Active: d.Alerts})
	}
	records := buildMetricRecordsFor(samples, "local", localPluginID)
	return append(records, buildScopedAlertRecords(alerts, localAlertScope, "local", localPluginID)...)
}

func runLocal(raw []byte, grpc grpcDoer, httpc httpDoer, emit func([]sdk.TelemetryRecord) error) *sdk.Result {
	cfg, err := parseLocalConfig(raw)
	if err != nil {
		return sdk.Critical(err.Error())
	}
	run := collectLocal(cfg, grpc, httpc)
	records := buildLocalRecords(run, len(run.Errors) == 0)
	emitErr := ""
	for start := 0; start < len(records); start += maxRecordsPerEmit {
		end := min(start+maxRecordsPerEmit, len(records))
		if err := emit(records[start:end]); err != nil {
			emitErr = "starlink_local_emit_failed"
			break
		}
	}

	active := 0
	for _, d := range run.Devices {
		active += len(d.Alerts)
	}
	summary := fmt.Sprintf("Starlink local diagnostics: %d devices, %d active alerts", len(run.Devices), active)
	problems := append([]string{}, run.Errors...)
	if emitErr != "" {
		problems = append(problems, emitErr)
	}
	result := sdk.Ok(summary)
	switch {
	case len(run.Devices) == 0:
		result = sdk.Critical(summary + " (" + strings.Join(problems, ", ") + ")")
	case len(problems) > 0:
		result = sdk.Warning(summary + " (" + strings.Join(problems, ", ") + ")")
	}
	details, _ := json.Marshal(map[string]any{"devices": len(run.Devices), "active_alerts": active, "problems": problems})
	return result.WithLabel("source", sourceName).WithDetails(string(details))
}
