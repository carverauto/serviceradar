package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func TestHTTPSyntheticJourneyMultiStepSSOAndRedaction(t *testing.T) {
	t.Parallel()

	const (
		apiToken   = "tok-test-1111"
		password   = "pw-test-2222"
		csrfSecret = "csrf-extracted-5544"
		sidSecret  = "sid-cookie-3322"
	)

	cfgJSON := `{
		"journey_name": "sso-checkout",
		"web_property_id": "00000000-0000-4000-8000-000000000401",
		"device_id": "sr:device-1",
		"target_ip": "198.51.100.10",
		"username": "synthetic-user",
		"password": "` + password + `",
		"api_token": "` + apiToken + `",
		"steps": [
			{
				"name": "login",
				"method": "POST",
				"url": "https://sso.example.test/login",
				"headers": {
					"Authorization": "Bearer {{api_token}}",
					"X-User": "{{username}}"
				},
				"body": "{\"user\":\"{{username}}\",\"pass\":\"{{password}}\"}",
				"content_type": "application/json",
				"follow_redirects": false,
				"expect_status": [302],
				"expect_headers": {"Location": "https://app.example.test/callback?code=hidden"},
				"expect_header_contains": {"X-Auth-Mode": "sso"},
				"expect_json_fields": [
					{"pointer": "/ok", "expected": "true", "value_type": "boolean"},
					{"pointer": "/attempts", "expected": "1", "value_type": "number"},
					{"pointer": "/error", "value_type": "null"}
				],
				"extract_headers": [{"header": "X-Request-Id", "var": "req_id"}],
				"extract_cookies": [{"cookie": "sid", "var": "sid_var"}],
				"extract_json_fields": [{"pointer": "/csrf", "var": "csrf_var"}]
			},
			{
				"name": "profile",
				"method": "GET",
				"url": "https://app.example.test/api/me",
				"headers": {
					"X-CSRF": "{{csrf_var}}",
					"X-Parent-Req": "{{req_id}}",
					"Authorization": "Bearer {{api_token}}"
				},
				"expect_status_min": 200,
				"expect_status_max": 299,
				"expect_body_contains": "profile-ready",
				"expect_json_fields": [
					{"pointer": "/role", "expected": "admin", "value_type": "string"}
				]
			}
		]
	}`

	var requests []sdk.HTTPRequest
	capture, err := sdk.RunLocalHost(sdk.LocalHostOptions{
		ConfigJSON: []byte(cfgJSON),
		HTTPHandler: func(_ context.Context, req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
			requests = append(requests, req)
			switch req.URL {
			case "https://sso.example.test/login":
				if req.FollowRedirects == nil || *req.FollowRedirects {
					t.Fatalf("step 1 follow_redirects = %v, want false", req.FollowRedirects)
				}
				if got := req.Headers["Authorization"]; got != "Bearer "+apiToken {
					t.Fatalf("step 1 Authorization = %q, want Bearer %s", got, apiToken)
				}
				if got := req.Headers["Content-Type"]; got != "application/json" {
					t.Fatalf("step 1 Content-Type = %q", got)
				}
				if !strings.Contains(string(req.Body), password) {
					t.Fatalf("step 1 body missing expanded password")
				}
				return &sdk.HTTPResponse{
					Status: 302,
					Headers: map[string]string{
						"Location":     "https://app.example.test/callback?code=hidden",
						"X-Auth-Mode":  "sso-oidc",
						"X-Request-Id": "req-001",
					},
					SetCookies: []string{
						"sid=" + sidSecret + "; Domain=example.test; Path=/; Secure",
					},
					Body:     []byte(`{"ok":true,"attempts":1,"error":null,"csrf":"` + csrfSecret + `"}`),
					Duration: 15 * time.Millisecond,
					Trace: &sdk.HTTPTrace{
						DNSDurationNS:          1_000_000,
						ConnectDurationNS:      2_000_000,
						TLSHandshakeDurationNS: 3_000_000,
						TTFBDurationNS:         4_000_000,
						TransferDurationNS:     1_000_000,
						TotalDurationNS:        11_000_000,
						RedirectCount:          0,
						FinalURL:               "https://sso.example.test/login",
						Protocol:               "HTTP/2.0",
						RemoteAddr:             "198.51.100.10:443",
					},
					TLS: &sdk.HTTPTLSInfo{
						Version:           "TLS1.3",
						LeafDaysRemaining: 45,
					},
				}, nil
			case "https://app.example.test/api/me":
				if got := req.Headers["Cookie"]; !strings.Contains(got, "sid="+sidSecret) {
					t.Fatalf("step 2 Cookie = %q, want sid=%s", got, sidSecret)
				}
				if got := req.Headers["X-CSRF"]; got != csrfSecret {
					t.Fatalf("step 2 X-CSRF = %q, want %s", got, csrfSecret)
				}
				if got := req.Headers["X-Parent-Req"]; got != "req-001" {
					t.Fatalf("step 2 X-Parent-Req = %q, want req-001", got)
				}
				return &sdk.HTTPResponse{
					Status:   200,
					Body:     []byte(`{"status":"profile-ready","role":"admin"}`),
					Duration: 9 * time.Millisecond,
					Trace: &sdk.HTTPTrace{
						DNSDurationNS:      500_000,
						ConnectDurationNS:  1_000_000,
						TTFBDurationNS:     5_000_000,
						TransferDurationNS: 1_000_000,
						TotalDurationNS:    7_500_000,
						FinalURL:           "https://app.example.test/api/me",
						Protocol:           "HTTP/2.0",
						RemoteAddr:         "198.51.100.10:443",
					},
				}, nil
			default:
				t.Fatalf("unexpected request URL %q", req.URL)
				return nil, nil
			}
		},
	}, func() error {
		run_check()
		return nil
	})
	if err != nil {
		t.Fatalf("RunLocalHost: %v", err)
	}

	if len(requests) != 2 {
		t.Fatalf("http requests = %d, want 2", len(requests))
	}

	var res sdk.Result
	if err := json.Unmarshal(capture.ResultJSON, &res); err != nil {
		t.Fatalf("decode ResultJSON: %v", err)
	}
	if res.Status != sdk.StatusOK {
		t.Fatalf("status = %s, summary = %q", res.Status, res.Summary)
	}
	if res.Labels["web_property_id"] != "00000000-0000-4000-8000-000000000401" {
		t.Fatalf("web_property_id label = %q", res.Labels["web_property_id"])
	}
	if res.Labels["journey"] != "sso-checkout" {
		t.Fatalf("journey label = %q", res.Labels["journey"])
	}

	for _, secret := range []string{apiToken, password, csrfSecret, sidSecret} {
		if strings.Contains(string(capture.ResultJSON), secret) {
			t.Fatalf("ResultJSON leaked secret %q", secret)
		}
	}

	if len(capture.TelemetryJSON) != 1 {
		t.Fatalf("telemetry calls = %d, want 1", len(capture.TelemetryJSON))
	}
	for _, secret := range []string{apiToken, password, csrfSecret, sidSecret} {
		if strings.Contains(string(capture.TelemetryJSON[0]), secret) {
			t.Fatalf("TelemetryJSON leaked secret %q", secret)
		}
	}

	var teleEnv struct {
		Records []struct {
			PayloadKind string `json:"payload_kind"`
			Payload     string `json:"payload"`
		} `json:"records"`
	}
	if err := json.Unmarshal(capture.TelemetryJSON[0], &teleEnv); err != nil {
		t.Fatalf("decode TelemetryJSON: %v", err)
	}
	if len(teleEnv.Records) != 1 || teleEnv.Records[0].PayloadKind != "serviceradar_metrics" {
		t.Fatalf("unexpected telemetry records: %+v", teleEnv.Records)
	}
	protoBytes, err := base64.StdEncoding.DecodeString(teleEnv.Records[0].Payload)
	if err != nil {
		t.Fatalf("decode base64 metric payload: %v", err)
	}
	if !strings.Contains(string(protoBytes), sdk.MetricEnvelopeSchemaVersion) ||
		!strings.Contains(string(protoBytes), "synthetic.journey.available") ||
		!strings.Contains(string(protoBytes), "synthetic.step.duration_ms") ||
		!strings.Contains(string(protoBytes), "00000000-0000-4000-8000-000000000401") {
		t.Fatalf("metric protobuf missing expected synthetic metrics or web_property_id")
	}
}

