package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

// fakeHTTPClient captures the requests issued by the plugin and returns
// canned responses keyed off URL suffix.
type fakeHTTPClient struct {
	requests  []sdk.HTTPRequest
	responses map[string]*sdk.HTTPResponse
	err       error
}

func (f *fakeHTTPClient) Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	f.requests = append(f.requests, req)
	if f.err != nil {
		return nil, f.err
	}
	for suffix, resp := range f.responses {
		if strings.HasSuffix(req.URL, suffix) {
			return resp, nil
		}
	}
	return &sdk.HTTPResponse{Status: http.StatusNotFound, Body: []byte(`{}`)}, nil
}

func swapHTTP(t *testing.T, fake httpClient) {
	t.Helper()
	prev := awxHTTP
	awxHTTP = fake
	t.Cleanup(func() { awxHTTP = prev })
}

func TestRunPingHappyPath(t *testing.T) {
	body := []byte(`{
		"version": "23.5.1",
		"active_node": "awx-1",
		"install_uuid": "abcdef",
		"ha": false,
		"instances": [
			{"node": "awx-1", "node_type": "hybrid", "uuid": "u1", "version": "23.5.1", "capacity": 100}
		],
		"instance_groups": [
			{"name": "default", "capacity": 100, "instances": ["awx-1"]}
		]
	}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/ping/": {Status: http.StatusOK, Body: body},
	}}
	swapHTTP(t, fake)

	cfg := Config{BaseURL: "https://awx.example.com", APIToken: "tok", Verb: "awx.ping"}
	res := dispatch(cfg)

	if res.Status != sdk.StatusOK {
		t.Fatalf("expected OK, got %s (%s)", res.Status, res.Summary)
	}
	if !strings.Contains(res.Summary, "23.5.1") {
		t.Errorf("expected summary to mention version, got %q", res.Summary)
	}

	var payload map[string]any
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("Details should be JSON: %v", err)
	}
	if payload["verb"] != "awx.ping" {
		t.Errorf("payload.verb = %v, want awx.ping", payload["verb"])
	}
	if payload["ok"] != true {
		t.Errorf("payload.ok = %v, want true", payload["ok"])
	}
	if payload["version"] != "23.5.1" {
		t.Errorf("payload.version = %v", payload["version"])
	}

	if len(fake.requests) != 1 {
		t.Fatalf("expected 1 HTTP call, got %d", len(fake.requests))
	}
	got := fake.requests[0]
	if got.URL != "https://awx.example.com/api/v2/ping/" {
		t.Errorf("URL = %q", got.URL)
	}
	if got.Headers["Authorization"] != "Bearer tok" {
		t.Errorf("Authorization = %q (want Bearer tok)", got.Headers["Authorization"])
	}
	if got.Headers["Accept"] != "application/json" {
		t.Errorf("Accept = %q", got.Headers["Accept"])
	}
}

func TestRunPingTrimsTrailingSlashOnBaseURL(t *testing.T) {
	body := []byte(`{"version":"23.5.1","active_node":"awx"}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/ping/": {Status: http.StatusOK, Body: body},
	}}
	swapHTTP(t, fake)

	cfg := Config{BaseURL: "https://awx.example.com/", APIToken: "tok", Verb: "awx.ping"}
	_ = dispatch(cfg)

	if got := fake.requests[0].URL; got != "https://awx.example.com/api/v2/ping/" {
		t.Errorf("trailing slash should be trimmed; got %q", got)
	}
}

func TestRunPingUnauthorizedSurfacesTypedError(t *testing.T) {
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/ping/": {Status: http.StatusUnauthorized, Body: []byte(`{"detail":"Authentication credentials were not provided."}`)},
	}}
	swapHTTP(t, fake)

	cfg := Config{BaseURL: "https://awx.example.com", APIToken: "bad", Verb: "awx.ping"}
	res := dispatch(cfg)

	if res.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL, got %s", res.Status)
	}
	if !strings.Contains(res.Summary, "401") || !strings.Contains(res.Summary, "controller token") {
		t.Errorf("expected operator-safe 401 summary, got %q", res.Summary)
	}

	var payload map[string]any
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("Details should be JSON: %v", err)
	}
	if payload["ok"] != false {
		t.Errorf("payload.ok = %v, want false", payload["ok"])
	}
}

func TestRunPingHTTPErrorSanitizesURL(t *testing.T) {
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/ping/": {Status: http.StatusInternalServerError, Body: []byte(`{}`)},
	}}
	swapHTTP(t, fake)

	cfg := Config{BaseURL: "https://awx.internal.example.com", APIToken: "tok", Verb: "awx.ping"}
	res := dispatch(cfg)

	if res.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL, got %s", res.Status)
	}
	if strings.Contains(res.Summary, "internal.example.com") {
		t.Errorf("hostname should not leak into summary: %q", res.Summary)
	}
}

func TestDispatchUnknownVerbIsCritical(t *testing.T) {
	swapHTTP(t, &fakeHTTPClient{})
	cfg := Config{BaseURL: "https://awx.example.com", APIToken: "tok", Verb: "awx.bogus"}
	res := dispatch(cfg)
	if res.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL for unknown verb, got %s", res.Status)
	}
	if !strings.Contains(res.Summary, "unknown verb") {
		t.Errorf("expected summary to call out unknown verb, got %q", res.Summary)
	}
}

func TestDispatchPlannedVerbsReportNotImplemented(t *testing.T) {
	swapHTTP(t, &fakeHTTPClient{})
	planned := []string{
		"awx.list_inventories",
		"awx.list_hosts",
		"awx.list_projects",
		"awx.list_templates",
		"awx.fetch_template",
		"awx.launch_job",
		"awx.fetch_job",
		"awx.cancel_job",
		"awx.fetch_events_for_jobs",
	}
	for _, verb := range planned {
		t.Run(verb, func(t *testing.T) {
			cfg := Config{BaseURL: "https://awx.example.com", APIToken: "tok", Verb: verb}
			res := dispatch(cfg)
			if res.Status != sdk.StatusCritical {
				t.Fatalf("expected CRITICAL, got %s", res.Status)
			}
			if !strings.Contains(res.Summary, "not yet implemented") {
				t.Errorf("expected 'not yet implemented' in summary, got %q", res.Summary)
			}
		})
	}
}

func TestSanitizeErrorRedactsURL(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"GET https://awx.example.com/api failed: timeout", "GET <awx>/api failed: timeout"},
		{`Get "https://awx.example.com/api/v2/ping/": EOF`, `Get "<awx>/api/v2/ping/": EOF`},
		{"could not dial http://10.0.0.5:8080: refused", "could not dial <awx> refused"},
		{"plain error message", "plain error message"},
	}
	for _, c := range cases {
		got := sanitizeError(errString(c.in))
		if got != c.want {
			t.Errorf("sanitizeError(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

type errString string

func (e errString) Error() string { return string(e) }
