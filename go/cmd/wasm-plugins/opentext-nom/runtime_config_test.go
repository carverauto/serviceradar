package main

import (
	"encoding/json"
	"testing"
)

func TestRuntimeConfigPayloadPreservesSettingsAndDropsInvocation(t *testing.T) {
	var raw map[string]json.RawMessage
	err := json.Unmarshal([]byte(`{
        "instance_id":"lab-network-automation",
        "token_url":"https://network-automation.example/oauth/token",
        "api_url":"https://network-automation.example/api/v1/commands",
        "page_size":100,
        "max_rows":1000,
        "action_invocation":{
          "credential_brokers":[{"credential_secret_ref":"secret"}],
          "input_values":{"queries":[{"name":"switches","parameters":{"type":"Switch"}}]}
        }
      }`), &raw)
	if err != nil {
		t.Fatal(err)
	}

	payload, err := runtimeConfigPayload(raw)
	if err != nil {
		t.Fatalf("runtimeConfigPayload() error = %v", err)
	}
	var normalized map[string]json.RawMessage
	if err := json.Unmarshal(payload, &normalized); err != nil {
		t.Fatal(err)
	}
	if _, exists := normalized["action_invocation"]; exists {
		t.Fatal("action_invocation leaked into plugin configuration")
	}
	if string(normalized["page_size"]) != "100" {
		t.Fatalf("page_size = %s, want exact integer", normalized["page_size"])
	}
	if _, err := ParseConfig(payload); err != nil {
		t.Fatalf("ParseConfig() error = %v", err)
	}
}

func TestRuntimeConfigPayloadRejectsInvalidInvocation(t *testing.T) {
	raw := map[string]json.RawMessage{
		"action_invocation": json.RawMessage(`"invalid"`),
	}
	if _, err := runtimeConfigPayload(raw); err == nil {
		t.Fatal("expected invalid action invocation to fail")
	}
}

func TestRuntimeConfigPayloadAcceptsConfigRetrieveDeviceIdentity(t *testing.T) {
	var raw map[string]json.RawMessage
	err := json.Unmarshal([]byte(`{
        "instance_id":"lab-network-automation",
        "token_url":"https://network-automation.example/oauth/token",
        "api_url":"https://network-automation.example/api/v1/commands",
        "action_invocation":{
          "action_id":"opentext-nom.config.retrieve",
          "input_values":{"device_id":"1001","device_uid":"sr:host01.example.com"}
        }
      }`), &raw)
	if err != nil {
		t.Fatal(err)
	}

	payload, err := runtimeConfigPayload(raw)
	if err != nil {
		t.Fatalf("runtimeConfigPayload() error = %v", err)
	}
	cfg, err := ParseConfig(payload)
	if err != nil {
		t.Fatalf("ParseConfig() error = %v", err)
	}
	if cfg.DeviceID != "1001" || cfg.DeviceUID != "sr:host01.example.com" {
		t.Fatalf("device identity = (%q, %q)", cfg.DeviceID, cfg.DeviceUID)
	}
}

func TestDeviceIdentityFromRawPrefersInvocationInput(t *testing.T) {
	cases := []struct {
		name    string
		raw     string
		wantID  string
		wantUID string
	}{
		{
			name: "invocation input overrides configured default",
			raw: `{"device_id":"1001","device_uid":"sr:host01.example.com",
              "action_invocation":{"input_values":{"device_id":"1002","device_uid":"sr:host02.example.com"}}}`,
			wantID:  "1002",
			wantUID: "sr:host02.example.com",
		},
		{
			name:    "configured default when invocation omits identity",
			raw:     `{"device_id":"1001","device_uid":"sr:host01.example.com","action_invocation":{"input_values":{}}}`,
			wantID:  "1001",
			wantUID: "sr:host01.example.com",
		},
		{
			name:    "target uid is the last fallback",
			raw:     `{"action_invocation":{"input_values":{"device_id":"1003"},"targets":[{"device_uid":"sr:host03.example.com"}]}}`,
			wantID:  "1003",
			wantUID: "sr:host03.example.com",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var raw map[string]json.RawMessage
			if err := json.Unmarshal([]byte(tc.raw), &raw); err != nil {
				t.Fatal(err)
			}
			gotID, gotUID := deviceIdentityFromRaw(raw)
			if gotID != tc.wantID || gotUID != tc.wantUID {
				t.Fatalf("identity = (%q, %q), want (%q, %q)", gotID, gotUID, tc.wantID, tc.wantUID)
			}
		})
	}
}
