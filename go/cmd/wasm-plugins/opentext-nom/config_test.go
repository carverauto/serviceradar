package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
)

func TestConfigFixtures(t *testing.T) {
	tests := []struct {
		path    string
		wantErr bool
	}{
		{path: "testdata/config-valid-default.json"},
		{path: "testdata/config-valid-nnm-origin.json"},
		{path: "testdata/config-valid-direct-na.json"},
		{path: "testdata/config-valid-multiple-queries.json"},
		{path: "testdata/config-invalid-command.json", wantErr: true},
		{path: "testdata/config-invalid-context.json", wantErr: true},
	}
	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			payload, err := os.ReadFile(test.path)
			if err != nil {
				t.Fatal(err)
			}
			_, err = ParseConfig(payload)
			if (err != nil) != test.wantErr {
				t.Fatalf("ParseConfig() error = %v, wantErr = %t", err, test.wantErr)
			}
		})
	}
}

func TestParseConfigInsecureSkipVerify(t *testing.T) {
	cfg, err := ParseConfig([]byte(`{
		"instance_id":"network-automation-prod",
		"nnm_url":"https://nnm.example.com:443",
		"api_url":"https://na.example.com/nom/api/automation/v1/wrapper",
		"insecure_skip_verify":true
	}`))
	if err != nil {
		t.Fatalf("ParseConfig() error = %v", err)
	}
	if !cfg.InsecureSkipVerify {
		t.Fatal("InsecureSkipVerify = false, want true")
	}
}

func TestParseConfigAppliesSafeSwitchDefaults(t *testing.T) {
	cfg, err := ParseConfig([]byte(`{
		"instance_id":"network-automation-prod",
        "token_url":"https://nnm.example.com/idp/oauth2/token",
        "api_url":"https://na.example.com/nom/api/automation/v1/wrapper"
    }`))
	if err != nil {
		t.Fatalf("ParseConfig() error = %v", err)
	}
	if len(cfg.Queries) != 1 || cfg.Queries[0].Name != "switches" {
		t.Fatalf("unexpected default queries: %#v", cfg.Queries)
	}
	if got := cfg.Queries[0].Parameters["type"]; got != "Switch" {
		t.Fatalf("default type = %#v, want Switch", got)
	}
	if cfg.PageSize != 1000 || cfg.MaxRows != 25000 || cfg.MaxResultBytes != 10*1024*1024 {
		t.Fatalf("unexpected bounds: %#v", cfg)
	}
}

func TestParseConfigDistinguishesExplicitValuesFromDefaults(t *testing.T) {
	base := `{
		"instance_id":"network-automation-prod",
        "token_url":"https://nnm.example.com/idp/oauth2/token",
        "api_url":"https://na.example.com/nom/api/automation/v1/wrapper",
        %s
    }`

	cfg, err := ParseConfig([]byte(fmt.Sprintf(base, `"max_retries":0`)))
	if err != nil {
		t.Fatalf("ParseConfig(max_retries=0) error = %v", err)
	}
	if cfg.MaxRetries != 0 {
		t.Fatalf("MaxRetries = %d, want explicit 0", cfg.MaxRetries)
	}

	invalid := []string{
		`"queries":[]`,
		`"page_size":0`,
		`"max_rows":0`,
		`"max_result_bytes":null`,
	}
	for _, field := range invalid {
		if _, err := ParseConfig([]byte(fmt.Sprintf(base, field))); err == nil {
			t.Fatalf("ParseConfig(%s) unexpectedly succeeded", field)
		}
	}
}

func TestConfigAllowsEveryApprovedFilter(t *testing.T) {
	parameters := map[string]any{
		"software":     "IOS",
		"vendor":       "Cisco",
		"type":         "Switch",
		"model":        "Nexus",
		"family":       "Cisco NX-OS",
		"group":        "Campus",
		"hierarchy":    "Global/Switches",
		"host":         "sw",
		"ip":           "10.0.0.1",
		"realm":        "Default",
		"vtpdomain":    "EXAMPLE",
		"disabled":     false,
		"pollexcluded": false,
		"ids":          []any{json.Number("1"), json.Number("2")},
		"context":      "default",
	}
	cfg := validTestConfig()
	cfg.Queries = []Query{{Name: "all-approved", Parameters: parameters}}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() error = %v", err)
	}
}

func TestParseConfigDecodesQueryParametersWithoutDynamicJSONValues(t *testing.T) {
	cfg, err := ParseConfig([]byte(`{
		"instance_id":"network-automation-prod",
        "token_url":"https://nnm.example/token",
        "api_url":"https://na.example/wrapper",
        "queries":[{
          "name":"switches",
          "parameters":{"type":"Switch","disabled":false,"ids":[1,2]}
        }]
      }`))
	if err != nil {
		t.Fatalf("ParseConfig() error = %v", err)
	}
	parameters := cfg.Queries[0].Parameters
	if parameters["type"] != "Switch" || parameters["disabled"] != false {
		t.Fatalf("unexpected decoded parameters: %#v", parameters)
	}
	ids, ok := parameters["ids"].([]any)
	if !ok || len(ids) != 2 {
		t.Fatalf("decoded ids = %#v, want two values", parameters["ids"])
	}
}