func TestHTTPSyntheticJourneyEnvelopeAndSingleURLFallback(t *testing.T) {
	t.Parallel()

	envelopeJSON := `{
		"schema": "serviceradar.plugin_inputs.v1",
		"template": {
			"journey_name": "single-url-check",
			"url": "https://portal.example.test/health",
			"method": "HEAD",
			"follow_redirects": false,
			"warn_ms": 1000
		},
		"inputs": [{"items": [{"id": "wp-1"}]}]
	}`

	capture, err := sdk.RunLocalHost(sdk.LocalHostOptions{
		ConfigJSON: []byte(envelopeJSON),
		HTTPHandler: func(_ context.Context, req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
			if req.Method != "HEAD" {
				t.Fatalf("method = %q, want HEAD", req.Method)
			}
			if req.FollowRedirects == nil || *req.FollowRedirects {
				t.Fatalf("follow_redirects = %v, want false", req.FollowRedirects)
			}
			return &sdk.HTTPResponse{
				Status:   204,
				Duration: 10 * time.Millisecond,
			}, nil
		},
	}, func() error {
		run_check()
		return nil
	})
	if err != nil {
		t.Fatalf("RunLocalHost: %v", err)
	}

	var res sdk.Result
	if err := json.Unmarshal(capture.ResultJSON, &res); err != nil {
		t.Fatalf("decode ResultJSON: %v", err)
	}
	if res.Status != sdk.StatusOK {
		t.Fatalf("status = %s, summary = %q", res.Status, res.Summary)
	}
}

