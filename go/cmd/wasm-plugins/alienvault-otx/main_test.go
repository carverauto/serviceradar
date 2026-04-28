package main

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/sdk"
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
	if page.Counts.SkippedByType["domain"] != 1 {
		t.Fatalf("skipped_by_type[domain] = %d, want 1", page.Counts.SkippedByType["domain"])
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
		ModifiedSince: "2026-04-27T10:00:00Z",
	})
	if err != nil {
		t.Fatalf("subscribedPulsesURL returned error: %v", err)
	}

	want := "https://otx.alienvault.com/api/v1/pulses/subscribed?limit=25&modified_since=2026-04-27T10%3A00%3A00Z&page=3"
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
	}

	cfg.applyDefaults()

	if cfg.BaseURL != defaultBaseURL {
		t.Fatalf("base url = %q, want default %q", cfg.BaseURL, defaultBaseURL)
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
	if page.Counts.SkippedByType["domain"] != 1 {
		t.Fatalf("domain skipped = %d, want 1", page.Counts.SkippedByType["domain"])
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

func TestDecodeOTXHTTPResponseAvoidsJSONMapDecoding(t *testing.T) {
	body := strings.Repeat(`{"indicator":"192.0.2.10","type":"IPv4"}`, 100)
	payload := []byte(`{"status":200,"headers":{"content-type":["application/json"]},"body_base64":"` +
		base64.StdEncoding.EncodeToString([]byte(body)) +
		`","body_encoding":"base64"}`)

	resp, err := decodeOTXHTTPResponse(payload)
	if err != nil {
		t.Fatalf("decodeOTXHTTPResponse: %v", err)
	}
	if resp.Status != 200 {
		t.Fatalf("status = %d, want 200", resp.Status)
	}
	if string(resp.Body) != body {
		t.Fatalf("body did not round-trip")
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
	if page.Counts.SkippedByType["max_indicators"] != 1 {
		t.Fatalf("skipped_by_type[max_indicators] = %d, want 1", page.Counts.SkippedByType["max_indicators"])
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
	if decoded.ThreatIntel.Counts.SkippedByType["domain"] != 1 {
		t.Fatalf("skipped domain count = %d, want 1", decoded.ThreatIntel.Counts.SkippedByType["domain"])
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
		"max_indicators": 25
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
	if cfg.Limit != 10 || cfg.TimeoutMS != 30000 || cfg.MaxIndicators != 25 {
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

	bound := properties["max_indicators"].(map[string]any)
	if got := int(bound["maximum"].(float64)); got != maxIndicators {
		t.Fatalf("max_indicators maximum = %d, want %d", got, maxIndicators)
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
