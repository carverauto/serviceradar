package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

// fakeHTTPClient captures the requests issued by the plugin and returns
// canned responses keyed off URL suffix.
type fakeHTTPClient struct {
	requests  []sdk.HTTPRequest
	responses map[string]*sdk.HTTPResponse
	err       error
}

type scriptedHTTPClient struct {
	requests  []sdk.HTTPRequest
	responses []*sdk.HTTPResponse
}

func (f *scriptedHTTPClient) Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	f.requests = append(f.requests, req)
	if len(f.responses) == 0 {
		return &sdk.HTTPResponse{Status: http.StatusNotFound, Body: []byte(`{}`)}, nil
	}
	response := f.responses[0]
	f.responses = f.responses[1:]
	return response, nil
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
		"install_uuid": "SR_PING_SECRET",
		"ha": false,
		"instances": [
			{"node": "SR_PING_SECRET", "node_type": "hybrid", "uuid": "u1", "version": "23.5.1", "capacity": 100}
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
	assertExactMapKeys(t, payload, "verb", "ok", "version", "active_node")
	if strings.Contains(res.Details, "SR_PING_SECRET") {
		t.Fatalf("ping topology leaked into result: %s", res.Details)
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

func TestSafeStaticTextRejectsControlAndFormatCharacters(t *testing.T) {
	for _, value := range []string{"tab\tvalue", "escape\x1bvalue", "bidi\u202evalue"} {
		if safeStaticText(value, 64) {
			t.Errorf("safeStaticText accepted unsafe value %q", value)
		}
	}
	if !safeStaticText("plain value", 64) {
		t.Errorf("safeStaticText rejected bounded plain text")
	}
	if safeStaticText(strings.Repeat("x", 65), 64) {
		t.Errorf("safeStaticText accepted an overlong value")
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

func TestRunPingUnauthorizedUsesFixedUpstreamFailure(t *testing.T) {
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/ping/": {Status: http.StatusUnauthorized, Body: []byte(`{"detail":"Authentication credentials were not provided."}`)},
	}}
	swapHTTP(t, fake)

	cfg := Config{BaseURL: "https://awx.example.com", APIToken: "bad", Verb: "awx.ping"}
	res := dispatch(cfg)

	if res.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL, got %s", res.Status)
	}
	if res.Summary != "awx.ping: AWX request failed" {
		t.Errorf("expected fixed upstream failure, got %q", res.Summary)
	}

	var payload map[string]any
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("Details should be JSON: %v", err)
	}
	if payload["ok"] != false {
		t.Errorf("payload.ok = %v, want false", payload["ok"])
	}
	if payload["error"] != "AWX request failed" {
		t.Errorf("payload.error = %v, want fixed upstream failure", payload["error"])
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
	unknown := "awx.bogus-Bearer-secret"
	cfg := Config{BaseURL: "https://awx.example.com", APIToken: "tok", Verb: unknown}
	res := dispatch(cfg)
	if res.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL for unknown verb, got %s", res.Status)
	}
	if !strings.Contains(res.Summary, "unknown AWX command") ||
		strings.Contains(res.Summary, unknown) || strings.Contains(res.Details, unknown) {
		t.Errorf("expected fixed secret-free unknown command result, got summary=%q details=%q", res.Summary, res.Details)
	}
}

func TestRunLaunchJobSuccess(t *testing.T) {
	jobBody := []byte(`{"id": 7331, "status": "pending", "job_template": 42}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/job_templates/42/launch/": {Status: http.StatusCreated, Body: jobBody},
	}}
	swapHTTP(t, fake)

	cfg := Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.launch_job",
		Args: map[string]any{
			"template_id": float64(42),
			"extra_vars": map[string]any{
				"version":                      "1.2.3",
				"serviceradar_dispatch_id":     "dispatch-018f",
				"serviceradar_snapshot_digest": "sha256:abc123",
			},
			"host_limit":               "web01,web02",
			"inventory_id":             float64(7),
			"credential_ids":           []any{float64(101), float64(102)},
			"execution_environment_id": float64(9),
			"job_type":                 "check",
			"diff_mode":                true,
			"verbosity":                float64(3),
			"forks":                    float64(20),
			"job_slice_count":          float64(2),
			"timeout":                  float64(900),
			"job_tags":                 "enrollment,canary",
			"skip_tags":                "destructive",
			"labels":                   []any{float64(301)},
			"instance_group_ids":       []any{float64(401)},
		},
	}
	res := dispatch(cfg)

	if res.Status != sdk.StatusOK {
		t.Fatalf("expected OK, got %s: %s", res.Status, res.Summary)
	}
	if len(fake.requests) != 1 {
		t.Fatalf("expected 1 POST, got %d", len(fake.requests))
	}
	req := fake.requests[0]
	if req.Method != http.MethodPost {
		t.Errorf("method = %s, want POST", req.Method)
	}
	if req.Headers["Content-Type"] != "application/json" {
		t.Errorf("Content-Type = %q", req.Headers["Content-Type"])
	}
	if req.Headers["Authorization"] != "Bearer tok" {
		t.Errorf("Authorization = %q", req.Headers["Authorization"])
	}

	var sentBody map[string]any
	if err := json.Unmarshal(req.Body, &sentBody); err != nil {
		t.Fatalf("decode request body: %v", err)
	}
	if sentBody["limit"] != "web01,web02" {
		t.Errorf("body.limit = %v, want web01,web02", sentBody["limit"])
	}
	if sentBody["inventory"] != float64(7) {
		t.Errorf("body.inventory = %v, want 7", sentBody["inventory"])
	}
	extra, ok := sentBody["extra_vars"].(map[string]any)
	if !ok || extra["version"] != "1.2.3" {
		t.Errorf("body.extra_vars = %v", sentBody["extra_vars"])
	}
	if extra["serviceradar_dispatch_id"] != "dispatch-018f" ||
		extra["serviceradar_snapshot_digest"] != "sha256:abc123" {
		t.Errorf("reserved dispatch markers not forwarded exactly: %v", extra)
	}
	assertJSONNumber(t, sentBody, "execution_environment", 9)
	assertJSONNumber(t, sentBody, "verbosity", 3)
	assertJSONNumber(t, sentBody, "forks", 20)
	assertJSONNumber(t, sentBody, "job_slice_count", 2)
	assertJSONNumber(t, sentBody, "timeout", 900)
	if sentBody["job_type"] != "check" || sentBody["diff_mode"] != true {
		t.Errorf("mode fields not forwarded: %v", sentBody)
	}
	if sentBody["job_tags"] != "enrollment,canary" || sentBody["skip_tags"] != "destructive" {
		t.Errorf("tag fields not forwarded: %v", sentBody)
	}
	assertJSONNumberSlice(t, sentBody, "credentials", []float64{101, 102})
	assertJSONNumberSlice(t, sentBody, "labels", []float64{301})
	assertJSONNumberSlice(t, sentBody, "instance_groups", []float64{401})

	var payload map[string]any
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("decode response payload: %v", err)
	}
	if payload["template_id"].(float64) != 42 {
		t.Errorf("template_id = %v", payload["template_id"])
	}
	if payload["job"] == nil {
		t.Errorf("payload.job missing")
	}
}

func assertJSONNumber(t *testing.T, body map[string]any, key string, want float64) {
	t.Helper()
	if got := body[key]; got != want {
		t.Errorf("body.%s = %v, want %v", key, got, want)
	}
}

func assertJSONNumberSlice(t *testing.T, body map[string]any, key string, want []float64) {
	t.Helper()
	got, ok := body[key].([]any)
	if !ok {
		t.Errorf("body.%s = %T, want array", key, body[key])
		return
	}
	if len(got) != len(want) {
		t.Errorf("body.%s len = %d, want %d", key, len(got), len(want))
		return
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("body.%s[%d] = %v, want %v", key, i, got[i], want[i])
		}
	}
}

func TestRunLaunchJobRequiresTemplateID(t *testing.T) {
	swapHTTP(t, &fakeHTTPClient{})
	cfg := Config{BaseURL: "https://awx.example.com", APIToken: "tok", Verb: "awx.launch_job"}
	res := dispatch(cfg)
	if res.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL, got %s", res.Status)
	}
	if !strings.Contains(res.Summary, "template_id") {
		t.Errorf("expected 'template_id' in summary, got %q", res.Summary)
	}
}

func TestRunLaunchJobOmitsEmptyOptionalArgs(t *testing.T) {
	jobBody := []byte(`{"id": 1, "status": "pending"}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/job_templates/1/launch/": {Status: http.StatusCreated, Body: jobBody},
	}}
	swapHTTP(t, fake)

	cfg := Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.launch_job",
		Args:     map[string]any{"template_id": float64(1)},
	}
	_ = dispatch(cfg)

	var sentBody map[string]any
	_ = json.Unmarshal(fake.requests[0].Body, &sentBody)
	if _, has := sentBody["limit"]; has {
		t.Errorf("limit should be omitted when empty, got %v", sentBody)
	}
	if _, has := sentBody["extra_vars"]; has {
		t.Errorf("extra_vars should be omitted when empty, got %v", sentBody)
	}
}

func TestRunLaunchJobRejectsUnsafeOrMalformedFields(t *testing.T) {
	tests := []struct {
		name string
		args map[string]any
		want string
	}{
		{
			name: "credential passwords are prohibited",
			args: map[string]any{"template_id": 1, "credential_passwords": map[string]any{"ssh_password": "secret"}},
			want: "unreviewed field",
		},
		{
			name: "moving scm branch is prohibited",
			args: map[string]any{"template_id": 1, "scm_branch": "main"},
			want: "unreviewed field",
		},
		{
			name: "fractional inventory ID",
			args: map[string]any{"template_id": 1, "inventory_id": 7.5},
			want: "inventory_id",
		},
		{
			name: "empty explicit limit",
			args: map[string]any{"template_id": 1, "host_limit": "  "},
			want: "must not be empty",
		},
		{
			name: "invalid check mode",
			args: map[string]any{"template_id": 1, "job_type": "dry-run"},
			want: "job_type",
		},
		{
			name: "duplicate credential IDs",
			args: map[string]any{"template_id": 1, "credential_ids": []any{2.0, 2.0}},
			want: "duplicate",
		},
		{
			name: "non-string dispatch marker",
			args: map[string]any{
				"template_id": 1,
				"extra_vars":  map[string]any{"serviceradar_dispatch_id": 123},
			},
			want: "serviceradar_dispatch_id",
		},
		{
			name: "unbounded timeout",
			args: map[string]any{"template_id": 1, "timeout": maxLaunchTimeoutSecond + 1},
			want: "timeout",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeHTTPClient{}
			swapHTTP(t, fake)
			res := dispatch(Config{
				BaseURL:  "https://awx.example.com",
				APIToken: "tok",
				Verb:     "awx.launch_job",
				Args:     tt.args,
			})
			if res.Status != sdk.StatusCritical {
				t.Fatalf("expected CRITICAL, got %s", res.Status)
			}
			if !strings.Contains(res.Summary, tt.want) {
				t.Errorf("summary %q does not contain %q", res.Summary, tt.want)
			}
			if len(fake.requests) != 0 {
				t.Errorf("malformed launch must not contact AWX")
			}
		})
	}
}

func TestRunCreateCallbackCredentialUsesOnlySentinelsAndReturnsSanitizedBinding(t *testing.T) {
	response := []byte(`{
		"id":401,
		"name":"sr-callback-018f3f56-1111-7222-8333-123456789abc",
		"credential_type":91,
		"organization":2,
		"inputs":{"callback_grant":"$encrypted$"},
		"related":{"activity_stream":"/api/v2/activity_stream/"}
	}`)
	fake := &scriptedHTTPClient{responses: []*sdk.HTTPResponse{
		{Status: http.StatusOK, Body: callbackCredentialTypeBody(t)},
		{Status: http.StatusOK, Body: []byte(`{"count":0,"next":null,"results":[]}`)},
		{Status: http.StatusCreated, Body: response},
	}}
	swapHTTP(t, fake)

	res := dispatch(Config{
		BaseURL: "https://awx.example.com", APIToken: "controller-token",
		Verb: "awx.create_callback_credential",
		Args: map[string]any{
			"credential_type_id": float64(91),
			"organization_id":    float64(2),
			"credential_name":    "sr-callback-018f3f56-1111-7222-8333-123456789abc",
			"injector_sha256":    callbackCredentialTypeDigest(t),
		},
	})
	if res.Status != sdk.StatusOK {
		t.Fatalf("expected OK, got %s: %s", res.Status, res.Summary)
	}
	if len(fake.requests) != 3 {
		t.Fatalf("requests = %d, want type GET + preflight GET + create POST", len(fake.requests))
	}
	if fake.requests[0].Method != http.MethodGet ||
		fake.requests[0].URL != "https://awx.example.com/api/v2/credential_types/91/" {
		t.Fatalf("unexpected credential type request: %s %s", fake.requests[0].Method, fake.requests[0].URL)
	}
	preflight := fake.requests[1]
	preflightURL, err := url.Parse(preflight.URL)
	if err != nil {
		t.Fatalf("parse preflight URL: %v", err)
	}
	if preflight.Method != http.MethodGet || preflightURL.Path != "/api/v2/credentials/" ||
		preflightURL.Query().Get("name") != "sr-callback-018f3f56-1111-7222-8333-123456789abc" ||
		preflightURL.Query().Get("credential_type") != "91" ||
		preflightURL.Query().Get("organization") != "2" || preflightURL.Query().Get("page_size") != "2" {
		t.Fatalf("unexpected preflight request: %s %s", preflight.Method, preflight.URL)
	}
	req := fake.requests[2]
	if req.Method != http.MethodPost || req.URL != "https://awx.example.com/api/v2/credentials/" {
		t.Fatalf("request = %s %s", req.Method, req.URL)
	}
	var body struct {
		Name           string            `json:"name"`
		Description    string            `json:"description"`
		CredentialType int               `json:"credential_type"`
		Organization   int               `json:"organization"`
		Inputs         map[string]string `json:"inputs"`
	}
	if err := json.Unmarshal(req.Body, &body); err != nil {
		t.Fatalf("decode request: %v", err)
	}
	if body.Name != "sr-callback-018f3f56-1111-7222-8333-123456789abc" ||
		body.Description != callbackCredentialDescription || body.CredentialType != 91 || body.Organization != 2 {
		t.Fatalf("unexpected bounded credential body: %#v", body)
	}
	if len(body.Inputs) != len(callbackCredentialInputKeys) {
		t.Fatalf("inputs = %#v", body.Inputs)
	}
	for _, key := range callbackCredentialInputKeys {
		if body.Inputs[key] != callbackCredentialInputSentinel {
			t.Fatalf("input %q = %q, want host-boundary sentinel", key, body.Inputs[key])
		}
	}

	for _, prohibited := range []string{"$encrypted$", "callback_grant", "inputs", "activity_stream", "controller-token"} {
		if strings.Contains(res.Details, prohibited) {
			t.Fatalf("sanitized response leaked %q: %s", prohibited, res.Details)
		}
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("decode details: %v", err)
	}
	if payload["credential_id"] != float64(401) || payload["credential_type_id"] != float64(91) ||
		payload["organization_id"] != float64(2) ||
		payload["credential_name"] != "sr-callback-018f3f56-1111-7222-8333-123456789abc" {
		t.Fatalf("unexpected sanitized details: %#v", payload)
	}
}

