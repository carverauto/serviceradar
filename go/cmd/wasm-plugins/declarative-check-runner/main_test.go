package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestHTTPRequestAndExtractThresholdPipeline(t *testing.T) {
	fixedNow := time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)
	var emitted []metricSample

	deps := defaultRunnerDeps()
	deps.Now = func() time.Time { return fixedNow }
	deps.EmitMetrics = func(_ string, samples []metricSample, _ time.Time) error {
		emitted = append(emitted, samples...)
		return nil
	}
	deps.HTTPDo = func(req hostHTTPReq) (*hostHTTPResp, error) {
		if req.URL != "https://api.example.com/health" {
			t.Fatalf("unexpected request URL: %s", req.URL)
		}
		return &hostHTTPResp{
			Status:   200,
			Headers:  map[string]string{"Content-Type": "application/json", "X-Region": "synth-east"},
			Body:     []byte(`{"status":"ready","queue_depth":4}`),
			Duration: 18 * time.Millisecond,
			Trace: &hostHTTPTrace{
				DNSMS:      2.5,
				TCPMS:      3.5,
				TLSMS:      5.0,
				TTFBMS:     15.0,
				TransferMS: 3.0,
				TotalMS:    18.0,
			},
		}, nil
	}

	cfg := RunnerConfig{
		Schema:              assignmentSchemaV1,
		CheckID:             "00000000-0000-4000-8000-000000000001",
		Slug:                "api-health-pipeline",
		Topology:            "edge_only",
		SingleAgentComplete: true,
		Allowlist: AllowlistSpec{
			Schemes: []string{"https"},
			Hosts:   []string{"api.example.com"},
			Ports:   []int{443},
		},
		Nodes: []NodeSpec{
			{
				ID:   "probe_http",
				Type: "http_request",
				Config: map[string]any{
					"url":             "https://api.example.com/health",
					"expected_status": 200,
					"expected_headers": map[string]any{
						"X-Region": "synth-east",
					},
					"json_assertions": []any{
						map[string]any{"path": "$.status", "op": "eq", "value": "ready"},
					},
				},
			},
			{
				ID:   "extract_depth",
				Type: "extract_field",
				Config: map[string]any{
					"json_path": "$.queue_depth",
					"cast":      "integer",
					"as":        "queue_depth",
				},
			},
			{
				ID:   "assert_depth",
				Type: "threshold_assert",
				Config: map[string]any{
					"field":    "queue_depth",
					"warning":  10,
					"critical": 25,
				},
			},
			{
				ID:   "verdict",
				Type: "decision_table",
				Config: map[string]any{
					"combine":         "first_match",
					"default_verdict": "down",
					"rules": []any{
						map[string]any{
							"when":    map[string]any{"probe_http": "healthy", "assert_depth": "healthy"},
							"verdict": "healthy",
							"summary": "API ready and queue depth nominal",
						},
					},
				},
			},
		},
		Edges: []EdgeSpec{
			{From: "probe_http", To: "extract_depth"},
			{From: "extract_depth", To: "assert_depth"},
			{From: "probe_http", To: "verdict"},
			{From: "assert_depth", To: "verdict"},
		},
	}

	res := executeCompiledCheck(cfg, deps)
	if res.Status != "OK" {
		t.Fatalf("status=%s summary=%s; want OK", res.Status, res.Summary)
	}

	var env edgeResultEnvelope
	if err := json.Unmarshal([]byte(res.Details), &env); err != nil {
		t.Fatalf("decode details: %v", err)
	}
	if env.Schema != edgeResultSchemaV1 || len(env.Targets) != 1 {
		t.Fatalf("unexpected envelope: %+v", env)
	}
	tgt := env.Targets[0]
	if tgt.Status != "healthy" || tgt.Verdict != "healthy" {
		t.Fatalf("target=%+v", tgt)
	}
	if len(emitted) < 6 {
		t.Fatalf("expected HTTP duration + status + httptrace phase metrics, got %d", len(emitted))
	}
}

