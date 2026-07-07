package main

import (
	"encoding/json"
	"errors"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

func TestBuildCTIPageNormalizesSupportedIndicators(t *testing.T) {
	resp := subscribedPulsesResponse{
		Count: 1,
		Next:  stringPtr("https://otx.alienvault.com/api/v1/pulses/subscribed?page=2"),
		Results: []otxPulse{
			{
				ID:         "pulse-1",
				Name:       "Test Pulse",
				AuthorName: "otx-user",
				Created:    "2026-04-27T10:00:00.000000",
				Modified:   "2026-04-27T11:00:00.000000",
				Indicators: []otxIndicator{
					{Indicator: "192.0.2.10", Type: "IPv4"},
					{Indicator: "2001:db8::1", Type: "IPv6"},
					{Indicator: "198.51.100.0/24", Type: "CIDR"},
					{Indicator: "example.invalid", Type: "domain"},
				},
			},
		},
	}

	page := buildCTIPage(resp, Config{MaxIndicators: 10})

	if page.Provider != sourceAlienVaultOTX {
		t.Fatalf("provider = %q, want %q", page.Provider, sourceAlienVaultOTX)
	}
	if page.Counts.Indicators != 3 {
		t.Fatalf("indicators = %d, want 3", page.Counts.Indicators)
	}
	if page.Counts.Skipped != 1 {
		t.Fatalf("skipped = %d, want 1", page.Counts.Skipped)
	}
	if page.Counts.SkippedByType.get("domain") != 1 {
		t.Fatalf("skipped_by_type[domain] = %d, want 1", page.Counts.SkippedByType.get("domain"))
	}
	if page.Indicators[0].SourceObject != "pulse-1" {
		t.Fatalf("source object = %q, want pulse-1", page.Indicators[0].SourceObject)
	}
}

func TestSubscribedPulsesURL(t *testing.T) {
	const apiKey = "super-secret-otx-key"

	got, err := subscribedPulsesURL(Config{
		BaseURL:       "https://otx.alienvault.com/",
		APIKey:        apiKey,
		Limit:         25,
		Page:          3,
		Types:         "IPv4,IPv6,CIDR",
		ModifiedSince: "2026-04-27T10:00:00Z",
	})
	if err != nil {
		t.Fatalf("subscribedPulsesURL returned error: %v", err)
	}

	want := "https://otx.alienvault.com/api/v1/indicators/export?limit=25&page=3&types=IPv4%2CIPv6%2CCIDR&modified_since=2026-04-27T10%3A00%3A00Z"
	if got != want {
		t.Fatalf("url = %q, want %q", got, want)
	}
	if strings.Contains(got, apiKey) {
		t.Fatalf("url leaked API key: %q", got)
	}
}

func TestApplyDefaultsClampsBounds(t *testing.T) {
	cfg := Config{
		BaseURL:       " ",
		Limit:         maxLimit + 50,
		Page:          -1,
		TimeoutMS:     -1,
		MaxIndicators: maxIndicators + 50,
		MaxPages:      maxPages + 50,
		MaxRetries:    maxRetries + 50,
		BackoffMS:     maxBackoffMS + 50,
	}

	cfg.applyDefaults()

	if cfg.BaseURL != defaultBaseURL {
		t.Fatalf("base url = %q, want default %q", cfg.BaseURL, defaultBaseURL)
	}
	if cfg.Types != defaultTypes {
		t.Fatalf("types = %q, want default %q", cfg.Types, defaultTypes)
	}
	if cfg.Limit != maxLimit {
		t.Fatalf("limit = %d, want %d", cfg.Limit, maxLimit)
	}
	if cfg.Page != defaultPage {
		t.Fatalf("page = %d, want %d", cfg.Page, defaultPage)
	}
	if cfg.TimeoutMS != defaultTimeoutMS {
		t.Fatalf("timeout = %d, want %d", cfg.TimeoutMS, defaultTimeoutMS)
	}
	if cfg.MaxIndicators != maxIndicators {
		t.Fatalf("max indicators = %d, want %d", cfg.MaxIndicators, maxIndicators)
	}
	if cfg.MaxPages != maxPages {
		t.Fatalf("max pages = %d, want %d", cfg.MaxPages, maxPages)
	}
	if cfg.MaxRetries != maxRetries {
		t.Fatalf("max retries = %d, want %d", cfg.MaxRetries, maxRetries)
	}
	if cfg.BackoffMS != maxBackoffMS {
		t.Fatalf("backoff ms = %d, want %d", cfg.BackoffMS, maxBackoffMS)
	}
}

func TestHTTPFailureSummaryIncludesSanitizedDetails(t *testing.T) {
	got := httpFailureSummary(&sdk.HTTPResponse{
		Status: 403,
		Body:   []byte(`{"detail":"Authentication required"}`),
	})

	if !strings.Contains(got, "HTTP 403") {
		t.Fatalf("summary = %q, want HTTP status", got)
	}
	if !strings.Contains(got, "Authentication required") {
		t.Fatalf("summary = %q, want response detail", got)
	}
}

func TestSubscribedPulsesResponseMatchesObservedOTXShape(t *testing.T) {
	body := []byte(`{
		"count": 2,
		"next": "https://otx.alienvault.com/api/v1/pulses/subscribed?page=2",
		"previous": null,
		"prefetch_pulse_ids": false,
		"t": 0.1,
		"t2": 0.2,
		"t3": 0.3,
		"results": [
			{
				"id": "pulse-1",
				"name": "Parser Pulse",
				"description": "Observed OTX pulse shape",
				"author_name": "otx-user",
				"adversary": "",
				"tlp": "white",
				"public": 1,
				"revision": 3,
				"more_indicators": false,
				"references": ["https://example.invalid/ref"],
				"attack_ids": [],
				"industries": [],
				"malware_families": [],
				"targeted_countries": [],
				"extract_source": [],
				"created": "2026-04-27T10:00:00Z",
				"modified": "2026-04-27T11:00:00Z",
				"indicators": [
					{"id": 1001, "indicator": "192.0.2.10", "type": "IPv4", "content": "", "title": "", "description": "", "created": "2026-04-27T10:10:00Z", "expiration": null, "is_active": 1, "role": null},
					{"id": 1002, "indicator": "example.invalid", "type": "domain", "expiration": null, "is_active": 1, "role": null}
				]
			},
			{
				"id": "pulse-2",
				"name": "Second Pulse",
				"indicators": [
					{"id": 1003, "indicator": "198.51.100.0/24", "type": "CIDR", "expiration": "2026-05-27T10:00:00Z", "is_active": 1, "role": null}
				]
			}
		]
	}`)

	var resp subscribedPulsesResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("unmarshal subscribed pulses response: %v", err)
	}

	if resp.Next == nil || *resp.Next == "" {
		t.Fatalf("next cursor was not decoded")
	}
	if resp.Previous != nil {
		t.Fatalf("previous = %q, want nil", *resp.Previous)
	}
	if resp.Results[0].TLP != "white" {
		t.Fatalf("tlp = %q, want white", resp.Results[0].TLP)
	}
	if resp.Results[0].Indicators[0].Expiration != nil {
		t.Fatalf("first indicator expiration = %q, want nil", *resp.Results[0].Indicators[0].Expiration)
	}

	page := buildCTIPage(resp, Config{MaxIndicators: 10})
	if page.Counts.Objects != 2 {
		t.Fatalf("objects = %d, want 2", page.Counts.Objects)
	}
	if page.Counts.Total != 2 {
		t.Fatalf("total = %d, want 2", page.Counts.Total)
	}
	if page.Counts.Indicators != 2 {
		t.Fatalf("indicators = %d, want 2", page.Counts.Indicators)
	}
	if page.Counts.SkippedByType.get("domain") != 1 {
		t.Fatalf("domain skipped = %d, want 1", page.Counts.SkippedByType.get("domain"))
	}
	if page.Indicators[0].SourceObject != "pulse-1" {
		t.Fatalf("source object = %q, want pulse-1", page.Indicators[0].SourceObject)
	}
	if page.Indicators[1].Indicator != "198.51.100.0/24" {
		t.Fatalf("second indicator = %q", page.Indicators[1].Indicator)
	}
	if page.Indicators[1].ExpiresAt != "2026-05-27T10:00:00Z" {
		t.Fatalf("expires_at = %q", page.Indicators[1].ExpiresAt)
	}

	scanned, err := parseOTXPage(body, Config{MaxIndicators: 10})
	if err != nil {
		t.Fatalf("parseOTXPage: %v", err)
	}
	if scanned.Counts.Indicators != page.Counts.Indicators {
		t.Fatalf("scanned indicators = %d, want %d", scanned.Counts.Indicators, page.Counts.Indicators)
	}
	if scanned.Indicators[1].ExpiresAt != "2026-05-27T10:00:00Z" {
		t.Fatalf("scanned expires_at = %q", scanned.Indicators[1].ExpiresAt)
	}
}

