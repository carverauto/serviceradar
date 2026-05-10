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

func TestRunListInventoriesPaginates(t *testing.T) {
	page1 := []byte(`{
		"count": 3,
		"next": "/api/v2/inventories/?page=2&page_size=2",
		"previous": null,
		"results": [
			{"id": 1, "name": "Production"},
			{"id": 2, "name": "Staging"}
		]
	}`)
	page2 := []byte(`{
		"count": 3,
		"next": null,
		"previous": "/api/v2/inventories/?page=1&page_size=2",
		"results": [
			{"id": 3, "name": "Lab"}
		]
	}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/inventories/?page_size=200":          {Status: http.StatusOK, Body: page1},
		"/api/v2/inventories/?page=2&page_size=2":     {Status: http.StatusOK, Body: page2},
	}}
	swapHTTP(t, fake)

	cfg := Config{BaseURL: "https://awx.example.com", APIToken: "tok", Verb: "awx.list_inventories"}
	res := dispatch(cfg)

	if res.Status != sdk.StatusOK {
		t.Fatalf("got %s: %s", res.Status, res.Summary)
	}
	var payload listResultPayload
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("Details should decode as list payload: %v", err)
	}
	if payload.Count != 3 {
		t.Errorf("count = %d, want 3", payload.Count)
	}
	if len(payload.Results) != 3 {
		t.Errorf("results len = %d, want 3", len(payload.Results))
	}
	if len(fake.requests) != 2 {
		t.Errorf("expected 2 page fetches, got %d", len(fake.requests))
	}
}

func TestRunListInventoriesAbsoluteNextLinkRebasedToConfiguredHost(t *testing.T) {
	// AWX sometimes returns absolute `next` URLs. We must NOT chase the
	// embedded host; we must reuse cfg.BaseURL.
	page1 := []byte(`{
		"count": 1,
		"next": "https://internal-awx.private/api/v2/inventories/?page=2&page_size=200",
		"results": [{"id": 1, "name": "X"}]
	}`)
	page2 := []byte(`{"count": 1, "next": null, "results": []}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/inventories/?page_size=200":          {Status: http.StatusOK, Body: page1},
		"/api/v2/inventories/?page=2&page_size=200":   {Status: http.StatusOK, Body: page2},
	}}
	swapHTTP(t, fake)

	cfg := Config{BaseURL: "https://awx.example.com", APIToken: "tok", Verb: "awx.list_inventories"}
	_ = dispatch(cfg)

	if len(fake.requests) != 2 {
		t.Fatalf("expected 2 requests, got %d", len(fake.requests))
	}
	for _, req := range fake.requests {
		if !strings.HasPrefix(req.URL, "https://awx.example.com/") {
			t.Errorf("plugin chased an absolute next link: %q", req.URL)
		}
	}
}

func TestRunListHostsRequiresInventoryID(t *testing.T) {
	swapHTTP(t, &fakeHTTPClient{})
	cfg := Config{BaseURL: "https://awx.example.com", APIToken: "tok", Verb: "awx.list_hosts"}
	res := dispatch(cfg)
	if res.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL when inventory_id missing, got %s", res.Status)
	}
	if !strings.Contains(res.Summary, "inventory_id") {
		t.Errorf("expected 'inventory_id' to be named in summary, got %q", res.Summary)
	}
}