func TestHTTPJourneyVariableExtractionSecretScrubbingAndRedirectGuard(t *testing.T) {
	fixedNow := time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)
	const syntheticSessionSecret = "synth-session-value-alpha"

	var recordedReqs []hostHTTPReq
	deps := defaultRunnerDeps()
	deps.Now = func() time.Time { return fixedNow }
	deps.HTTPDo = func(req hostHTTPReq) (*hostHTTPResp, error) {
		recordedReqs = append(recordedReqs, req)
		switch req.URL {
		case "https://checkout.example.com/api/login":
			return &hostHTTPResp{
				Status:   200,
				Headers:  map[string]string{"Set-Cookie": "sid=" + syntheticSessionSecret},
				Body:     []byte(`{"access_token":"` + syntheticSessionSecret + `","cart_id":"cart-42"}`),
				Duration: 10 * time.Millisecond,
			}, nil
		case "https://checkout.example.com/api/carts/cart-42":
			if req.Headers["X-Session"] != syntheticSessionSecret {
				t.Fatalf("step 2 did not receive interpolated secret session header: %+v", req.Headers)
			}
			return &hostHTTPResp{
				Status:   200,
				Body:     []byte(`{"checkout":"ready","echo":"Bearer ` + syntheticSessionSecret + `"}`),
				Duration: 12 * time.Millisecond,
			}, nil
		default:
			t.Fatalf("unexpected request URL: %s", req.URL)
			return nil, nil
		}
	}

	cfg := RunnerConfig{
		Schema:              assignmentSchemaV1,
		CheckID:             "00000000-0000-4000-8000-000000000002",
		Slug:                "checkout-journey",
		Topology:            "edge_only",
		SingleAgentComplete: true,
		Allowlist: AllowlistSpec{
			Schemes: []string{"https"},
			Hosts:   []string{"checkout.example.com"},
			Ports:   []int{443},
		},
		Targets: []TargetSpec{
			{
				TargetKey:  "singleton",
				TargetKind: "singleton",
				URL:        "https://checkout.example.com",
				CredentialBindings: map[string]CredentialBindingSpec{
					"api_auth": {
						Slot:      "api_auth",
						SecretRef: "credentialref:network-credential-secret:00000000-0000-4000-8000-000000000099",
						Inject: CredentialInjectHint{
							Mode:   "http_header",
							Name:   "Authorization",
							Scheme: "Bearer",
						},
						CredentialBroker: CredentialBrokerGrant{
							Schema:              "serviceradar.edge_credential_broker_grant.v1",
							GrantID:             "00000000-0000-4000-8000-000000000088",
							CredentialSecretRef: "credentialref:network-credential-secret:00000000-0000-4000-8000-000000000099",
							ExpiresAt:           "2026-11-18T12:05:00Z",
							Allow: &CredentialBrokerAllow{
								Schemes: []string{"https"},
								Hosts:   []string{"checkout.example.com"},
								Ports:   []int{443},
							},
						},
					},
				},
			},
		},
		Nodes: []NodeSpec{
			{
				ID:   "journey",
				Type: "http_journey",
				Config: map[string]any{
					"steps": []any{
						map[string]any{
							"id":              "login",
							"method":          "POST",
							"url":             "${target.url}/api/login",
							"credential_slot": "api_auth",
							"expected_status": 200,
							"extract": []any{
								map[string]any{"name": "access_token", "from": "json_path", "path": "$.access_token", "secret": true},
								map[string]any{"name": "cart_id", "from": "json_path", "path": "$.cart_id"},
							},
						},
						map[string]any{
							"id":     "inspect_cart",
							"method": "GET",
							"url":    "${target.url}/api/carts/${steps.login.cart_id}",
							"headers": map[string]any{
								"X-Session": "${steps.login.access_token}",
							},
							"expected_status": 200,
							"json_assertions": []any{
								map[string]any{"path": "$.checkout", "op": "eq", "value": "ready"},
							},
						},
					},
				},
			},
		},
	}

	res := executeCompiledCheck(cfg, deps)
	if res.Status != "OK" {
		t.Fatalf("status=%s summary=%s; want OK", res.Status, res.Summary)
	}
	if len(recordedReqs) != 2 {
		t.Fatalf("recordedReqs=%d; want 2", len(recordedReqs))
	}
	if recordedReqs[0].CredentialInjection == nil || recordedReqs[0].CredentialInjection.GrantID != "00000000-0000-4000-8000-000000000088" {
		t.Fatalf("expected brokered credential_injection on step 1, got %+v", recordedReqs[0].CredentialInjection)
	}
	if strings.Contains(res.Details, syntheticSessionSecret) || strings.Contains(res.Summary, syntheticSessionSecret) {
		t.Fatalf("secret value leaked into plugin result: %s", res.Details)
	}

	// Verify disallowed redirect fails closed without making a second HTTP call.
	redirectCalls := 0
	deps.HTTPDo = func(req hostHTTPReq) (*hostHTTPResp, error) {
		redirectCalls++
		return &hostHTTPResp{
			Status:  302,
			Headers: map[string]string{"Location": "http://192.0.2.99/internal"},
		}, nil
	}
	blockedRes := executeCompiledCheck(cfg, deps)
	if blockedRes.Status != "CRITICAL" || redirectCalls != 1 {
		t.Fatalf("status=%s redirectCalls=%d; want CRITICAL/1", blockedRes.Status, redirectCalls)
	}
	if !strings.Contains(blockedRes.Summary, "redirect destination blocked by allowlist") {
		t.Fatalf("unexpected summary for blocked redirect: %s", blockedRes.Summary)
	}
}