func TestRunCreateCallbackCredentialRequiresCleanupBeforeReissue(t *testing.T) {
	existing := []byte(`{
		"count":1,
		"next":null,
		"results":[{
			"id":401,
			"name":"sr-callback-018f3f56-1111-7222-8333-123456789abc",
			"credential_type":91,
			"organization":2,
			"inputs":{"callback_grant":"$encrypted$"}
		}]
	}`)
	fake := &scriptedHTTPClient{responses: []*sdk.HTTPResponse{
		{Status: http.StatusOK, Body: callbackCredentialTypeBody(t)},
		{Status: http.StatusOK, Body: existing},
	}}
	swapHTTP(t, fake)

	res := dispatch(Config{
		BaseURL: "https://awx.example.com", APIToken: "controller-token",
		Verb: "awx.create_callback_credential",
		Args: map[string]any{
			"credential_type_id": float64(91),
			"organization_id":    float64(2),
			"credential_name":    "sr-callback-018f3f56-1111-7222-8333-123456789abc",
			"injector_sha256":    callbackCredentialTypeDigest(t),
		},
	})
	if res.Status != sdk.StatusCritical || len(fake.requests) != 2 || fake.requests[1].Method != http.MethodGet {
		t.Fatalf("existing credential must stop before POST: status=%s requests=%#v", res.Status, fake.requests)
	}
	for _, required := range []string{
		`"cleanup_status":"cleanup_required"`,
		`"credential_id":401`,
		`"credential_type_id":91`,
		`"organization_id":2`,
	} {
		if !strings.Contains(res.Details, required) {
			t.Fatalf("conflict response missing %s: %s", required, res.Details)
		}
	}
	if strings.Contains(res.Details, "$encrypted$") || strings.Contains(res.Details, "inputs") {
		t.Fatalf("conflict response leaked AWX inputs: %s", res.Details)
	}
}

func TestRunFetchCallbackCredentialReturnsExactFoundIdentity(t *testing.T) {
	existing := []byte(`{
		"count":1,
		"next":null,
		"results":[{
			"id":401,
			"name":"sr-callback-018f3f56-1111-7222-8333-123456789abc",
			"credential_type":91,
			"organization":2
		}]
	}`)
	fake := &scriptedHTTPClient{responses: []*sdk.HTTPResponse{{Status: http.StatusOK, Body: existing}}}
	swapHTTP(t, fake)

	res := dispatch(callbackCredentialFetchConfig())
	if res.Status != sdk.StatusOK || len(fake.requests) != 1 || fake.requests[0].Method != http.MethodGet {
		t.Fatalf("expected one read-only lookup: status=%s requests=%#v", res.Status, fake.requests)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("decode details: %v", err)
	}
	if payload["verb"] != "awx.fetch_callback_credential" || payload["ok"] != true ||
		payload["found"] != true || payload["credential_id"] != float64(401) ||
		payload["credential_type_id"] != float64(91) || payload["organization_id"] != float64(2) {
		t.Fatalf("unexpected found payload: %#v", payload)
	}
	if len(payload) != 7 {
		t.Fatalf("unexpected fields in found payload: %#v", payload)
	}
}

func TestRunFetchCallbackCredentialReturnsExactAbsentIdentity(t *testing.T) {
	fake := &scriptedHTTPClient{responses: []*sdk.HTTPResponse{{
		Status: http.StatusOK,
		Body:   []byte(`{"count":0,"next":null,"results":[]}`),
	}}}
	swapHTTP(t, fake)

	res := dispatch(callbackCredentialFetchConfig())
	if res.Status != sdk.StatusOK || len(fake.requests) != 1 {
		t.Fatalf("expected successful absence lookup: status=%s requests=%#v", res.Status, fake.requests)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("decode details: %v", err)
	}
	if payload["found"] != false {
		t.Fatalf("unexpected absence payload: %#v", payload)
	}
	if _, exists := payload["credential_id"]; exists || len(payload) != 6 {
		t.Fatalf("absent payload must not invent a credential ID: %#v", payload)
	}
}

func TestRunFetchCallbackCredentialRejectsAmbiguityAndUnexpectedArgs(t *testing.T) {
	t.Run("ambiguous", func(t *testing.T) {
		fake := &scriptedHTTPClient{responses: []*sdk.HTTPResponse{{
			Status: http.StatusOK,
			Body:   []byte(`{"count":2,"next":null,"results":[{"id":401},{"id":402}]}`),
		}}}
		swapHTTP(t, fake)

		res := dispatch(callbackCredentialFetchConfig())
		if res.Status != sdk.StatusCritical || len(fake.requests) != 1 {
			t.Fatalf("ambiguous lookup must fail closed: status=%s requests=%#v", res.Status, fake.requests)
		}
	})

	t.Run("unexpected args", func(t *testing.T) {
		fake := &fakeHTTPClient{}
		swapHTTP(t, fake)
		cfg := callbackCredentialFetchConfig()
		cfg.Args["inputs"] = map[string]any{"callback_grant": "must-not-pass"}

		res := dispatch(cfg)
		if res.Status != sdk.StatusCritical || len(fake.requests) != 0 {
			t.Fatalf("unexpected args must fail before HTTP: status=%s requests=%#v", res.Status, fake.requests)
		}
	})
}

func callbackCredentialFetchConfig() Config {
	return Config{
		BaseURL: "https://awx.example.com", APIToken: "controller-token",
		Verb: "awx.fetch_callback_credential",
		Args: map[string]any{
			"credential_type_id": float64(91),
			"organization_id":    float64(2),
			"credential_name":    "sr-callback-018f3f56-1111-7222-8333-123456789abc",
		},
	}
}

