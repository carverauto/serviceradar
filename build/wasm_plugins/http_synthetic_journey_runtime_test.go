package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
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

func TestHTTPSyntheticJourneyInheritanceAndPrefixScrubbingInWasm(t *testing.T) {
	wasm := loadBuiltWasm(t, "http_synthetic_journey.wasm")

	t.Run("inherits follow_redirects=false and overrides insecure_skip_verify=true->false", func(t *testing.T) {
		cfgJSON := `{
			"journey_name": "wasm-inheritance",
			"follow_redirects": false,
			"insecure_skip_verify": true,
			"steps": [
				{
					"name": "inherited",
					"url": "https://app.example.test/one",
					"expect_status": [200]
				},
				{
					"name": "override",
					"url": "https://app.example.test/two",
					"follow_redirects": true,
					"insecure_skip_verify": false,
					"expect_status": [200]
				}
			]
		}`

		var seen []wasmHTTPRequest
		host := &wasmHost{
			config: []byte(cfgJSON),
			httpEnvelope: func(_ *testing.T, req wasmHTTPRequest) wasmHTTPEnvelopeResponse {
				seen = append(seen, req)
				return wasmHTTPEnvelopeResponse{
					Status: 200,
					Trace: &wasmHTTPTrace{
						TotalDurationNS: 1_000_000,
						FinalURL:        req.URL,
					},
				}
			},
		}
		host.run(t, wasm, "run_check")

		if len(seen) != 2 {
			t.Fatalf("http requests = %d, want 2", len(seen))
		}
		if seen[0].FollowRedirects == nil || *seen[0].FollowRedirects {
			t.Fatalf("step 0 follow_redirects = %v, want false", seen[0].FollowRedirects)
		}
		if !seen[0].InsecureSkipVerify {
			t.Fatalf("step 0 insecure_skip_verify = false, want true")
		}
		if seen[1].FollowRedirects == nil || !*seen[1].FollowRedirects {
			t.Fatalf("step 1 follow_redirects = %v, want true", seen[1].FollowRedirects)
		}
		if seen[1].InsecureSkipVerify {
			t.Fatalf("step 1 insecure_skip_verify = true, want false")
		}
		res := host.results[len(host.results)-1]
		if res["status"] != "OK" {
			t.Fatalf("status = %v, summary = %v", res["status"], res["summary"])
		}
	})

	t.Run("scrubs overlapping prefix secrets without leaking suffix", func(t *testing.T) {
		const (
			shortToken = "tok-1"
			longPass   = "tok-1-secret-suffix"
		)

		cfgJSON := `{
			"journey_name": "wasm-prefix-scrub",
			"api_token": "` + shortToken + `",
			"password": "` + longPass + `",
			"steps": [
				{
					"name": "s1",
					"url": "https://app.example.test/check",
					"expect_body_contains": "` + longPass + `"
				}
			]
		}`

		host := &wasmHost{
			config: []byte(cfgJSON),
			httpEnvelope: func(_ *testing.T, _ wasmHTTPRequest) wasmHTTPEnvelopeResponse {
				return wasmHTTPEnvelopeResponse{
					Status: 200,
					Body:   []byte("nope"),
					Trace: &wasmHTTPTrace{
						TotalDurationNS: 1_000_000,
						FinalURL:        "https://app.example.test/check",
					},
				}
			},
		}
		host.run(t, wasm, "run_check")

		res := host.results[len(host.results)-1]
		if res["status"] != "CRITICAL" {
			t.Fatalf("status = %v, want CRITICAL", res["status"])
		}
		rawRes, _ := json.Marshal(res)
		for _, forbidden := range []string{shortToken, longPass, "-secret-suffix", "[REDACTED]-secret-suffix"} {
			if strings.Contains(string(rawRes), forbidden) {
				t.Fatalf("wasm result leaked %q: %s", forbidden, rawRes)
			}
		}
	})
}