func TestRunListHostsHappyPath(t *testing.T) {
	body := []byte(`{
		"count": 2,
		"next": null,
		"results": [
			{"id": 100, "name": "web01", "inventory": 7, "enabled": true},
			{"id": 101, "name": "web02", "inventory": 7, "enabled": true}
		]
	}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/inventories/7/hosts/?page_size=200": {Status: http.StatusOK, Body: body},
	}}
	swapHTTP(t, fake)

	cfg := Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.list_hosts",
		Args:     map[string]any{"inventory_id": float64(7)},
	}
	res := dispatch(cfg)

	if res.Status != sdk.StatusOK {
		t.Fatalf("got %s: %s", res.Status, res.Summary)
	}
	var payload listResultPayload
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	if payload.Extra["inventory_id"].(float64) != 7 {
		t.Errorf("extra.inventory_id = %v, want 7", payload.Extra["inventory_id"])
	}
	if payload.Count != 2 {
		t.Errorf("count = %d, want 2", payload.Count)
	}
}

func TestRunFetchTemplateMergesTemplateAndSurvey(t *testing.T) {
	tmpl := []byte(`{"id": 42, "name": "Deploy", "playbook": "deploy.yml", "survey_enabled": true}`)
	survey := []byte(`{"name":"Deploy Survey","spec":[{"variable":"version","type":"text"}]}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/job_templates/42/":             {Status: http.StatusOK, Body: tmpl},
		"/api/v2/job_templates/42/survey_spec/": {Status: http.StatusOK, Body: survey},
	}}
	swapHTTP(t, fake)

	cfg := Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.fetch_template",
		Args:     map[string]any{"template_id": float64(42)},
	}
	res := dispatch(cfg)

	if res.Status != sdk.StatusOK {
		t.Fatalf("got %s: %s", res.Status, res.Summary)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	if payload["verb"] != "awx.fetch_template" {
		t.Errorf("verb = %v", payload["verb"])
	}
	if payload["template_id"].(float64) != 42 {
		t.Errorf("template_id = %v", payload["template_id"])
	}
	if payload["template"] == nil {
		t.Errorf("payload.template missing")
	}
	if payload["survey_spec"] == nil {
		t.Errorf("payload.survey_spec missing")
	}
	if len(fake.requests) != 2 {
		t.Errorf("expected 2 requests (template + survey_spec), got %d", len(fake.requests))
	}
}

func TestRunFetchTemplateToleratesMissingSurvey(t *testing.T) {
	tmpl := []byte(`{"id": 42, "name": "Deploy", "playbook": "deploy.yml"}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/job_templates/42/":             {Status: http.StatusOK, Body: tmpl},
		"/api/v2/job_templates/42/survey_spec/": {Status: http.StatusNotFound, Body: []byte(`{}`)},
	}}
	swapHTTP(t, fake)

	cfg := Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.fetch_template",
		Args:     map[string]any{"template_id": float64(42)},
	}
	res := dispatch(cfg)

	if res.Status != sdk.StatusOK {
		t.Fatalf("expected OK on missing survey, got %s: %s", res.Status, res.Summary)
	}
}

func TestRunListProjectsAndTemplatesUseCorrectPaths(t *testing.T) {
	emptyPage := []byte(`{"count":0,"next":null,"results":[]}`)
	cases := []struct {
		verb     string
		wantPath string
	}{
		{"awx.list_projects", "/api/v2/projects/?page_size=200"},
		{"awx.list_templates", "/api/v2/job_templates/?page_size=200"},
	}
	for _, c := range cases {
		t.Run(c.verb, func(t *testing.T) {
			fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
				c.wantPath: {Status: http.StatusOK, Body: emptyPage},
			}}
			swapHTTP(t, fake)
			cfg := Config{BaseURL: "https://awx.example.com", APIToken: "tok", Verb: c.verb}
			res := dispatch(cfg)
			if res.Status != sdk.StatusOK {
				t.Fatalf("got %s: %s", res.Status, res.Summary)
			}
			if len(fake.requests) != 1 || !strings.HasSuffix(fake.requests[0].URL, c.wantPath) {
				t.Errorf("expected GET %s, got %v", c.wantPath, fake.requests)
			}
		})
	}
}

func TestRelativizeAWXPath(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"", ""},
		{"/api/v2/inventories/?page=2", "/api/v2/inventories/?page=2"},
		{"https://other.host/api/v2/inventories/?page=2", "/api/v2/inventories/?page=2"},
		{"http://10.0.0.1:8080/api/v2/projects/?page=3&page_size=200", "/api/v2/projects/?page=3&page_size=200"},
	}
	for _, c := range cases {
		if got := relativizeAWXPath(c.in); got != c.want {
			t.Errorf("relativizeAWXPath(%q) = %q, want %q", c.in, got, c.want)
		}
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