func TestRunVerifyCallbackCredentialUsesDirectIDAndReturnsSecretFreeScope(t *testing.T) {
	credential := []byte(`{
		"id":401,
		"name":"sr-callback-018f3f56-1111-7222-8333-123456789abc",
		"credential_type":91,
		"organization":2,
		"inputs":{"callback_grant":"must-not-cross"},
		"related":{"activity_stream":"must-not-cross"}
	}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/credentials/401/": {Status: http.StatusOK, Body: credential},
	}}
	swapHTTP(t, fake)

	res := dispatch(callbackCredentialVerifyConfig())
	if res.Status != sdk.StatusOK || len(fake.requests) != 1 {
		t.Fatalf("expected one direct verification GET: status=%s requests=%#v", res.Status, fake.requests)
	}
	if fake.requests[0].Method != http.MethodGet ||
		fake.requests[0].URL != "https://awx.example.com/api/v2/credentials/401/" {
		t.Fatalf("unexpected verification request: %s %s", fake.requests[0].Method, fake.requests[0].URL)
	}

	var payload map[string]any
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("decode details: %v", err)
	}
	assertExactMapKeys(t, payload, "verb", "ok", "credential_id", "credential")
	projected := payload["credential"].(map[string]any)
	assertExactMapKeys(t, projected, "id", "name", "credential_type_id", "organization_id")
	if projected["id"] != float64(401) || projected["credential_type_id"] != float64(91) ||
		projected["organization_id"] != float64(2) {
		t.Fatalf("unexpected credential projection: %#v", projected)
	}
	if strings.Contains(res.Details, "must-not-cross") || strings.Contains(res.Details, "inputs") {
		t.Fatalf("verification leaked raw credential material: %s", res.Details)
	}
}

func TestRunVerifyCallbackCredentialRejectsScopeMismatch(t *testing.T) {
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/credentials/401/": {
			Status: http.StatusOK,
			Body:   []byte(`{"id":401,"name":"sr-callback-other","credential_type":91,"organization":2}`),
		},
	}}
	swapHTTP(t, fake)

	res := dispatch(callbackCredentialVerifyConfig())
	if res.Status != sdk.StatusCritical || len(fake.requests) != 1 {
		t.Fatalf("scope mismatch must fail closed: status=%s requests=%#v", res.Status, fake.requests)
	}
}

func callbackCredentialVerifyConfig() Config {
	cfg := callbackCredentialFetchConfig()
	cfg.Verb = "awx.verify_callback_credential"
	cfg.Args["credential_id"] = float64(401)
	return cfg
}

func TestRunListCallbackCredentialsPaginatesEveryExactMatch(t *testing.T) {
	page1 := []byte(`{
		"count":2,
		"next":"/api/v2/credentials/?page=2",
		"results":[{
			"id":401,
			"name":"sr-callback-018f3f56-1111-7222-8333-123456789abc",
			"credential_type":91,
			"organization":2,
			"inputs":{"callback_grant":"must-not-cross"}
		}]
	}`)
	page2 := []byte(`{
		"count":2,
		"next":null,
		"results":[{
			"id":402,
			"name":"sr-callback-018f3f56-1111-7222-8333-123456789abc",
			"credential_type":91,
			"organization":2
		}]
	}`)
	fake := &scriptedHTTPClient{responses: []*sdk.HTTPResponse{
		{Status: http.StatusOK, Body: page1},
		{Status: http.StatusOK, Body: page2},
	}}
	swapHTTP(t, fake)

	res := dispatch(callbackCredentialListConfig())
	if res.Status != sdk.StatusOK || len(fake.requests) != 2 {
		t.Fatalf("expected complete callback lookup: status=%s requests=%#v", res.Status, fake.requests)
	}
	firstURL, err := url.Parse(fake.requests[0].URL)
	if err != nil {
		t.Fatalf("parse lookup URL: %v", err)
	}
	if firstURL.Path != "/api/v2/credentials/" || firstURL.Query().Get("credential_type") != "91" ||
		firstURL.Query().Get("organization") != "2" || firstURL.Query().Get("order_by") != "id" ||
		firstURL.Query().Get("page_size") != "200" {
		t.Fatalf("unexpected exact lookup URL: %s", fake.requests[0].URL)
	}

	var payload struct {
		Verb             string           `json:"verb"`
		OK               bool             `json:"ok"`
		CredentialTypeID int              `json:"credential_type_id"`
		OrganizationID   int              `json:"organization_id"`
		CredentialName   string           `json:"credential_name"`
		MaxCredentials   int              `json:"max_credentials"`
		Count            int              `json:"count"`
		Complete         bool             `json:"complete"`
		Credentials      []map[string]any `json:"credentials"`
	}
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("decode details: %v", err)
	}
	var exactPayload map[string]any
	if err := json.Unmarshal([]byte(res.Details), &exactPayload); err != nil {
		t.Fatalf("decode exact payload: %v", err)
	}
	assertExactMapKeys(t, exactPayload,
		"verb", "ok", "credential_type_id", "organization_id", "credential_name",
		"max_credentials", "count", "complete", "credentials")
	if payload.Verb != "awx.list_callback_credentials" || !payload.OK || !payload.Complete ||
		payload.CredentialTypeID != 91 || payload.OrganizationID != 2 ||
		payload.MaxCredentials != 5000 || payload.Count != 2 || len(payload.Credentials) != 2 {
		t.Fatalf("unexpected list payload: %#v", payload)
	}
	for index, credential := range payload.Credentials {
		assertExactMapKeys(t, credential, "id", "name", "credential_type_id", "organization_id")
		if credential["id"] != float64(401+index) {
			t.Fatalf("credentials were not complete and ordered: %#v", payload.Credentials)
		}
	}
	if strings.Contains(res.Details, "must-not-cross") || strings.Contains(res.Details, "inputs") {
		t.Fatalf("list leaked raw credential material: %s", res.Details)
	}
}

func TestRunListCallbackCredentialsRejectsCountAboveBound(t *testing.T) {
	fake := &scriptedHTTPClient{responses: []*sdk.HTTPResponse{{
		Status: http.StatusOK,
		Body:   []byte(`{"count":5001,"next":"/api/v2/credentials/?page=2","results":[]}`),
	}}}
	swapHTTP(t, fake)

	res := dispatch(callbackCredentialListConfig())
	if res.Status != sdk.StatusCritical || len(fake.requests) != 1 {
		t.Fatalf("oversized lookup must fail closed: status=%s requests=%#v", res.Status, fake.requests)
	}
}

func callbackCredentialListConfig() Config {
	cfg := callbackCredentialFetchConfig()
	cfg.Verb = "awx.list_callback_credentials"
	cfg.Args["max_credentials"] = float64(5000)
	return cfg
}

func TestRunCreateCallbackCredentialRejectsUnreviewedInputsBeforeHTTP(t *testing.T) {
	fake := &fakeHTTPClient{}
	swapHTTP(t, fake)

	res := dispatch(Config{
		BaseURL: "https://awx.example.com", APIToken: "controller-token",
		Verb: "awx.create_callback_credential",
		Args: map[string]any{
			"credential_type_id": float64(91),
			"organization_id":    float64(2),
			"credential_name":    "sr-callback-018f3f56-1111-7222-8333-123456789abc",
			"injector_sha256":    callbackCredentialTypeDigest(t),
			"inputs":             map[string]any{"callback_grant": "direct-secret"},
		},
	})
	if res.Status != sdk.StatusCritical || len(fake.requests) != 0 {
		t.Fatalf("unreviewed input must fail before HTTP: status=%s requests=%d", res.Status, len(fake.requests))
	}
	if strings.Contains(res.Details, "direct-secret") {
		t.Fatalf("error details leaked direct input: %s", res.Details)
	}
}

func TestNormalizeCallbackCredentialTypeRejectsInputSchemaDrift(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(map[string]any)
	}{
		{
			name: "label",
			mutate: func(document map[string]any) {
				fields := document["inputs"].(map[string]any)["fields"].([]any)
				fields[0].(map[string]any)["label"] = "Unreviewed callback URL"
			},
		},
		{
			name: "field property",
			mutate: func(document map[string]any) {
				fields := document["inputs"].(map[string]any)["fields"].([]any)
				fields[0].(map[string]any)["help_text"] = "unreviewed"
			},
		},
		{
			name: "input property",
			mutate: func(document map[string]any) {
				document["inputs"].(map[string]any)["prompt_on_launch"] = true
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var document map[string]any
			if err := json.Unmarshal(callbackCredentialTypeBody(t), &document); err != nil {
				t.Fatalf("decode credential type fixture: %v", err)
			}
			test.mutate(document)
			body, err := json.Marshal(document)
			if err != nil {
				t.Fatalf("encode drifted credential type: %v", err)
			}
			if _, err := normalizeCallbackCredentialType(body, 91); err == nil {
				t.Fatalf("%s drift must fail closed", test.name)
			}
		})
	}
}

func TestRunCreateCallbackCredentialRejectsInjectorDriftBeforeSecretPost(t *testing.T) {
	typeBody := callbackCredentialTypeBody(t)
	var decoded map[string]any
	if err := json.Unmarshal(typeBody, &decoded); err != nil {
		t.Fatalf("decode credential type fixture: %v", err)
	}
	injectors := decoded["injectors"].(map[string]any)
	injectors["extra_vars"] = map[string]any{"SERVICERADAR_CALLBACK_GRANT": "{{ callback_grant }}"}
	drifted, _ := json.Marshal(decoded)
	fake := &scriptedHTTPClient{responses: []*sdk.HTTPResponse{{Status: http.StatusOK, Body: drifted}}}
	swapHTTP(t, fake)

	res := dispatch(Config{
		BaseURL: "https://awx.example.com", APIToken: "controller-token",
		Verb: "awx.create_callback_credential",
		Args: map[string]any{
			"credential_type_id": float64(91),
			"organization_id":    float64(2),
			"credential_name":    "sr-callback-018f3f56-1111-7222-8333-123456789abc",
			"injector_sha256":    callbackCredentialTypeDigest(t),
		},
	})
	if res.Status != sdk.StatusCritical || len(fake.requests) != 1 ||
		fake.requests[0].URL != "https://awx.example.com/api/v2/credential_types/91/" {
		t.Fatalf("drift must fail after only credential type GET: status=%s requests=%#v", res.Status, fake.requests)
	}
}

func TestRunCreateCallbackCredentialRejectsReviewedContractDigestMismatch(t *testing.T) {
	fake := &scriptedHTTPClient{responses: []*sdk.HTTPResponse{{Status: http.StatusOK, Body: callbackCredentialTypeBody(t)}}}
	swapHTTP(t, fake)

	res := dispatch(Config{
		BaseURL: "https://awx.example.com", APIToken: "controller-token",
		Verb: "awx.create_callback_credential",
		Args: map[string]any{
			"credential_type_id": float64(91),
			"organization_id":    float64(2),
			"credential_name":    "sr-callback-018f3f56-1111-7222-8333-123456789abc",
			"injector_sha256":    strings.Repeat("0", 64),
		},
	})
	if res.Status != sdk.StatusCritical || len(fake.requests) != 1 ||
		fake.requests[0].URL != "https://awx.example.com/api/v2/credential_types/91/" {
		t.Fatalf("digest mismatch must fail after only credential type GET: status=%s requests=%#v", res.Status, fake.requests)
	}
}

func TestRunDeleteCallbackCredentialVerifiesThenDeletes(t *testing.T) {
	credential := []byte(`{
		"id":401,
		"name":"sr-callback-018f3f56-1111-7222-8333-123456789abc",
		"credential_type":91,
		"organization":2,
		"inputs":{"callback_grant":"$encrypted$"}
	}`)
	fake := &scriptedHTTPClient{responses: []*sdk.HTTPResponse{
		{Status: http.StatusOK, Body: credential},
		{Status: http.StatusNoContent},
	}}
	swapHTTP(t, fake)

	res := dispatch(callbackCredentialDeleteConfig())
	if res.Status != sdk.StatusOK {
		t.Fatalf("expected OK, got %s: %s", res.Status, res.Summary)
	}
	if len(fake.requests) != 2 || fake.requests[0].Method != http.MethodGet || fake.requests[1].Method != http.MethodDelete {
		t.Fatalf("requests = %#v, want GET then DELETE", fake.requests)
	}
	for _, req := range fake.requests {
		if req.URL != "https://awx.example.com/api/v2/credentials/401/" {
			t.Fatalf("unexpected cleanup URL: %s", req.URL)
		}
	}
	if strings.Contains(res.Details, "$encrypted$") || strings.Contains(res.Details, "inputs") {
		t.Fatalf("cleanup response leaked credential detail: %s", res.Details)
	}
	if !strings.Contains(res.Details, `"cleanup_status":"deleted"`) {
		t.Fatalf("cleanup status missing: %s", res.Details)
	}
}

func TestRunDeleteCallbackCredentialIsIdempotentWhenAlreadyAbsent(t *testing.T) {
	fake := &scriptedHTTPClient{responses: []*sdk.HTTPResponse{{Status: http.StatusNotFound, Body: []byte(`{}`)}}}
	swapHTTP(t, fake)

	res := dispatch(callbackCredentialDeleteConfig())
	if res.Status != sdk.StatusOK || len(fake.requests) != 1 || fake.requests[0].Method != http.MethodGet {
		t.Fatalf("already absent cleanup must be one successful GET: status=%s requests=%#v", res.Status, fake.requests)
	}
	if !strings.Contains(res.Details, `"cleanup_status":"already_absent"`) {
		t.Fatalf("already_absent status missing: %s", res.Details)
	}
}

func TestRunDeleteCallbackCredentialRefusesBindingMismatch(t *testing.T) {
	credential := []byte(`{
		"id":401,
		"name":"unrelated-static-credential",
		"credential_type":91,
		"organization":2
	}`)
	fake := &scriptedHTTPClient{responses: []*sdk.HTTPResponse{{Status: http.StatusOK, Body: credential}}}
	swapHTTP(t, fake)

	res := dispatch(callbackCredentialDeleteConfig())
	if res.Status != sdk.StatusCritical || len(fake.requests) != 1 || fake.requests[0].Method != http.MethodGet {
		t.Fatalf("mismatch must stop before DELETE: status=%s requests=%#v", res.Status, fake.requests)
	}
}

func callbackCredentialDeleteConfig() Config {
	return Config{
		BaseURL: "https://awx.example.com", APIToken: "controller-token",
		Verb: "awx.delete_callback_credential",
		Args: map[string]any{
			"credential_id":      float64(401),
			"credential_type_id": float64(91),
			"organization_id":    float64(2),
			"credential_name":    "sr-callback-018f3f56-1111-7222-8333-123456789abc",
		},
	}
}

func callbackCredentialTypeBody(t *testing.T) []byte {
	t.Helper()
	fields := make([]map[string]any, 0, len(callbackCredentialInputKeys))
	required := make([]string, 0, len(callbackCredentialInputKeys))
	labels := expectedCallbackCredentialFieldLabels()
	for _, id := range callbackCredentialInputKeys {
		fields = append(fields, map[string]any{
			"id":     id,
			"label":  labels[id],
			"type":   "string",
			"secret": id == "callback_grant" || id == "callback_idempotency_key",
		})
		required = append(required, id)
	}
	body, err := json.Marshal(map[string]any{
		"id":      91,
		"kind":    "cloud",
		"managed": false,
		"inputs": map[string]any{
			"fields":   fields,
			"required": required,
		},
		"injectors": map[string]any{
			"env": expectedCallbackCredentialEnvironment(),
		},
	})
	if err != nil {
		t.Fatalf("marshal callback credential type fixture: %v", err)
	}
	return body
}

func callbackCredentialTypeDigest(t *testing.T) string {
	t.Helper()
	contract, err := normalizeCallbackCredentialType(callbackCredentialTypeBody(t), 91)
	if err != nil {
		t.Fatalf("normalize callback credential type fixture: %v", err)
	}
	encoded, err := canonicalCallbackCredentialTypeDocument(contract)
	if err != nil {
		t.Fatalf("marshal callback credential type contract: %v", err)
	}
	return fmt.Sprintf("%x", sha256.Sum256(encoded))
}

func TestCallbackCredentialTypeCanonicalConformanceVector(t *testing.T) {
	contract, err := normalizeCallbackCredentialType(callbackCredentialTypeBody(t), 91)
	if err != nil {
		t.Fatalf("normalize callback credential type fixture: %v", err)
	}
	encoded, err := canonicalCallbackCredentialTypeDocument(contract)
	if err != nil {
		t.Fatalf("encode callback credential type contract: %v", err)
	}
	const expectedCanonical = `{"credential_type_id":91,"environment":{"SERVICERADAR_CALLBACK_ALLOWED_ORIGIN":"{{ callback_allowed_origin }}","SERVICERADAR_CALLBACK_GRANT":"{{ callback_grant }}","SERVICERADAR_CALLBACK_IDEMPOTENCY_KEY":"{{ callback_idempotency_key }}","SERVICERADAR_CALLBACK_MANIFEST_SHA256":"{{ callback_manifest_sha256 }}","SERVICERADAR_CALLBACK_OPERATION":"{{ callback_operation }}","SERVICERADAR_CALLBACK_PHASE":"{{ callback_phase }}","SERVICERADAR_CALLBACK_STATE":"{{ callback_state }}","SERVICERADAR_CALLBACK_URL":"{{ callback_url }}","SERVICERADAR_CONTENT_SHA256":"{{ content_sha256 }}","SERVICERADAR_SCM_REVISION":"{{ scm_revision }}"},"fields":[{"id":"callback_allowed_origin","secret":false,"type":"string"},{"id":"callback_grant","secret":true,"type":"string"},{"id":"callback_idempotency_key","secret":true,"type":"string"},{"id":"callback_manifest_sha256","secret":false,"type":"string"},{"id":"callback_operation","secret":false,"type":"string"},{"id":"callback_phase","secret":false,"type":"string"},{"id":"callback_state","secret":false,"type":"string"},{"id":"callback_url","secret":false,"type":"string"},{"id":"content_sha256","secret":false,"type":"string"},{"id":"scm_revision","secret":false,"type":"string"}],"kind":"cloud","required":["callback_allowed_origin","callback_grant","callback_idempotency_key","callback_manifest_sha256","callback_operation","callback_phase","callback_state","callback_url","content_sha256","scm_revision"],"schema":"serviceradar.awx_callback_credential_type","version":1}`
	if string(encoded) != expectedCanonical {
		t.Fatalf("canonical document mismatch:\n got: %s\nwant: %s", encoded, expectedCanonical)
	}
	digest := fmt.Sprintf("%x", sha256.Sum256(encoded))
	if digest != "cd42bea50b45fcb010c1cc1e89243b8d9d0230bc2fe0b6bb9d49839d17f5a263" {
		t.Fatalf("canonical digest = %s", digest)
	}
}

func TestRunFetchJob(t *testing.T) {
	body := []byte(`{"id": 7331, "status": "successful", "started": "2026-05-10T11:00:00Z", "finished": "2026-05-10T11:02:00Z"}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/jobs/7331/": {Status: http.StatusOK, Body: body},
	}}
	swapHTTP(t, fake)

	cfg := Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.fetch_job",
		Args:     map[string]any{"job_id": float64(7331)},
	}
	res := dispatch(cfg)

	if res.Status != sdk.StatusOK {
		t.Fatalf("got %s: %s", res.Status, res.Summary)
	}
	var payload map[string]any
	_ = json.Unmarshal([]byte(res.Details), &payload)
	if payload["job_id"].(float64) != 7331 {
		t.Errorf("job_id = %v", payload["job_id"])
	}
	if payload["job"] == nil {
		t.Errorf("payload.job missing")
	}
}

