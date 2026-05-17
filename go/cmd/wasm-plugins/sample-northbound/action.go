package main

import (
	"encoding/json"
	"fmt"
	"strings"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

const (
	deviceLookupAction   = "sample.device.lookup"
	interfaceAuditAction = "sample.interface.audit"
)

type Config struct {
	APIBaseURL           string `json:"api_base_url"`
	InventoryPrefix      string `json:"inventory_prefix"`
	DefaultPolicyState   string `json:"default_policy_state"`
	ExternalURLTemplate  string `json:"external_url_template"`
	SimulatedLatencyMS   int    `json:"simulated_latency_ms"`
	InterfaceDefaultVLAN int    `json:"interface_default_vlan"`
}

func defaultConfig() Config {
	return Config{
		APIBaseURL:           "mock://sample-nms",
		InventoryPrefix:      "nms",
		DefaultPolicyState:   "compliant",
		ExternalURLTemplate:  "https://nms.example.local/devices/%s",
		SimulatedLatencyMS:   23,
		InterfaceDefaultVLAN: 100,
	}
}

func handleAction(hostConfig *sdk.ActionHostConfig, cfg Config) *sdk.ActionResult {
	if hostConfig == nil {
		return sdk.ActionFailed("invalid_config", "action host config is nil")
	}

	invocation := hostConfig.ActionInvocation

	switch invocation.ActionID {
	case deviceLookupAction:
		return runDeviceLookup(invocation, cfg)
	case interfaceAuditAction:
		return runInterfaceAudit(invocation, cfg)
	default:
		return sdk.ActionFailed("unsupported_action", fmt.Sprintf("unsupported action %q", invocation.ActionID))
	}
}

func runDeviceLookup(invocation sdk.ActionInvocation, cfg Config) *sdk.ActionResult {
	if invocation.Phase == "poll" {
		return pollDeferredAction(invocation, cfg, "device", runDeviceLookupImmediate)
	}

	if stringInput(invocation.InputValues, "execution_mode", "immediate") == "deferred" {
		return deferAction(invocation, "device")
	}

	return runDeviceLookupImmediate(invocation, cfg)
}

func runDeviceLookupImmediate(invocation sdk.ActionInvocation, cfg Config) *sdk.ActionResult {
	result := sdk.ActionSucceeded("sample device lookup completed").
		WithSummary("action_id", invocation.ActionID).
		WithSummary("target_count", len(invocation.Targets)).
		WithSummary("api_base_url", cfg.APIBaseURL).
		WithSummary("simulated_latency_ms", cfg.SimulatedLatencyMS).
		WithCorrelationID(correlationID(invocation.InvocationID, "device"))

	queryMode := stringInput(invocation.InputValues, "query_mode", "summary")
	includeNeighbors := boolInput(invocation.InputValues, "include_neighbors", false)

	for _, target := range invocation.Targets {
		result.AddTargetResult(sdk.ActionTargetResult{
			DeviceUID:             target.DeviceUID,
			Status:                sdk.ActionStatusSucceeded,
			ExternalCorrelationID: correlationID(invocation.InvocationID, target.DeviceUID),
			Result: map[string]any{
				"external_inventory_id": externalInventoryID(cfg, target),
				"api_query":             fmt.Sprintf("GET /devices/%s?mode=%s", target.Address(), queryMode),
				"device_ip":             target.Address(),
				"device_name":           firstNonEmpty(target.DeviceName, target.Hostname, target.DeviceHostname, target.DeviceUID),
				"platform":              firstNonEmpty(target.Model, target.Type, "unknown"),
				"policy_state":          cfg.DefaultPolicyState,
				"neighbors_included":    includeNeighbors,
				"external_url":          externalDeviceURL(cfg, target),
			},
		})
	}

	return result
}

func runInterfaceAudit(invocation sdk.ActionInvocation, cfg Config) *sdk.ActionResult {
	if invocation.Phase == "poll" {
		return pollDeferredAction(invocation, cfg, "interface", runInterfaceAuditImmediate)
	}

	if stringInput(invocation.InputValues, "execution_mode", "immediate") == "deferred" {
		return deferAction(invocation, "interface")
	}

	return runInterfaceAuditImmediate(invocation, cfg)
}

func runInterfaceAuditImmediate(invocation sdk.ActionInvocation, cfg Config) *sdk.ActionResult {
	result := sdk.ActionSucceeded("sample interface audit completed").
		WithSummary("action_id", invocation.ActionID).
		WithSummary("target_count", len(invocation.Targets)).
		WithSummary("api_base_url", cfg.APIBaseURL).
		WithSummary("simulated_latency_ms", cfg.SimulatedLatencyMS).
		WithCorrelationID(correlationID(invocation.InvocationID, "interface"))

	operation := stringInput(invocation.InputValues, "operation", "audit")
	dryRun := boolInput(invocation.InputValues, "dry_run", true)
	changeTicket := stringInput(invocation.InputValues, "change_ticket", "")

	for _, target := range invocation.Targets {
		ifName := firstNonEmpty(target.IfName, target.Name, target.IfDescr, "unknown")

		result.AddTargetResult(sdk.ActionTargetResult{
			DeviceUID:             target.DeviceUID,
			InterfaceUID:          target.InterfaceUID,
			Status:                sdk.ActionStatusSucceeded,
			ExternalCorrelationID: correlationID(invocation.InvocationID, target.InterfaceUID),
			Result: map[string]any{
				"external_inventory_id": externalInventoryID(cfg, target),
				"api_query": fmt.Sprintf(
					"POST /devices/%s/interfaces/%s/actions/%s",
					target.Address(),
					ifName,
					operation,
				),
				"device_ip":           target.Address(),
				"interface_name":      ifName,
				"admin_status":        firstNonEmpty(target.IfAdminStatus, "up"),
				"oper_status":         firstNonEmpty(target.IfOperStatus, "up"),
				"vlan":                cfg.InterfaceDefaultVLAN,
				"policy_state":        cfg.DefaultPolicyState,
				"operation":           operation,
				"dry_run":             dryRun,
				"change_ticket":       changeTicket,
				"remediation_preview": remediationPreview(operation, dryRun, ifName),
				"external_url":        externalDeviceURL(cfg, target),
			},
		})
	}

	return result
}

func deferAction(invocation sdk.ActionInvocation, suffix string) *sdk.ActionResult {
	taskID := correlationID(invocation.InvocationID, suffix+"-async-task")
	continuation := map[string]any{
		"external_task_id": taskID,
		"action_id":        invocation.ActionID,
		"stage":            "poll",
	}

	result := sdk.ActionDeferred("sample external API task accepted").
		WithCorrelationID(taskID).
		WithContinuationState(continuation).
		WithNextPollDelay(1).
		WithMaxDuration(120)

	for _, target := range invocation.Targets {
		result.AddTargetResult(sdk.ActionTargetResult{
			DeviceUID:             target.DeviceUID,
			InterfaceUID:          target.InterfaceUID,
			Status:                sdk.ActionStatusDeferred,
			ExternalCorrelationID: correlationID(invocation.InvocationID, firstNonEmpty(target.InterfaceUID, target.DeviceUID, suffix)),
			ContinuationState:     continuation,
			NextPollDelaySeconds:  1,
			MaxDurationSeconds:    120,
			Result: map[string]any{
				"message":          "queued in sample external API",
				"external_task_id": taskID,
			},
		})
	}

	return result
}

func pollDeferredAction(
	invocation sdk.ActionInvocation,
	cfg Config,
	suffix string,
	finalize func(sdk.ActionInvocation, Config) *sdk.ActionResult,
) *sdk.ActionResult {
	taskID := stringFromMap(invocation.ContinuationState, "external_task_id", correlationID(invocation.InvocationID, suffix+"-async-task"))

	if invocation.PollAttemptCount < 1 {
		return sdk.ActionResultFetching("sample external API task completed; fetching results").
			WithCorrelationID(taskID).
			WithContinuationState(map[string]any{
				"external_task_id": taskID,
				"action_id":        invocation.ActionID,
				"stage":            "result_fetch",
			}).
			WithNextPollDelay(1).
			WithMaxDuration(120)
	}

	return finalize(invocation, cfg).
		WithCorrelationID(taskID).
		WithSummary("external_task_id", taskID).
		WithSummary("poll_attempt_count", invocation.PollAttemptCount)
}

func decodePluginConfig(hostConfig *sdk.ActionHostConfig) Config {
	cfg := defaultConfig()
	if hostConfig != nil {
		_ = hostConfig.DecodePluginConfig(&cfg)
	}

	return normalizeConfig(cfg)
}

func decodePluginConfigMap(raw map[string]any) Config {
	cfg := defaultConfig()
	if len(raw) > 0 {
		data, err := json.Marshal(raw)
		if err == nil {
			_ = json.Unmarshal(data, &cfg)
		}
	}

	return normalizeConfig(cfg)
}

func normalizeConfig(cfg Config) Config {
	if cfg.InventoryPrefix == "" {
		cfg.InventoryPrefix = "nms"
	}
	if cfg.DefaultPolicyState == "" {
		cfg.DefaultPolicyState = "compliant"
	}
	if cfg.ExternalURLTemplate == "" {
		cfg.ExternalURLTemplate = "https://nms.example.local/devices/%s"
	}
	if cfg.InterfaceDefaultVLAN == 0 {
		cfg.InterfaceDefaultVLAN = 100
	}
	return cfg
}

func normalizeActionInvocationConfig(raw map[string]any) map[string]any {
	invocation, ok := raw["action_invocation"].(map[string]any)
	if !ok {
		return raw
	}

	targets, ok := invocation["targets"].([]any)
	if !ok {
		return raw
	}

	for _, targetValue := range targets {
		target, ok := targetValue.(map[string]any)
		if !ok {
			continue
		}

		normalizeInterfaceStatusField(target, "if_admin_status", "if_admin_status_id")
		normalizeInterfaceStatusField(target, "if_oper_status", "if_oper_status_id")
	}

	return raw
}

func normalizeInterfaceStatusField(target map[string]any, statusKey, idKey string) {
	value, ok := target[statusKey]
	if !ok || value == nil {
		return
	}

	switch typed := value.(type) {
	case string:
		if normalized := interfaceStatusName(typed); normalized != "" {
			target[statusKey] = normalized
		}
	case float64:
		target[statusKey] = interfaceStatusName(fmt.Sprintf("%.0f", typed))
		if _, ok := target[idKey]; !ok {
			target[idKey] = int(typed)
		}
	case int:
		target[statusKey] = interfaceStatusName(fmt.Sprintf("%d", typed))
		if _, ok := target[idKey]; !ok {
			target[idKey] = typed
		}
	case json.Number:
		target[statusKey] = interfaceStatusName(typed.String())
		if _, ok := target[idKey]; !ok {
			target[idKey] = typed.String()
		}
	}
}

func interfaceStatusName(value string) string {
	switch strings.TrimSpace(strings.ToLower(value)) {
	case "1":
		return "up"
	case "2":
		return "down"
	case "3":
		return "testing"
	case "up", "down", "testing", "unknown", "dormant", "notpresent", "lowerlayerdown":
		return strings.TrimSpace(value)
	default:
		return strings.TrimSpace(value)
	}
}

func serviceCheckResult(cfg Config) *sdk.Result {
	details := map[string]any{
		"api_base_url":           cfg.APIBaseURL,
		"inventory_prefix":       cfg.InventoryPrefix,
		"default_policy_state":   cfg.DefaultPolicyState,
		"simulated_latency_ms":   cfg.SimulatedLatencyMS,
		"interface_default_vlan": cfg.InterfaceDefaultVLAN,
		"actions": []string{
			deviceLookupAction,
			interfaceAuditAction,
		},
	}

	data, err := json.Marshal(details)
	if err != nil {
		data = []byte(`{}`)
	}

	return sdk.Ok("sample northbound NMS ready").
		WithDetails(string(data)).
		WithLabel("plugin_mode", "northbound_actions").
		WithLabel("integration", "sample-nms")
}

func externalInventoryID(cfg Config, target sdk.ActionTargetSnapshot) string {
	source := firstNonEmpty(target.DeviceUID, target.DeviceIP, target.IP, target.InterfaceUID, "unknown")
	source = strings.NewReplacer(":", "-", "/", "-").Replace(source)
	return cfg.InventoryPrefix + "-" + source
}

func externalDeviceURL(cfg Config, target sdk.ActionTargetSnapshot) string {
	return fmt.Sprintf(cfg.ExternalURLTemplate, externalInventoryID(cfg, target))
}

func correlationID(invocationID, suffix string) string {
	suffix = strings.TrimSpace(suffix)
	if suffix == "" {
		suffix = "target"
	}
	if invocationID == "" {
		return "sample-" + suffix
	}
	return invocationID + "-" + strings.NewReplacer(":", "-", "/", "-").Replace(suffix)
}

func remediationPreview(operation string, dryRun bool, ifName string) string {
	if operation == "" || operation == "audit" {
		return "no change requested for " + ifName
	}
	if dryRun {
		return "would run " + operation + " for " + ifName
	}
	return "run " + operation + " for " + ifName
}

func stringInput(values map[string]any, key, fallback string) string {
	if values == nil {
		return fallback
	}
	value, ok := values[key].(string)
	if !ok || strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func boolInput(values map[string]any, key string, fallback bool) bool {
	if values == nil {
		return fallback
	}
	value, ok := values[key].(bool)
	if !ok {
		return fallback
	}
	return value
}

func stringFromMap(values map[string]any, key, fallback string) string {
	if values == nil {
		return fallback
	}
	value, ok := values[key].(string)
	if !ok || strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
