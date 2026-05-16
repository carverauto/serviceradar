package main

import (
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

func decodePluginConfig(hostConfig *sdk.ActionHostConfig) Config {
	cfg := defaultConfig()
	if hostConfig != nil {
		_ = hostConfig.DecodePluginConfig(&cfg)
	}
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

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
