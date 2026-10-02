package main

import (
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"gopkg.in/yaml.v3"
)

// manifestGrant is the part of a plugin.yaml credential grant the agent host
// enforces: allowed methods, hosts and path prefixes.
type manifestGrant struct {
	Name  string `yaml:"name"`
	Allow struct {
		Methods []string `yaml:"methods"`
		Hosts   []string `yaml:"hosts"`
		Paths   []string `yaml:"paths"`
	} `yaml:"allow"`
}

type manifestCredentialRequirement struct {
	Grants []manifestGrant `yaml:"grants"`
}

type manifestModel struct {
	Actions []struct {
		ActionID               string                                   `yaml:"action_id"`
		CredentialRequirements map[string]manifestCredentialRequirement `yaml:"credential_requirements"`
	} `yaml:"actions"`
	ProducerSchedules []struct {
		ActionID               string                                   `yaml:"action_id"`
		CredentialRequirements map[string]manifestCredentialRequirement `yaml:"credential_requirements"`
	} `yaml:"producer_schedules"`
}

func loadManifestGrants(t *testing.T) map[string][]manifestGrant {
	t.Helper()
	raw, err := os.ReadFile("plugin.yaml")
	if err != nil {
		t.Fatalf("read plugin.yaml: %v", err)
	}
	var m manifestModel
	if err := yaml.Unmarshal(raw, &m); err != nil {
		t.Fatalf("parse plugin.yaml: %v", err)
	}
	out := map[string][]manifestGrant{}
	for _, a := range m.Actions {
		for _, req := range a.CredentialRequirements {
			out[a.ActionID] = append(out[a.ActionID], req.Grants...)
		}
	}
	for _, s := range m.ProducerSchedules {
		for _, req := range s.CredentialRequirements {
			out[s.ActionID] = append(out[s.ActionID], req.Grants...)
		}
	}
	return out
}

// grantAllows mirrors the agent host's matching: method and host must be
// listed; a path matches exactly or by a trailing-"*" prefix.
func grantAllows(g manifestGrant, method string, u *url.URL) bool {
	if !containsFold(g.Allow.Methods, method) || !containsFold(g.Allow.Hosts, u.Hostname()) {
		return false
	}
	for _, p := range g.Allow.Paths {
		if p == u.Path || (strings.HasSuffix(p, "*") && strings.HasPrefix(u.Path, strings.TrimSuffix(p, "*"))) {
			return true
		}
	}
	return false
}

func containsFold(list []string, v string) bool {
	for _, x := range list {
		if strings.EqualFold(x, v) {
			return true
		}
	}
	return false
}

// recordingDoer captures every request an action sends before delegating.
type recordingDoer struct {
	inner    httpDoer
	requests []sdk.HTTPRequest
}

func (r *recordingDoer) Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	r.requests = append(r.requests, req)
	return r.inner.Do(req)
}

// Every request each management action sends must be allowed by exactly one
// of that action's declared grants: none would leave the call unauthenticated,
// two would make the host refuse it as ambiguous.
func TestManagementActionRequestsMatchExactlyOneDeclaredGrant(t *testing.T) {
	grants := loadManifestGrants(t)
	if len(grants[actionRebootTerminal]) == 0 {
		t.Skip("management actions are not declared in plugin.yaml yet; they land with the northbound credential_source binding")
	}
	cases := map[string]map[string]any{
		actionRebootTerminal: nil,
		actionSwapTerminal:   {"new_device_id": testNewKit},
		actionChangeProduct:  {"product_reference_id": "example-product-2"},
		actionDeactivateLine: {"end_now": false},
	}
	for actionID, inputs := range cases {
		declared := grants[actionID]
		if len(declared) == 0 {
			t.Fatalf("%s declares no credential grants", actionID)
		}
		rec := &recordingDoer{inner: newFakeVendor(t)}
		if r := runManagementAction(invocationConfig(t, actionID, inputs, nil), rec); r.Status != sdk.ActionStatusSucceeded {
			t.Fatalf("%s: %q %s", actionID, r.Status, r.ErrorMessage)
		}
		for _, req := range rec.requests {
			u, _ := url.Parse(req.URL)
			matches := 0
			for _, g := range declared {
				if grantAllows(g, req.Method, u) {
					matches++
				}
			}
			if matches != 1 {
				t.Fatalf("%s: %s %s matched %d grants, want exactly 1", actionID, req.Method, u.Path, matches)
			}
		}
	}
}

// The same holds for the scheduled collection actions.
func TestScheduledRequestsMatchExactlyOneDeclaredGrant(t *testing.T) {
	grants := loadManifestGrants(t)

	fake := newFakeHTTP(t)
	fake.on("GET", "/account", 200, accountFixture())
	fake.on("GET", "/user-terminals?page=0", 200, terminalsPage(0, true, terminalRowA))
	fake.on("GET", "/service-lines?page=0", 200, envelope(serviceLinesPage))
	fake.on("POST", "/data-usage/query", 200, envelope(`{"dataUsages":[]}`))
	rec := &recordingDoer{inner: fake}
	dispatch(actionConfig(t, actionInventoryRefresh), rec, testObservedAt)

	row := `["u",1700000000000000000,"ut` + testTerminalA + `",1,2,[],"x"]`
	cache := &cacheHTTP{fakeHTTP: newFakeHTTP(t), wantBody: cacheQueryPage0, status: 200}
	cache.on("GET", "/account", 200, accountFixture())
	cache.on("GET", "/user-terminals?page=0", 200, terminalsPage(0, true, terminalRowA))
	telemetryRec := &recordingDoer{inner: &streamThenFake{inner: cache, bodies: []string{streamBody(terminalColumns, row)}}}
	cfg := actionConfig(t, actionTelemetryCollect)
	runTelemetry(newAPIClient(telemetryRec, cfg), cfg, func(string) func([]sdk.TelemetryRecord) error {
		return func([]sdk.TelemetryRecord) error { return nil }
	})

	for actionID, reqs := range map[string][]sdk.HTTPRequest{
		actionInventoryRefresh: rec.requests,
		actionTelemetryCollect: telemetryRec.requests,
	} {
		if len(reqs) == 0 {
			t.Fatalf("%s sent no requests", actionID)
		}
		for _, req := range reqs {
			u, _ := url.Parse(req.URL)
			matches := 0
			for _, g := range grants[actionID] {
				if grantAllows(g, req.Method, u) {
					matches++
				}
			}
			if matches != 1 {
				t.Fatalf("%s: %s %s matched %d grants, want exactly 1", actionID, req.Method, u.Path, matches)
			}
		}
	}
}
