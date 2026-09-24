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
	checks interfaceCheckConfig
	items  []map[string]any
}

// parseConfigCheckRun reads the check definition from the merged plugin config
// and the target devices from the action invocation.
func parseConfigCheckRun(raw map[string]json.RawMessage) (configCheckRun, error) {
	checks, err := parseCheckDefinition(raw)
	if err != nil {
		return configCheckRun{}, err
	}
	items, err := targetItems(raw)
	if err != nil {
		return configCheckRun{}, err
	}
	return configCheckRun{checks: checks, items: items}, nil
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

func targetItems(raw map[string]json.RawMessage) ([]map[string]any, error) {
	var invocation struct {
		TargetItems *struct {
			Entity string           `json:"entity"`
			Items  []map[string]any `json:"items"`
		} `json:"target_items"`
	}
	if json.Unmarshal(raw["action_invocation"], &invocation) != nil || invocation.TargetItems == nil {
		return nil, runError("opentext_nom_check_targets_missing")
	}
	if entity := strings.TrimSpace(invocation.TargetItems.Entity); entity != "" && entity != "devices" {
		return nil, runError("opentext_nom_check_targets_invalid")
	}
	return invocation.TargetItems.Items, nil
}

func runConfigCheck(cfg Config, run configCheckRun) error {
	verdicts, err := NewCollector(SDKHTTPDoer{}).runInterfaceChecks(context.Background(), cfg, run.checks, run.items)
	if err != nil {
		return submitPluginError(err)
	}
	result, err := buildConfigCheckResult(verdicts, cfg.MaxResultBytes)
	if err != nil {
		return submitPluginError(err)
	}
	return sdk.Execute(func() (*sdk.Result, error) { return result, nil })
}

func buildConfigCheckResult(verdicts []checkVerdict, maxResultBytes int) (*sdk.Result, error) {
	counts := map[string]int{}
	for _, verdict := range verdicts {
		counts[verdict.Status]++
	}
	details, err := json.Marshal(map[string]any{
		"schema":   configCheckResultSchema,
		"source":   "opentext-nom",
		"counts":   counts,
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
	return sdk.Ok(summary).
		WithLabel("source", "opentext-nom").
		WithLabel("kind", "interface_config_check").
		WithDetails(string(details)), nil
}