func TestTCPConnectProbe(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ln.Close() }()

	go func() {
		conn, acceptErr := ln.Accept()
		if acceptErr != nil {
			return
		}
		defer func() { _ = conn.Close() }()
		_, _ = conn.Write([]byte("220 synth.example.com ESMTP\r\n"))
	}()

	_, portStr, _ := net.SplitHostPort(ln.Addr().String())
	port, _ := strconv.Atoi(portStr)

	cfg := RunnerConfig{
		Schema:              assignmentSchemaV1,
		CheckID:             "00000000-0000-4000-8000-000000000003",
		Slug:                "smtp-banner-tcp",
		Topology:            "edge_only",
		SingleAgentComplete: true,
		Allowlist: AllowlistSpec{
			Networks: []string{"127.0.0.1/32"},
			Ports:    []int{port},
		},
		Targets: []TargetSpec{
			{TargetKey: "singleton", TargetKind: "singleton", Host: "127.0.0.1", Port: port},
		},
		Nodes: []NodeSpec{
			{
				ID:   "tcp_banner",
				Type: "tcp_connect",
				Config: map[string]any{
					"expect": "220 synth.example.com",
				},
			},
		},
	}

	res := executeCompiledCheck(cfg, defaultRunnerDeps())
	if res.Status != "OK" {
		t.Fatalf("status=%s summary=%s; want OK", res.Status, res.Summary)
	}
}

