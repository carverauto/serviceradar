package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"

	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
	"google.golang.org/protobuf/proto"
)

func TestHTTPSyntheticJourneyRunsUnderAgentLifecycle(t *testing.T) {
	wasm := loadBuiltWasm(t, "http_synthetic_journey.wasm")

	const (
		apiToken   = "runtime-secret-token-4455"
		csrfSecret = "runtime-csrf-secret-8899"
		sidSecret  = "runtime-sid-cookie-1122"
		webPropID  = "00000000-0000-4000-8000-000000000402"
	)

	cfgJSON := `{
		"journey_name": "runtime-sso-journey",
		"web_property_id": "` + webPropID + `",
		"device_id": "sr:runtime-dev-1",
		"target_ip": "198.51.100.20",
		"api_token": "` + apiToken + `",
		"steps": [
			{
				"name": "login",
				"method": "POST",
				"url": "https://sso.example.test/login",
				"headers": {"Authorization": "Bearer {{api_token}}"},
				"body": "{\"grant\":\"token\"}",
				"content_type": "application/json",
				"follow_redirects": false,
				"expect_status": [302],
				"expect_json_fields": [
					{"pointer": "/ok", "expected": "true", "value_type": "boolean"}
				],
				"extract_cookies": [{"cookie": "sid", "var": "sid_var"}],
				"extract_json_fields": [{"pointer": "/csrf", "var": "csrf_var"}]
			},
			{
				"name": "profile",
				"method": "GET",
				"url": "https://app.example.test/api/me",
				"headers": {
					"X-CSRF": "{{csrf_var}}",
					"Authorization": "Bearer {{api_token}}"
				},
				"expect_status_min": 200,
				"expect_status_max": 299,
				"expect_body_contains": "profile-ok"
			}
		]
	}`

	daysRemain := 60
	host := &wasmHost{
		config: []byte(cfgJSON),
		httpEnvelope: func(t *testing.T, req wasmHTTPRequest) wasmHTTPEnvelopeResponse {
			switch req.URL {
			case "https://sso.example.test/login":
				if req.FollowRedirects == nil || *req.FollowRedirects {
					t.Fatalf("step 1 follow_redirects = %v, want false", req.FollowRedirects)
				}
				if got := req.Headers["Authorization"]; got != "Bearer "+apiToken {
					t.Fatalf("step 1 Authorization = %q", got)
				}
				return wasmHTTPEnvelopeResponse{
					Status:  302,
					Headers: map[string]string{"Location": "https://app.example.test/callback?code=secret"},
					SetCookies: []string{
						"sid=" + sidSecret + "; Expires=Thu, 21 Oct 2027 07:28:00 GMT; Domain=example.test; Path=/; Secure",
					},
					Body: []byte(`{"ok":true,"csrf":"` + csrfSecret + `"}`),
					Trace: &wasmHTTPTrace{
						DNSDurationNS:          1_000_000,
						ConnectDurationNS:      2_000_000,
						TLSHandshakeDurationNS: 3_000_000,
						TTFBDurationNS:         4_000_000,
						TransferDurationNS:     1_000_000,
						TotalDurationNS:        11_000_000,
						FinalURL:               "https://sso.example.test/login",
						Protocol:               "HTTP/2.0",
						RemoteAddr:             "198.51.100.20:443",
					},
					TLS: &wasmHTTPTLSInfo{
						Version:           "TLS1.3",
						LeafDaysRemaining: &daysRemain,
					},
				}
			case "https://app.example.test/api/me":
				if got := req.Headers["Cookie"]; !strings.Contains(got, "sid="+sidSecret) {
					t.Fatalf("step 2 Cookie = %q, want sid", got)
				}
				if got := req.Headers["X-CSRF"]; got != csrfSecret {
					t.Fatalf("step 2 X-CSRF = %q", got)
				}
				return wasmHTTPEnvelopeResponse{
					Status: 200,
					Body:   []byte(`{"status":"profile-ok"}`),
					Trace: &wasmHTTPTrace{
						DNSDurationNS:          500_000,
						ConnectDurationNS:      1_000_000,
						TLSHandshakeDurationNS: 1_500_000,
						TTFBDurationNS:         3_000_000,
						TransferDurationNS:     500_000,
						TotalDurationNS:        6_500_000,
						FinalURL:               "https://app.example.test/api/me",
						Protocol:               "HTTP/2.0",
						RemoteAddr:             "198.51.100.20:443",
					},
					TLS: &wasmHTTPTLSInfo{
						Version:           "TLS1.3",
						LeafDaysRemaining: &daysRemain,
					},
				}
			default:
				t.Fatalf("unexpected HTTP request URL %q", req.URL)
				return wasmHTTPEnvelopeResponse{}
			}
		},
	}

	host.run(t, wasm, "run_check")

	if host.httpCalls != 2 {
		t.Fatalf("httpCalls = %d, want 2; results = %+v", host.httpCalls, host.results)
	}
	res := host.results[len(host.results)-1]
	if res["status"] != "OK" {
		t.Fatalf("result status = %v, summary = %v", res["status"], res["summary"])
	}
	labels, _ := res["labels"].(map[string]any)
	if labels["web_property_id"] != webPropID {
		t.Fatalf("labels.web_property_id = %v, want %s", labels["web_property_id"], webPropID)
	}

	rawRes, _ := json.Marshal(res)
	for _, secret := range []string{apiToken, csrfSecret, sidSecret} {
		if strings.Contains(string(rawRes), secret) {
			t.Fatalf("result leaked secret %q", secret)
		}
	}

	if len(host.telemetry) != 1 {
		t.Fatalf("telemetry emissions = %d, want 1", len(host.telemetry))
	}
	if strings.Contains(string(host.telemetry[0]), apiToken) ||
		strings.Contains(string(host.telemetry[0]), csrfSecret) ||
		strings.Contains(string(host.telemetry[0]), sidSecret) {
		t.Fatalf("telemetry JSON leaked secret")
	}

	var teleBatch struct {
		Records []struct {
			PayloadKind string `json:"payload_kind"`
			Payload     string `json:"payload"`
		} `json:"records"`
	}
	if err := json.Unmarshal(host.telemetry[0], &teleBatch); err != nil {
		t.Fatalf("unmarshal telemetry batch: %v", err)
	}
	if len(teleBatch.Records) != 1 {
		t.Fatalf("records = %d, want 1", len(teleBatch.Records))
	}
	rawProto, err := base64.StdEncoding.DecodeString(teleBatch.Records[0].Payload)
	if err != nil {
		t.Fatalf("decode telemetry payload: %v", err)
	}
	var batch metricpb.MetricBatch
	if err := proto.Unmarshal(rawProto, &batch); err != nil {
		t.Fatalf("unmarshal MetricBatch: %v", err)
	}
	if batch.GetSchemaVersion() != "serviceradar.metric.v1" {
		t.Fatalf("schema_version = %q", batch.GetSchemaVersion())
	}

	seenNames := map[string]bool{}
	for _, m := range batch.GetMetrics() {
		if m.GetMetricType() != "synthetic" {
			t.Fatalf("metric %q type = %q, want synthetic", m.GetName(), m.GetMetricType())
		}
		seenNames[m.GetName()] = true
		for _, pt := range m.GetPoints() {
			foundWebProp := false
			for _, attr := range pt.GetAttributes() {
				if attr.GetKey() == "web_property_id" && attr.GetValue() == webPropID {
					foundWebProp = true
				}
			}
			if !foundWebProp {
				t.Fatalf("metric %q point missing web_property_id attribute", m.GetName())
			}
		}
	}
	for _, want := range []string{
		"synthetic.journey.available",
		"synthetic.journey.duration_ms",
		"synthetic.journey.steps_completed",
		"synthetic.step.duration_ms",
		"synthetic.step.dns_ms",
		"synthetic.step.connect_ms",
		"synthetic.step.tls_ms",
		"synthetic.step.ttfb_ms",
		"synthetic.step.transfer_ms",
		"synthetic.step.tls_cert_days_remaining",
	} {
		if !seenNames[want] {
			t.Fatalf("missing metric %q in %v", want, seenNames)
		}
	}
}

