package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

// configCheckKey is the template section holding the interface check
// definition. The rest of the template is the normal NA connection config.
const configCheckKey = "config_check"

type configCheckRun struct {
	config   Config
	checks   interfaceCheckConfig
	policyID string
	items    []map[string]any
}

func isPluginInputsPayload(raw map[string]json.RawMessage) bool {
	var schema string
	if value, ok := raw["schema"]; ok && json.Unmarshal(value, &schema) == nil {
		return strings.TrimSpace(schema) == sdk.PluginInputsSchemaV1
	}
	return false
}

// parseConfigCheckRun reads a plugin_inputs.v1 payload: connection settings
// and the check definition from its template, targets from its inputs.
func parseConfigCheckRun(raw map[string]json.RawMessage) (configCheckRun, error) {
	encoded, err := json.Marshal(raw)
	if err != nil {
		return configCheckRun{}, runError("opentext_nom_check_inputs_invalid")
	}
	payload, err := sdk.ParsePluginInputsJSON(encoded)
	if err != nil {
		return configCheckRun{}, runError("opentext_nom_check_inputs_invalid")
	}
	cfg, checks, err := splitCheckTemplate(payload.Template)
	if err != nil {
		return configCheckRun{}, err
	}
	run := configCheckRun{config: cfg, checks: checks, policyID: payload.PolicyID}
	for _, item := range payload.FlattenItems() {
		if strings.EqualFold(item.Entity, "devices") {
			run.items = append(run.items, item.Item)
		}
	}
	return run, nil
}

func splitCheckTemplate(template map[string]any) (Config, interfaceCheckConfig, error) {
	if len(template) == 0 {
		return Config{}, interfaceCheckConfig{}, runError("opentext_nom_check_config_invalid")
	}
	connection := make(map[string]any, len(template))
	for key, value := range template {
		if key != configCheckKey {
			connection[key] = value
		}
	}
	checkJSON, err := json.Marshal(template[configCheckKey])
	if err != nil || template[configCheckKey] == nil {
		return Config{}, interfaceCheckConfig{}, runError("opentext_nom_check_config_invalid")
	}
	checks, err := parseInterfaceCheckConfig(checkJSON)
	if err != nil {
		return Config{}, interfaceCheckConfig{}, runError("opentext_nom_check_config_invalid")
	}
	connectionJSON, err := json.Marshal(connection)
	if err != nil {
		return Config{}, interfaceCheckConfig{}, runError("opentext_nom_check_config_invalid")
	}
	cfg, err := ParseConfig(connectionJSON)
	if err != nil {
		return Config{}, interfaceCheckConfig{}, runError(configErrorCode(err))
	}
	return cfg, checks, nil
}

func runConfigCheck(run configCheckRun) error {
	verdicts, err := NewCollector(SDKHTTPDoer{}).runInterfaceChecks(context.Background(), run.config, run.checks, run.items)
	if err != nil {
		return submitPluginError(err)
	}
	result, err := buildConfigCheckResult(run.policyID, verdicts, run.config.MaxResultBytes)
	if err != nil {
		return submitPluginError(err)
	}
	return sdk.Execute(func() (*sdk.Result, error) { return result, nil })
}

func buildConfigCheckResult(policyID string, verdicts []checkVerdict, maxResultBytes int) (*sdk.Result, error) {
	counts := map[string]int{}
	for _, verdict := range verdicts {
		counts[verdict.Status]++
	}
	details, err := json.Marshal(map[string]any{
		"schema":    configCheckResultSchema,
		"source":    "opentext-nom",
		"policy_id": policyID,
		"counts":    counts,
		"verdicts":  verdicts,
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
