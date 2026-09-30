package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

const (
	cloudPluginID = "starlink-cloud"
	localPluginID = "starlink-local"

	actionInventoryRefresh = "starlink.inventory.refresh"
	actionTelemetryCollect = "starlink.telemetry.collect"
)

// starlinkHTTP is package-level so tests can swap it for a fake.
var starlinkHTTP httpDoer = &sdk.HTTPClient{MaxResponseBytes: sdk.MaxHTTPResponseBytes}

// runPlugin dispatches one invocation. Scheduled collection arrives as
// producer-schedule actions because the agent injects the brokered
// service-account token only into action-mode runs.
func runPlugin() error {
	primeTinyGoJSON()
	cfg, err := loadConfig()
	if err != nil {
		return submit(sdk.Critical(err.Error()))
	}
	if isManagementAction(cfg.ActionID) {
		return sdk.SubmitActionResult(runManagementAction(cfg, starlinkHTTP))
	}
	return submit(dispatch(cfg, starlinkHTTP, time.Now().UTC()))
}

// runLocalPlugin is the starlink-local entrypoint: device-local diagnostics
// on the agent's LAN, no credentials.
func runLocalPlugin() error {
	primeTinyGoJSON()
	var raw json.RawMessage
	if err := sdk.GetConfig(&raw); err != nil {
		return submit(sdk.Critical("starlink_config_read_failed"))
	}
	emit := func(records []sdk.TelemetryRecord) error {
		return sdk.EmitTelemetry(sdk.TelemetryBatch{
			Source:  sdk.TelemetrySource{SourceType: sourceName, SourceInstance: "local"},
			Records: records,
		})
	}
	return submit(runLocal(raw, sdk.GRPC, starlinkHTTP, emit))
}

func dispatch(cfg Config, doer httpDoer, now time.Time) *sdk.Result {
	client := newAPIClient(doer, cfg)
	switch cfg.ActionID {
	case actionInventoryRefresh:
		return runInventory(client, now)
	case actionTelemetryCollect:
		return runTelemetry(client, cfg, emitTelemetryRecords)
	case "":
		return sdk.Unknown("starlink-cloud runs only as scheduled or operator actions; attach a Starlink credential rule")
	default:
		return sdk.Unknown("starlink_action_unsupported")
	}
}

func runInventory(client *apiClient, now time.Time) *sdk.Result {
	snap, err := collectInventory(client)
	if err != nil {
		return sdk.Critical(errorCode(err))
	}
	discovery := buildDiscovery(snap, now)

	routers := len(discovery.Devices) - len(snap.Terminals)
	summary := fmt.Sprintf("Starlink inventory: %d terminals, %d routers, %d service lines",
		len(snap.Terminals), routers, len(snap.ServiceLines))

	result := sdk.Ok(summary)
	if !snap.Complete {
		result = sdk.Warning(summary + " (incomplete: " + strings.Join(snap.Errors, ", ") + ")")
	}
	details, _ := json.Marshal(map[string]any{
		"terminals":      len(snap.Terminals),
		"routers":        routers,
		"service_lines":  len(snap.ServiceLines),
		"complete":       snap.Complete,
		"pages":          snap.Pages,
		"invalid_rows":   snap.InvalidRows,
		"duplicate_rows": snap.DuplicateRows,
		"requests":       client.requests,
		"errors":         snap.Errors,
	})
	return result.
		WithObservedAt(now).
		WithLabel("source", sourceName).
		WithLabel("source_instance", sourceInstance(snap.Account.Number)).
		WithDetails(string(details)).
		WithDeviceDiscovery(*discovery)
}

func runTelemetry(client *apiClient, cfg Config, emitter func(string) func([]sdk.TelemetryRecord) error) *sdk.Result {
	content, err := client.call(http.MethodGet, "/account", nil, nil, 0)
	if err != nil {
		return sdk.Critical(errorCode(err))
	}
	accountNumber := trimmed(content, "accountNumber")
	if accountNumber == "" {
		return sdk.Critical("starlink_account_unidentified")
	}
	instance := sourceInstance(accountNumber)
	emit := emitter(instance)

	run := drainTelemetry(client, cfg, instance, emit)
	alerts := collectAlerts(client)
	alertRecords := buildAlertRecords(alerts, instance, cloudPluginID)
	alertEmitErr := ""
	for start := 0; start < len(alertRecords); start += maxRecordsPerEmit {
		end := min(start+maxRecordsPerEmit, len(alertRecords))
		if err := emit(alertRecords[start:end]); err != nil {
			alertEmitErr = "starlink_alert_emit_failed"
			break
		}
	}

	active := 0
	for _, d := range alerts.Devices {
		active += len(d.Active)
	}
	summary := fmt.Sprintf("Starlink telemetry: %d rows from %d devices in %d requests; %d active alerts",
		run.Rows, run.Devices, run.Iterations, active)

	var problems []string
	if run.Err != nil {
		problems = append(problems, errorCode(run.Err))
	}
	problems = append(problems, alerts.Errors...)
	if alertEmitErr != "" {
		problems = append(problems, alertEmitErr)
	}
	if run.Err == nil && run.Rows == 0 {
		// Either every device is offline, or another consumer shares this
		// service account and is reading the stream (each client ID has one
		// read position, so two readers split the data between them).
		problems = append(problems, "starlink_telemetry_no_rows")
	}

	result := sdk.Ok(summary)
	if len(problems) > 0 {
		result = sdk.Warning(summary + " (" + strings.Join(problems, ", ") + ")")
	}
	details, _ := json.Marshal(map[string]any{
		"stream_iterations": run.Iterations,
		"stream_rows":       run.Rows,
		"stream_invalid":    run.Invalid,
		"stream_caught_up":  run.CaughtUp,
		"devices":           run.Devices,
		"active_alerts":     active,
		"alerts_complete":   alerts.Complete,
		"requests":          client.requests,
		"problems":          problems,
	})
	return result.
		WithLabel("source", sourceName).
		WithLabel("source_instance", instance).
		WithDetails(string(details))
}

func submit(result *sdk.Result) error {
	return sdk.Execute(func() (*sdk.Result, error) { return result, nil })
}

// primeTinyGoJSON registers types we marshal so TinyGo's reflection-free JSON
// support pulls them in. Mirrors the other first-party plugins.
func primeTinyGoJSON() {
	_, _ = json.Marshal(map[string]any{"n": 0})
	_, _ = json.Marshal(sdk.DiscoveredDevice{})
	_, _ = json.Marshal(sdk.OCSFEvent{})
}
