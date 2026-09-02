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