func TestHTTPSyntheticJourneyWarningThreshold(t *testing.T) {
	t.Parallel()

	cfgJSON := `{
		"journey_name": "slow-portal",
		"url": "https://portal.example.test/",
		"warn_ms": 50,
		"crit_ms": 5000
	}`

	capture, err := sdk.RunLocalHost(sdk.LocalHostOptions{
		ConfigJSON: []byte(cfgJSON),
		HTTPHandler: func(_ context.Context, _ sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
			return &sdk.HTTPResponse{
				Status:   200,
				Duration: 120 * time.Millisecond,
				Trace: &sdk.HTTPTrace{
					TotalDurationNS: 120_000_000,
					FinalURL:        "https://portal.example.test/",
				},
			}, nil
		},
	}, func() error {
		run_check()
		return nil
	})
	if err != nil {
		t.Fatalf("RunLocalHost: %v", err)
	}

	var res sdk.Result
	if err := json.Unmarshal(capture.ResultJSON, &res); err != nil {
		t.Fatalf("decode ResultJSON: %v", err)
	}
	if res.Status != sdk.StatusWarning {
		t.Fatalf("status = %s, want WARNING (summary=%q)", res.Status, res.Summary)
	}
}

func TestHTTPSyntheticJourneyCriticalShortCircuit(t *testing.T) {
	t.Parallel()

	cfgJSON := `{
		"journey_name": "short-circuit",
		"steps": [
			{"name": "step-one", "url": "https://app.example.test/one", "expect_status": [200]},
			{"name": "step-two", "url": "https://app.example.test/two", "expect_status": [200]}
		]
	}`

	calls := 0
	capture, err := sdk.RunLocalHost(sdk.LocalHostOptions{
		ConfigJSON: []byte(cfgJSON),
		HTTPHandler: func(_ context.Context, _ sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
			calls++
			return &sdk.HTTPResponse{Status: 503, Duration: 5 * time.Millisecond}, nil
		},
	}, func() error {
		run_check()
		return nil
	})
	if err != nil {
		t.Fatalf("RunLocalHost: %v", err)
	}
	if calls != 1 {
		t.Fatalf("http calls = %d, want 1 (step-two must be short-circuited)", calls)
	}

	var res sdk.Result
	if err := json.Unmarshal(capture.ResultJSON, &res); err != nil {
		t.Fatalf("decode ResultJSON: %v", err)
	}
	if res.Status != sdk.StatusCritical {
		t.Fatalf("status = %s, want CRITICAL", res.Status)
	}
	if !strings.Contains(string(capture.ResultJSON), "SKIPPED") {
		t.Fatalf("expected SKIPPED step in ResultJSON: %s", capture.ResultJSON)
	}
}