func TestRunFetchJobReturnsOnlyReconciliationFieldsAndNonSecretMarkers(t *testing.T) {
	body := []byte(`{
		"id": 7331,
		"status": "running",
		"job_template": 42,
		"inventory": 7,
		"project": 8,
		"scm_revision": "84bf9c8",
		"execution_environment": 9,
		"job_type": "run",
		"diff_mode": false,
		"limit": "web01",
		"instance_group": 3,
		"extra_vars": "{\"serviceradar_dispatch_id\":\"dispatch-1\",\"serviceradar_snapshot_digest\":\"sha256:abc\",\"password\":\"do-not-return\"}",
		"job_env": {"TOKEN": "do-not-return"},
		"job_args": "--vault-password-file do-not-return",
		"artifacts": {"private": "do-not-return"},
		"result_traceback": "do-not-return",
		"launched_by": {"id": 17, "name": "integration", "type": "user", "url": "/api/v2/users/17/"},
		"summary_fields": {
			"credentials": [{"id":101,"name":"machine","kind":"ssh","description":"internal"}],
			"labels": {"count":1,"results":[{"id":301,"name":"canary"}]}
		}
	}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/jobs/7331/": {Status: http.StatusOK, Body: body},
	}}
	swapHTTP(t, fake)
	res := dispatch(Config{
		BaseURL: "https://awx.example.com", APIToken: "tok",
		Verb: "awx.fetch_job", Args: map[string]any{"job_id": 7331},
	})
	if res.Status != sdk.StatusOK {
		t.Fatalf("got %s: %s", res.Status, res.Summary)
	}
	for _, prohibited := range []string{
		"do-not-return", "job_env", "job_args", "artifacts", "result_traceback", `"password"`,
	} {
		if strings.Contains(res.Details, prohibited) {
			t.Errorf("response leaked prohibited job detail %q: %s", prohibited, res.Details)
		}
	}
	var payload struct {
		Job map[string]any `json:"job"`
	}
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	markers, ok := payload.Job["dispatch_markers"].(map[string]any)
	if !ok || markers["serviceradar_dispatch_id"] != "dispatch-1" ||
		markers["serviceradar_snapshot_digest"] != "sha256:abc" {
		t.Errorf("safe markers missing: %v", payload.Job)
	}
	credentials, ok := payload.Job["credentials"].([]any)
	if !ok || len(credentials) != 1 {
		t.Fatalf("credential references missing: %v", payload.Job["credentials"])
	}
	credential := credentials[0].(map[string]any)
	if credential["id"] != float64(101) || credential["kind"] != "ssh" || len(credential) != 2 {
		t.Errorf("credential summary was not minimized: %v", credential)
	}
}

func TestRunFetchJobRequiresJobID(t *testing.T) {
	swapHTTP(t, &fakeHTTPClient{})
	cfg := Config{BaseURL: "https://awx.example.com", APIToken: "tok", Verb: "awx.fetch_job"}
	res := dispatch(cfg)
	if res.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL, got %s", res.Status)
	}
}

func TestRunCurrentUserReturnsNumericIntegrationIdentity(t *testing.T) {
	body := []byte(`{
		"count": 1,
		"next": null,
		"results": [{"id": 17, "username": "serviceradar-awx", "email": "not-returned@example.invalid"}]
	}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/me/?page_size=2": {Status: http.StatusOK, Body: body},
	}}
	swapHTTP(t, fake)

	res := dispatch(Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.current_user",
	})
	if res.Status != sdk.StatusOK {
		t.Fatalf("got %s: %s", res.Status, res.Summary)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	if payload["user_id"] != float64(17) {
		t.Errorf("user_id = %v, want 17", payload["user_id"])
	}
	if payload["username"] != "serviceradar-awx" {
		t.Errorf("username = %v", payload["username"])
	}
	if strings.Contains(res.Details, "not-returned@example.invalid") {
		t.Errorf("current-user response should expose only bounded identity fields")
	}
}

func TestRunCurrentUserFailsClosedWithoutExactlyOneNumericID(t *testing.T) {
	tests := []struct {
		name string
		body string
	}{
		{name: "empty", body: `{"count":0,"next":null,"results":[]}`},
		{name: "multiple", body: `{"count":2,"next":null,"results":[{"id":1},{"id":2}]}`},
		{name: "missing ID", body: `{"count":1,"next":null,"results":[{"username":"integration"}]}`},
		{name: "oversized ID", body: `{"count":1,"next":null,"results":[{"id":2147483648,"username":"integration"}]}`},
		{name: "empty username", body: `{"count":1,"next":null,"results":[{"id":17,"username":""}]}`},
		{name: "unsafe username", body: `{"count":1,"next":null,"results":[{"id":17,"username":"integration\u202esecret"}]}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
				"/api/v2/me/?page_size=2": {Status: http.StatusOK, Body: []byte(tt.body)},
			}}
			swapHTTP(t, fake)
			res := dispatch(Config{BaseURL: "https://awx.example.com", APIToken: "tok", Verb: "awx.current_user"})
			if res.Status != sdk.StatusCritical {
				t.Fatalf("expected CRITICAL, got %s", res.Status)
			}
		})
	}
}

func TestRunListRecentJobsUsesBoundedAWXFiltersAndReturnsMarkersForCaller(t *testing.T) {
	body := []byte(`{
		"count": 2,
		"next": null,
		"results": [
			{"id":7332,"created":"2026-07-12T21:03:00Z","job_template":42,"inventory":7,"launched_by":{"id":17,"type":"user"},"extra_vars":"{\"serviceradar_dispatch_id\":\"other\"}"},
			{"id":7331,"created":"2026-07-12T21:02:00Z","job_template":42,"inventory":7,"launched_by":{"id":17,"type":"user"},"extra_vars":"{\"serviceradar_dispatch_id\":\"dispatch-018f\",\"serviceradar_snapshot_digest\":\"sha256:abc\"}"}
		]
	}`)
	createdAfter := "2026-07-12T16:00:00-05:00"
	wantPath := "/api/v2/jobs/?created__gte=2026-07-12T21%3A00%3A00Z&created_by=17&inventory=7&job_template=42&order_by=-created&page_size=25"
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		wantPath: {Status: http.StatusOK, Body: body},
	}}
	swapHTTP(t, fake)

	res := dispatch(Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.list_recent_jobs",
		Args: map[string]any{
			"template_id":    42.0,
			"inventory_id":   7.0,
			"created_by_id":  17.0,
			"created_after":  createdAfter,
			"page_size":      25.0,
			"max_candidates": 5000.0,
		},
	})
	if res.Status != sdk.StatusOK {
		t.Fatalf("got %s: %s", res.Status, res.Summary)
	}
	if len(fake.requests) != 1 || !strings.HasSuffix(fake.requests[0].URL, wantPath) {
		t.Fatalf("unexpected recent-job request: %+v", fake.requests)
	}
	var payload struct {
		Count         int               `json:"count"`
		Complete      bool              `json:"complete"`
		MaxCandidates int               `json:"max_candidates"`
		Jobs          []json.RawMessage `json:"jobs"`
	}
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	var exactPayload map[string]any
	if err := json.Unmarshal([]byte(res.Details), &exactPayload); err != nil {
		t.Fatalf("decode exact payload: %v", err)
	}
	assertExactMapKeys(t, exactPayload,
		"verb", "ok", "template_id", "inventory_id", "created_by_id", "created_after",
		"page_size", "max_candidates", "count", "complete", "jobs")
	if payload.Count != 2 || !payload.Complete || payload.MaxCandidates != 5000 || len(payload.Jobs) != 2 {
		t.Fatalf("unexpected payload: %+v", payload)
	}
	if !strings.Contains(string(payload.Jobs[1]), "dispatch-018f") {
		t.Errorf("jobs must retain marker-bearing extra_vars for exact caller-side comparison")
	}
}

func TestRunListRecentJobsPaginatesToACompleteCandidateSet(t *testing.T) {
	page1 := []byte(`{
		"count": 2,
		"next": "/api/v2/jobs/?page=2&page_size=1",
		"results": [{"id":7332,"created":"2026-07-12T16:02:00Z","job_template":42,"inventory":7,"launched_by":{"id":17,"type":"user"},"extra_vars":"{}"}]
	}`)
	page2 := []byte(`{
		"count": 2,
		"next": null,
		"results": [{"id":7331,"created":"2026-07-12T16:01:00Z","job_template":42,"inventory":7,"launched_by":{"id":17,"type":"user"},"extra_vars":"{}"}]
	}`)
	fake := &scriptedHTTPClient{responses: []*sdk.HTTPResponse{
		{Status: http.StatusOK, Body: page1},
		{Status: http.StatusOK, Body: page2},
	}}
	swapHTTP(t, fake)
	res := dispatch(Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.list_recent_jobs",
		Args: map[string]any{
			"template_id":    42,
			"inventory_id":   7,
			"created_by_id":  17,
			"created_after":  "2026-07-12T16:00:00Z",
			"page_size":      1,
			"max_candidates": 5000,
		},
	})
	if res.Status != sdk.StatusOK {
		t.Fatalf("got %s: %s", res.Status, res.Summary)
	}
	var payload struct {
		Count    int               `json:"count"`
		Complete bool              `json:"complete"`
		Jobs     []json.RawMessage `json:"jobs"`
	}
	_ = json.Unmarshal([]byte(res.Details), &payload)
	if !payload.Complete || payload.Count != 2 || len(payload.Jobs) != 2 || len(fake.requests) != 2 {
		t.Errorf("candidate set was not completely paginated: payload=%+v requests=%d", payload, len(fake.requests))
	}
}

func TestRunListRecentJobsRejectsCountAboveDurableBound(t *testing.T) {
	fake := &scriptedHTTPClient{responses: []*sdk.HTTPResponse{{
		Status: http.StatusOK,
		Body:   []byte(`{"count":5001,"next":"/api/v2/jobs/?page=2","results":[]}`),
	}}}
	swapHTTP(t, fake)

	res := dispatch(Config{
		BaseURL: "https://awx.example.com", APIToken: "tok",
		Verb: "awx.list_recent_jobs",
		Args: map[string]any{
			"template_id":    42,
			"inventory_id":   7,
			"created_by_id":  17,
			"created_after":  "2026-07-12T16:00:00Z",
			"page_size":      50,
			"max_candidates": 5000,
		},
	})
	if res.Status != sdk.StatusCritical || len(fake.requests) != 1 {
		t.Fatalf("oversized candidate set must fail closed: status=%s requests=%#v", res.Status, fake.requests)
	}
}

func TestRunListRecentJobsRequiresExactScope(t *testing.T) {
	base := map[string]any{
		"template_id":    42,
		"inventory_id":   7,
		"created_by_id":  17,
		"created_after":  "2026-07-12T16:00:00Z",
		"page_size":      50,
		"max_candidates": 5000,
	}
	for _, key := range []string{"template_id", "inventory_id", "created_by_id", "created_after", "page_size", "max_candidates"} {
		t.Run(key, func(t *testing.T) {
			args := make(map[string]any, len(base))
			for k, v := range base {
				args[k] = v
			}
			delete(args, key)
			fake := &fakeHTTPClient{}
			swapHTTP(t, fake)
			res := dispatch(Config{
				BaseURL: "https://awx.example.com", APIToken: "tok",
				Verb: "awx.list_recent_jobs", Args: args,
			})
			if res.Status != sdk.StatusCritical || len(fake.requests) != 0 {
				t.Fatalf("missing %s must fail before AWX contact", key)
			}
		})
	}
}

func TestRunListRecentJobsRejectsControllerResponseOutsideExactScope(t *testing.T) {
	body := []byte(`{
		"count": 1,
		"next": null,
		"results": [{
			"id":7331,
			"created":"2026-07-12T16:01:00Z",
			"job_template":99,
			"inventory":7,
			"launched_by":{"id":17,"type":"user"},
			"extra_vars":"{}"
		}]
	}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"page_size=50": {Status: http.StatusOK, Body: body},
	}}
	swapHTTP(t, fake)
	res := dispatch(Config{
		BaseURL: "https://awx.example.com", APIToken: "tok",
		Verb: "awx.list_recent_jobs",
		Args: map[string]any{
			"template_id":    42,
			"inventory_id":   7,
			"created_by_id":  17,
			"created_after":  "2026-07-12T16:00:00Z",
			"page_size":      50,
			"max_candidates": 5000,
		},
	})
	if res.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL, got %s", res.Status)
	}
	if !strings.Contains(res.Summary, "outside the requested exact scope") {
		t.Errorf("unexpected summary: %q", res.Summary)
	}
}

