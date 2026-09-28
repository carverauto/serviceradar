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

// syntheticConfigList mirrors NA's list config shape: oldest revision first,
// plus a non-configuration block that must be ignored.
const syntheticConfigList = `[
  {"deviceDataID":5001,"deviceID":71061,"blockType":"configuration","createDate":"2026-01-02T03:04:05.000Z[UTC]"},
  {"deviceDataID":5009,"deviceID":71061,"blockType":"diagnostic","createDate":"2026-03-01T00:00:00.000Z[UTC]"},
  {"deviceDataID":5007,"deviceID":71061,"blockType":"configuration","createDate":"2026-02-02T03:04:05.000Z[UTC]"}
]`

func decodeCommand(t *testing.T, request HTTPRequest) (string, map[string]any) {
	t.Helper()
	var envelope struct {
		Command    string         `json:"command"`
		Parameters map[string]any `json:"parameters"`
	}
	if err := json.Unmarshal(request.Body, &envelope); err != nil {
		t.Fatal(err)
	}
	return envelope.Command, envelope.Parameters
}

func TestRetrieveRunningConfigReadsNewestMaskedStoredConfig(t *testing.T) {
	httpClient := &fakeHTTPDoer{
		responses: []HTTPResponse{
			{Status: 200, Body: []byte(syntheticConfigList)},
			{Status: 200, Body: []byte(`{"result":` + jsonString(syntheticIOS) + `}`)},
		},
	}
	collector := &Collector{HTTP: httpClient, Now: func() time.Time { return time.Unix(1, 0).UTC() }, Sleep: sleepWithContext}
	cfg := mustValidConfig(t)

	got, err := collector.RetrieveRunningConfig(context.Background(), cfg, "71061", "sr:host01.example.com")
	if err != nil {
		t.Fatalf("RetrieveRunningConfig: %v", err)
	}
	if got.DeviceID != "71061" || got.DeviceUID != "sr:host01.example.com" || got.ConfigID != "5007" {
		t.Fatalf("identity = %#v, want newest configuration revision 5007", got)
	}
	if !strings.Contains(got.Body, "interface GigabitEthernet0/1") || got.Hash == "" {
		t.Fatalf("unexpected body/hash: %#v", got)
	}
	if len(httpClient.requests) != 2 {
		t.Fatalf("requests = %d, want list config then show config", len(httpClient.requests))
	}

	command, params := decodeCommand(t, httpClient.requests[0])
	if command != listConfigCommand || len(params) != 1 || params["deviceid"] != "71061" {
		t.Fatalf("first request = %q %#v", command, params)
	}
	command, params = decodeCommand(t, httpClient.requests[1])
	if command != showConfigCommand || params["id"] != "5007" || len(params) != 2 {
		t.Fatalf("second request = %q %#v", command, params)
	}
	if mask, ok := params["mask"]; !ok || mask != "" {
		t.Fatalf("mask flag = %#v, want an empty-string flag", params["mask"])
	}
	for _, request := range httpClient.requests {
		if command, _ := decodeCommand(t, request); command == "show running-config" || command == "show device config" {
			t.Fatalf("config retrieve sent %q; it must only read NA's masked stored config", command)
		}
	}
}

func TestNewestStoredConfigIDHandlesEnvelopesAndEmptyLists(t *testing.T) {
	wrapped := `{"result":` + syntheticConfigList + `}`
	if id, err := newestStoredConfigID([]byte(wrapped)); err != nil || id != "5007" {
		t.Fatalf("wrapped list: id=%q err=%v", id, err)
	}
	sameDate := `[
	  {"deviceDataID":10,"blockType":"configuration","createDate":"2026-01-01T00:00:00.000Z[UTC]"},
	  {"deviceDataID":12,"blockType":"configuration","createDate":"2026-01-01T00:00:00.000Z[UTC]"}
	]`
	if id, err := newestStoredConfigID([]byte(sameDate)); err != nil || id != "12" {
		t.Fatalf("tie on date: id=%q err=%v, want the higher revision", id, err)
	}
	for name, body := range map[string]string{
		"empty list":       `[]`,
		"no configuration": `[{"deviceDataID":3,"blockType":"diagnostic","createDate":"2026-01-01T00:00:00.000Z[UTC]"}]`,
		"not a list":       `{"message":"nope"}`,
	} {
		if _, err := newestStoredConfigID([]byte(body)); err == nil {
			t.Fatalf("%s: expected an error", name)
		}
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
		"json string scalar":     jsonString(syntheticIOS),
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
		"empty string":    `""`,
		"json array":      `[]`,
		"json null":       `null`,
		"json number":     `42`,
		"json boolean":    `true`,
		"html error page": `<html><body>Bad Gateway</body></html>`,
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
