package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func loadRuntimeConfig() (Config, error) {
	var raw map[string]json.RawMessage
	if err := sdk.LoadConfig(&raw); err != nil {
		return Config{}, runError("opentext_nom_config_read_failed")
	}
	payload, err := runtimeConfigPayload(raw)
	if err != nil {
		return Config{}, runError("opentext_nom_config_invocation_invalid")
	}
	cfg, err := ParseConfig(payload)
	if err != nil {
		return Config{}, runError(configErrorCode(err))
	}
	return cfg, nil
}

func configErrorCode(err error) string {
	message := err.Error()
	classifications := []struct {
		fragment string
		code     string
	}{
		{"instance_id", "opentext_nom_config_instance_invalid"},
		{"nnm_url", "opentext_nom_config_nnm_url_invalid"},
		{"token_url", "opentext_nom_config_token_url_invalid"},
		{"api_url", "opentext_nom_config_api_url_invalid"},
		{"must match nnm_url", "opentext_nom_config_token_url_mismatch"},
		{"queries must contain", "opentext_nom_config_query_count_invalid"},
		{"name is invalid", "opentext_nom_config_query_name_invalid"},
		{"name is duplicated", "opentext_nom_config_query_name_duplicate"},
		{"parameters must not be empty", "opentext_nom_config_query_parameters_empty"},
		{"must be a string", "opentext_nom_config_query_string_invalid"},
		{"must be boolean", "opentext_nom_config_query_boolean_invalid"},
		{"integer array", "opentext_nom_config_query_ids_invalid"},
		{"is not allowed", "opentext_nom_config_query_filter_not_allowed"},
		{"invalid string", "opentext_nom_config_query_string_value_invalid"},
		{"parameter", "opentext_nom_config_query_parameter_invalid"},
		{"queries", "opentext_nom_config_queries_invalid"},
		{"max_rows", "opentext_nom_config_max_rows_invalid"},
		{"page_size", "opentext_nom_config_page_size_invalid"},
		{"max_result_bytes", "opentext_nom_config_result_limit_invalid"},
		{"request_timeout_seconds", "opentext_nom_config_timeout_invalid"},
		{"max_retries", "opentext_nom_config_retries_invalid"},
		{"trailing data", "opentext_nom_config_trailing_data"},
	}
	for _, classification := range classifications {
		if strings.Contains(message, classification.fragment) {
			return classification.code
		}
	}
	return "opentext_nom_config_decode_failed"
}

func runtimeConfigPayload(raw map[string]json.RawMessage) ([]byte, error) {
	if raw == nil {
		return nil, errors.New("runtime configuration is missing")
	}
	if invocationJSON, ok := raw["action_invocation"]; ok && len(bytes.TrimSpace(invocationJSON)) > 0 {
		var invocation struct {
			InputValues map[string]json.RawMessage `json:"input_values"`
		}
		if err := json.Unmarshal(invocationJSON, &invocation); err != nil {
			return nil, errors.New("action invocation is invalid")
		}
		for key, value := range invocation.InputValues {
			raw[key] = value
		}
	}
	delete(raw, "action_invocation")
	delete(raw, "plugin_config")
	delete(raw, "plugin_config_base64")

	return json.Marshal(raw)
}