func TestHTTPSyntheticJourneyCriticalShortCircuitUnderAgentLifecycle(t *testing.T) {
	wasm := loadBuiltWasm(t, "http_synthetic_journey.wasm")
	cfgJSON := `{
		"journey_name": "runtime-critical-short-circuit",
		"steps": [
			{"name": "step-a", "url": "https://app.example.test/a", "expect_status": [200]},
			{"name": "step-b", "url": "https://app.example.test/b", "expect_status": [200]}
		]
	}`

	host := &wasmHost{
		config: []byte(cfgJSON),
		httpEnvelope: func(_ *testing.T, _ wasmHTTPRequest) wasmHTTPEnvelopeResponse {
			return wasmHTTPEnvelopeResponse{
				Status: 500,
				Body:   []byte(`internal error`),
				Trace: &wasmHTTPTrace{
					TotalDurationNS: 2_000_000,
					FinalURL:        "https://app.example.test/a",
				},
			}
		},
	}
	host.run(t, wasm, "run_check")

	if host.httpCalls != 1 {
		t.Fatalf("httpCalls = %d, want 1", host.httpCalls)
	}
	res := host.results[len(host.results)-1]
	if res["status"] != "CRITICAL" {
		t.Fatalf("status = %v, want CRITICAL", res["status"])
	}
	rawRes, _ := json.Marshal(res)
	if !strings.Contains(string(rawRes), "SKIPPED") {
		t.Fatalf("expected SKIPPED in result: %s", rawRes)
	}
}