func TestParseObservedOTXFixture(t *testing.T) {
	fixturePath := os.Getenv("OTX_RESPONSE_FIXTURE")
	if fixturePath == "" {
		t.Skip("set OTX_RESPONSE_FIXTURE to a captured OTX response")
	}

	body, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}

	page, err := parseOTXExportPage(body, Config{MaxIndicators: 2000})
	if err != nil {
		t.Fatalf("parseOTXPage: %v", err)
	}
	if page.Counts.Indicators == 0 {
		t.Fatalf("indicators = 0")
	}
}

func TestMergeExportPagesTracksRowsIndicatorsAndCursor(t *testing.T) {
	first := []byte(`{
		"count": 4,
		"next": "https://otx.alienvault.com/api/v1/indicators/export?limit=2&page=2",
		"results": [
			{"id": 1, "indicator": "example.invalid", "type": "domain"},
			{"id": 2, "indicator": "192.0.2.10", "type": "IPv4"}
		]
	}`)
	second := []byte(`{
		"count": 4,
		"next": null,
		"results": [
			{"id": 3, "indicator": "198.51.100.0/24", "type": "CIDR"},
			{"id": 4, "indicator": "https://example.invalid/a", "type": "URL"}
		]
	}`)

	cfg := Config{Limit: 2, Page: 1, MaxIndicators: 10, MaxPages: 10}
	cfg.applyDefaults()

	page1, err := parseOTXExportPage(first, cfg)
	if err != nil {
		t.Fatalf("parse first page: %v", err)
	}
	page2, err := parseOTXExportPage(second, cfg)
	if err != nil {
		t.Fatalf("parse second page: %v", err)
	}

	merged := newCTIPage(cfg)
	mergeCTIPage(&merged, page1)
	mergeCTIPage(&merged, page2)

	if merged.Counts.Objects != 4 {
		t.Fatalf("objects = %d, want 4", merged.Counts.Objects)
	}
	if merged.Counts.Indicators != 2 {
		t.Fatalf("indicators = %d, want 2", merged.Counts.Indicators)
	}
	if merged.Counts.SkippedByType.get("domain") != 1 || merged.Counts.SkippedByType.get("url") != 1 {
		t.Fatalf("skipped_by_type = %#v", merged.Counts.SkippedByType)
	}
	if got := pageFromURL(page1.Cursor.Next); got != 2 {
		t.Fatalf("next page = %d, want 2", got)
	}
}