func TestRunFetchJobHostSummariesPaginatesAndPreservesHostIDs(t *testing.T) {
	page1 := []byte(`{
		"count": 3,
		"next": "/api/v2/jobs/7331/job_host_summaries/?order_by=id&page=2&page_size=200",
		"results": [
			{"id":1,"job":7331,"host":100,"constructed_host":null,"host_name":"pve01","changed":1,"dark":0,"failures":0,"ok":9,"processed":10,"skipped":0,"failed":false,"ignored":0,"rescued":0},
			{"id":2,"job":7331,"host":101,"constructed_host":null,"host_name":"pve01","changed":0,"dark":1,"failures":0,"ok":0,"processed":1,"skipped":0,"failed":true,"ignored":0,"rescued":0}
		]
	}`)
	page2 := []byte(`{
		"count": 3,
		"next": null,
		"results": [
			{"id":3,"job":7331,"host":null,"constructed_host":202,"host_name":"constructed01","changed":0,"dark":0,"failures":0,"ok":2,"processed":2,"skipped":0,"failed":false,"ignored":0,"rescued":0}
		]
	}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/jobs/7331/job_host_summaries/?page_size=200&order_by=id":        {Status: http.StatusOK, Body: page1},
		"/api/v2/jobs/7331/job_host_summaries/?order_by=id&page=2&page_size=200": {Status: http.StatusOK, Body: page2},
	}}
	swapHTTP(t, fake)

	res := dispatch(Config{
		BaseURL: "https://awx.example.com", APIToken: "tok",
		Verb: "awx.fetch_job_host_summaries",
		Args: map[string]any{"job_id": 7331.0, "max_hosts": 3.0},
	})
	if res.Status != sdk.StatusOK {
		t.Fatalf("got %s: %s", res.Status, res.Summary)
	}
	var payload struct {
		Count     int                    `json:"count"`
		Summaries []jobHostSummaryResult `json:"summaries"`
	}
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	if payload.Count != 3 || len(payload.Summaries) != 3 {
		t.Fatalf("unexpected payload: %+v", payload)
	}
	if payload.Summaries[0].HostID == nil || *payload.Summaries[0].HostID != 100 {
		t.Errorf("first host ID = %v", payload.Summaries[0].HostID)
	}
	if payload.Summaries[1].HostID == nil || *payload.Summaries[1].HostID != 101 {
		t.Errorf("duplicate display names must preserve distinct IDs: %+v", payload.Summaries[:2])
	}
	if payload.Summaries[2].HostID != nil || payload.Summaries[2].ConstructedHostID == nil {
		t.Errorf("missing source host must remain missing, not be inferred from name: %+v", payload.Summaries[2])
	}
}

func TestRunFetchJobHostSummariesFailsOnBoundOrCrossJobResult(t *testing.T) {
	tests := []struct {
		name     string
		body     string
		maxHosts int
	}{
		{
			name:     "controller count exceeds bound",
			body:     `{"count":2,"next":null,"results":[]}`,
			maxHosts: 1,
		},
		{
			name:     "summary belongs to another job",
			body:     `{"count":1,"next":null,"results":[{"id":1,"job":9999,"host":100,"host_name":"web01"}]}`,
			maxHosts: 1,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
				"/api/v2/jobs/7331/job_host_summaries/?page_size=200&order_by=id": {Status: http.StatusOK, Body: []byte(tt.body)},
			}}
			swapHTTP(t, fake)
			res := dispatch(Config{
				BaseURL: "https://awx.example.com", APIToken: "tok",
				Verb: "awx.fetch_job_host_summaries",
				Args: map[string]any{"job_id": 7331, "max_hosts": tt.maxHosts},
			})
			if res.Status != sdk.StatusCritical {
				t.Fatalf("expected CRITICAL, got %s", res.Status)
			}
		})
	}
}

func TestRunCancelJob(t *testing.T) {
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/jobs/7331/cancel/": {Status: http.StatusAccepted, Body: []byte(`{}`)},
	}}
	swapHTTP(t, fake)

	cfg := Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.cancel_job",
		Args:     map[string]any{"job_id": float64(7331)},
	}
	res := dispatch(cfg)

	if res.Status != sdk.StatusOK {
		t.Fatalf("got %s: %s", res.Status, res.Summary)
	}
	if len(fake.requests) != 1 {
		t.Fatalf("expected 1 request, got %d", len(fake.requests))
	}
	if fake.requests[0].Method != http.MethodPost {
		t.Errorf("method = %s, want POST", fake.requests[0].Method)
	}
	if len(fake.requests[0].Body) != 0 {
		t.Errorf("body should be empty for cancel, got %q", string(fake.requests[0].Body))
	}
}

func TestRunCancelJobReportsHTTPErrors(t *testing.T) {
	// AWX returns 405 / 409 when the job isn't cancelable.
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/jobs/7331/cancel/": {Status: http.StatusMethodNotAllowed, Body: []byte(`{}`)},
	}}
	swapHTTP(t, fake)

	cfg := Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.cancel_job",
		Args:     map[string]any{"job_id": float64(7331)},
	}
	res := dispatch(cfg)
	if res.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL on 405, got %s", res.Status)
	}
}

func TestRunFetchEventsForJobsBulk(t *testing.T) {
	job1Page := []byte(`{
		"count": 2,
		"next": null,
		"results": [
			{
				"counter": 5,
				"event": "playbook_on_play_start",
				"created": "2026-07-13T12:00:00Z",
				"event_data": {
					"play_uuid": "11111111-1111-4111-8111-111111111111",
					"play": "Deploy"
				}
			},
			{
				"counter": 6,
				"event": "runner_on_ok",
				"changed": true,
				"event_data": {
					"play_uuid": "11111111-1111-4111-8111-111111111111",
					"task_uuid": "22222222-2222-4222-8222-222222222222",
					"host": "web01.example.com"
				}
			}
		]
	}`)
	job2Page := []byte(`{
		"count": 1,
		"next": null,
		"results": [
			{
				"counter": 50,
				"event": "runner_on_ok",
				"event_data": {
					"play_uuid": "33333333-3333-4333-8333-333333333333",
					"task_uuid": "44444444-4444-4444-8444-444444444444",
					"host": "web02.example.com"
				}
			}
		]
	}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/jobs/7331/job_events/?counter__gt=0&page_size=10&order_by=counter":  {Status: http.StatusOK, Body: job1Page},
		"/api/v2/jobs/7332/job_events/?counter__gt=49&page_size=10&order_by=counter": {Status: http.StatusOK, Body: job2Page},
	}}
	swapHTTP(t, fake)

	cfg := Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.fetch_events_for_jobs",
		Args: map[string]any{
			"pairs": []any{
				map[string]any{"job_id": float64(7331), "since_id": float64(0)},
				map[string]any{"job_id": float64(7332), "since_id": float64(49)},
			},
		},
	}
	res := dispatch(cfg)

	if res.Status != sdk.StatusOK {
		t.Fatalf("got %s: %s", res.Status, res.Summary)
	}

	var payload struct {
		OK              bool              `json:"ok"`
		ContractVersion int               `json:"contract_version"`
		Jobs            []jobEventsResult `json:"jobs"`
	}
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	if !payload.OK {
		t.Errorf("payload.ok = false")
	}
	if payload.ContractVersion != 2 {
		t.Errorf("payload.contract_version = %d, want 2", payload.ContractVersion)
	}
	if len(payload.Jobs) != 2 {
		t.Fatalf("expected 2 job entries, got %d", len(payload.Jobs))
	}

	byJob := map[int]jobEventsResult{}
	for _, j := range payload.Jobs {
		byJob[j.JobID] = j
	}
	if got := byJob[7331]; !got.OK || len(got.Events) != 2 || got.MaxCounter != 6 {
		t.Errorf("job 7331 = %+v", got)
	}
	if got := byJob[7332]; !got.OK || len(got.Events) != 1 || got.MaxCounter != 50 {
		t.Errorf("job 7332 = %+v", got)
	}
}

func TestRunFetchEventsForJobsRequiresPairs(t *testing.T) {
	swapHTTP(t, &fakeHTTPClient{})
	cfg := Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.fetch_events_for_jobs",
	}
	res := dispatch(cfg)
	if res.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL, got %s", res.Status)
	}
}

func TestRunFetchEventsForJobsPartialFailure(t *testing.T) {
	// One job succeeds, the other 5xxs. The verb must return ok=true overall
	// with per-job error so the worker can retry the failure next tick
	// without losing the success.
	job1Page := []byte(`{"count":0,"next":null,"results":[]}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/jobs/7331/job_events/?counter__gt=0&page_size=10&order_by=counter": {Status: http.StatusOK, Body: job1Page},
		"/api/v2/jobs/9999/job_events/?counter__gt=0&page_size=10&order_by=counter": {Status: http.StatusInternalServerError, Body: []byte(`{"detail":"SR_EVENT_FAILURE_SECRET"}`)},
	}}
	swapHTTP(t, fake)

	cfg := Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.fetch_events_for_jobs",
		Args: map[string]any{
			"pairs": []any{
				map[string]any{"job_id": float64(7331), "since_id": float64(0)},
				map[string]any{"job_id": float64(9999), "since_id": float64(0)},
			},
		},
	}
	res := dispatch(cfg)

	if res.Status != sdk.StatusOK {
		t.Fatalf("partial failure should still be top-level OK, got %s", res.Status)
	}
	if !strings.Contains(res.Summary, "1/2") {
		t.Errorf("summary should report 1/2 success, got %q", res.Summary)
	}

	var payload struct {
		Jobs []jobEventsResult `json:"jobs"`
	}
	_ = json.Unmarshal([]byte(res.Details), &payload)
	byJob := map[int]jobEventsResult{}
	for _, j := range payload.Jobs {
		byJob[j.JobID] = j
	}
	if !byJob[7331].OK {
		t.Errorf("job 7331 should be ok")
	}
	if byJob[9999].OK {
		t.Errorf("job 9999 should NOT be ok")
	}
	if byJob[9999].Error != awxEventFetchFailure {
		t.Errorf("job 9999 error = %q, want fixed error", byJob[9999].Error)
	}
	if strings.Contains(res.Details, "SR_EVENT_FAILURE_SECRET") {
		t.Fatalf("per-job failure leaked controller response: %s", res.Details)
	}
}

func TestRunFetchEventsForJobsRejectsInexactDuplicateOrUnboundedPairs(t *testing.T) {
	validPair := func(jobID int) map[string]any {
		return map[string]any{"job_id": jobID, "since_id": 0}
	}
	eleven := make([]any, 11)
	for i := range eleven {
		eleven[i] = validPair(i + 1)
	}
	tests := []struct {
		name string
		args map[string]any
	}{
		{name: "empty", args: map[string]any{"pairs": []any{}}},
		{name: "more than ten", args: map[string]any{"pairs": eleven}},
		{name: "duplicate job", args: map[string]any{"pairs": []any{validPair(1), validPair(1)}}},
		{name: "missing since", args: map[string]any{"pairs": []any{map[string]any{"job_id": 1}}}},
		{name: "extra pair property", args: map[string]any{"pairs": []any{map[string]any{"job_id": 1, "since_id": 0, "unsafe": true}}}},
		{name: "negative since", args: map[string]any{"pairs": []any{map[string]any{"job_id": 1, "since_id": -1}}}},
		{name: "fractional job", args: map[string]any{"pairs": []any{map[string]any{"job_id": 1.5, "since_id": 0}}}},
		{name: "extra args", args: map[string]any{"pairs": []any{validPair(1)}, "page_size": 1000}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fake := &fakeHTTPClient{}
			swapHTTP(t, fake)
			res := dispatch(Config{
				BaseURL:  "https://awx.example.com",
				APIToken: "tok",
				Verb:     "awx.fetch_events_for_jobs",
				Args:     test.args,
			})
			if res.Status != sdk.StatusCritical {
				t.Fatalf("expected CRITICAL, got %s", res.Status)
			}
			if len(fake.requests) != 0 {
				t.Fatalf("invalid args issued %d HTTP requests", len(fake.requests))
			}
		})
	}
}

func TestRunFetchEventsForJobsUsesOneTenEventWindowAndAdvancesPastUnhandled(t *testing.T) {
	results := make([]map[string]any, 0, 10)
	for counter := 1; counter <= 9; counter++ {
		results = append(results, map[string]any{
			"counter": counter,
			"event":   "playbook_on_play_start",
			"event_data": map[string]any{
				"play_uuid": "11111111-1111-4111-8111-111111111111",
				"play":      "Deploy",
			},
		})
	}
	results = append(results, map[string]any{
		"counter":    10,
		"event":      "verbose",
		"stdout":     "SR_UNHANDLED_EVENT_SECRET",
		"event_data": map[string]any{"msg": "SR_UNHANDLED_EVENT_SECRET"},
	})
	firstPage, err := json.Marshal(map[string]any{
		"count":   11,
		"next":    "/api/v2/jobs/7331/job_events/?counter__gt=0&page=2",
		"results": results,
	})
	if err != nil {
		t.Fatalf("encode first page: %v", err)
	}
	secondPage := []byte(`{
		"count": 1,
		"next": null,
		"results": [{
			"counter": 11,
			"event": "playbook_on_play_start",
			"event_data": {"play_uuid":"11111111-1111-4111-8111-111111111111"}
		}]
	}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/jobs/7331/job_events/?counter__gt=0&page_size=10&order_by=counter":  {Status: http.StatusOK, Body: firstPage},
		"/api/v2/jobs/7331/job_events/?counter__gt=10&page_size=10&order_by=counter": {Status: http.StatusOK, Body: secondPage},
	}}
	swapHTTP(t, fake)

	fetch := func(sinceID int) jobEventsResult {
		t.Helper()
		res := dispatch(Config{
			BaseURL:  "https://awx.example.com",
			APIToken: "tok",
			Verb:     "awx.fetch_events_for_jobs",
			Args: map[string]any{
				"pairs": []any{map[string]any{"job_id": 7331, "since_id": sinceID}},
			},
		})
		if res.Status != sdk.StatusOK {
			t.Fatalf("fetch since %d failed: %s", sinceID, res.Summary)
		}
		if strings.Contains(res.Details, "SR_UNHANDLED_EVENT_SECRET") {
			t.Fatalf("unhandled event leaked into result: %s", res.Details)
		}
		var payload struct {
			Jobs []jobEventsResult `json:"jobs"`
		}
		if err := json.Unmarshal([]byte(res.Details), &payload); err != nil || len(payload.Jobs) != 1 {
			t.Fatalf("decode result: jobs=%d err=%v", len(payload.Jobs), err)
		}
		return payload.Jobs[0]
	}

	first := fetch(0)
	if first.MaxCounter != 10 || first.Count != 9 || len(first.Events) != 9 {
		t.Fatalf("first window = %+v, want max=10 and 9 projected events", first)
	}
	second := fetch(first.MaxCounter)
	if second.MaxCounter != 11 || second.Count != 1 || len(second.Events) != 1 {
		t.Fatalf("second window = %+v, want max=11 and 1 projected event", second)
	}
	if len(fake.requests) != 2 {
		t.Fatalf("expected exactly one HTTP request per tick, got %d", len(fake.requests))
	}
}

