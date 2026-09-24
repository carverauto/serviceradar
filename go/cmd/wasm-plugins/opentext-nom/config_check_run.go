package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

// The interface config check runs as its own producer schedule. Its operator
// configuration (NA connection settings plus the keys below) arrives as the
// schedule params, merged into the plugin config like any action's
// input_values; the target devices arrive as action_invocation.target_items,
// resolved by core from the configured SRQL query.
const (
	interfaceCheckActionID = "opentext-nom.interface.check"
	configCheckKey         = "config_check"
	targetQueryKey         = "target_query"
	targetFieldsKey        = "target_fields"
)

// checkOnlyConfigKeys are plugin-config keys that belong to the interface
// check. Both profiles share one config schema, so the inventory and retrieve
// paths drop them before their strict parse.
var checkOnlyConfigKeys = []string{configCheckKey, targetQueryKey, targetFieldsKey}

type configCheckRun struct {
	checks    interfaceCheckConfig
	items     []map[string]any
	total     int
	truncated bool
}

// parseConfigCheckRun reads the check definition from the merged plugin config
// and the target devices from the action invocation.
func parseConfigCheckRun(raw map[string]json.RawMessage) (configCheckRun, error) {
	checks, err := parseCheckDefinition(raw)
	if err != nil {
		return configCheckRun{}, err
	}
	targets, err := parseTargetItems(raw)
	if err != nil {
		return configCheckRun{}, err
	}
	return configCheckRun{checks: checks, items: targets.Items, total: targets.Total, truncated: targets.Truncated}, nil
}

// parseCheckDefinition accepts the definition as a JSON object or as a JSON
// string holding one (the config form stores it as text).
func parseCheckDefinition(raw map[string]json.RawMessage) (interfaceCheckConfig, error) {
	value, ok := raw[configCheckKey]
	if !ok {
		value = invocationInputValue(raw, configCheckKey)
	}
	if len(strings.TrimSpace(string(value))) == 0 || string(value) == "null" {
		return interfaceCheckConfig{}, runError("opentext_nom_check_config_invalid")
	}
	var text string
	if json.Unmarshal(value, &text) == nil {
		value = json.RawMessage(text)
	}
	checks, err := parseInterfaceCheckConfig(value)
	if err != nil {
		return interfaceCheckConfig{}, runError("opentext_nom_check_config_invalid")
	}
	return checks, nil
}

func invocationInputValue(raw map[string]json.RawMessage, key string) json.RawMessage {
	var invocation struct {
		InputValues map[string]json.RawMessage `json:"input_values"`
	}
	if json.Unmarshal(raw["action_invocation"], &invocation) != nil {
		return nil
	}
	return invocation.InputValues[key]
}

type targetItemsPayload struct {
	Entity    string           `json:"entity"`
	Total     int              `json:"total"`
	Truncated bool             `json:"truncated"`
	Items     []map[string]any `json:"items"`
}

func parseTargetItems(raw map[string]json.RawMessage) (targetItemsPayload, error) {
	var invocation struct {
		TargetItems *targetItemsPayload `json:"target_items"`
	}
	if json.Unmarshal(raw["action_invocation"], &invocation) != nil || invocation.TargetItems == nil {
		return targetItemsPayload{}, runError("opentext_nom_check_targets_missing")
	}
	if entity := strings.TrimSpace(invocation.TargetItems.Entity); entity != "" && entity != "devices" {
		return targetItemsPayload{}, runError("opentext_nom_check_targets_invalid")
	}
	return *invocation.TargetItems, nil
}

func runConfigCheck(cfg Config, run configCheckRun) error {
	verdicts, err := NewCollector(SDKHTTPDoer{}).runInterfaceChecks(context.Background(), cfg, run.checks, run.items)
	if err != nil {
		return submitPluginError(err)
	}
	result, err := buildConfigCheckResult(verdicts, run.coverage(), cfg.MaxResultBytes)
	if err != nil {
		return submitPluginError(err)
	}
	return sdk.Execute(func() (*sdk.Result, error) { return result, nil })
}

// checkCoverage says how much of the requested target set was actually checked.
type checkCoverage struct {
	Delivered    int  `json:"delivered"`
	Total        int  `json:"total"`
	CoreCapped   bool `json:"core_truncated"`
	NotDelivered int  `json:"not_delivered"`
	Skipped      int  `json:"skipped"`
}

func (r configCheckRun) coverage() checkCoverage {
	coverage := checkCoverage{Delivered: len(r.items), Total: r.total, CoreCapped: r.truncated}
	if r.truncated && r.total > len(r.items) {
		coverage.NotDelivered = r.total - len(r.items)
	}
	return coverage
}

func buildConfigCheckResult(verdicts []checkVerdict, coverage checkCoverage, maxResultBytes int) (*sdk.Result, error) {
	counts := map[string]int{}
	skipped := map[string]bool{}
	for _, verdict := range verdicts {
		counts[verdict.Status]++
		if verdict.Reason == reasonTargetLimitExceeded {
			skipped[verdict.DeviceUID] = true
		}
	}
	coverage.Skipped = len(skipped)
	details, err := json.Marshal(map[string]any{
		"schema":   configCheckResultSchema,
		"source":   "opentext-nom",
		"counts":   counts,
		"coverage": coverage,
		"verdicts": verdicts,
	})
	if err != nil {
		return nil, runError("opentext_nom_result_invalid")
	}
	if len(details) > maxResultBytes {
		return nil, runError("opentext_nom_result_too_large")
	}
	summary := fmt.Sprintf("OpenText NOM interface checks: %d compliant, %d non-compliant, %d unknown",
		counts[checkStatusCompliant], counts[checkStatusNonCompliant], counts[checkStatusUnknown])
	if coverage.Skipped > 0 {
		summary += fmt.Sprintf(", %d endpoints not checked (%s)", coverage.Skipped, reasonTargetLimitExceeded)
	}
	if coverage.NotDelivered > 0 {
		summary += fmt.Sprintf(", %d endpoints not delivered (query matched more than the schedule limit)", coverage.NotDelivered)
	}
	return sdk.Ok(summary).
		WithLabel("source", "opentext-nom").
		WithLabel("kind", "interface_config_check").
		WithDetails(string(details)), nil
}