func TestBuildCTIPageHonorsMaxIndicatorsAndRedactsSecrets(t *testing.T) {
	resp := subscribedPulsesResponse{
		Count: 1,
		Results: []otxPulse{
			{
				ID:   "pulse-1",
				Name: "Bounded Pulse",
				Indicators: []otxIndicator{
					{Indicator: "192.0.2.10", Type: "IPv4"},
					{Indicator: "192.0.2.11", Type: "IPv4"},
					{Indicator: "192.0.2.12", Type: "IPv4"},
				},
			},
		},
	}

	page := buildCTIPage(resp, Config{APIKey: "secret-api-key", MaxIndicators: 2})

	if page.Counts.Indicators != 2 {
		t.Fatalf("indicators = %d, want 2", page.Counts.Indicators)
	}
	if page.Counts.Skipped != 1 {
		t.Fatalf("skipped = %d, want 1", page.Counts.Skipped)
	}
	if page.Counts.SkippedByType.get("max_indicators") != 1 {
		t.Fatalf("skipped_by_type[max_indicators] = %d, want 1", page.Counts.SkippedByType.get("max_indicators"))
	}

	encoded, err := json.Marshal(ctiPageEnvelope{ThreatIntel: page})
	if err != nil {
		t.Fatalf("marshal CTI page: %v", err)
	}
	if strings.Contains(string(encoded), "secret-api-key") {
		t.Fatalf("CTI payload leaked API key: %s", string(encoded))
	}
}

func TestCTIPageDetailsJSONEncodesPayloadWithoutSecrets(t *testing.T) {
	resp := subscribedPulsesResponse{
		Count: 1,
		Next:  stringPtr("https://otx.alienvault.com/api/v1/pulses/subscribed?page=2"),
		Results: []otxPulse{
			{
				ID:         "pulse-1",
				Name:       "Quoted \"Pulse\"",
				AuthorName: "otx-user",
				Created:    "2026-04-27T10:00:00Z",
				Modified:   "2026-04-27T11:00:00Z",
				Indicators: []otxIndicator{
					{Indicator: "192.0.2.10", Type: "IPv4"},
					{Indicator: "example.invalid", Type: "domain"},
				},
			},
		},
	}

	page := buildCTIPage(resp, Config{
		APIKey:        "secret-api-key",
		ModifiedSince: "2026-04-27T00:00:00Z",
		MaxIndicators: 10,
	})
	encoded := ctiPageDetailsJSON(page)

	if strings.Contains(encoded, "secret-api-key") {
		t.Fatalf("CTI payload leaked API key: %s", encoded)
	}

	var decoded ctiPageEnvelope
	if err := json.Unmarshal([]byte(encoded), &decoded); err != nil {
		t.Fatalf("manual CTI JSON did not decode: %v\n%s", err, encoded)
	}
	if decoded.ThreatIntel.Counts.Indicators != 1 {
		t.Fatalf("indicators = %d, want 1", decoded.ThreatIntel.Counts.Indicators)
	}
	if decoded.ThreatIntel.Counts.SkippedByType.get("domain") != 1 {
		t.Fatalf("skipped domain count = %d, want 1", decoded.ThreatIntel.Counts.SkippedByType.get("domain"))
	}
	if decoded.ThreatIntel.Indicators[0].Label != `Quoted "Pulse"` {
		t.Fatalf("label = %q", decoded.ThreatIntel.Indicators[0].Label)
	}
}

func TestPluginResultJSONEncodesMinimalResult(t *testing.T) {
	encoded := pluginResultJSON("OK", `OTX "ready"`, `{"threat_intel":{"indicators":[]}}`)

	var decoded map[string]any
	if err := json.Unmarshal([]byte(encoded), &decoded); err != nil {
		t.Fatalf("result JSON did not decode: %v\n%s", err, encoded)
	}
	if decoded["schema_version"].(float64) != 1 {
		t.Fatalf("schema_version = %v", decoded["schema_version"])
	}
	if decoded["status"] != "OK" {
		t.Fatalf("status = %v", decoded["status"])
	}
	if decoded["summary"] != `OTX "ready"` {
		t.Fatalf("summary = %v", decoded["summary"])
	}
	if decoded["details"] != `{"threat_intel":{"indicators":[]}}` {
		t.Fatalf("details = %v", decoded["details"])
	}
}

func TestConfigDecodingSupportsSecretRefsAndRuntimeSecret(t *testing.T) {
	const raw = `{
		"base_url": "https://otx.example.test",
		"api_key_secret_ref": "secret://api-key",
		"api_key": "resolved-secret",
		"limit": 10,
		"timeout_ms": 30000,
		"max_pages": 5,
		"max_indicators": 25,
		"max_retries": 4,
		"backoff_ms": 2500
	}`

	var cfg Config
	if err := json.Unmarshal([]byte(raw), &cfg); err != nil {
		t.Fatalf("unmarshal config: %v", err)
	}

	if cfg.APIKeySecretRef != "secret://api-key" {
		t.Fatalf("api_key_secret_ref = %q", cfg.APIKeySecretRef)
	}
	if cfg.APIKey != "resolved-secret" {
		t.Fatalf("api_key was not decoded from runtime secret field")
	}
	if cfg.Limit != 10 || cfg.TimeoutMS != 30000 || cfg.MaxPages != 5 ||
		cfg.MaxIndicators != 25 || cfg.MaxRetries != 4 || cfg.BackoffMS != 2500 {
		t.Fatalf("decoded numeric config = %+v", cfg)
	}
}