func TestRunFetchEventsForJobsProjectsRunnerEventWithoutArbitraryOutput(t *testing.T) {
	sentinel := "SR_RUNNER_EVENT_SECRET_DO_NOT_PERSIST"
	overlong := strings.Repeat("x", maxAWXEventPathBytes+1) + sentinel
	page, err := json.Marshal(map[string]any{
		"count": 2,
		"next":  nil,
		"results": []any{
			map[string]any{
				"counter": 1,
				"event":   "runner_on_failed",
				"created": "2026-07-13T12:00:00.123456Z",
				"changed": false,
				"failed":  true,
				"stdout":  sentinel,
				"stderr":  sentinel,
				"event_data": map[string]any{
					"play_uuid":        "11111111-1111-4111-8111-111111111111",
					"task_uuid":        "22222222-2222-4222-8222-222222222222",
					"host":             "web01.example.com",
					"task":             "Install package",
					"play":             overlong,
					"task_action":      overlong,
					"task_path":        overlong,
					"ignore_errors":    true,
					"delegated":        "unsafe:delegated",
					"facts":            map[string]any{"password": sentinel},
					"set_stats":        map[string]any{"secret": sentinel},
					"unknown":          sentinel,
					"task_line_number": 42,
					"res": map[string]any{
						"rc":            7,
						"stdout":        sentinel,
						"stderr":        sentinel,
						"cmd":           sentinel,
						"msg":           sentinel,
						"warnings":      []string{sentinel},
						"ansible_facts": map[string]any{"token": sentinel},
					},
				},
			},
			map[string]any{
				"counter": 2,
				"event":   "runner_on_ok",
				"event_data": map[string]any{
					"play_uuid": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
					"task_uuid": "22222222-2222-4222-8222-222222222222",
					"host":      "web01.example.com",
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("encode page: %v", err)
	}
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/jobs/7331/job_events/?counter__gt=0&page_size=10&order_by=counter": {Status: http.StatusOK, Body: page},
	}}
	swapHTTP(t, fake)

	res := dispatch(Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.fetch_events_for_jobs",
		Args: map[string]any{
			"pairs": []any{map[string]any{"job_id": 7331, "since_id": 0}},
		},
	})
	if res.Status != sdk.StatusOK {
		t.Fatalf("got %s: %s", res.Status, res.Summary)
	}
	if strings.Contains(res.Details, sentinel) {
		t.Fatalf("projected runner event leaked sentinel: %s", res.Details)
	}

	var payload struct {
		Jobs []jobEventsResult `json:"jobs"`
	}
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil || len(payload.Jobs) != 1 {
		t.Fatalf("decode payload: jobs=%d err=%v", len(payload.Jobs), err)
	}
	job := payload.Jobs[0]
	if job.MaxCounter != 2 || job.Count != 2 || len(job.Events) != 2 {
		t.Fatalf("job = %+v, want two safe projected events", job)
	}
	var event map[string]any
	if err := json.Unmarshal(job.Events[0], &event); err != nil {
		t.Fatalf("decode event: %v", err)
	}
	assertExactMapKeys(t, event, "event", "counter", "created", "changed", "failed", "event_data")
	data := event["event_data"].(map[string]any)
	assertExactMapKeys(t, data,
		"play_uuid", "task_uuid", "host", "task", "ignore_errors", "res")
	result := data["res"].(map[string]any)
	assertExactMapKeys(t, result, "rc")
	if result["rc"] != float64(7) {
		t.Fatalf("projected rc = %v, want 7", result["rc"])
	}
}

func TestRunFetchEventsForJobsFailsMalformedHandledEventWithoutAdvancing(t *testing.T) {
	page := []byte(`{
		"count": 1,
		"next": null,
		"results": [{
			"counter": 1,
			"event": "runner_on_ok",
			"event_data": {
				"play_uuid": "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
				"task_uuid": "22222222-2222-4222-8222-222222222222",
				"host": "web01"
			}
		}]
	}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/jobs/7331/job_events/?counter__gt=0&page_size=10&order_by=counter": {Status: http.StatusOK, Body: page},
	}}
	swapHTTP(t, fake)

	res := dispatch(Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.fetch_events_for_jobs",
		Args: map[string]any{
			"pairs": []any{map[string]any{"job_id": 7331, "since_id": 0}},
		},
	})
	if res.Status != sdk.StatusOK {
		t.Fatalf("bulk fetch should report the bounded per-job failure: %s", res.Summary)
	}
	var payload struct {
		Jobs []jobEventsResult `json:"jobs"`
	}
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil || len(payload.Jobs) != 1 {
		t.Fatalf("decode payload: jobs=%d err=%v", len(payload.Jobs), err)
	}
	job := payload.Jobs[0]
	if job.OK || job.Error != awxEventFetchFailure || job.MaxCounter != 0 || job.Count != 0 || len(job.Events) != 0 {
		t.Fatalf("malformed handled event must fail without advancing: %+v", job)
	}
}

func TestRunFetchEventsForJobsProjectsExactNumericStats(t *testing.T) {
	sentinel := "SR_STATS_EVENT_SECRET_DO_NOT_PERSIST"
	page := []byte(`{
		"count": 1,
		"next": null,
		"results": [{
			"counter": 12,
			"event": "playbook_on_stats",
			"event_data": {
				"ok": {"web01": 4},
				"failures": {"web02": 1},
				"dark": {},
				"skipped": {"web01": 2},
				"changed": {"web01": 3},
				"set_stats": {"secret": "SR_STATS_EVENT_SECRET_DO_NOT_PERSIST"},
				"artifact_data": {"token": "SR_STATS_EVENT_SECRET_DO_NOT_PERSIST"}
			},
			"stdout": "SR_STATS_EVENT_SECRET_DO_NOT_PERSIST"
		}]
	}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/jobs/7331/job_events/?counter__gt=11&page_size=10&order_by=counter": {Status: http.StatusOK, Body: page},
	}}
	swapHTTP(t, fake)

	res := dispatch(Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.fetch_events_for_jobs",
		Args: map[string]any{
			"pairs": []any{map[string]any{"job_id": 7331, "since_id": 11}},
		},
	})
	if res.Status != sdk.StatusOK || strings.Contains(res.Details, sentinel) {
		t.Fatalf("unsafe stats projection: status=%s details=%s", res.Status, res.Details)
	}
	var payload struct {
		Jobs []jobEventsResult `json:"jobs"`
	}
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	var event map[string]any
	if err := json.Unmarshal(payload.Jobs[0].Events[0], &event); err != nil {
		t.Fatalf("decode stats event: %v", err)
	}
	assertExactMapKeys(t, event, "event", "counter", "event_data")
	data := event["event_data"].(map[string]any)
	assertExactMapKeys(t, data, "ok", "failures", "dark", "skipped", "changed")
	if data["ok"].(map[string]any)["web01"] != float64(4) {
		t.Fatalf("stats ok projection = %#v", data["ok"])
	}
}

func assertExactMapKeys(t *testing.T, values map[string]any, expected ...string) {
	t.Helper()
	if len(values) != len(expected) {
		t.Fatalf("map keys = %v, want exactly %v", sortedMapKeys(values), expected)
	}
	for _, key := range expected {
		if _, present := values[key]; !present {
			t.Fatalf("map keys = %v, missing %q", sortedMapKeys(values), key)
		}
	}
}

func sortedMapKeys(values map[string]any) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func TestRunInventorySyncBuildsDeviceDiscovery(t *testing.T) {
	inventories := []byte(`{
		"count": 2,
		"next": null,
		"results": [
			{"id": 7, "name": "Production"},
			{"id": 8, "name": "Lab"}
		]
	}`)
	prodHosts := []byte(`{
		"count": 2,
		"next": null,
		"results": [
			{"id": 100, "name": "web01.example.com", "inventory": 7, "enabled": true, "variables": "ansible_host: 10.0.0.5\nansible_user: ubuntu\n"},
			{"id": 101, "name": "web02.example.com", "inventory": 7, "enabled": true, "variables": "{\"ansible_host\":\"10.0.0.6\"}"}
		]
	}`)
	labHosts := []byte(`{
		"count": 1,
		"next": null,
		"results": [
			{"id": 200, "name": "lab01", "inventory": 8, "enabled": false, "variables": ""}
		]
	}`)

	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/inventories/?page_size=200":         {Status: http.StatusOK, Body: inventories},
		"/api/v2/inventories/7/hosts/?page_size=200": {Status: http.StatusOK, Body: prodHosts},
		"/api/v2/inventories/8/hosts/?page_size=200": {Status: http.StatusOK, Body: labHosts},
	}}
	swapHTTP(t, fake)

	cfg := InventorySyncConfig{
		ControllerID:   "ctrl-uuid-1",
		ControllerName: "Production AWX",
		BaseURL:        "https://awx.example.com",
		APIToken:       "tok",
	}
	res := runInventorySync(cfg)

	if res.Status != sdk.StatusOK {
		t.Fatalf("got %s: %s", res.Status, res.Summary)
	}
	if !strings.Contains(res.Summary, "3 hosts") {
		t.Errorf("summary should report 3 hosts, got %q", res.Summary)
	}
	if !strings.Contains(res.Summary, "2 inventories") {
		t.Errorf("summary should report 2 inventories, got %q", res.Summary)
	}

	if len(res.DeviceDiscovery) != 1 {
		t.Fatalf("expected 1 DeviceDiscovery, got %d", len(res.DeviceDiscovery))
	}
	disc := res.DeviceDiscovery[0]
	if disc.Source != "awx" {
		t.Errorf("source = %q, want awx", disc.Source)
	}
	if !strings.HasPrefix(disc.CollectionID, "awx-ctrl-uuid-1-") {
		t.Errorf("collection_id = %q", disc.CollectionID)
	}
	if disc.Metadata["controller_id"] != "ctrl-uuid-1" {
		t.Errorf("metadata.controller_id = %v", disc.Metadata["controller_id"])
	}
	if disc.Metadata["controller_name"] != "Production AWX" {
		t.Errorf("metadata.controller_name = %v", disc.Metadata["controller_name"])
	}
	if generation, ok := disc.Metadata["source_generation"].(int64); !ok || generation <= 0 {
		t.Errorf("metadata.source_generation = %#v", disc.Metadata["source_generation"])
	}
	if disc.Metadata["complete"] != true {
		t.Errorf("metadata.complete = %#v, want true", disc.Metadata["complete"])
	}
	if fingerprint, ok := disc.Metadata["source_fingerprint"].(string); !ok || len(fingerprint) != 71 || !strings.HasPrefix(fingerprint, "sha256:") {
		t.Errorf("metadata.source_fingerprint = %#v", disc.Metadata["source_fingerprint"])
	}
	if len(disc.Devices) != 3 {
		t.Fatalf("expected 3 devices, got %d", len(disc.Devices))
	}

	byID := map[string]sdk.DiscoveredDevice{}
	for _, d := range disc.Devices {
		byID[d.DeviceID] = d
	}

	web01 := byID["awx:ctrl-uuid-1:host:100"]
	if web01.Hostname != "web01.example.com" {
		t.Errorf("web01.hostname = %q", web01.Hostname)
	}
	if web01.IP != "10.0.0.5" {
		t.Errorf("web01.ip = %q (YAML variables should resolve)", web01.IP)
	}
	if web01.Labels["controller_id"] != "ctrl-uuid-1" {
		t.Errorf("web01.labels.controller_id = %v", web01.Labels["controller_id"])
	}
	if web01.Labels["provider"] != "awx" {
		t.Errorf("web01.labels.provider = %v", web01.Labels["provider"])
	}
	awxMeta, ok := web01.Metadata["awx"].(map[string]any)
	if !ok {
		t.Fatalf("web01.metadata.awx not a map: %T", web01.Metadata["awx"])
	}
	if awxMeta["host_id"].(int) != 100 {
		t.Errorf("metadata.awx.host_id = %v", awxMeta["host_id"])
	}
	if awxMeta["inventory_id"].(int) != 7 {
		t.Errorf("metadata.awx.inventory_id = %v", awxMeta["inventory_id"])
	}
	if awxMeta["ansible_host"] != "10.0.0.5" {
		t.Errorf("metadata.awx.ansible_host = %v", awxMeta["ansible_host"])
	}
	if _, present := awxMeta["variables"]; present {
		t.Error("secret-capable AWX variables must not enter discovery metadata")
	}

	web02 := byID["awx:ctrl-uuid-1:host:101"]
	if web02.IP != "10.0.0.6" {
		t.Errorf("web02.ip = %q (JSON variables should resolve)", web02.IP)
	}

	lab01 := byID["awx:ctrl-uuid-1:host:200"]
	if lab01.IP != "" {
		t.Errorf("lab01.ip should be empty (no variables), got %q", lab01.IP)
	}
	if lab01.IsAvailable == nil || *lab01.IsAvailable {
		t.Errorf("lab01.is_available should reflect enabled=false")
	}
}