func TestHTTPSyntheticJourneyMaxStepsWithinMemoryLimitInWasm(t *testing.T) {
	wasm := loadBuiltWasm(t, "http_synthetic_journey.wasm")

	const (
		maxSteps  = 64
		pageLimit = 1024 // 64 MiB, matching plugin.yaml requested_memory_mb: 64
		webPropID = "00000000-0000-4000-8000-000000000764"
	)

	steps := make([]map[string]any, 0, maxSteps)
	for i := 0; i < maxSteps; i++ {
		step := map[string]any{
			"name":          fmt.Sprintf("step-%02d", i+1),
			"method":        "GET",
			"url":           fmt.Sprintf("https://app.example.test/steps/%d", i+1),
			"expect_status": []int{200},
			"expect_json_fields": []map[string]any{
				{"pointer": "/step", "expected": fmt.Sprintf("%d", i+1), "value_type": "number"},
			},
			"extract_json_fields": []map[string]any{
				{"pointer": "/token", "var": "step_tok"},
			},
		}
		if i == 0 {
			step["extract_cookies"] = []map[string]any{{"cookie": "sid", "var": "sid_var"}}
		} else {
			step["headers"] = map[string]string{"X-Step-Token": "{{step_tok}}"}
		}
		steps = append(steps, step)
	}

	cfgBytes, err := json.Marshal(map[string]any{
		"journey_name":    "max-steps-64-mib",
		"web_property_id": webPropID,
		"emit_telemetry":  true,
		"steps":           steps,
	})
	if err != nil {
		t.Fatal(err)
	}

	daysRemain := 45
	callIndex := 0
	host := &wasmHost{
		config:           cfgBytes,
		memoryLimitPages: pageLimit,
		httpEnvelope: func(t *testing.T, req wasmHTTPRequest) wasmHTTPEnvelopeResponse {
			callIndex++
			var setCookies []string
			if callIndex == 1 {
				setCookies = []string{"sid=max-step-sid-secret; Path=/; Secure"}
			} else if req.Headers["X-Step-Token"] != fmt.Sprintf("tok-step-%d", callIndex-1) {
				t.Fatalf("step %d X-Step-Token = %q, want tok-step-%d", callIndex, req.Headers["X-Step-Token"], callIndex-1)
			}
			return wasmHTTPEnvelopeResponse{
				Status:     200,
				SetCookies: setCookies,
				Body:       []byte(fmt.Sprintf(`{"step":%d,"token":"tok-step-%d","padding":"%s"}`, callIndex, callIndex, strings.Repeat("a", 512))),
				Trace: &wasmHTTPTrace{
					DNSDurationNS:          100_000,
					ConnectDurationNS:      200_000,
					TLSHandshakeDurationNS: 300_000,
					TTFBDurationNS:         400_000,
					TransferDurationNS:     100_000,
					TotalDurationNS:        1_100_000,
					ConnectionReused:       callIndex > 1,
					FinalURL:               req.URL,
					Protocol:               "HTTP/2.0",
					RemoteAddr:             "198.51.100.20:443",
				},
				TLS: &wasmHTTPTLSInfo{
					Version:           "TLS1.3",
					LeafDaysRemaining: &daysRemain,
				},
			}
		},
	}

	host.run(t, wasm, "run_check")

	t.Logf("64-step compiled wasm memory size: %d bytes (%.2f MiB), limit %d MiB",
		host.lastMemoryBytes, float64(host.lastMemoryBytes)/(1024*1024), pageLimit*64/1024)

	if host.httpCalls != maxSteps {
		t.Fatalf("httpCalls = %d, want %d", host.httpCalls, maxSteps)
	}
	res := host.results[len(host.results)-1]
	if res["status"] != "OK" {
		t.Fatalf("result status = %v, summary = %v", res["status"], res["summary"])
	}
	if len(host.telemetry) != 1 {
		t.Fatalf("telemetry emissions = %d, want 1", len(host.telemetry))
	}

	var teleBatch struct {
		Records []struct {
			Payload string `json:"payload"`
		} `json:"records"`
	}
	if err := json.Unmarshal(host.telemetry[0], &teleBatch); err != nil {
		t.Fatalf("unmarshal telemetry batch: %v", err)
	}
	if len(teleBatch.Records) != 1 {
		t.Fatalf("telemetry records = %d, want 1", len(teleBatch.Records))
	}
	rawProto, err := base64.StdEncoding.DecodeString(teleBatch.Records[0].Payload)
	if err != nil {
		t.Fatalf("decode telemetry payload: %v", err)
	}
	var batch metricpb.MetricBatch
	if err := proto.Unmarshal(rawProto, &batch); err != nil {
		t.Fatalf("unmarshal MetricBatch: %v", err)
	}

	var stepsCompleted float64
	var journeyAvail float64
	for _, m := range batch.GetMetrics() {
		switch m.GetName() {
		case "synthetic.journey.steps_completed":
			stepsCompleted = m.GetPoints()[0].GetValue()
		case "synthetic.journey.available":
			journeyAvail = m.GetPoints()[0].GetValue()
		}
	}
	if stepsCompleted != float64(maxSteps) || journeyAvail != 1.0 {
		t.Fatalf("unexpected journey metrics: steps_completed=%v available=%v", stepsCompleted, journeyAvail)
	}
}

