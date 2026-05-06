package main

import (
	"crypto/tls"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

func TestRunProxmoxCheckLiveFromEnv(t *testing.T) {
	cfg, ok := liveConfigFromEnv(t)
	if !ok {
		t.Skip("set SERVICERADAR_PROXMOX_URL plus SERVICERADAR_PROXMOX_API_TOKEN or token id/secret env vars")
	}

	oldHTTP := proxmoxHTTP
	proxmoxHTTP = liveHTTPClient{}
	t.Cleanup(func() { proxmoxHTTP = oldHTTP })

	result, err := runProxmoxCheck(cfg)
	if err != nil {
		t.Fatalf("runProxmoxCheck() live error = %v", err)
	}
	if result.Status != sdk.StatusOK && result.Status != sdk.StatusWarning {
		t.Fatalf("unexpected status: %s summary=%s", result.Status, result.Summary)
	}

	var details proxmoxDetails
	if err := json.Unmarshal([]byte(result.Details), &details); err != nil {
		t.Fatalf("decode details: %v", err)
	}

	if details.Schema != "serviceradar.proxmox_enrichment.v1" {
		t.Fatalf("unexpected details schema: %s", details.Schema)
	}
	if details.Summary.Targets != 1 {
		t.Fatalf("expected one target, got %d", details.Summary.Targets)
	}
	if details.Summary.Nodes < 1 {
		t.Fatalf("expected at least one Proxmox node, got %d; details=%s", details.Summary.Nodes, result.Details)
	}
	if len(details.Targets) != 1 || len(details.Targets[0].Nodes) < 1 {
		t.Fatalf("expected target node details, got %#v", details.Targets)
	}
	if len(result.DeviceDiscovery) != 1 || len(result.DeviceDiscovery[0].Devices) < 1 {
		t.Fatalf("expected node device discovery, got %#v", result.DeviceDiscovery)
	}

	token := cfg.APIToken
	if strings.TrimSpace(token) != "" && strings.Contains(result.Details, token) {
		t.Fatal("result details leaked Proxmox API token")
	}
	if strings.Contains(result.Details, "PVEAPIToken=") {
		t.Fatal("result details leaked Proxmox API token header marker")
	}

	t.Logf("Proxmox live plugin smoke passed: nodes=%d guests=%d status=%s", details.Summary.Nodes, details.Summary.Guests, result.Status)
}

func liveConfigFromEnv(t *testing.T) (Config, bool) {
	t.Helper()

	baseURL := strings.TrimSpace(os.Getenv("SERVICERADAR_PROXMOX_URL"))
	token := liveTokenFromEnv()
	if baseURL == "" || token == "" {
		return Config{}, false
	}

	includeGuests := false
	cfg := Config{
		BaseURL:            normalizeBaseURL(baseURL),
		APIToken:           token,
		TimeoutMS:          liveEnvInt("SERVICERADAR_PROXMOX_TIMEOUT_MS", defaultTimeoutMS),
		IncludeGuests:      &includeGuests,
		InsecureSkipVerify: liveEnvBool("SERVICERADAR_PROXMOX_INSECURE_SKIP_VERIFY"),
	}
	cfg.applyDefaults()

	return cfg, true
}

func liveTokenFromEnv() string {
	if token := strings.TrimSpace(os.Getenv("SERVICERADAR_PROXMOX_API_TOKEN")); token != "" {
		return proxmoxTokenHeader(token)
	}

	tokenID := strings.TrimSpace(os.Getenv("SERVICERADAR_PROXMOX_TOKEN_ID"))
	tokenSecret := strings.TrimSpace(os.Getenv("SERVICERADAR_PROXMOX_TOKEN_SECRET"))
	if tokenID == "" || tokenSecret == "" {
		return ""
	}

	return proxmoxTokenHeader(tokenID + "=" + tokenSecret)
}

func proxmoxTokenHeader(token string) string {
	token = strings.TrimSpace(token)
	if strings.HasPrefix(token, "PVEAPIToken=") {
		return token
	}
	return "PVEAPIToken=" + token
}

func liveEnvInt(key string, fallback int) int {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}

	parsed, err := strconv.Atoi(value)
	if err != nil || parsed <= 0 {
		return fallback
	}

	return parsed
}

func liveEnvBool(key string) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(key))) {
	case "1", "true", "yes", "y", "on":
		return true
	default:
		return false
	}
}

type liveHTTPClient struct{}

func (liveHTTPClient) Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	timeout := 30 * time.Second
	if req.TimeoutMS > 0 {
		timeout = time.Duration(req.TimeoutMS) * time.Millisecond
	}

	transport := http.DefaultTransport.(*http.Transport).Clone()
	if req.InsecureSkipVerify {
		transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true} //nolint:gosec // operator-controlled live smoke test
	}

	client := &http.Client{Timeout: timeout, Transport: transport}
	method := strings.TrimSpace(req.Method)
	if method == "" {
		method = http.MethodGet
	}

	httpReq, err := http.NewRequest(method, req.URL, strings.NewReader(string(req.Body)))
	if err != nil {
		return nil, err
	}
	for key, value := range req.Headers {
		httpReq.Header.Set(key, value)
	}

	start := time.Now()
	resp, err := client.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, sdk.MaxHTTPResponseBytes))
	if err != nil {
		return nil, err
	}

	return &sdk.HTTPResponse{
		Status:   resp.StatusCode,
		Headers:  liveResponseHeaders(resp.Header),
		Body:     body,
		Duration: time.Since(start),
	}, nil
}

func liveResponseHeaders(headers http.Header) map[string]string {
	out := make(map[string]string, len(headers))
	for key, values := range headers {
		out[key] = strings.Join(values, ",")
	}
	return out
}
