//go:build !tinygo

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func TestConfigRetrieveBatchLifecycle(t *testing.T) {
	for _, tc := range []struct {
		name              string
		devices           string
		configuredDevices string
		inputValues       string
		retrieveFailure   bool
		stageFailure      bool
		wantArtifacts     int
		wantStatus        string
		wantCalls         int
	}{
		{name: "complete batch", wantArtifacts: 2, wantStatus: "OK", wantCalls: 4},
		{name: "single action overrides empty configured batch", configuredDevices: `[]`, inputValues: `{"device_id":"1001","device_uid":"sr:host01.example.com"}`, wantArtifacts: 1, wantStatus: "OK", wantCalls: 2},
		{name: "single action overrides configured batch", configuredDevices: `[{"device_id":"1002","device_uid":"sr:host02.example.com"}]`, inputValues: `{"device_id":"1001","device_uid":"sr:host01.example.com"}`, wantArtifacts: 1, wantStatus: "OK", wantCalls: 2},
		{name: "second retrieval fails before staging", retrieveFailure: true, wantStatus: "CRITICAL", wantCalls: 3},
		{name: "partial staging reports committed references", stageFailure: true, wantArtifacts: 1, wantStatus: "CRITICAL", wantCalls: 4},
		{name: "invalid second device", devices: `[{"device_id":"1001","device_uid":"sr:host01.example.com"},{"device_id":"../1002","device_uid":"sr:host02.example.com"}]`, wantStatus: "CRITICAL"},
		{name: "duplicate numeric alias", devices: `[{"device_id":"1001","device_uid":"sr:host01.example.com"},{"device_id":"01001","device_uid":"sr:host02.example.com"}]`, wantStatus: "CRITICAL"},
		{name: "empty explicit batch", devices: `[]`, wantStatus: "CRITICAL"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			devices := tc.devices
			if devices == "" {
				devices = `[{"device_id":"1001","device_uid":"sr:host01.example.com"},{"device_id":"1002","device_uid":"sr:host02.example.com"}]`
			}
			inputs := tc.inputValues
			if inputs == "" {
				inputs = fmt.Sprintf(`{"devices":%s}`, devices)
			}
			configured := ""
			if tc.configuredDevices != "" {
				configured = `,"devices":` + tc.configuredDevices
			}
			config := []byte(fmt.Sprintf(`{"instance_id":"nom-test","api_url":"https://nom.example.com/api/v1/commands","max_retries":0%s,"action_invocation":{"action_id":"opentext-nom.config.retrieve","input_values":%s}}`, configured, inputs))
			dir := t.TempDir()
			if tc.stageFailure {
				if err := os.MkdirAll(filepath.Join(dir, "opentext-nom/running-config"), 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(dir, "opentext-nom/running-config/1002"), []byte("synthetic blocked parent"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			calls := 0
			capture, err := sdk.RunLocalHost(sdk.LocalHostOptions{
				ConfigJSON: config, ArtifactDir: dir,
				HTTPHandler: func(_ context.Context, req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
					calls++
					if _, err := os.Stat(filepath.Join(dir, "opentext-nom/running-config/1001")); !os.IsNotExist(err) {
						t.Fatal("first artifact staged before all device retrievals finished")
					}
					var command struct {
						Command    string         `json:"command"`
						Parameters map[string]any `json:"parameters"`
					}
					if err := json.Unmarshal(req.Body, &command); err != nil {
						t.Fatal(err)
					}
					switch command.Command {
					case listConfigCommand:
						id := command.Parameters["deviceid"]
						if tc.retrieveFailure && id == "1002" {
							return &sdk.HTTPResponse{Status: 400}, nil
						}
						configID := 2001
						if id == "1002" {
							configID = 2002
						}
						return &sdk.HTTPResponse{Status: 200, Body: []byte(fmt.Sprintf(`[{"deviceDataID":%d,"blockType":"configuration","createDate":"2026-01-01T00:00:00Z"}]`, configID))}, nil
					case showConfigCommand:
						if command.Parameters["mask"] != "" {
							t.Fatal("stored config must be masked")
						}
						return &sdk.HTTPResponse{Status: 200, Body: []byte(fmt.Sprintf(`{"result":%s}`, jsonString(syntheticIOS)))}, nil
					default:
						t.Fatalf("unexpected command %q", command.Command)
					}
					return nil, fmt.Errorf("unexpected command")
				},
			}, runPlugin)
			if err != nil {
				t.Fatal(err)
			}
			if calls != tc.wantCalls {
				t.Fatalf("NOM requests = %d, want %d", calls, tc.wantCalls)
			}
			if len(capture.Artifacts) != tc.wantArtifacts {
				t.Fatalf("committed artifacts = %d, want %d", len(capture.Artifacts), tc.wantArtifacts)
			}
			var result sdk.Result
			if err := json.Unmarshal(capture.ResultJSON, &result); err != nil {
				t.Fatal(err)
			}
			if string(result.Status) != tc.wantStatus {
				t.Fatalf("status = %q, want %q", result.Status, tc.wantStatus)
			}
			if strings.Contains(result.Details, "GigabitEthernet0/1") {
				t.Fatal("config body leaked into status details")
			}
			if tc.wantArtifacts > 0 {
				var details struct {
					Complete bool `json:"complete"`
					Artifact struct {
						Key string `json:"object_key"`
					} `json:"artifact"`
					Configs []struct {
						Artifact struct {
							Key string `json:"object_key"`
						} `json:"artifact"`
					} `json:"running_configs"`
				}
				if err := json.Unmarshal([]byte(result.Details), &details); err != nil {
					t.Fatal(err)
				}
				if tc.inputValues != "" {
					if details.Artifact.Key != capture.Artifacts[0].ObjectKey || !strings.HasPrefix(details.Artifact.Key, "opentext-nom/running-config/1001/") {
						t.Fatal("single invocation did not select the requested device")
					}
					return
				}
				if details.Complete == tc.stageFailure {
					t.Fatal("incorrect batch completion status")
				}
				if len(details.Configs) != tc.wantArtifacts {
					t.Fatal("committed reference missing from result")
				}
				for i, entry := range details.Configs {
					if entry.Artifact.Key != capture.Artifacts[i].ObjectKey {
						t.Fatal("wrong committed reference")
					}
				}
			}
		})
	}
}
