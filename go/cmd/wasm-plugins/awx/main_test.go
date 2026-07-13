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
			want: "not an allowed AWX launch field",
		},
		{
			name: "moving scm branch is prohibited",
			args: map[string]any{"template_id": 1, "scm_branch": "main"},
			want: "not an allowed AWX launch field",
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
			"template_id":   42.0,
			"inventory_id":  7.0,
			"created_by_id": 17.0,
			"created_after": createdAfter,
			"page_size":     25.0,
		},
	})
	if res.Status != sdk.StatusOK {
		t.Fatalf("got %s: %s", res.Status, res.Summary)
	}
	if len(fake.requests) != 1 || !strings.HasSuffix(fake.requests[0].URL, wantPath) {
		t.Fatalf("unexpected recent-job request: %+v", fake.requests)
	}
	var payload struct {
		Count     int               `json:"count"`
		Truncated bool              `json:"truncated"`
		Jobs      []json.RawMessage `json:"jobs"`
	}
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	if payload.Count != 2 || payload.Truncated || len(payload.Jobs) != 2 {
		t.Fatalf("unexpected payload: %+v", payload)
	}
	if !strings.Contains(string(payload.Jobs[1]), "dispatch-018f") {
		t.Errorf("jobs must retain marker-bearing extra_vars for exact caller-side comparison")
	}
}

func TestRunListRecentJobsMarksTruncatedCandidateSet(t *testing.T) {
	body := []byte(`{
		"count": 101,
		"next": "/api/v2/jobs/?page=2",
		"results": [{"id":7331,"created":"2026-07-12T16:01:00Z","job_template":42,"inventory":7,"launched_by":{"id":17,"type":"user"},"extra_vars":"{}"}]
	}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"page_size=1": {Status: http.StatusOK, Body: body},
	}}
	swapHTTP(t, fake)
	res := dispatch(Config{
		BaseURL:  "https://awx.example.com",
		APIToken: "tok",
		Verb:     "awx.list_recent_jobs",
		Args: map[string]any{
			"template_id":   42,
			"inventory_id":  7,
			"created_by_id": 17,
			"created_after": "2026-07-12T16:00:00Z",
			"page_size":     1,
		},
	})
	if res.Status != sdk.StatusOK {
		t.Fatalf("got %s: %s", res.Status, res.Summary)
	}
	var payload struct {
		Truncated bool `json:"truncated"`
	}
	_ = json.Unmarshal([]byte(res.Details), &payload)
	if !payload.Truncated {
		t.Errorf("incomplete candidate set must be marked truncated")
	}
}

func TestRunListRecentJobsRequiresExactScope(t *testing.T) {
	base := map[string]any{
		"template_id":   42,
		"inventory_id":  7,
		"created_by_id": 17,
		"created_after": "2026-07-12T16:00:00Z",
	}
	for _, key := range []string{"template_id", "inventory_id", "created_by_id", "created_after"} {
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
			"template_id":   42,
			"inventory_id":  7,
			"created_by_id": 17,
			"created_after": "2026-07-12T16:00:00Z",
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
			{"id": 1001, "counter": 5,  "type": "playbook_on_play_start", "stdout": ""},
			{"id": 1002, "counter": 6,  "type": "runner_on_ok",            "stdout": "ok"}
		]
	}`)
	job2Page := []byte(`{
		"count": 1,
		"next": null,
		"results": [
			{"id": 2001, "counter": 50, "type": "runner_on_ok"}
		]
	}`)
	fake := &fakeHTTPClient{responses: map[string]*sdk.HTTPResponse{
		"/api/v2/jobs/7331/job_events/?counter__gt=0&page_size=200&order=counter":  {Status: http.StatusOK, Body: job1Page},
		"/api/v2/jobs/7332/job_events/?counter__gt=49&page_size=200&order=counter": {Status: http.StatusOK, Body: job2Page},
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
		OK   bool              `json:"ok"`
		Jobs []jobEventsResult `json:"jobs"`
	}
	if err := json.Unmarshal([]byte(res.Details), &payload); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	if !payload.OK {
		t.Errorf("payload.ok = false")
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
		"/api/v2/jobs/7331/job_events/?counter__gt=0&page_size=200&order=counter": {Status: http.StatusOK, Body: job1Page},
		"/api/v2/jobs/9999/job_events/?counter__gt=0&page_size=200&order=counter": {Status: http.StatusInternalServerError, Body: []byte(`{}`)},
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
	if byJob[9999].Error == "" {
		t.Errorf("job 9999 should carry an error string")
	}
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

func TestInventorySyncConfigAcceptsResolvedControllerListContract(t *testing.T) {
	payload := []byte(`{
		"controllers": [
			{
				"controller_id": "awx-a",
				"controller_name": "AWX A",
				"base_url": "https://awx-a.example.invalid",
				"api_token": "root@pam!sr-inventory=secret-a",
				"timeout_ms": 30000,
				"insecure_skip_verify": false
			},
			{
				"controller_id": "awx-b",
				"base_url": "https://awx-b.example.invalid",
				"api_token": "root@pam!sr-inventory=secret-b"
			}
		]
	}`)

	var cfg InventorySyncConfig
	if err := json.Unmarshal(payload, &cfg); err != nil {
		t.Fatalf("unmarshal resolved controller-list contract: %v", err)
	}
	if err := validateInventorySyncConfig(cfg); err != nil {
		t.Fatalf("validate resolved controller-list contract: %v", err)
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