func TestConfigRejectsUnsafeParameters(t *testing.T) {
	tests := []struct {
		name       string
		parameters map[string]any
		want       string
	}{
		{name: "command", parameters: map[string]any{"command": "delete device"}, want: "not allowed"},
		{name: "startid", parameters: map[string]any{"startid": 1}, want: "not allowed"},
		{name: "limitcount", parameters: map[string]any{"limitcount": 10}, want: "not allowed"},
		{name: "nested", parameters: map[string]any{"type": map[string]any{"value": "Switch"}}, want: "must be a string"},
		{name: "context without ip", parameters: map[string]any{"context": "default"}, want: "requires"},
		{name: "ids type", parameters: map[string]any{"ids": "1,2"}, want: "must be an array"},
		{name: "control character", parameters: map[string]any{"host": "sw\nnext"}, want: "invalid string"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cfg := validTestConfig()
			cfg.Queries = []Query{{Name: "unsafe", Parameters: test.parameters}}
			err := cfg.Validate()
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Validate() error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestParseConfigRejectsUnknownAndTrailingData(t *testing.T) {
	base := `{"instance_id":"prod","token_url":"https://nnm.example/token","api_url":"https://na.example/wrapper"}`
	if _, err := ParseConfig([]byte(strings.TrimSuffix(base, "}") + `,"password":"secret"}`)); err == nil {
		t.Fatal("expected unknown field to fail")
	}
	if _, err := ParseConfig([]byte(base + `{}`)); err == nil {
		t.Fatal("expected trailing data to fail")
	}
}

func TestConfigRejectsEndpointAndBoundViolations(t *testing.T) {
	cfg := validTestConfig()
	cfg.TokenURL = "http://nnm.example/token"
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected non-HTTPS token URL to fail")
	}

	cfg = validTestConfig()
	cfg.APIURL = "https://user:secret@na.example/wrapper"
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected URL userinfo to fail")
	}

	for _, endpoint := range []string{
		"https://na.example/",
		"https://na.example/wrapper/",
		"https://na.example:70000/wrapper",
		"https://na.example/wrapper%2Fchild",
	} {
		cfg = validTestConfig()
		cfg.APIURL = endpoint
		if err := cfg.Validate(); err == nil {
			t.Fatalf("expected API URL %q to fail", endpoint)
		}
	}

	cfg = validTestConfig()
	cfg.PageSize = 5001
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected excessive page size to fail")
	}

	cfg = validTestConfig()
	cfg.MaxRows = cfg.PageSize - 1
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected max_rows below page_size to fail")
	}
}

func TestParseConfigDerivesNNMAndDirectTokenEndpoints(t *testing.T) {
	nnm, err := ParseConfig([]byte(`{
		"instance_id":"network-automation-prod",
		"nnm_url":"https://nnm.example.com:443",
		"api_url":"https://na.example.com/nom/api/automation/v1/wrapper"
	}`))
	if err != nil {
		t.Fatalf("ParseConfig(nnm) error = %v", err)
	}
	if nnm.TokenURL != "https://nnm.example.com:443/idp/oauth2/token" {
		t.Fatalf("nnm token URL = %q", nnm.TokenURL)
	}
	if nnm.UsesDirectNAToken() {
		t.Fatal("nnm config unexpectedly uses direct NA client credentials")
	}

	direct, err := ParseConfig([]byte(`{
		"instance_id":"lab-network-automation",
		"api_url":"https://na.example.com/nom/api/automation/v1/wrapper"
	}`))
	if err != nil {
		t.Fatalf("ParseConfig(direct) error = %v", err)
	}
	if direct.TokenURL != "https://na.example.com/nom-na/idp/oauth2/token" {
		t.Fatalf("direct token URL = %q", direct.TokenURL)
	}
	if !direct.UsesDirectNAToken() {
		t.Fatal("direct NA config did not select NA client credentials")
	}

	if _, err := ParseConfig([]byte(`{
		"instance_id":"network-automation-prod",
		"nnm_url":"https://nnm.example.com:443",
		"token_url":"https://other.example.com/idp/oauth2/token",
		"api_url":"https://na.example.com/nom/api/automation/v1/wrapper"
	}`)); err == nil {
		t.Fatal("expected mismatched nnm_url and token_url to fail")
	}
}

func validTestConfig() Config {
	return Config{
		InstanceID:            "network-automation-prod",
		NNMURL:                "https://nnm.example.com:443",
		TokenURL:              "https://nnm.example.com:443/idp/oauth2/token",
		APIURL:                "https://na.example.com/nom/api/automation/v1/wrapper",
		tokenAuthMode:         tokenAuthNNM,
		Queries:               []Query{{Name: "switches", Parameters: map[string]any{"type": "Switch"}}},
		PageSize:              2,
		MaxRows:               100,
		MaxResultBytes:        1024 * 1024,
		RequestTimeoutSeconds: 30,
		MaxRetries:            1,
	}
}