func TestConfigSchemaDeclaresSecretRefAndBounds(t *testing.T) {
	body, err := os.ReadFile("config.schema.json")
	if err != nil {
		t.Fatalf("read config schema: %v", err)
	}

	var schema map[string]any
	if err := json.Unmarshal(body, &schema); err != nil {
		t.Fatalf("decode config schema: %v", err)
	}

	properties := schema["properties"].(map[string]any)
	apiKey := properties["api_key_secret_ref"].(map[string]any)
	if apiKey["secretRef"] != true {
		t.Fatalf("api_key_secret_ref.secretRef = %v, want true", apiKey["secretRef"])
	}
	if !requiredField(schema, "api_key_secret_ref") {
		t.Fatalf("api_key_secret_ref must remain required")
	}

	limit := properties["limit"].(map[string]any)
	if got := int(limit["maximum"].(float64)); got != maxLimit {
		t.Fatalf("limit maximum = %d, want %d", got, maxLimit)
	}
	if got := limit["default"].(float64); int(got) != defaultLimit {
		t.Fatalf("limit default = %.0f, want %d", got, defaultLimit)
	}
	types := properties["types"].(map[string]any)
	if types["default"] != defaultTypes {
		t.Fatalf("types default = %v, want %q", types["default"], defaultTypes)
	}
	timeout := properties["timeout_ms"].(map[string]any)
	if got := int(timeout["maximum"].(float64)); got != maxTimeoutMS {
		t.Fatalf("timeout_ms maximum = %d, want %d", got, maxTimeoutMS)
	}

	bound := properties["max_indicators"].(map[string]any)
	if got := int(bound["maximum"].(float64)); got != maxIndicators {
		t.Fatalf("max_indicators maximum = %d, want %d", got, maxIndicators)
	}
	pages := properties["max_pages"].(map[string]any)
	if got := int(pages["maximum"].(float64)); got != maxPages {
		t.Fatalf("max_pages maximum = %d, want %d", got, maxPages)
	}
}

func TestPluginManifestRestrictsHTTPAllowlist(t *testing.T) {
	body, err := os.ReadFile("plugin.yaml")
	if err != nil {
		t.Fatalf("read plugin manifest: %v", err)
	}
	manifest := string(body)

	for _, want := range []string{
		"- http_request",
		"allowed_domains:",
		"- otx.alienvault.com",
		"allowed_ports:",
		"- 443",
		"max_open_connections: 2",
	} {
		if !strings.Contains(manifest, want) {
			t.Fatalf("plugin manifest missing %q", want)
		}
	}
}

func requiredField(schema map[string]any, field string) bool {
	values, ok := schema["required"].([]any)
	if !ok {
		return false
	}
	for _, value := range values {
		if value == field {
			return true
		}
	}
	return false
}

func stringPtr(value string) *string {
	return &value
}

type fakeOTXHTTPClient struct {
	requests []sdk.HTTPRequest
	handler  func(req sdk.HTTPRequest) (*sdk.HTTPResponse, error)
}

func (f *fakeOTXHTTPClient) Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	f.requests = append(f.requests, req)
	return f.handler(req)
}

func swapOTXHTTP(t *testing.T, fake httpClient) {
	t.Helper()
	prev := otxHTTP
	otxHTTP = fake
	t.Cleanup(func() { otxHTTP = prev })
}

func swapOTXSleep(t *testing.T) *[]time.Duration {
	t.Helper()
	prev := otxSleep
	sleeps := &[]time.Duration{}
	otxSleep = func(d time.Duration) { *sleeps = append(*sleeps, d) }
	t.Cleanup(func() { otxSleep = prev })
	return sleeps
}

// swapOTXRand forces deterministic (zero) backoff jitter so exact sleep
// durations can be asserted.
func swapOTXRand(t *testing.T) {
	t.Helper()
	prev := otxRandN
	otxRandN = func(int) int { return 0 }
	t.Cleanup(func() { otxRandN = prev })
}

// swapOTXRandFunc installs a custom jitter source.
func swapOTXRandFunc(t *testing.T, fn func(int) int) {
	t.Helper()
	prev := otxRandN
	otxRandN = fn
	t.Cleanup(func() { otxRandN = prev })
}

// swapOTXNow pins the throttle/backoff clock.
func swapOTXNow(t *testing.T, fixed time.Time) {
	t.Helper()
	prev := otxNow
	otxNow = func() time.Time { return fixed.UTC() }
	t.Cleanup(func() { otxNow = prev })
}

