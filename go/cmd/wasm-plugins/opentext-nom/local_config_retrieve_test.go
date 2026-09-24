//go:build !tinygo

package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

// TestLocalHostRunsConfigRetrieveAndStagesArtifact drives the real
// config.retrieve action natively: local OAuth broker, list config then masked
// show config
// request, artifact staging into a directory, and the result details.
func TestLocalHostRunsConfigRetrieveAndStagesArtifact(t *testing.T) {
	const token = "local-short-lived-token"

	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/oauth/token":
			response.Header().Set("Content-Type", "application/json")
			_, _ = fmt.Fprintf(response, `{"access_token":%q,"expires_in":300}`, token)
		case "/api/v1/commands":
			var command struct {
				Command    string         `json:"command"`
				Parameters map[string]any `json:"parameters"`
			}
			if err := json.NewDecoder(request.Body).Decode(&command); err != nil {
				response.WriteHeader(http.StatusBadRequest)
				return
			}
			response.Header().Set("Content-Type", "application/json")
			switch {
			case command.Command == listConfigCommand && command.Parameters["deviceid"] == "1001":
				_, _ = fmt.Fprint(response, `[{"deviceDataID":2002,"blockType":"configuration","createDate":"2026-01-01T00:00:00.000Z[UTC]"}]`)
			case command.Command == showConfigCommand && command.Parameters["id"] == "2002" && command.Parameters["mask"] == "":
				_, _ = fmt.Fprintf(response, `{"result":%s}`, jsonString(syntheticIOS))
			default:
				t.Errorf("unexpected command: %#v", command)
				response.WriteHeader(http.StatusBadRequest)
			}
		default:
			response.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()

	configJSON := []byte(fmt.Sprintf(`{
		"instance_id":"local-test",
		"token_url":%q,
		"api_url":%q
	}`, server.URL+"/oauth/token", server.URL+"/api/v1/commands"))
	actionJSON := []byte(`{
		"action_id":"opentext-nom.config.retrieve",
		"input_values":{"device_id":"1001","device_uid":"sr:host01.example.com"}
	}`)
	inputs, err := sdk.LoadLocalInputs(sdk.LocalInputOptions{
		ConfigJSON: configJSON,
		ActionJSON: actionJSON,
		Environment: []string{
			sdk.LocalCredentialPrefix + "USERNAME=local-user",
			sdk.LocalCredentialPrefix + "PASSWORD=local-password",
		},
	})
	if err != nil {
		t.Fatalf("LoadLocalInputs() error = %v", err)
	}
	runtimeConfig, err := inputs.RuntimeConfigJSON()
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := parseLocalRuntimeConfig(runtimeConfig)
	if err != nil {
		t.Fatalf("parseLocalRuntimeConfig() error = %v", err)
	}
	broker, err := newLocalOAuthBroker(cfg, inputs.Credentials(), server.Client())
	if err != nil {
		t.Fatal(err)
	}

	artifactDir := t.TempDir()
	capture, err := sdk.RunLocalHost(sdk.LocalHostOptions{
		ConfigJSON:  runtimeConfig,
		HTTPHandler: broker.Handle,
		ArtifactDir: artifactDir,
	}, runPlugin)
	if err != nil {
		t.Fatalf("RunLocalHost() error = %v", err)
	}
	if safeError := broker.SafeError(); safeError != "" {
		t.Fatalf("local broker error = %s", safeError)
	}

	if len(capture.Artifacts) != 1 {
		t.Fatalf("artifacts = %#v, want one running-config", capture.Artifacts)
	}
	artifact := capture.Artifacts[0]
	body, err := os.ReadFile(artifact.Path)
	if err != nil {
		t.Fatalf("staged artifact not on disk: %v", err)
	}
	if string(body) != syntheticIOS {
		t.Fatalf("staged body = %q", body)
	}
	if artifact.ObjectKey != "opentext-nom/running-config/1001" {
		t.Fatalf("object key = %q", artifact.ObjectKey)
	}

	var result struct {
		Status  string `json:"status"`
		Details string `json:"details"`
	}
	if err := json.Unmarshal(capture.ResultJSON, &result); err != nil {
		t.Fatal(err)
	}
	if result.Status != "OK" {
		t.Fatalf("result status = %q: %s", result.Status, capture.ResultJSON)
	}
	if strings.Contains(result.Details, "GigabitEthernet0/1") {
		t.Fatal("running-config body leaked into result details")
	}
	var details map[string]any
	if err := json.Unmarshal([]byte(result.Details), &details); err != nil {
		t.Fatal(err)
	}
	meta, ok := details["artifact"].(map[string]any)
	if !ok || meta["object_key"] != artifact.ObjectKey || meta["sha256"] != artifact.SHA256 {
		t.Fatalf("details artifact = %#v, capture = %#v", details["artifact"], artifact)
	}
	if details["device_uid"] != "sr:host01.example.com" {
		t.Fatalf("device_uid = %#v", details["device_uid"])
	}
}
