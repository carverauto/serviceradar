package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

const maxRetrieveDevices = 32

type RetrieveDevice struct {
	DeviceID  string `json:"device_id"`
	DeviceUID string `json:"device_uid"`
}

func runtimeRetrieveDevices(raw map[string]json.RawMessage) ([]RetrieveDevice, error) {
	encoded, hasDevices := raw["devices"]
	if invocationJSON, ok := raw["action_invocation"]; ok {
		var invocation struct {
			InputValues map[string]json.RawMessage `json:"input_values"`
		}
		if err := json.Unmarshal(invocationJSON, &invocation); err != nil {
			return nil, runError("opentext_nom_config_invocation_invalid")
		}
		if input, present := invocation.InputValues["devices"]; present {
			encoded, hasDevices = input, true
		} else if _, hasID := invocation.InputValues["device_id"]; hasID {
			// A requested single-device action overrides a configured batch.
			hasDevices = false
		} else if _, hasUID := invocation.InputValues["device_uid"]; hasUID {
			hasDevices = false
		}
	}
	var devices []RetrieveDevice
	if hasDevices {
		if err := json.Unmarshal(encoded, &devices); err != nil {
			return nil, runError("opentext_nom_devices_invalid")
		}
	} else {
		id, uid := deviceIdentityFromRaw(raw)
		devices = []RetrieveDevice{{DeviceID: id, DeviceUID: uid}}
	}
	if len(devices) == 0 || len(devices) > maxRetrieveDevices {
		return nil, runError("opentext_nom_devices_invalid")
	}
	ids, uids := make(map[string]bool), make(map[string]bool)
	for i := range devices {
		id, valid := parseDeviceID(devices[i].DeviceID)
		uid := strings.TrimSpace(devices[i].DeviceUID)
		if !valid || uid == "" {
			return nil, runError("opentext_nom_devices_invalid")
		}
		devices[i].DeviceID, devices[i].DeviceUID = strconv.FormatInt(id, 10), uid
		if ids[devices[i].DeviceID] || uids[uid] {
			return nil, runError("opentext_nom_devices_duplicate")
		}
		ids[devices[i].DeviceID], uids[uid] = true, true
	}
	return devices, nil
}

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
	for _, key := range checkOnlyConfigKeys {
		delete(raw, key)
	}

	return json.Marshal(raw)
}

func loadRuntimeActionID() string {
	raw := loadRawConfigMap()
	if raw == nil {
		return ""
	}
	invocationJSON, ok := raw["action_invocation"]
	if !ok || len(bytes.TrimSpace(invocationJSON)) == 0 {
		return ""
	}
	var invocation struct {
		ActionID string `json:"action_id"`
	}
	if err := json.Unmarshal(invocationJSON, &invocation); err != nil {
		return ""
	}
	return strings.TrimSpace(invocation.ActionID)
}

func deviceIdentityFromRaw(raw map[string]json.RawMessage) (deviceID, deviceUID string) {
	if raw == nil {
		return "", ""
	}
	var targetUID string
	if invocationJSON, ok := raw["action_invocation"]; ok && len(bytes.TrimSpace(invocationJSON)) > 0 {
		var invocation struct {
			ActionID    string           `json:"action_id"`
			InputValues map[string]any   `json:"input_values"`
			Targets     []map[string]any `json:"targets"`
		}
		if err := json.Unmarshal(invocationJSON, &invocation); err == nil {
			deviceID = stringFromAny(invocation.InputValues["device_id"])
			deviceUID = stringFromAny(invocation.InputValues["device_uid"])
			if len(invocation.Targets) > 0 {
				targetUID = stringFromAny(invocation.Targets[0]["device_uid"])
			}
		}
	}
	// Per-invocation input wins over the configured default.
	if deviceID == "" {
		deviceID = stringFromRaw(raw, "device_id")
	}
	if deviceUID == "" {
		deviceUID = stringFromRaw(raw, "device_uid")
	}
	if deviceUID == "" {
		deviceUID = targetUID
	}
	return deviceID, deviceUID
}

func loadRawConfigMap() map[string]json.RawMessage {
	var raw map[string]json.RawMessage
	if err := sdk.LoadConfig(&raw); err != nil {
		return nil
	}
	return raw
}

func stringFromRaw(raw map[string]json.RawMessage, key string) string {
	value, ok := raw[key]
	if !ok {
		return ""
	}
	var text string
	if err := json.Unmarshal(value, &text); err != nil {
		return ""
	}
	return strings.TrimSpace(text)
}

func stringFromAny(value any) string {
	text, _ := value.(string)
	return strings.TrimSpace(text)
}
