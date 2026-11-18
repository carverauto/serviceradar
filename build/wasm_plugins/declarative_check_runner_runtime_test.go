package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
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

func TestDeclarativeCheckRunnerHTTPJourneyAndTelemetryWithoutWASIStart(t *testing.T) {
	wasm := loadBuiltWasm(t, "declarative_check_runner.wasm")
	const secretToken = "synth-ephemeral-token-99"

	cfgBytes, err := json.Marshal(map[string]any{
		"schema":                "serviceradar.declarative_check_assignment.v1",
		"check_id":              "00000000-0000-4000-8000-000000000101",
		"slug":                  "checkout-wasm-journey",
		"topology":              "edge_only",
		"single_agent_complete": true,
		"allowlist": map[string]any{
			"schemes": []string{"https"},
			"hosts":   []string{"portal.example.com"},
			"ports":   []int{443},
		},
		"targets": []any{
			map[string]any{
				"target_key":  "singleton",
				"target_kind": "singleton",
				"url":         "https://portal.example.com",
				"credential_bindings": map[string]any{
					"portal_auth": map[string]any{
						"slot":       "portal_auth",
						"secret_ref": "credentialref:network-credential-secret:00000000-0000-4000-8000-000000000102",
						"inject": map[string]any{
							"mode":   "http_header",
							"name":   "Authorization",
							"scheme": "Bearer",
						},
						"credential_broker": map[string]any{
							"schema":                "serviceradar.edge_credential_broker_grant.v1",
							"grant_id":              "00000000-0000-4000-8000-000000000103",
							"credential_secret_ref": "credentialref:network-credential-secret:00000000-0000-4000-8000-000000000102",
							"expires_at":            "2099-01-01T00:00:00Z",
							"allow": map[string]any{
								"schemes": []string{"https"},
								"hosts":   []string{"portal.example.com"},
								"ports":   []int{443},
							},
						},
					},
				},
			},
		},
		"nodes": []any{
			map[string]any{
				"id":   "journey",
				"type": "http_journey",
				"config": map[string]any{
					"steps": []any{
						map[string]any{
							"id":              "auth",
							"method":          "POST",
							"url":             "${target.url}/v1/session",
							"credential_slot": "portal_auth",
							"expected_status": 200,
							"extract": []any{
								map[string]any{"name": "session_token", "from": "json_path", "path": "$.token", "secret": true},
								map[string]any{"name": "order_id", "from": "json_path", "path": "$.order_id"},
							},
						},
						map[string]any{
							"id":     "verify_order",
							"method": "GET",
							"url":    "${target.url}/v1/orders/${steps.auth.order_id}",
							"headers": map[string]any{
								"X-Portal-Token": "${steps.auth.session_token}",
							},
							"expected_status": 200,
							"json_assertions": []any{
								map[string]any{"path": "$.state", "op": "eq", "value": "confirmed"},
							},
						},
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	host := &wasmHost{
		config: cfgBytes,
		httpEnvelope: func(t *testing.T, req wasmHTTPRequest) wasmHTTPEnvelopeResponse {
			switch req.URL {
			case "https://portal.example.com/v1/session":
				if req.CredentialInjection == nil || req.CredentialInjection.GrantID != "00000000-0000-4000-8000-000000000103" {
					t.Fatalf("missing credential_injection on step 1: %+v", req.CredentialInjection)
				}
				return wasmHTTPEnvelopeResponse{
					Status:  200,
					Headers: map[string]string{"Content-Type": "application/json"},
					Body:    []byte(`{"token":"` + secretToken + `","order_id":"ord-7"}`),
					HTTPTrace: map[string]any{
						"dns_ms":   1.5,
						"tcp_ms":   2.5,
						"tls_ms":   4.0,
						"ttfb_ms":  9.0,
						"total_ms": 11.0,
					},
				}
			case "https://portal.example.com/v1/orders/ord-7":
				if req.Headers["X-Portal-Token"] != secretToken {
					t.Fatalf("step 2 missing interpolated session_token header: %+v", req.Headers)
				}
				return wasmHTTPEnvelopeResponse{
					Status:  200,
					Headers: map[string]string{"Content-Type": "application/json"},
					Body:    []byte(`{"state":"confirmed"}`),
					HTTPTrace: map[string]any{
						"ttfb_ms":  6.0,
						"total_ms": 8.0,
					},
				}
			default:
				t.Fatalf("unexpected URL: %s", req.URL)
				return wasmHTTPEnvelopeResponse{Status: 500}
			}
		},
	}

	host.run(t, wasm, "run_check")
	if host.httpCalls != 2 {
		t.Fatalf("httpCalls=%d; want 2", host.httpCalls)
	}
	res := host.results[0]
	if res["status"] != "OK" {
		t.Fatalf("status=%v summary=%v; want OK", res["status"], res["summary"])
	}
	detailsRaw, _ := res["details"].(string)
	if strings.Contains(detailsRaw, secretToken) {
		t.Fatalf("secretToken leaked in Wasm result details: %s", detailsRaw)
	}

	var details map[string]any
	if err := json.Unmarshal([]byte(detailsRaw), &details); err != nil {
		t.Fatal(err)
	}
	if details["schema"] != "serviceradar.declarative_check_edge_result.v1" {
		t.Fatalf("unexpected details schema: %v", details["schema"])
	}

	if len(host.telemetry) != 1 {
		t.Fatalf("telemetry batches=%d; want 1", len(host.telemetry))
	}
	var telemetryBatch map[string]any
	if err := json.Unmarshal(host.telemetry[0], &telemetryBatch); err != nil {
		t.Fatal(err)
	}
	records, _ := telemetryBatch["records"].([]any)
	if len(records) != 1 {
		t.Fatalf("telemetry records=%d; want 1", len(records))
	}
	rec0, _ := records[0].(map[string]any)
	if rec0["payload_kind"] != "serviceradar_metrics" {
		t.Fatalf("payload_kind=%v; want serviceradar_metrics", rec0["payload_kind"])
	}
	protoBytes, err := base64.StdEncoding.DecodeString(rec0["payload"].(string))
	if err != nil || !strings.Contains(string(protoBytes), "serviceradar.metric.v1") {
		t.Fatalf("expected serviceradar.metric.v1 protobuf batch, err=%v", err)
	}
}

func TestDeclarativeCheckRunnerTCPTLSAndDNSOverWazeroHost(t *testing.T) {
	wasm := loadBuiltWasm(t, "declarative_check_runner.wasm")

	// Start local TLS 1.3 test listener
	now := time.Now().UTC()
	certPEM, keyPEM := runtimeEphemeralCert(t, "edge.example.com", now.Add(-time.Hour), now.Add(60*24*time.Hour))
	tlsCert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	tlsLn, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{
		Certificates: []tls.Certificate{tlsCert},
		MinVersion:   tls.VersionTLS13,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tlsLn.Close() }()
	go func() {
		for {
			c, aErr := tlsLn.Accept()
			if aErr != nil {
				return
			}
			go func(conn net.Conn) {
				defer func() { _ = conn.Close() }()
				if tc, ok := conn.(*tls.Conn); ok {
					_ = tc.Handshake()
				}
			}(c)
		}
	}()
	_, tlsPortStr, _ := net.SplitHostPort(tlsLn.Addr().String())
	tlsPort, _ := strconv.Atoi(tlsPortStr)

	// Start local DNS-over-TCP test listener
	dnsLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = dnsLn.Close() }()
	go func() {
		for {
			c, aErr := dnsLn.Accept()
			if aErr != nil {
				return
			}
			go serveRuntimeDNSOverTCP(c)
		}
	}()
	_, dnsPortStr, _ := net.SplitHostPort(dnsLn.Addr().String())
	dnsPort, _ := strconv.Atoi(dnsPortStr)

	cfgBytes, err := json.Marshal(map[string]any{
		"schema":                "serviceradar.declarative_check_assignment.v1",
		"check_id":              "00000000-0000-4000-8000-000000000201",
		"slug":                  "composite-edge-posture",
		"topology":              "edge_only",
		"single_agent_complete": true,
		"allowlist": map[string]any{
			"networks": []string{"127.0.0.1/32"},
			"ports":    []int{tlsPort, dnsPort},
		},
		"targets": []any{
			map[string]any{
				"target_key":  "singleton",
				"target_kind": "singleton",
				"host":        "127.0.0.1",
			},
		},
		"nodes": []any{
			map[string]any{
				"id":   "tcp_probe",
				"type": "tcp_connect",
				"config": map[string]any{
					"host": "127.0.0.1",
					"port": dnsPort,
				},
			},
			map[string]any{
				"id":   "tls_probe",
				"type": "tls_handshake",
				"config": map[string]any{
					"host":               "127.0.0.1",
					"port":               tlsPort,
					"server_name":        "edge.example.com",
					"ca_bundle_pem":      string(certPEM),
					"min_days_remaining": 30,
				},
			},
			map[string]any{
				"id":   "dns_probe",
				"type": "dns_lookup",
				"config": map[string]any{
					"nameserver":       "127.0.0.1",
					"port":             dnsPort,
					"query_name":       "edge.example.com",
					"record_type":      "A",
					"expected_answers": []string{"192.0.2.25"},
				},
			},
			map[string]any{
				"id":   "verdict",
				"type": "decision_table",
				"config": map[string]any{
					"combine":         "first_match",
					"default_verdict": "down",
					"rules": []any{
						map[string]any{
							"when": map[string]any{
								"tcp_probe": "healthy",
								"tls_probe": "healthy",
								"dns_probe": "healthy",
							},
							"verdict": "healthy",
							"summary": "TCP, TLS, and DNS healthy",
						},
					},
				},
			},
		},
		"edges": []any{
			map[string]any{"from": "tcp_probe", "to": "verdict"},
			map[string]any{"from": "tls_probe", "to": "verdict"},
			map[string]any{"from": "dns_probe", "to": "verdict"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	host := &wasmHost{
		config: cfgBytes,
		tcpDial: func(t *testing.T, hostAddr string, port uint16, timeout time.Duration) (net.Conn, int32) {
			if timeout <= 0 {
				timeout = 5 * time.Second
			}
			conn, dErr := net.DialTimeout("tcp", net.JoinHostPort(hostAddr, strconv.Itoa(int(port))), timeout)
			if dErr != nil {
				return nil, -5
			}
			return conn, 0
		},
	}

	host.run(t, wasm, "run_check")
	res := host.results[0]
	if res["status"] != "OK" {
		t.Fatalf("status=%v summary=%v details=%v; want OK", res["status"], res["summary"], res["details"])
	}
	if host.tcpCalls != 3 {
		t.Fatalf("tcpCalls=%d; want 3 (tcp_connect + tls_handshake + dns_lookup)", host.tcpCalls)
	}
}

func runtimeEphemeralCert(t *testing.T, dnsName string, notBefore, notAfter time.Time) ([]byte, []byte) {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(7),
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
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
}

func serveRuntimeDNSOverTCP(conn net.Conn) {
	defer func() { _ = conn.Close() }()
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	var lenBuf [2]byte
	if _, err := io.ReadFull(conn, lenBuf[:]); err != nil {
		return
	}
	qLen := int(binary.BigEndian.Uint16(lenBuf[:]))
	q := make([]byte, qLen)
	if _, err := io.ReadFull(conn, q); err != nil || len(q) < 12 {
		return
	}
	var resp []byte
	resp = append(resp, q[0], q[1], 0x85, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00)
	resp = append(resp, q[12:]...)
	resp = append(resp, 0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04, 192, 0, 2, 25)
	out := make([]byte, 2+len(resp))
	binary.BigEndian.PutUint16(out[:2], uint16(len(resp)))
	copy(out[2:], resp)
	_, _ = conn.Write(out)
}
