package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

const syntheticIOS = `
!
hostname host01.example.com
!
interface GigabitEthernet0/1
 description Uplink to core
 ip address 192.0.2.1 255.255.255.0
 no shutdown
!
`

func TestRetrieveRunningConfigPostsShowRunningConfigNotListDevice(t *testing.T) {
	httpClient := &fakeHTTPDoer{
		responses: []HTTPResponse{{
			Status: 200,
			Body:   []byte(`{"config":` + jsonString(syntheticIOS) + `}`),
		}},
	}
	collector := &Collector{HTTP: httpClient, Now: func() time.Time { return time.Unix(1, 0).UTC() }, Sleep: sleepWithContext}
	cfg := mustValidConfig(t)

	got, err := collector.RetrieveRunningConfig(context.Background(), cfg, "71061", "sr:host01.example.com")
	if err != nil {
		t.Fatalf("RetrieveRunningConfig: %v", err)
	}
	if got.DeviceID != "71061" || got.DeviceUID != "sr:host01.example.com" {
		t.Fatalf("identity = %#v", got)
	}
	if !strings.Contains(got.Body, "interface GigabitEthernet0/1") {
		t.Fatalf("body missing invented interface stanza")
	}
	if got.Hash == "" {
		t.Fatal("expected content hash")
	}
	if len(httpClient.requests) != 1 {
		t.Fatalf("requests = %d", len(httpClient.requests))
	}
	var envelope map[string]any
	if err := json.Unmarshal(httpClient.requests[0].Body, &envelope); err != nil {
		t.Fatal(err)
	}
	if envelope["command"] != runningConfigCommand {
		t.Fatalf("command = %#v, want %q", envelope["command"], runningConfigCommand)
	}
	if envelope["command"] == "list device" {
		t.Fatal("config retrieve must not use list device")
	}
}

func TestRetrieveRunningConfigRequiresDeviceUID(t *testing.T) {
	httpClient := &fakeHTTPDoer{}
	collector := &Collector{HTTP: httpClient, Now: func() time.Time { return time.Unix(1, 0).UTC() }, Sleep: sleepWithContext}

	_, err := collector.RetrieveRunningConfig(context.Background(), mustValidConfig(t), "71061", "  ")
	if err == nil || !strings.Contains(err.Error(), "opentext_nom_config_device_uid_invalid") {
		t.Fatalf("err = %v, want opentext_nom_config_device_uid_invalid", err)
	}
	if len(httpClient.requests) != 0 {
		t.Fatalf("requests = %d, want none before identity is valid", len(httpClient.requests))
	}
}

func TestRetrieveRunningConfigDoesNotEmitInterfaceFacts(t *testing.T) {
	result := buildConfigRetrieveResult(RunningConfig{
		DeviceID:  "71061",
		DeviceUID: "sr:host01.example.com",
		Body:      syntheticIOS,
		Hash:      "abc",
	}, nil)
	if result == nil {
		t.Fatal("nil result")
	}
	if len(result.DeviceDiscovery) != 0 {
		t.Fatalf("plugin must not emit device discovery from config retrieve: %#v", result.DeviceDiscovery)
	}
	if strings.Contains(result.Summary, "vlan") {
		t.Fatal("plugin must not parse config facts")
	}
}

func TestDecodeRunningConfigBodyUnwrapsAutomationEnvelope(t *testing.T) {
	cases := map[string]string{
		"top-level config":       `{"config":` + jsonString(syntheticIOS) + `}`,
		"result string":          `{"result":` + jsonString(syntheticIOS) + `}`,
		"result object output":   `{"result":{"output":` + jsonString(syntheticIOS) + `}}`,
		"data object config":     `{"data":{"config":` + jsonString(syntheticIOS) + `}}`,
		"plain text, no wrapper": syntheticIOS,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			got, err := decodeRunningConfigBody([]byte(body))
			if err != nil {
				t.Fatalf("decodeRunningConfigBody: %v", err)
			}
			if !strings.Contains(got, "interface GigabitEthernet0/1") {
				t.Fatalf("decoded body = %q", got)
			}
		})
	}

	for name, body := range map[string]string{
		"empty result":    `{"result":""}`,
		"unknown wrapper": `{"result":{"rows":[]}}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeRunningConfigBody([]byte(body)); err == nil {
				t.Fatal("expected opentext_nom_config_invalid")
			}
		})
	}
}

func TestConfigRetrieveResultCarriesArtifactNotBody(t *testing.T) {
	result := buildConfigRetrieveResult(RunningConfig{
		DeviceID:  "71061",
		DeviceUID: "sr:host01.example.com",
		Body:      syntheticIOS,
		Hash:      "abc",
	}, &sdk.ArtifactCommitResponse{
		ObjectKey:   "agent-artifacts/agent-01/assign-01/opentext-nom/running-config/71061",
		ContentType: "text/plain",
		SHA256:      "abc",
		SizeBytes:   int64(len(syntheticIOS)),
	})

	var details map[string]any
	if err := json.Unmarshal([]byte(result.Details), &details); err != nil {
		t.Fatal(err)
	}
	if _, exists := details["body"]; exists {
		t.Fatal("running-config body must not be embedded in status details")
	}
	if strings.Contains(result.Details, "GigabitEthernet0/1") {
		t.Fatal("running-config content leaked into status details")
	}
	artifact, ok := details["artifact"].(map[string]any)
	if !ok || artifact["object_key"] == "" || artifact["sha256"] != "abc" {
		t.Fatalf("artifact reference = %#v", details["artifact"])
	}
}

func jsonString(value string) string {
	encoded, _ := json.Marshal(value)
	return string(encoded)
}

func mustValidConfig(t *testing.T) Config {
	t.Helper()
	cfg, err := ParseConfig([]byte(`{
		"instance_id":"na-lab",
		"api_url":"https://na.example.com/nom/api/automation/v1/wrapper",
		"queries":[{"name":"switches","parameters":{"type":"Switch"}}]
	}`))
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}