func TestHTTPSyntheticJourneyWasmTLSWithoutLeafCertAndJSONPointerSlash(t *testing.T) {
	wasm := loadBuiltWasm(t, "http_synthetic_journey.wasm")

	cfgJSON := `{
		"journey_name": "wasm-adversarial-g2-g4",
		"min_cert_days_warn": 30,
		"min_cert_days_crit": 7,
		"steps": [
			{
				"name": "edge",
				"method": "GET",
				"url": "https://app.example.test/edge",
				"expect_status": [200],
				"expect_json_fields": [
					{"pointer": "/", "expected": "empty-key-val"}
				]
			}
		]
	}`

	hostNoLeaf := &wasmHost{
		config: []byte(cfgJSON),
		httpEnvelope: func(t *testing.T, _ wasmHTTPRequest) wasmHTTPEnvelopeResponse {
			return wasmHTTPEnvelopeResponse{
				Status: 200,
				Headers: map[string]string{
					"Content-Type": "application/json",
				},
				Body: []byte(`{"":"empty-key-val","a":"other"}`),
				Trace: &wasmHTTPTrace{
					TotalDurationNS:    5_000_000,
					TTFBDurationNS:     4_000_000,
					TransferDurationNS: 1_000_000,
					FinalURL:           "https://app.example.test/edge",
					Protocol:           "HTTP/2.0",
				},
				TLS: &wasmHTTPTLSInfo{
					Version:     "TLS1.3",
					CipherSuite: "TLS_AES_128_GCM_SHA256",
					ALPN:        "h2",
				},
			}
		},
	}

	hostNoLeaf.run(t, wasm, "run_check")
	res := hostNoLeaf.results[len(hostNoLeaf.results)-1]
	if res["status"] != "OK" {
		t.Fatalf("no-leaf-cert result status = %v, summary = %v", res["status"], res["summary"])
	}
	if len(hostNoLeaf.telemetry) != 1 {
		t.Fatalf("telemetry emissions = %d, want 1", len(hostNoLeaf.telemetry))
	}
	var teleNoLeaf struct {
		Records []struct {
			Payload string `json:"payload"`
		} `json:"records"`
	}
	if err := json.Unmarshal(hostNoLeaf.telemetry[0], &teleNoLeaf); err != nil {
		t.Fatalf("unmarshal telemetry batch: %v", err)
	}
	rawNoLeaf, err := base64.StdEncoding.DecodeString(teleNoLeaf.Records[0].Payload)
	if err != nil {
		t.Fatalf("decode telemetry payload: %v", err)
	}
	var batchNoLeaf metricpb.MetricBatch
	if err := proto.Unmarshal(rawNoLeaf, &batchNoLeaf); err != nil {
		t.Fatalf("unmarshal MetricBatch: %v", err)
	}
	for _, m := range batchNoLeaf.GetMetrics() {
		if m.GetName() == "synthetic.step.tls_cert_days_remaining" {
			t.Fatalf("unexpected metric %s emitted without leaf cert", m.GetName())
		}
	}

	// Verify 0 days remaining STILL triggers CRITICAL in compiled TinyGo Wasm when LeafDaysRemaining == 0.
	zeroDays := 0
	notAfter := int64(1790553600)
	hostZeroDays := &wasmHost{
		config: []byte(cfgJSON),
		httpEnvelope: func(t *testing.T, _ wasmHTTPRequest) wasmHTTPEnvelopeResponse {
			return wasmHTTPEnvelopeResponse{
				Status: 200,
				Body:   []byte(`{"":"empty-key-val"}`),
				TLS: &wasmHTTPTLSInfo{
					Version:           "TLS1.3",
					LeafNotAfterUnix:  &notAfter,
					LeafDaysRemaining: &zeroDays,
				},
			}
		},
	}

	hostZeroDays.run(t, wasm, "run_check")
	zeroRes := hostZeroDays.results[len(hostZeroDays.results)-1]
	if zeroRes["status"] != "CRITICAL" {
		t.Fatalf("zero-day-cert result status = %v, want CRITICAL (summary=%v)", zeroRes["status"], zeroRes["summary"])
	}
}