func TestRunInventorySyncContinuesOnPerInventoryError(t *testing.T) {
	inventories := []byte(`{
		"count": 2,
		"next": null,
		"results": [
			{"id": 7, "name": "Production"},
			{"id": 8, "name": "Broken"}
		]
	}`)
	prodHosts := []byte(`{"count":1,"next":null,"results":[{"id":100,"name":"ok","inventory":7,"enabled":true}]}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/inventories/?page_size=200":         {Status: http.StatusOK, Body: inventories},
		"/api/v2/inventories/7/hosts/?page_size=200": {Status: http.StatusOK, Body: prodHosts},
		"/api/v2/inventories/8/hosts/?page_size=200": {Status: http.StatusInternalServerError, Body: []byte(`{}`)},
	}}
	swapHTTP(t, fake)

	cfg := InventorySyncConfig{
		ControllerID: "ctrl-1",
		BaseURL:      "https://awx.example.com",
		APIToken:     "tok",
	}
	res := runInventorySync(cfg)

	if res.Status != sdk.StatusOK {
		t.Fatalf("expected OK with partial coverage, got %s", res.Status)
	}
	if len(res.DeviceDiscovery) != 1 {
		t.Fatalf("expected 1 DeviceDiscovery, got %d", len(res.DeviceDiscovery))
	}
	disc := res.DeviceDiscovery[0]
	if len(disc.Devices) != 1 {
		t.Errorf("expected 1 device from working inventory, got %d", len(disc.Devices))
	}
	if _, has := disc.Metadata["error_inventory_8"]; !has {
		t.Errorf("expected metadata.error_inventory_8 to flag the failure, got %+v", disc.Metadata)
	}
	if disc.Metadata["complete"] != false {
		t.Errorf("partial inventory walk must set metadata.complete=false, got %#v", disc.Metadata["complete"])
	}
}

func TestInventorySourceFingerprintIsOrderIndependent(t *testing.T) {
	first := []sdk.DiscoveredDevice{{DeviceID: "awx:ctrl:host:2"}, {DeviceID: "awx:ctrl:host:1"}}
	second := []sdk.DiscoveredDevice{{DeviceID: "awx:ctrl:host:1"}, {DeviceID: "awx:ctrl:host:2"}}

	if inventorySourceFingerprint("ctrl", first) != inventorySourceFingerprint("ctrl", second) {
		t.Fatal("source fingerprint must not depend on AWX result ordering")
	}
}

func TestRunInventorySyncSupportsMultipleControllers(t *testing.T) {
	inventories := []byte(`{
		"count": 1,
		"next": null,
		"results": [
			{"id": 7, "name": "Production"}
		]
	}`)
	hosts := []byte(`{"count":1,"next":null,"results":[{"id":100,"name":"web01","inventory":7,"enabled":true}]}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/inventories/?page_size=200":         {Status: http.StatusOK, Body: inventories},
		"/api/v2/inventories/7/hosts/?page_size=200": {Status: http.StatusOK, Body: hosts},
	}}
	swapHTTP(t, fake)

	cfg := InventorySyncConfig{
		Controllers: []InventorySyncControllerConfig{
			{
				ControllerID:   "ctrl-a",
				ControllerName: "AWX A",
				BaseURL:        "https://awx-a.example.com",
				APIToken:       "tok-a",
			},
			{
				ControllerID:   "ctrl-b",
				ControllerName: "AWX B",
				BaseURL:        "https://awx-b.example.com",
				APIToken:       "tok-b",
			},
		},
	}
	res := runInventorySync(cfg)

	if res.Status != sdk.StatusOK {
		t.Fatalf("expected OK, got %s: %s", res.Status, res.Summary)
	}
	if len(res.DeviceDiscovery) != 2 {
		t.Fatalf("expected 2 DeviceDiscovery envelopes, got %d", len(res.DeviceDiscovery))
	}
	if res.Labels["controllers"] != "2" {
		t.Errorf("controllers label = %q", res.Labels["controllers"])
	}
	if res.Labels["hosts"] != "2" {
		t.Errorf("hosts label = %q", res.Labels["hosts"])
	}

	gotIDs := map[string]bool{}
	for _, discovery := range res.DeviceDiscovery {
		if len(discovery.Devices) != 1 {
			t.Fatalf("expected one device per discovery, got %d", len(discovery.Devices))
		}
		gotIDs[discovery.Devices[0].DeviceID] = true
	}
	if !gotIDs["awx:ctrl-a:host:100"] || !gotIDs["awx:ctrl-b:host:100"] {
		t.Fatalf("missing controller-scoped device IDs: %#v", gotIDs)
	}
}

func TestInventorySyncConfigAcceptsHostCredentialSentinelContract(t *testing.T) {
	payload := []byte(`{
		"controllers": [
			{
				"controller_id": "awx-a",
				"controller_name": "AWX A",
				"base_url": "https://awx-a.example.invalid",
				"api_token": "__SERVICERADAR_AWX_INVENTORY_HOST_CREDENTIAL__",
				"timeout_ms": 30000,
				"insecure_skip_verify": false
			},
			{
				"controller_id": "awx-b",
				"base_url": "https://awx-b.example.invalid",
				"api_token": "__SERVICERADAR_AWX_INVENTORY_HOST_CREDENTIAL__"
			}
		]
	}`)

	var cfg InventorySyncConfig
	if err := json.Unmarshal(payload, &cfg); err != nil {
		t.Fatalf("unmarshal host-sentinel controller-list contract: %v", err)
	}
	if err := validateInventorySyncConfig(cfg); err != nil {
		t.Fatalf("validate host-sentinel controller-list contract: %v", err)
	}
}

func TestInventorySyncConfigRejectsPlaintextControllerToken(t *testing.T) {
	t.Parallel()

	cfg := InventorySyncConfig{Controllers: []InventorySyncControllerConfig{{
		ControllerID: "controller-a",
		BaseURL:      "https://awx-a.example.test",
		APIToken:     "plaintext-token-must-not-enter-wasm",
	}}}
	if err := validateInventorySyncConfig(cfg); err == nil {
		t.Fatal("validateInventorySyncConfig accepted a plaintext controller token")
	}
}

func TestRunInventorySyncFailsHardWhenInventoriesEndpointFails(t *testing.T) {
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/inventories/?page_size=200": {Status: http.StatusInternalServerError, Body: []byte(`{}`)},
	}}
	swapHTTP(t, fake)

	cfg := InventorySyncConfig{
		ControllerID: "ctrl-1",
		BaseURL:      "https://awx.example.com",
		APIToken:     "tok",
	}
	res := runInventorySync(cfg)

	if res.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL when inventories endpoint fails, got %s", res.Status)
	}
}