func exportPageBody(next string, indicators ...string) []byte {
	b := jsonBuilder{}
	b.WriteString(`{"count":123456,"next":`)
	if next == "" {
		b.WriteString(`null`)
	} else {
		writeJSONString(&b, next)
	}
	b.WriteString(`,"results":[`)
	for i, indicator := range indicators {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"id":` + strconv.Itoa(i+1) + `,"indicator":"` + indicator + `","type":"IPv4","created":"2026-07-01T00:00:00"}`)
	}
	b.WriteString(`]}`)
	return []byte(b.String())
}

func adaptiveTestConfig() Config {
	return Config{
		BaseURL:       defaultBaseURL,
		APIKey:        "test-key",
		Types:         defaultTypes,
		Limit:         1000,
		Page:          23,
		TimeoutMS:     1000,
		MaxIndicators: 5000,
		MaxPages:      10,
		MaxRetries:    0,
		BackoffMS:     1,
	}
}

func exportNextURL(limit, page int) string {
	return defaultBaseURL + "/api/v1/indicators/export?limit=" + strconv.Itoa(limit) +
		"&page=" + strconv.Itoa(page) + "&types=IPv4%2CIPv6%2CCIDR"
}

func TestFetchSingleOTXExportPageWithRetryRetries429WithExponentialBackoff(t *testing.T) {
	fake := &fakeOTXHTTPClient{}
	fake.handler = func(_ sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
		if len(fake.requests) < 3 {
			return &sdk.HTTPResponse{Status: 429, Body: []byte("rate limited")}, nil
		}
		return &sdk.HTTPResponse{Status: 200, Body: exportPageBody("", "192.0.2.1")}, nil
	}
	swapOTXHTTP(t, fake)
	sleeps := swapOTXSleep(t)
	swapOTXRand(t)

	cfg := adaptiveTestConfig()
	cfg.MaxRetries = 3
	cfg.BackoffMS = 1000

	page, err := fetchSingleOTXExportPageWithRetry(cfg)
	if err != nil {
		t.Fatalf("fetch returned error: %v", err)
	}
	if len(fake.requests) != 3 {
		t.Fatalf("requests = %d, want 3", len(fake.requests))
	}
	if len(page.Indicators) != 1 {
		t.Fatalf("indicators = %d, want 1", len(page.Indicators))
	}
	if want := []time.Duration{time.Second, 2 * time.Second}; len(*sleeps) != len(want) ||
		(*sleeps)[0] != want[0] || (*sleeps)[1] != want[1] {
		t.Fatalf("sleeps = %v, want %v", *sleeps, want)
	}
}

func TestFetchOTXExportPageAdaptiveSplitsDeepPageTimeouts(t *testing.T) {
	gateway504 := []byte("<html><head><title>504 Gateway Time-out</title></head></html>")

	fake := &fakeOTXHTTPClient{}
	fake.handler = func(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
		switch {
		case strings.Contains(req.URL, "limit=1000&page=23"):
			return &sdk.HTTPResponse{Status: 504, Body: gateway504}, nil
		case strings.Contains(req.URL, "limit=500&page=45"):
			return &sdk.HTTPResponse{
				Status: 200,
				Body:   exportPageBody(exportNextURL(500, 46), "192.0.2.1", "192.0.2.2"),
			}, nil
		case strings.Contains(req.URL, "limit=500&page=46"):
			return &sdk.HTTPResponse{
				Status: 200,
				Body:   exportPageBody(exportNextURL(500, 47), "192.0.2.3", "192.0.2.4"),
			}, nil
		default:
			t.Fatalf("unexpected request URL %q", req.URL)
			return nil, nil
		}
	}
	swapOTXHTTP(t, fake)
	swapOTXSleep(t)

	page, err := fetchOTXExportPageAdaptive(adaptiveTestConfig())
	if err != nil {
		t.Fatalf("adaptive fetch returned error: %v", err)
	}
	if len(fake.requests) != 3 {
		t.Fatalf("requests = %d, want 3", len(fake.requests))
	}
	if len(page.Indicators) != 4 {
		t.Fatalf("indicators = %d, want 4", len(page.Indicators))
	}
	if page.Counts.Objects != 4 {
		t.Fatalf("objects = %d, want 4", page.Counts.Objects)
	}
	if !strings.Contains(page.Cursor.Next, "limit=1000&page=24") {
		t.Fatalf("cursor next = %q, want original-limit page 24", page.Cursor.Next)
	}
}

func TestFetchOTXExportPageAdaptiveCompletesWhenFirstHalfEndsExport(t *testing.T) {
	fake := &fakeOTXHTTPClient{}
	fake.handler = func(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
		if strings.Contains(req.URL, "limit=1000&page=23") {
			return &sdk.HTTPResponse{Status: 504, Body: []byte("504 Gateway Time-out")}, nil
		}
		return &sdk.HTTPResponse{Status: 200, Body: exportPageBody("", "192.0.2.1")}, nil
	}
	swapOTXHTTP(t, fake)
	swapOTXSleep(t)

	page, err := fetchOTXExportPageAdaptive(adaptiveTestConfig())
	if err != nil {
		t.Fatalf("adaptive fetch returned error: %v", err)
	}
	if len(fake.requests) != 2 {
		t.Fatalf("requests = %d, want 2 (no second half after exhausted export)", len(fake.requests))
	}
	if page.Cursor.Next != "" {
		t.Fatalf("cursor next = %q, want empty", page.Cursor.Next)
	}
	if len(page.Indicators) != 1 {
		t.Fatalf("indicators = %d, want 1", len(page.Indicators))
	}
}

func TestFetchOTXExportPageAdaptiveBoundedRecursion(t *testing.T) {
	fake := &fakeOTXHTTPClient{}
	fake.handler = func(_ sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
		return &sdk.HTTPResponse{Status: 504, Body: []byte("504 Gateway Time-out")}, nil
	}
	swapOTXHTTP(t, fake)
	swapOTXSleep(t)

	_, err := fetchOTXExportPageAdaptive(adaptiveTestConfig())
	if err == nil {
		t.Fatal("expected error when every page size times out")
	}
	if !strings.Contains(err.Error(), "HTTP 504") {
		t.Fatalf("error = %v, want HTTP 504", err)
	}

	wantURLs := []string{
		"limit=1000&page=23",
		"limit=500&page=45",
		"limit=250&page=89",
	}
	if len(fake.requests) != len(wantURLs) {
		t.Fatalf("requests = %d, want %d", len(fake.requests), len(wantURLs))
	}
	for i, fragment := range wantURLs {
		if !strings.Contains(fake.requests[i].URL, fragment) {
			t.Fatalf("request %d URL = %q, want fragment %q", i, fake.requests[i].URL, fragment)
		}
	}
}

func TestFetchOTXExportPageAdaptiveSplitsOnBodyCapWithoutRetrying(t *testing.T) {
	fake := &fakeOTXHTTPClient{}
	fake.handler = func(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
		if strings.Contains(req.URL, "limit=1000&page=23") {
			return nil, sdk.HostError{Code: -3, Op: "http_request"}
		}
		if strings.Contains(req.URL, "limit=500&page=45") {
			return &sdk.HTTPResponse{
				Status: 200,
				Body:   exportPageBody(exportNextURL(500, 46), "192.0.2.1"),
			}, nil
		}
		return &sdk.HTTPResponse{Status: 200, Body: exportPageBody("", "192.0.2.2")}, nil
	}
	swapOTXHTTP(t, fake)
	sleeps := swapOTXSleep(t)

	cfg := adaptiveTestConfig()
	cfg.MaxRetries = 3

	page, err := fetchOTXExportPageAdaptive(cfg)
	if err != nil {
		t.Fatalf("adaptive fetch returned error: %v", err)
	}
	if len(fake.requests) != 3 {
		t.Fatalf("requests = %d, want 3 (too-large must not be retried at the same size)", len(fake.requests))
	}
	if len(*sleeps) != 0 {
		t.Fatalf("sleeps = %v, want none", *sleeps)
	}
	if len(page.Indicators) != 2 {
		t.Fatalf("indicators = %d, want 2", len(page.Indicators))
	}
}

func TestFetchAndSubmitOTXExportPagesAdvancesCursorAcrossAdaptivePages(t *testing.T) {
	fake := &fakeOTXHTTPClient{}
	fake.handler = func(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
		switch {
		case strings.Contains(req.URL, "limit=1000&page=23"):
			return &sdk.HTTPResponse{Status: 504, Body: []byte("504 Gateway Time-out")}, nil
		case strings.Contains(req.URL, "limit=500&page=45"):
			return &sdk.HTTPResponse{
				Status: 200,
				Body:   exportPageBody(exportNextURL(500, 46), "192.0.2.1", "192.0.2.2"),
			}, nil
		case strings.Contains(req.URL, "limit=500&page=46"):
			return &sdk.HTTPResponse{
				Status: 200,
				Body:   exportPageBody(exportNextURL(500, 47), "192.0.2.3", "192.0.2.4"),
			}, nil
		case strings.Contains(req.URL, "limit=1000&page=24"):
			return &sdk.HTTPResponse{Status: 200, Body: exportPageBody("", "192.0.2.9")}, nil
		default:
			t.Fatalf("unexpected request URL %q", req.URL)
			return nil, nil
		}
	}
	swapOTXHTTP(t, fake)
	swapOTXSleep(t)

	cfg := adaptiveTestConfig()
	cfg.MaxPages = 5

	var emitted []ctiPage
	pages, err := fetchAndSubmitOTXExportPages(cfg, func(page ctiPage) error {
		emitted = append(emitted, page)
		return nil
	})
	if err != nil {
		t.Fatalf("walk returned error: %v", err)
	}
	if pages != 2 || len(emitted) != 2 {
		t.Fatalf("pages = %d emitted = %d, want 2 and 2", pages, len(emitted))
	}

	first := emitted[0]
	if first.Cursor.Complete != "false" || first.Cursor.NextPage != "24" {
		t.Fatalf("first cursor = %+v, want complete=false next_page=24", first.Cursor)
	}
	if first.Cursor.Limit != "1000" || first.Cursor.LastPage != "23" {
		t.Fatalf("first cursor = %+v, want limit=1000 last_page=23", first.Cursor)
	}
	if first.Counts.Indicators != 4 {
		t.Fatalf("first indicators = %d, want 4", first.Counts.Indicators)
	}

	second := emitted[1]
	if second.Cursor.Complete != "true" || second.Cursor.PagesFetched != "2" {
		t.Fatalf("second cursor = %+v, want complete=true pages_fetched=2", second.Cursor)
	}
}

func TestThrottleSkipsFreshPullWithinDailyWindow(t *testing.T) {
	now := time.Date(2026, 7, 6, 12, 0, 0, 0, time.UTC)

	cfg := Config{
		CursorComplete:    true,
		LastPullAt:        now.Add(-2 * time.Hour).Format(time.RFC3339),
		MinPullIntervalMS: defaultMinPullIntervalMS,
	}

	skip, summary := throttleSkip(cfg, now)
	if !skip {
		t.Fatalf("expected throttle skip within window")
	}
	if !strings.Contains(summary, "OTX daily pull skipped") {
		t.Fatalf("summary = %q, want skip message", summary)
	}
	if !strings.Contains(summary, "last pull ") || !strings.Contains(summary, "next due ") {
		t.Fatalf("summary = %q, want last pull / next due stamps", summary)
	}
	// next due should be last pull + 24h.
	if !strings.Contains(summary, "2026-07-07T10:00:00Z") {
		t.Fatalf("summary = %q, want next-due 24h after last pull", summary)
	}
}

func TestThrottleDoesNotSkipWhenNotDueOrResuming(t *testing.T) {
	now := time.Date(2026, 7, 6, 12, 0, 0, 0, time.UTC)
	recent := now.Add(-2 * time.Hour).Format(time.RFC3339)

	cases := []struct {
		name string
		cfg  Config
	}{
		{
			name: "stale last pull outside window",
			cfg: Config{
				CursorComplete:    true,
				LastPullAt:        now.Add(-25 * time.Hour).Format(time.RFC3339),
				MinPullIntervalMS: defaultMinPullIntervalMS,
			},
		},
		{
			name: "partial walk must resume",
			cfg: Config{
				CursorComplete:    false,
				LastPullAt:        recent,
				MinPullIntervalMS: defaultMinPullIntervalMS,
			},
		},
		{
			name: "throttle disabled",
			cfg: Config{
				CursorComplete:    true,
				LastPullAt:        recent,
				MinPullIntervalMS: 0,
			},
		},
		{
			name: "no persisted last pull",
			cfg: Config{
				CursorComplete:    true,
				LastPullAt:        "",
				MinPullIntervalMS: defaultMinPullIntervalMS,
			},
		},
		{
			name: "unparseable last pull",
			cfg: Config{
				CursorComplete:    true,
				LastPullAt:        "not-a-timestamp",
				MinPullIntervalMS: defaultMinPullIntervalMS,
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if skip, _ := throttleSkip(tc.cfg, now); skip {
				t.Fatalf("expected no throttle skip for %q", tc.name)
			}
		})
	}
}

func TestFetchSingleOTXExportPageWithRetrySucceedsAfterTransientFailures(t *testing.T) {
	fake := &fakeOTXHTTPClient{}
	fake.handler = func(_ sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
		switch len(fake.requests) {
		case 1:
			// host-side timeout (host error -6).
			return nil, sdk.HostError{Code: -6, Op: "http_request"}
		case 2:
			// gateway timeout.
			return &sdk.HTTPResponse{Status: 504, Body: []byte("504 Gateway Time-out")}, nil
		default:
			return &sdk.HTTPResponse{Status: 200, Body: exportPageBody("", "192.0.2.1")}, nil
		}
	}
	swapOTXHTTP(t, fake)
	sleeps := swapOTXSleep(t)
	swapOTXRand(t)

	cfg := adaptiveTestConfig()
	cfg.MaxRetries = 5
	cfg.BackoffMS = 2000

	page, err := fetchSingleOTXExportPageWithRetry(cfg)
	if err != nil {
		t.Fatalf("fetch returned error after transient failures: %v", err)
	}
	if len(fake.requests) != 3 {
		t.Fatalf("requests = %d, want 3", len(fake.requests))
	}
	if len(page.Indicators) != 1 {
		t.Fatalf("indicators = %d, want 1", len(page.Indicators))
	}
	if want := []time.Duration{2 * time.Second, 4 * time.Second}; len(*sleeps) != len(want) ||
		(*sleeps)[0] != want[0] || (*sleeps)[1] != want[1] {
		t.Fatalf("sleeps = %v, want %v (base 2s, factor 2)", *sleeps, want)
	}
}

func TestFetchSingleOTXExportPageWithRetryFailsFastOnAuthError(t *testing.T) {
	fake := &fakeOTXHTTPClient{}
	fake.handler = func(_ sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
		return &sdk.HTTPResponse{Status: 403, Body: []byte(`{"detail":"Authentication required"}`)}, nil
	}
	swapOTXHTTP(t, fake)
	sleeps := swapOTXSleep(t)
	swapOTXRand(t)

	cfg := adaptiveTestConfig()
	cfg.MaxRetries = 5

	if _, err := fetchSingleOTXExportPageWithRetry(cfg); err == nil {
		t.Fatal("expected auth error")
	}
	if len(fake.requests) != 1 {
		t.Fatalf("requests = %d, want 1 (auth errors must not be retried)", len(fake.requests))
	}
	if len(*sleeps) != 0 {
		t.Fatalf("sleeps = %v, want none", *sleeps)
	}
}

func TestBackoffDelayIsBoundedExponentialWithJitter(t *testing.T) {
	swapOTXRand(t) // no jitter: exponential ceiling.

	if got := backoffDelayMS(2000, 1); got != 2000 {
		t.Fatalf("attempt 1 delay = %d, want 2000", got)
	}
	if got := backoffDelayMS(2000, 2); got != 4000 {
		t.Fatalf("attempt 2 delay = %d, want 4000", got)
	}
	if got := backoffDelayMS(2000, 3); got != 8000 {
		t.Fatalf("attempt 3 delay = %d, want 8000", got)
	}
	// Deep attempts saturate at the cap.
	if got := backoffDelayMS(2000, 10); got != maxBackoffMS {
		t.Fatalf("attempt 10 delay = %d, want cap %d", got, maxBackoffMS)
	}

	// Equal jitter keeps the delay within [ceil/2, ceil].
	swapOTXRandFunc(t, func(n int) int { return n - 1 })
	if got := backoffDelayMS(2000, 3); got < 4000 || got > 8000 {
		t.Fatalf("jittered attempt 3 delay = %d, want within [4000,8000]", got)
	}
}

func TestFetchAndSubmitStampsLastPullAtOnCompletionAndCountsAttempts(t *testing.T) {
	now := time.Date(2026, 7, 6, 15, 30, 0, 0, time.UTC)
	swapOTXNow(t, now)

	fake := &fakeOTXHTTPClient{}
	fake.handler = func(_ sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
		return &sdk.HTTPResponse{Status: 200, Body: exportPageBody("", "192.0.2.1")}, nil
	}
	swapOTXHTTP(t, fake)
	swapOTXSleep(t)
	swapOTXRand(t)

	otxAttempts = 0
	cfg := adaptiveTestConfig()

	var emitted []ctiPage
	pages, err := fetchAndSubmitOTXExportPages(cfg, func(page ctiPage) error {
		emitted = append(emitted, page)
		return nil
	})
	if err != nil {
		t.Fatalf("walk returned error: %v", err)
	}
	if pages != 1 || len(emitted) != 1 {
		t.Fatalf("pages = %d emitted = %d, want 1 and 1", pages, len(emitted))
	}

	final := emitted[0]
	if final.Cursor.Complete != "true" {
		t.Fatalf("cursor complete = %q, want true", final.Cursor.Complete)
	}
	if final.Cursor.LastPullAt != now.Format(time.RFC3339) {
		t.Fatalf("last_pull_at = %q, want %q", final.Cursor.LastPullAt, now.Format(time.RFC3339))
	}

	// The stamped cursor must survive JSON round-trip so core can persist it.
	details := ctiPageDetailsJSON(final)
	if !strings.Contains(details, `"last_pull_at":"`+now.Format(time.RFC3339)+`"`) {
		t.Fatalf("details missing last_pull_at: %s", details)
	}

	if otxAttempts != 1 {
		t.Fatalf("otxAttempts = %d, want 1", otxAttempts)
	}
}

func TestDailyPullFailureSummaryIsActionable(t *testing.T) {
	summary := dailyPullFailureSummary(6, 45*time.Second, errors.New("OTX request returned HTTP 504"))

	for _, want := range []string{
		"OTX daily pull failed after 6 attempts",
		"over 45000ms",
		"HTTP 504",
	} {
		if !strings.Contains(summary, want) {
			t.Fatalf("summary = %q, want substring %q", summary, want)
		}
	}
}

func TestAllRetriesExhaustedSurfacesCriticalAlert(t *testing.T) {
	// Every page size times out: the walk fails and the run must render a
	// CRITICAL alert result rather than failing silently.
	fake := &fakeOTXHTTPClient{}
	fake.handler = func(_ sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
		return &sdk.HTTPResponse{Status: 504, Body: []byte("504 Gateway Time-out")}, nil
	}
	swapOTXHTTP(t, fake)
	swapOTXSleep(t)
	swapOTXRand(t)

	otxAttempts = 0
	cfg := adaptiveTestConfig()

	_, err := fetchAndSubmitOTXExportPages(cfg, func(ctiPage) error { return nil })
	if err == nil {
		t.Fatal("expected walk error when every attempt times out")
	}
	if otxAttempts == 0 {
		t.Fatal("otxAttempts = 0, want retries counted")
	}

	summary := dailyPullFailureSummary(otxAttempts, 10*time.Second, err)
	result := pluginResultJSON(string(sdk.StatusCritical), summary, "")

	var decoded map[string]any
	if jsonErr := json.Unmarshal([]byte(result), &decoded); jsonErr != nil {
		t.Fatalf("alert result did not decode: %v\n%s", jsonErr, result)
	}
	if decoded["status"] != string(sdk.StatusCritical) {
		t.Fatalf("status = %v, want CRITICAL", decoded["status"])
	}
	if summary, _ := decoded["summary"].(string); !strings.Contains(summary, "OTX daily pull failed after") {
		t.Fatalf("summary = %v, want actionable failure message", decoded["summary"])
	}
}

func TestApplyDefaultsClampsMinPullInterval(t *testing.T) {
	// Absent field keeps the daily default.
	cfg := defaultConfig()
	cfg.MinPullIntervalMS = 0 // simulate operator opt-out
	cfg.applyDefaults()
	if cfg.MinPullIntervalMS != 0 {
		t.Fatalf("explicit 0 (disabled) = %d, want 0", cfg.MinPullIntervalMS)
	}

	over := Config{MinPullIntervalMS: maxMinPullIntervalMS + 1000}
	over.applyDefaults()
	if over.MinPullIntervalMS != maxMinPullIntervalMS {
		t.Fatalf("over-max = %d, want clamp %d", over.MinPullIntervalMS, maxMinPullIntervalMS)
	}

	negative := Config{MinPullIntervalMS: -5}
	negative.applyDefaults()
	if negative.MinPullIntervalMS != defaultMinPullIntervalMS {
		t.Fatalf("negative = %d, want default %d", negative.MinPullIntervalMS, defaultMinPullIntervalMS)
	}

	fresh := defaultConfig()
	fresh.applyDefaults()
	if fresh.MinPullIntervalMS != defaultMinPullIntervalMS {
		t.Fatalf("default = %d, want %d", fresh.MinPullIntervalMS, defaultMinPullIntervalMS)
	}
}