func TestTLSHandshakeExpiryAndVersionAssertions(t *testing.T) {
	now := time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)
	certPEM, keyPEM := generateEphemeralCertPEM(t, "tls.example.com", now.Add(-time.Hour), now.Add(45*24*time.Hour))

	tlsCert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{
		Certificates: []tls.Certificate{tlsCert},
		MinVersion:   tls.VersionTLS13,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ln.Close() }()

	go func() {
		for {
			conn, acceptErr := ln.Accept()
			if acceptErr != nil {
				return
			}
			go func(c net.Conn) {
				defer func() { _ = c.Close() }()
				if tc, ok := c.(*tls.Conn); ok {
					_ = tc.Handshake()
				}
			}(conn)
		}
	}()

	_, portStr, _ := net.SplitHostPort(ln.Addr().String())
	port, _ := strconv.Atoi(portStr)

	deps := defaultRunnerDeps()
	deps.Now = func() time.Time { return now }

	makeCfg := func(minDays float64) RunnerConfig {
		return RunnerConfig{
			Schema:              assignmentSchemaV1,
			CheckID:             "00000000-0000-4000-8000-000000000004",
			Slug:                "tls-expiry-check",
			Topology:            "edge_only",
			SingleAgentComplete: true,
			Allowlist: AllowlistSpec{
				Networks: []string{"127.0.0.1/32"},
				Ports:    []int{port},
			},
			Targets: []TargetSpec{
				{TargetKey: "singleton", TargetKind: "singleton", Host: "127.0.0.1", Port: port},
			},
			Nodes: []NodeSpec{
				{
					ID:   "tls_probe",
					Type: "tls_handshake",
					Config: map[string]any{
						"server_name":          "tls.example.com",
						"ca_bundle_pem":        string(certPEM),
						"expected_tls_version": "TLSv1.3",
						"min_days_remaining":   minDays,
					},
				},
			},
		}
	}

	passRes := executeCompiledCheck(makeCfg(30), deps)
	if passRes.Status != "OK" {
		t.Fatalf("status=%s summary=%s; want OK", passRes.Status, passRes.Summary)
	}

	failRes := executeCompiledCheck(makeCfg(60), deps)
	if failRes.Status != "CRITICAL" || !strings.Contains(failRes.Summary, "certificate expires in") {
		t.Fatalf("status=%s summary=%s; want CRITICAL certificate expiry failure", failRes.Status, failRes.Summary)
	}
}

func TestDNSLookupOverTCP(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ln.Close() }()

	go func() {
		for {
			conn, acceptErr := ln.Accept()
			if acceptErr != nil {
				return
			}
			go serveSyntheticDNSOverTCP(conn)
		}
	}()

	_, portStr, _ := net.SplitHostPort(ln.Addr().String())
	port, _ := strconv.Atoi(portStr)

	cfg := RunnerConfig{
		Schema:              assignmentSchemaV1,
		CheckID:             "00000000-0000-4000-8000-000000000005",
		Slug:                "dns-authoritative-check",
		Topology:            "edge_only",
		SingleAgentComplete: true,
		Allowlist: AllowlistSpec{
			Networks: []string{"127.0.0.1/32"},
			Ports:    []int{port},
		},
		Targets: []TargetSpec{
			{TargetKey: "singleton", TargetKind: "singleton", Host: "127.0.0.1", Port: port},
		},
		Nodes: []NodeSpec{
			{
				ID:   "dns_a",
				Type: "dns_lookup",
				Config: map[string]any{
					"query_name":       "api.example.com",
					"record_type":      "A",
					"expected_answers": []any{"192.0.2.10"},
				},
			},
		},
	}

	res := executeCompiledCheck(cfg, defaultRunnerDeps())
	if res.Status != "OK" {
		t.Fatalf("status=%s summary=%s; want OK", res.Status, res.Summary)
	}

	cfg.Nodes[0].Config["expected_answers"] = []any{"192.0.2.99"}
	mismatchRes := executeCompiledCheck(cfg, defaultRunnerDeps())
	if mismatchRes.Status != "CRITICAL" {
		t.Fatalf("status=%s summary=%s; want CRITICAL on answer mismatch", mismatchRes.Status, mismatchRes.Summary)
	}
}

func generateEphemeralCertPEM(t *testing.T, dnsName string, notBefore, notAfter time.Time) ([]byte, []byte) {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: dnsName},
		NotBefore:             notBefore,
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
		DNSNames:              []string{dnsName},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	return certPEM, keyPEM
}

func serveSyntheticDNSOverTCP(conn net.Conn) {
	defer func() { _ = conn.Close() }()
	var lenBuf [2]byte
	if _, err := io.ReadFull(conn, lenBuf[:]); err != nil {
		return
	}
	qLen := int(binary.BigEndian.Uint16(lenBuf[:]))
	q := make([]byte, qLen)
	if _, err := io.ReadFull(conn, q); err != nil || len(q) < 12 {
		return
	}
	// Echo TXID + standard response flags (QR=1, AA=1, RD=1, RA=1), QDCOUNT=1, ANCOUNT=1
	var resp []byte
	resp = append(resp, q[0], q[1])
	resp = append(resp, 0x85, 0x80)
	resp = append(resp, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00)
	// Copy question section verbatim
	resp = append(resp, q[12:]...)
	// Answer pointer to offset 12 (0xC00C), TYPE A (1), CLASS IN (1), TTL 60, RDLENGTH 4, 192.0.2.10
	resp = append(resp,
		0xC0, 0x0C,
		0x00, 0x01,
		0x00, 0x01,
		0x00, 0x00, 0x00, 0x3C,
		0x00, 0x04,
		192, 0, 2, 10,
	)
	out := make([]byte, 2+len(resp))
	binary.BigEndian.PutUint16(out[:2], uint16(len(resp)))
	copy(out[2:], resp)
	_, _ = conn.Write(out)
}