func TestHTTPSyntheticJourneyInvalidConfigsAndCredentialGuards(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		config string
		secret string
	}{
		{
			name:   "empty config",
			config: `{}`,
		},
		{
			name:   "credential placeholder in URL rejected",
			config: `{"api_token":"secret-in-url","steps":[{"name":"bad","url":"https://app.example.test/?t={{api_token}}"}]}`,
			secret: "secret-in-url",
		},
		{
			name:   "missing api_token for placeholder",
			config: `{"steps":[{"name":"bad","url":"https://app.example.test/","headers":{"Authorization":"Bearer {{api_token}}"}}]}`,
		},
		{
			name:   "invalid expect_json_fields number",
			config: `{"steps":[{"name":"bad","url":"https://app.example.test/","expect_json_fields":[{"pointer":"/n","expected":"not-a-num","value_type":"number"}]}]}`,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			capture, err := sdk.RunLocalHost(sdk.LocalHostOptions{
				ConfigJSON: []byte(tc.config),
			}, func() error {
				run_check()
				return nil
			})
			if err != nil {
				t.Fatalf("RunLocalHost: %v", err)
			}
			var res sdk.Result
			if err := json.Unmarshal(capture.ResultJSON, &res); err != nil {
				t.Fatalf("decode ResultJSON: %v", err)
			}
			if res.Status != sdk.StatusUnknown {
				t.Fatalf("status = %s, want UNKNOWN (summary=%q)", res.Status, res.Summary)
			}
			if tc.secret != "" && strings.Contains(string(capture.ResultJSON), tc.secret) {
				t.Fatalf("ResultJSON leaked secret %q", tc.secret)
			}
		})
	}
}

func TestHTTPSyntheticJourneyScrubsSecretsFromResultSummaryDetailsEvents(t *testing.T) {
	t.Parallel()

	cfg := Config{
		APIToken: "tok-leak-1",
		Password: "pw-leak-2",
	}
	res := sdk.Critical("failed with tok-leak-1 and pw-leak-2").
		WithDetails("detail tok-leak-1 pw-leak-2")
	res.EmitEvent(sdk.SeverityCritical, "event tok-leak-1 pw-leak-2", "synthetic_journey_failed")
	res.AddTable(map[string]string{"01. login": "CRITICAL | tok-leak-1 | pw-leak-2"}, "full")

	scrubbed := scrubResultSecrets(res, cfg)
	raw, err := json.Marshal(scrubbed)
	if err != nil {
		t.Fatalf("marshal scrubbed result: %v", err)
	}
	if strings.Contains(string(raw), "tok-leak-1") || strings.Contains(string(raw), "pw-leak-2") {
		t.Fatalf("scrubbed result still contained secret: %s", raw)
	}
}

func TestHTTPSyntheticJourneyScrubsOverlappingPrefixSecretsAndLabels(t *testing.T) {
	t.Parallel()

	const (
		shortToken = "tok-1"
		longPass   = "tok-1-secret-suffix"
	)

	cfgJSON := fmt.Sprintf(`{
		"journey_name": "prefix-secret-scrub",
		"api_token": %q,
		"password": %q,
		"steps": [
			{
				"name": "s1",
				"url": "https://app.example.test/check",
				"expect_body_contains": %q
			}
		]
	}`, shortToken, longPass, longPass)

	capture, err := sdk.RunLocalHost(sdk.LocalHostOptions{
		ConfigJSON: []byte(cfgJSON),
		HTTPHandler: func(_ context.Context, _ sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
			return &sdk.HTTPResponse{
				Status:   200,
				Body:     []byte("nope"),
				Duration: 2 * time.Millisecond,
			}, nil
		},
	}, func() error {
		run_check()
		return nil
	})
	if err != nil {
		t.Fatalf("RunLocalHost: %v", err)
	}

	raw := string(capture.ResultJSON)
	for _, forbidden := range []string{shortToken, longPass, "-secret-suffix", "[REDACTED]-secret-suffix"} {
		if strings.Contains(raw, forbidden) {
			t.Fatalf("ResultJSON leaked %q: %s", forbidden, raw)
		}
	}

	res := sdk.Critical("failed "+longPass).WithLabel("leak", longPass)
	scrubbed := scrubResultSecrets(res, Config{APIToken: shortToken, Password: longPass})
	if strings.Contains(scrubbed.Labels["leak"], "-secret-suffix") || scrubbed.Labels["leak"] != redactedSecret {
		t.Fatalf("scrubbed label = %q, want %q", scrubbed.Labels["leak"], redactedSecret)
	}
}

