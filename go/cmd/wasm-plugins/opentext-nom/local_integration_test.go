//go:build !tinygo

package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func TestLocalHostRunsCollectorWithActionInputAndBrokeredCredentials(t *testing.T) {
	const (
		username = "local-integration-user"
		password = "local-integration-password"
		token    = "local-short-lived-token"
	)

	var mu sync.Mutex
	tokenRequests := 0
	apiRequests := 0
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch request.URL.Path {
		case "/oauth/token":
			tokenRequests++
			if err := request.ParseForm(); err != nil {
				t.Errorf("ParseForm() error = %v", err)
				response.WriteHeader(http.StatusBadRequest)
				return
			}
			if request.Form.Get("username") != username || request.Form.Get("password") != password ||
				request.Form.Get("grant_type") != "password" {
				t.Error("token request did not receive the local host credential form")
				response.WriteHeader(http.StatusUnauthorized)
				return
			}
			response.Header().Set("Content-Type", "application/json")
			_, _ = fmt.Fprintf(response, `{"access_token":%q,"expires_in":300}`, token)
		case "/api/v1/commands":
			apiRequests++
			if request.Header.Get("Authorization") != "Bearer "+token {
				t.Error("upstream request did not receive the host-owned bearer token")
				response.WriteHeader(http.StatusUnauthorized)
				return
			}
			var command struct {
				Command    string         `json:"command"`
				Parameters map[string]any `json:"parameters"`
			}
			if err := json.NewDecoder(request.Body).Decode(&command); err != nil {
				t.Errorf("decode command: %v", err)
				response.WriteHeader(http.StatusBadRequest)
				return
			}
			if command.Command != "list device" || command.Parameters["vendor"] != "Cisco" {
				t.Errorf("unexpected command: %#v", command)
			}
			response.Header().Set("Content-Type", "application/json")
			_, _ = response.Write([]byte(`[{"deviceID":1,"hostName":"ORD-ASW001","primaryIPAddress":"10.0.0.1","serialNumber":"SER-1","vendor":"Cisco","model":"Nexus 9300","deviceType":"Switch","siteName":"ORD","managementStatus":"Managed","excludeFromPoll":false}]`))
		default:
			response.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()

	configJSON := []byte(fmt.Sprintf(`{
		"instance_id":"local-test",
		"token_url":%q,
		"api_url":%q,
		"page_size":100,
		"max_rows":1000
	}`, server.URL+"/oauth/token", server.URL+"/api/v1/commands"))
	actionJSON := []byte(`{
		"schema":"serviceradar.northbound_action_invocation.v1",
		"invocation_id":"local-run-1",
		"action_id":"collect_inventory",
		"input_values":{"queries":[{"name":"cisco","parameters":{"vendor":"Cisco"}}]}
	}`)
	inputs, err := sdk.LoadLocalInputs(sdk.LocalInputOptions{
		ConfigJSON: configJSON,
		ActionJSON: actionJSON,
		Environment: []string{
			sdk.LocalCredentialPrefix + "USERNAME=" + username,
			sdk.LocalCredentialPrefix + "PASSWORD=" + password,
		},
	})
	if err != nil {
		t.Fatalf("LoadLocalInputs() error = %v", err)
	}
	runtimeConfig, err := inputs.RuntimeConfigJSON()
	if err != nil {
		t.Fatalf("RuntimeConfigJSON() error = %v", err)
	}
	cfg, err := parseLocalRuntimeConfig(runtimeConfig)
	if err != nil {
		t.Fatalf("parseLocalRuntimeConfig() error = %v", err)
	}
	broker, err := newLocalOAuthBroker(cfg, inputs.Credentials(), server.Client())
	if err != nil {
		t.Fatalf("newLocalOAuthBroker() error = %v", err)
	}

	capture, err := sdk.RunLocalHost(sdk.LocalHostOptions{
		ConfigJSON:  runtimeConfig,
		HTTPHandler: broker.Handle,
	}, runPlugin)
	if err != nil {
		t.Fatalf("RunLocalHost() error = %v", err)
	}
	if safeError := broker.SafeError(); safeError != "" {
		t.Fatalf("local broker error = %s", safeError)
	}
	mu.Lock()
	gotTokenRequests, gotAPIRequests := tokenRequests, apiRequests
	mu.Unlock()
	if gotTokenRequests != 1 || gotAPIRequests != 1 {
		t.Fatalf("request counts = token %d, API %d", gotTokenRequests, gotAPIRequests)
	}

	payload := string(capture.ResultJSON)
	for _, secret := range []string{username, password, token} {
		if strings.Contains(payload, secret) {
			t.Fatalf("local result leaked credential material: %s", payload)
		}
	}
	if !strings.Contains(payload, `"device_id":"1"`) ||
		!strings.Contains(payload, `"source":"opentext-nom"`) {
		t.Fatalf("local result did not contain the inventory snapshot: %s", payload)
	}
}

func TestLocalOAuthBrokerRejectsMismatchedUpstreamBeforeTokenExchange(t *testing.T) {
	tokenRequests := 0
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		tokenRequests++
		response.WriteHeader(http.StatusInternalServerError)
	}))
	defer server.Close()

	cfg := validTestConfig()
	cfg.TokenURL = server.URL + "/oauth/token"
	cfg.APIURL = server.URL + "/api/v1/commands"
	broker, err := newLocalOAuthBroker(cfg, map[string]string{
		"username": "user",
		"password": "password",
	}, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	_, err = broker.Handle(t.Context(), sdk.HTTPRequest{
		Method: http.MethodPost,
		URL:    server.URL + "/different",
	})
	if err == nil || broker.SafeError() != "opentext_nom_local_target_denied" {
		t.Fatalf("mismatched target error = %v, code = %s", err, broker.SafeError())
	}
	if tokenRequests != 0 {
		t.Fatalf("mismatched target performed %d token exchanges", tokenRequests)
	}
}

func TestLocalOAuthBrokerDisablesTokenRedirects(t *testing.T) {
	redirectTargetCalls := 0
	server := httptest.NewTLSServer(nil)
	server.Config.Handler = http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/oauth/token":
			http.Redirect(response, request, server.URL+"/capture", http.StatusTemporaryRedirect)
		case "/capture":
			redirectTargetCalls++
			response.WriteHeader(http.StatusNoContent)
		default:
			response.WriteHeader(http.StatusNotFound)
		}
	})
	defer server.Close()

	cfg := validTestConfig()
	cfg.TokenURL = server.URL + "/oauth/token"
	cfg.APIURL = server.URL + "/api/v1/commands"
	broker, err := newLocalOAuthBroker(cfg, map[string]string{
		"username": "user",
		"password": "password",
	}, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	_, err = broker.Handle(t.Context(), sdk.HTTPRequest{Method: http.MethodPost, URL: cfg.APIURL})
	if err == nil || broker.SafeError() != "opentext_nom_local_token_exchange_failed" {
		t.Fatalf("redirect error = %v, code = %s", err, broker.SafeError())
	}
	if redirectTargetCalls != 0 {
		t.Fatalf("token redirect target received %d requests", redirectTargetCalls)
	}
}