func TestCanonicalSchemaValidatorNodeFormats(t *testing.T) {
	deps := defaultRunnerDeps()
	deps.HTTPDo = func(_ hostHTTPReq) (*hostHTTPResp, error) {
		return &hostHTTPResp{
			Status:   200,
			Headers:  map[string]string{"Content-Type": "application/json"},
			Body:     []byte(`{"queue":{"depth":3}}`),
			Duration: 10 * time.Millisecond,
		}, nil
	}

	cfg := RunnerConfig{
		Schema:              assignmentSchemaV1,
		CheckID:             "00000000-0000-4000-8000-000000000006",
		Slug:                "canonical-schema-check",
		Topology:            "edge_only",
		SingleAgentComplete: true,
		Allowlist: AllowlistSpec{
			Schemes: []string{"https"},
			Hosts:   []string{"api.example.com"},
			Ports:   []int{443},
		},
		Targets: []TargetSpec{
			{TargetKey: "singleton", TargetKind: "singleton", URL: "https://api.example.com/metrics"},
		},
		Nodes: []NodeSpec{
			{
				ID:   "http_probe",
				Kind: "http_request",
				Config: map[string]any{
					"url": "{{target.url}}",
				},
			},
			{
				ID:   "extract_depth",
				Kind: "extract_field",
				Config: map[string]any{
					"source_type": "jsonpath",
					"expression":  "$.queue.depth",
					"output_key":  "depth",
					"cast":        "integer",
				},
			},
			{
				ID:   "assert_depth",
				Kind: "threshold_assert",
				Config: map[string]any{
					"field":        "depth",
					"warn":         map[string]any{"op": ">=", "value": 5},
					"crit":         map[string]any{"op": ">=", "value": 10},
					"pass_verdict": "queue_ok",
				},
			},
			{
				ID:   "decide",
				Kind: "decision_table",
				Config: map[string]any{
					"inputs": []any{
						map[string]any{"key": "probe", "field": "status"},
						map[string]any{"key": "queue", "field": "verdict"},
					},
					"rules": []any{
						map[string]any{
							"match":   map[string]any{"probe": "healthy", "queue": "queue_ok"},
							"verdict": "healthy",
							"status":  "healthy",
							"summary": "Probe and queue healthy",
						},
						map[string]any{
							"match":   map[string]any{"probe": "*", "queue": "*"},
							"verdict": "degraded",
							"status":  "degraded",
							"summary": "Fallback degraded",
						},
					},
				},
			},
			{
				ID:   "alert",
				Kind: "alert_output",
				Config: map[string]any{
					"verdict_map":      map[string]any{"healthy": "operational"},
					"summary_template": "State={{verdict}} ({{status}})",
				},
			},
		},
		Edges: []EdgeSpec{
			{Source: "http_probe", Target: "extract_depth"},
			{Source: "extract_depth", Target: "assert_depth"},
			{Source: "http_probe", Target: "decide", TargetHandle: "in:probe"},
			{Source: "assert_depth", Target: "decide", TargetHandle: "in:queue"},
			{Source: "decide", Target: "alert"},
		},
	}

	res := executeCompiledCheck(cfg, deps)
	if res.Status != "OK" {
		t.Fatalf("status=%s summary=%s; want OK", res.Status, res.Summary)
	}
	if res.Summary != "State=operational (healthy)" {
		t.Fatalf("summary=%q; want State=operational (healthy)", res.Summary)
	}
}