func TestExtractAnsibleHostFromVariables(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"", ""},
		{"ansible_host: 10.0.0.1\nansible_user: ubuntu", "10.0.0.1"},
		{`{"ansible_host":"10.0.0.2"}`, "10.0.0.2"},
		{`ansible_host: "host.example.com"`, "host.example.com"},
		{`ansible_ssh_host: 192.168.1.1`, "192.168.1.1"},
		{`ansible_host: 10.0.0.1 # comment`, "10.0.0.1"},
		{"unrelated: value\nfoo: bar", ""},
	}
	for _, c := range cases {
		if got := extractAnsibleHostFromVariables(c.in); got != c.want {
			t.Errorf("extractAnsibleHostFromVariables(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestIsProbablyIP(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"10.0.0.1", true},
		{"192.168.1.255", true},
		{"::1", true},
		{"fe80::1", true},
		{"host.example.com", false},
		{"10.0.0", false},
		{"10.0.0.1.5", false},
		{"", false},
	}
	for _, c := range cases {
		if got := isProbablyIP(c.in); got != c.want {
			t.Errorf("isProbablyIP(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestArgHelpers(t *testing.T) {
	args := map[string]any{
		"int_f": float64(7),
		"int_i": 10,
		"str":   "hello",
		"map":   map[string]any{"a": 1.0},
		"wrong": []any{},
	}
	if v, ok := argInt(args, "int_f"); !ok || v != 7 {
		t.Errorf("argInt(float64) = (%d, %v)", v, ok)
	}
	if v, ok := argInt(args, "int_i"); !ok || v != 10 {
		t.Errorf("argInt(int) = (%d, %v)", v, ok)
	}
	if _, ok := argInt(args, "wrong"); ok {
		t.Errorf("argInt(wrong type) should return ok=false")
	}
	if v, ok := argString(args, "str"); !ok || v != "hello" {
		t.Errorf("argString = (%q, %v)", v, ok)
	}
	if v, ok := argMap(args, "map"); !ok || v["a"].(float64) != 1.0 {
		t.Errorf("argMap = (%v, %v)", v, ok)
	}
}

func TestRunListInventoriesPaginates(t *testing.T) {
	page1 := []byte(`{
		"count": 3,
		"next": "/api/v2/inventories/?page=2&page_size=2",
		"previous": null,
		"results": [
			{"id": 1, "name": "Production", "kind":"", "organization":1, "total_hosts":10,
			 "variables":"password: SR_CATALOG_SECRET", "url":"https://SR_CATALOG_SECRET"},
			{"id": 2, "name": "Staging", "kind":"smart", "organization":1, "total_hosts":5}
		]
	}`)
	page2 := []byte(`{
		"count": 3,
		"next": null,
		"previous": "/api/v2/inventories/?page=1&page_size=2",
		"results": [
			{"id": 3, "name": "Lab", "kind":"constructed", "organization":null, "total_hosts":2}
		]
	}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/inventories/?page_size=200":      {Status: http.StatusOK, Body: page1},
		"/api/v2/inventories/?page=2&page_size=2": {Status: http.StatusOK, Body: page2},
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
	if strings.Contains(res.Details, "SR_CATALOG_SECRET") || strings.Contains(res.Details, "variables") {
		t.Fatalf("inventory projection leaked controller metadata: %s", res.Details)
	}
	var firstInventory map[string]any
	if err := json.Unmarshal(payload.Results[0], &firstInventory); err != nil {
		t.Fatalf("decode projected inventory: %v", err)
	}
	assertExactMapKeys(t, firstInventory, "id", "name", "kind", "organization", "total_hosts")
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
		"results": [{"id": 1, "name": "X", "kind":"", "organization":1, "total_hosts":0}]
	}`)
	page2 := []byte(`{"count": 1, "next": null, "results": []}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/inventories/?page_size=200":        {Status: http.StatusOK, Body: page1},
		"/api/v2/inventories/?page=2&page_size=200": {Status: http.StatusOK, Body: page2},
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
			{"id": 100, "name": "web01", "inventory": 7, "enabled": true,
			 "variables":"api_token: SR_HOST_SECRET", "related":{"facts":"SR_HOST_SECRET"}},
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
	if strings.Contains(res.Details, "SR_HOST_SECRET") || strings.Contains(res.Details, "variables") {
		t.Fatalf("host projection leaked controller metadata: %s", res.Details)
	}
	var firstHost map[string]any
	if err := json.Unmarshal(payload.Results[0], &firstHost); err != nil {
		t.Fatalf("decode projected host: %v", err)
	}
	assertExactMapKeys(t, firstHost, "id", "name", "inventory", "enabled")
}

func TestRunListInventoryGroupsReturnsExactNamesForLimitCollisionChecks(t *testing.T) {
	body := []byte(`{
		"count": 3,
		"next": null,
		"results": [
			{"id": 201, "name": "linux"},
			{"id": 202, "name": "pve01", "variables": "api_token: do-not-return"},
			{"id": 203, "name": "windows"}
		]
	}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/inventories/7/groups/?page_size=200&order_by=id": {Status: http.StatusOK, Body: body},
	}}
	swapHTTP(t, fake)

	res := dispatch(Config{
		BaseURL: "https://awx.example.com", APIToken: "tok",
		Verb: "awx.list_inventory_groups",
		Args: map[string]any{"inventory_id": 7.0, "max_groups": 10.0},
	})
	if res.Status != sdk.StatusOK {
		t.Fatalf("got %s: %s", res.Status, res.Summary)
	}
	var payload listResultPayload
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	if payload.Count != 3 || len(payload.Results) != 3 {
		t.Fatalf("unexpected payload: %+v", payload)
	}
	if !strings.Contains(string(payload.Results[1]), `"name":"pve01"`) {
		t.Errorf("group names must remain available for exact host/group collision checks")
	}
	if strings.Contains(res.Details, "do-not-return") || strings.Contains(res.Details, "variables") {
		t.Errorf("group inventory variables must not enter reconciliation command results")
	}
	// `all` and `ungrouped` are implicit Ansible tokens and therefore are not
	// synthesized by this AWX endpoint. The launch planner must reject them
	// independently even when they do not appear in this result.
}

func TestRunListInventoryGroupsFailsWhenControllerCountExceedsBound(t *testing.T) {
	body := []byte(`{"count":2,"next":null,"results":[{"id":201,"name":"linux"}]}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/inventories/7/groups/?page_size=200&order_by=id": {Status: http.StatusOK, Body: body},
	}}
	swapHTTP(t, fake)
	res := dispatch(Config{
		BaseURL: "https://awx.example.com", APIToken: "tok",
		Verb: "awx.list_inventory_groups",
		Args: map[string]any{"inventory_id": 7, "max_groups": 1},
	})
	if res.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL, got %s", res.Status)
	}
	if !strings.Contains(res.Summary, "exceeds bound") {
		t.Errorf("expected bound failure, got %q", res.Summary)
	}
}

func TestRunFetchTemplateMergesTemplateAndSurvey(t *testing.T) {
	tmpl := []byte(`{
		"id":42,"name":"Deploy","description":"Deploy app","job_tags":"deploy","limit":"",
		"job_type":"run","playbook":"deploy.yml","project":7,"inventory":8,
		"survey_enabled":true,"ask_variables_on_launch":true,
		"ask_inventory_on_launch":false,"ask_limit_on_launch":true,
		"ask_credential_on_launch":true
	}`)
	survey := []byte(`{
		"name":"Deploy Survey","description":"Reviewed inputs","spec":[{
			"variable":"version","question_name":"Version","question_description":"Release version",
			"type":"text","required":true,"min":1,"max":20,"default":"must-not-cross"
		}]
	}`)
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
	if strings.Contains(res.Details, "must-not-cross") || strings.Contains(res.Details, `"default"`) {
		t.Fatalf("survey default crossed the source projection: %s", res.Details)
	}
	template := payload["template"].(map[string]any)
	assertExactMapKeys(t, template,
		"id", "name", "description", "job_tags", "limit", "job_type", "playbook", "project",
		"inventory", "survey_enabled", "ask_variables_on_launch", "ask_inventory_on_launch", "ask_limit_on_launch",
		"ask_credential_on_launch")
	surveySpec := payload["survey_spec"].(map[string]any)
	assertExactMapKeys(t, surveySpec, "spec")
	fields := surveySpec["spec"].([]any)
	field := fields[0].(map[string]any)
	assertExactMapKeys(t, field,
		"variable", "question_name", "question_description", "type", "required", "min", "max")
	if len(fake.requests) != 2 {
		t.Errorf("expected 2 requests (template + survey_spec), got %d", len(fake.requests))
	}
}

func TestRunFetchTemplateToleratesMissingSurvey(t *testing.T) {
	tmpl := []byte(`{
		"id":42,"name":"Deploy","description":"","job_tags":"","limit":"",
		"job_type":"run","playbook":"deploy.yml","project":7,"inventory":8,
		"survey_enabled":false,"ask_variables_on_launch":false,
		"ask_inventory_on_launch":false,"ask_limit_on_launch":false,
		"ask_credential_on_launch":false
	}`)
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

func TestRunListProjectsAndTemplatesProjectReviewedFieldsOnly(t *testing.T) {
	sentinel := "SR_PROJECT_TEMPLATE_SECRET"
	projectPage := []byte(`{
		"count":1,"next":null,"results":[{
			"id":76,"name":"ServiceRadar Playbooks","organization":3,"status":"successful",
			"scm_type":"git","scm_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			"scm_update_on_launch":false,"scm_url":"https://SR_PROJECT_TEMPLATE_SECRET",
			"summary_fields":{"credential":{"password":"SR_PROJECT_TEMPLATE_SECRET"}}
		}]
	}`)
	templatePage := []byte(`{
		"count":1,"next":null,"results":[{
			"id":78,"name":"Install Agent","description":"Reviewed template","job_tags":"install",
			"limit":"","job_type":"run","playbook":"install.yml","project":76,"inventory":67,
			"survey_enabled":false,"ask_variables_on_launch":false,
			"ask_inventory_on_launch":false,"ask_limit_on_launch":true,
			"ask_credential_on_launch":true,
			"variables":"api_token: SR_PROJECT_TEMPLATE_SECRET",
			"extra_vars":{"password":"SR_PROJECT_TEMPLATE_SECRET"},
			"credentials":[{"inputs":"SR_PROJECT_TEMPLATE_SECRET"}],
			"related":{"survey_spec":"SR_PROJECT_TEMPLATE_SECRET"}
		}]
	}`)

	tests := []struct {
		verb     string
		path     string
		body     []byte
		wantKeys []string
	}{
		{
			verb: "awx.list_projects", path: "/api/v2/projects/?page_size=200", body: projectPage,
			wantKeys: []string{"id", "name", "organization", "status", "scm_type", "scm_revision", "update_on_launch"},
		},
		{
			verb: "awx.list_templates", path: "/api/v2/job_templates/?page_size=200", body: templatePage,
			wantKeys: []string{
				"id", "name", "description", "job_tags", "limit", "job_type", "playbook", "project",
				"inventory", "survey_enabled", "ask_variables_on_launch", "ask_inventory_on_launch", "ask_limit_on_launch",
				"ask_credential_on_launch",
			},
		},
	}
	for _, test := range tests {
		t.Run(test.verb, func(t *testing.T) {
			fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
				test.path: {Status: http.StatusOK, Body: test.body},
			}}
			swapHTTP(t, fake)
			res := dispatch(Config{BaseURL: "https://awx.example.com", APIToken: "tok", Verb: test.verb})
			if res.Status != sdk.StatusOK {
				t.Fatalf("got %s: %s", res.Status, res.Summary)
			}
			if strings.Contains(res.Details, sentinel) || strings.Contains(res.Details, "extra_vars") ||
				strings.Contains(res.Details, "credentials") || strings.Contains(res.Details, "scm_url") {
				t.Fatalf("catalog projection leaked controller metadata: %s", res.Details)
			}
			var payload listResultPayload
			if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
				t.Fatalf("decode payload: %v", err)
			}
			var row map[string]any
			if err := json.Unmarshal(payload.Results[0], &row); err != nil {
				t.Fatalf("decode projected row: %v", err)
			}
			assertExactMapKeys(t, row, test.wantKeys...)
		})
	}
}

func TestProjectAWXTemplateRequiresCredentialLaunchPromptEvidence(t *testing.T) {
	missing := json.RawMessage(`{
		"id":78,"name":"Install Agent","job_type":"run",
		"survey_enabled":false,"ask_variables_on_launch":false,
		"ask_inventory_on_launch":false,"ask_limit_on_launch":true
	}`)
	if _, ok := projectAWXTemplate(missing); ok {
		t.Fatal("template without ask_credential_on_launch must fail closed")
	}

	wrongType := json.RawMessage(`{
		"id":78,"name":"Install Agent","job_type":"run",
		"survey_enabled":false,"ask_variables_on_launch":false,
		"ask_inventory_on_launch":false,"ask_limit_on_launch":true,
		"ask_credential_on_launch":"true"
	}`)
	if _, ok := projectAWXTemplate(wrongType); ok {
		t.Fatal("non-boolean ask_credential_on_launch must fail closed")
	}
}

func TestCatalogProjectionFailsClosedOnOversizedReviewedText(t *testing.T) {
	name := strings.Repeat("x", maxAWXCatalogNameBytes+1)
	body, err := json.Marshal(map[string]any{
		"count": 1, "next": nil,
		"results": []any{map[string]any{
			"id": 1, "name": name, "kind": "", "organization": 1, "total_hosts": 0,
		}},
	})
	if err != nil {
		t.Fatalf("encode oversized row: %v", err)
	}
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/inventories/?page_size=200": {Status: http.StatusOK, Body: body},
	}}
	swapHTTP(t, fake)
	res := dispatch(Config{BaseURL: "https://awx.example.com", APIToken: "tok", Verb: "awx.list_inventories"})
	if res.Status != sdk.StatusCritical {
		t.Fatalf("oversized catalog field must fail closed, got %s", res.Status)
	}
}

func TestProjectAWXSurveyRejectsSensitiveReservedPasswordAndOversizedSpecs(t *testing.T) {
	field := func(variable, fieldType string) map[string]any {
		return map[string]any{
			"variable": variable, "question_name": "Value", "type": fieldType,
			"required": true, "default": "SR_SURVEY_DEFAULT_SECRET",
		}
	}
	for _, test := range []struct {
		name     string
		variable string
		kind     string
	}{
		{name: "password name", variable: "password", kind: "text"},
		{name: "api token name", variable: "api_token", kind: "text"},
		{name: "camel api key name", variable: "apiKey", kind: "text"},
		{name: "acronym api key name", variable: "APIKey", kind: "text"},
		{name: "uppercase api key name", variable: "APIKEY", kind: "text"},
		{name: "uppercase api token suffix", variable: "MYAPITOKEN", kind: "text"},
		{name: "camel private key name", variable: "privateKey", kind: "text"},
		{name: "camel bearer token name", variable: "bearerToken", kind: "text"},
		{name: "numeric password suffix", variable: "password1", kind: "text"},
		{name: "camel credential value", variable: "credentialValue", kind: "text"},
		{name: "ansible reserved", variable: "ansible_password", kind: "text"},
		{name: "magic variable", variable: "inventory_hostname", kind: "text"},
		{name: "callback reserved", variable: "callback_url", kind: "text"},
		{name: "password type", variable: "safe_name", kind: "password"},
	} {
		t.Run(test.name, func(t *testing.T) {
			body, _ := json.Marshal(map[string]any{"spec": []any{field(test.variable, test.kind)}})
			if _, ok := projectAWXSurvey(body); ok {
				t.Fatalf("unsafe survey field was accepted")
			}
		})
	}

	fields := make([]any, maxAWXSurveyFields+1)
	for i := range fields {
		fields[i] = field(fmt.Sprintf("value_%d", i), "text")
	}
	body, _ := json.Marshal(map[string]any{"spec": fields})
	if _, ok := projectAWXSurvey(body); ok {
		t.Fatalf("survey with more than %d fields was accepted", maxAWXSurveyFields)
	}

	for _, variable := range []string{
		"environment", "qemuGuestAgentState", "apiary_zone", "key_rotation_days", "tokenizer_mode",
	} {
		body, _ := json.Marshal(map[string]any{"spec": []any{field(variable, "text")}})
		if _, ok := projectAWXSurvey(body); !ok {
			t.Fatalf("legitimate survey field %q was rejected", variable)
		}
	}
}

func TestProjectAWXSurveyAcceptsOnlyExactDispatchMarkerFields(t *testing.T) {
	dispatch := map[string]any{
		"variable":             "serviceradar_dispatch_id",
		"question_name":        "ServiceRadar dispatch ID",
		"question_description": "Injected by ServiceRadar",
		"type":                 "text",
		"required":             true,
		"choices":              "",
		"min":                  36,
		"max":                  36,
		"default":              "",
	}
	snapshot := map[string]any{
		"variable":      "serviceradar_snapshot_digest",
		"question_name": "ServiceRadar snapshot digest",
		"type":          "text",
		"required":      true,
		"choices":       []string{},
		"min":           64,
		"max":           64,
		"default":       nil,
	}

	body, err := json.Marshal(map[string]any{"spec": []any{dispatch, snapshot}})
	if err != nil {
		t.Fatalf("encode exact marker survey: %v", err)
	}
	projected, ok := projectAWXSurvey(body)
	if !ok {
		t.Fatal("exact restricted marker survey was rejected")
	}
	fields, ok := projected["spec"].([]map[string]any)
	if !ok || len(fields) != 2 {
		t.Fatalf("unexpected projected marker fields: %#v", projected["spec"])
	}
	for _, field := range fields {
		if _, leaked := field["default"]; leaked {
			t.Fatalf("marker default leaked into projection: %#v", field)
		}
	}

	invalid := []struct {
		name  string
		field map[string]any
	}{
		{name: "not required", field: cloneSurveyField(dispatch, "required", false)},
		{name: "wrong type", field: cloneSurveyField(dispatch, "type", "textarea")},
		{name: "missing minimum", field: deleteSurveyField(dispatch, "min")},
		{name: "short minimum", field: cloneSurveyField(dispatch, "min", 35)},
		{name: "long maximum", field: cloneSurveyField(dispatch, "max", 37)},
		{name: "nonempty choice", field: cloneSurveyField(dispatch, "choices", "operator")},
		{name: "nonempty default", field: cloneSurveyField(dispatch, "default", "operator-controlled")},
		{name: "case variant", field: cloneSurveyField(dispatch, "variable", "ServiceRadar_Dispatch_ID")},
	}
	for _, test := range invalid {
		t.Run(test.name, func(t *testing.T) {
			body, err := json.Marshal(map[string]any{"spec": []any{test.field, snapshot}})
			if err != nil {
				t.Fatalf("encode invalid marker survey: %v", err)
			}
			if _, ok := projectAWXSurvey(body); ok {
				t.Fatalf("invalid marker survey field was accepted: %#v", test.field)
			}
		})
	}
}

func cloneSurveyField(field map[string]any, key string, value any) map[string]any {
	copy := make(map[string]any, len(field))
	for fieldKey, fieldValue := range field {
		copy[fieldKey] = fieldValue
	}
	copy[key] = value
	return copy
}

func deleteSurveyField(field map[string]any, key string) map[string]any {
	copy := cloneSurveyField(field, key, nil)
	delete(copy, key)
	return copy
}

func TestRelativizeAWXPath(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"", ""},
		{"/api/v2/inventories/?page=2", "/api/v2/inventories/?page=2"},
		{"https://other.host/api/v2/inventories/?page=2", "/api/v2/inventories/?page=2"},
		{"http://10.0.0.1:8080/api/v2/projects/?page=3&page_size=200", "/api/v2/projects/?page=3&page_size=200"},
		{"controller-relative-without-leading-slash", ""},
		{"//other.host/api/v2/projects/?page=3", ""},
	}
	for _, c := range cases {
		if got := relativizeAWXPath(c.in); got != c.want {
			t.Errorf("relativizeAWXPath(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestSanitizeErrorPreservesOnlyBoundedPluginDiagnostics(t *testing.T) {
	if got := sanitizeError(errAWXRequestFailed); got != "AWX request failed" {
		t.Errorf("sanitizeError(upstream) = %q, want fixed failure", got)
	}
	if got := sanitizeError(errString("args.template_id is required")); got != "args.template_id is required" {
		t.Errorf("sanitizeError(local) = %q, want bounded diagnostic", got)
	}
	if got := sanitizeError(errString("unsafe\ntext")); got != "AWX command rejected" {
		t.Errorf("sanitizeError(control text) = %q, want fixed rejection", got)
	}
	if got := sanitizeError(errString("unsafe\n")); got != "AWX command rejected" {
		t.Errorf("sanitizeError(trailing control text) = %q, want fixed rejection", got)
	}
	if got := sanitizeError(errString("unsafe\u202etext")); got != "AWX command rejected" {
		t.Errorf("sanitizeError(format text) = %q, want fixed rejection", got)
	}
	if got := sanitizeError(nil); got != "" {
		t.Errorf("sanitizeError(nil) = %q, want empty", got)
	}
}

func TestProjectedResultCapFailsClosedWithoutRetainingPayload(t *testing.T) {
	secret := "Bearer projected-result-secret"
	result := sdk.Ok("oversized").WithDetails(strings.Repeat("x", maxProjectedResultByteCount) + secret)

	safe := enforceProjectedResultCap("awx.list_hosts", result)
	if safe.Status != sdk.StatusCritical {
		t.Fatalf("expected CRITICAL, got %s", safe.Status)
	}
	if strings.Contains(safe.Summary, secret) || strings.Contains(safe.Details, secret) {
		t.Fatalf("projected result cap retained oversized payload material")
	}
}

func TestControllerTransportErrorsNeverReachPluginResults(t *testing.T) {
	secret := "GET https://awx.internal/api?code=opaque-bearer-value then https://other.internal/?secret=two"
	swapHTTP(t, &fakeHTTPClient{err: errString(secret)})

	res := dispatch(Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "controller-token",
		Verb:     "awx.ping",
	})
	if res.Status != sdk.StatusCritical || !strings.Contains(res.Summary, "AWX request failed") {
		t.Fatalf("unexpected transport failure result: status=%s summary=%q", res.Status, res.Summary)
	}
	if strings.Contains(res.Summary, secret) || strings.Contains(res.Details, secret) ||
		strings.Contains(res.Details, "opaque-bearer-value") {
		t.Fatalf("transport failure leaked upstream text: summary=%q details=%q", res.Summary, res.Details)
	}
}

type errString string

func (e errString) Error() string { return string(e) }