func TestHTTPSyntheticJourneyTopLevelRedirectAndTLSInheritance(t *testing.T) {
	t.Parallel()

	cfgJSON := `{
		"journey_name": "inherit-flags",
		"follow_redirects": false,
		"insecure_skip_verify": true,
		"steps": [
			{
				"name": "inherited",
				"url": "https://app.example.test/inherited",
				"expect_status": [200]
			},
			{
				"name": "overridden",
				"url": "https://app.example.test/overridden",
				"follow_redirects": true,
				"insecure_skip_verify": false,
				"expect_status": [200]
			}
		]
	}`

	var requests []sdk.HTTPRequest
	capture, err := sdk.RunLocalHost(sdk.LocalHostOptions{
		ConfigJSON: []byte(cfgJSON),
		HTTPHandler: func(_ context.Context, req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
			requests = append(requests, req)
			return &sdk.HTTPResponse{Status: 200, Duration: time.Millisecond}, nil
		},
	}, func() error {
		run_check()
		return nil
	})
	if err != nil {
		t.Fatalf("RunLocalHost: %v", err)
	}

	var res sdk.Result
	if err := json.Unmarshal(capture.ResultJSON, &res); err != nil {
		t.Fatalf("decode ResultJSON: %v", err)
	}
	if res.Status != sdk.StatusOK {
		t.Fatalf("status = %s, summary = %q", res.Status, res.Summary)
	}
	if len(requests) != 2 {
		t.Fatalf("requests = %d, want 2", len(requests))
	}
	if requests[0].FollowRedirects == nil || *requests[0].FollowRedirects {
		t.Fatalf("step 0 follow_redirects = %v, want false (inherited)", requests[0].FollowRedirects)
	}
	if !requests[0].InsecureSkipVerify {
		t.Fatalf("step 0 insecure_skip_verify = false, want true (inherited)")
	}
	if requests[1].FollowRedirects == nil || !*requests[1].FollowRedirects {
		t.Fatalf("step 1 follow_redirects = %v, want true (overridden)", requests[1].FollowRedirects)
	}
	if requests[1].InsecureSkipVerify {
		t.Fatalf("step 1 insecure_skip_verify = true, want false (overridden)")
	}
}

func TestHTTPSyntheticJourneyRejectsExcessiveSteps(t *testing.T) {
	t.Parallel()

	steps := make([]StepConfig, maxJourneySteps+1)
	for i := range steps {
		steps[i] = StepConfig{
			Name: fmt.Sprintf("step-%d", i+1),
			URL:  "https://app.example.test/ping",
		}
	}
	rawCfg, err := json.Marshal(Config{
		JourneyName: "too-many-steps",
		Steps:       steps,
	})
	if err != nil {
		t.Fatalf("marshal config: %v", err)
	}

	capture, err := sdk.RunLocalHost(sdk.LocalHostOptions{
		ConfigJSON: rawCfg,
	}, func() error {
		run_check()
		return nil
	})
	if err != nil {
		t.Fatalf("RunLocalHost: %v", err)
	}

	var res sdk.Result
	if err := json.Unmarshal(capture.ResultJSON, &res); err != nil {
		t.Fatalf("decode ResultJSON: %v", err)
	}
	if res.Status != sdk.StatusUnknown {
		t.Fatalf("status = %s, want UNKNOWN (summary=%q)", res.Status, res.Summary)
	}
	if !strings.Contains(res.Summary, "exceeds maximum allowed") {
		t.Fatalf("summary = %q, want max steps message", res.Summary)
	}
}

func TestHTTPSyntheticJourneyManifestAndSchemaSanity(t *testing.T) {
	t.Parallel()

	pluginYAML, err := os.ReadFile("plugin.yaml")
	if err != nil {
		t.Fatalf("read plugin.yaml: %v", err)
	}
	yamlText := string(pluginYAML)
	for _, want := range []string{
		"id: http-synthetic-journey",
		"entrypoint: run_check",
		"runtime: wasi-preview1",
		"outputs: serviceradar.plugin_result.v1",
		"- emit_telemetry",
		"- http_request",
	} {
		if !strings.Contains(yamlText, want) {
			t.Fatalf("plugin.yaml missing %q", want)
		}
	}

	schemaBytes, err := os.ReadFile("config.schema.json")
	if err != nil {
		t.Fatalf("read config.schema.json: %v", err)
	}
	var schema map[string]any
	if err := json.Unmarshal(schemaBytes, &schema); err != nil {
		t.Fatalf("parse config.schema.json: %v", err)
	}
	if schema["type"] != "object" {
		t.Fatalf("schema.type = %v, want object", schema["type"])
	}
	for _, forbidden := range []string{"anyOf", "oneOf", "allOf", "not"} {
		if strings.Contains(string(schemaBytes), `"`+forbidden+`"`) {
			t.Fatalf("config.schema.json contains forbidden keyword %q", forbidden)
		}
	}
}
