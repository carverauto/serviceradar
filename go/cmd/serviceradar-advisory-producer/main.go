/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Command serviceradar-advisory-producer is a first-party native add-on that
// downloads vulnerability intelligence feeds and emits ServiceRadar's generic
// advisory-feed contract. Provider-specific parsing stays here; core only
// ingests the normalized contract.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/addon"
	"github.com/carverauto/serviceradar/go/pkg/addon/sdk"
)

const (
	addonID      = "advisory-producer"
	addonVersion = "0.1.0"

	providerCISA      = "cisa"
	providerNVD       = "nvd"
	providerVulnCheck = "vulncheck"

	defaultCISAKEVURL = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
	defaultNVDURL     = "https://services.nvd.nist.gov/rest/json/cves/2.0"
)

var (
	errMissingProviderURL = errors.New("advisory producer requires provider and url")
	errFetchHTTPStatus    = errors.New("advisory feed fetch returned non-success status")
	errEmptyFeed          = errors.New("advisory feed produced no advisory records")
	errUnsupportedFeed    = errors.New("unsupported advisory provider")
	errCloseResponseBody  = errors.New("close advisory feed response body")
)

type advisoryProducer struct {
	client *http.Client

	mu     sync.RWMutex
	config producerConfig
}

type producerConfig struct {
	Provider    string                 `json:"provider,omitempty"`
	FeedKey     string                 `json:"feed_key,omitempty"`
	URL         string                 `json:"url,omitempty"`
	APIKey      string                 `json:"api_key,omitempty"`
	APIToken    string                 `json:"api_token,omitempty"`
	Credentials addon.CredentialBundle `json:"-"`
}

type runPayload struct {
	ActionID        string           `json:"action_id,omitempty"`
	InputValues     map[string]any   `json:"input_values,omitempty"`
	CredentialRefs  map[string]any   `json:"credential_refs,omitempty"`
	CredentialGrant []map[string]any `json:"credential_grants,omitempty"`
}

func (p *advisoryProducer) Info(context.Context) (addon.Info, error) {
	return addon.Info{
		ID:      addonID,
		Version: addonVersion,
		Capabilities: []string{
			addon.CapabilityAdvisoryFeedV1,
			addon.CapabilityProducerScheduleV1,
			addon.CapabilityArtifactStagingV1,
		},
	}, nil
}

func (p *advisoryProducer) Configure(_ context.Context, configJSON []byte) (addon.ConfigureResult, error) {
	var cfg producerConfig
	if len(strings.TrimSpace(string(configJSON))) > 0 {
		if err := json.Unmarshal(configJSON, &cfg); err != nil {
			return addon.ConfigureResult{Accepted: false, Error: err.Error()}, nil
		}

		credentials, err := addon.CredentialBundleFromConfig(configJSON)
		if err != nil {
			return addon.ConfigureResult{Accepted: false, Error: err.Error()}, nil
		}
		cfg.Credentials = credentials
	}

	sum := sha256.Sum256(configJSON)

	p.mu.Lock()
	p.config = cfg
	p.mu.Unlock()

	return addon.ConfigureResult{
		ConfigHash: hex.EncodeToString(sum[:]),
		Accepted:   true,
	}, nil
}

func (p *advisoryProducer) Health(context.Context) (addon.Health, error) {
	return addon.Health{
		Status:  addon.HealthHealthy,
		Version: addonVersion,
	}, nil
}

func (p *advisoryProducer) RunCommand(ctx context.Context, request addon.CommandRequest) (addon.CommandResult, error) {
	settings, err := p.commandSettings(request)
	if err != nil {
		return addon.CommandResult{Success: false, Message: err.Error()}, nil
	}

	body, sourceURL, err := p.fetch(ctx, settings)
	if err != nil {
		return addon.CommandResult{Success: false, Message: err.Error()}, nil
	}

	batch, err := normalizeFeed(settings, sourceURL, body, time.Now().UTC())
	if err != nil {
		return addon.CommandResult{Success: false, Message: err.Error()}, nil
	}

	payload, err := json.Marshal(batch)
	if err != nil {
		return addon.CommandResult{}, err
	}

	return addon.CommandResult{
		Success:     true,
		Message:     fmt.Sprintf("normalized %d %s advisories", len(batch.Advisories), settings.Provider),
		PayloadJSON: payload,
		Metadata: map[string]string{
			"contract": addon.AdvisoryFeedContractVersion,
			"provider": settings.Provider,
			"feed_key": settings.FeedKey,
		},
	}, nil
}

func (p *advisoryProducer) commandSettings(request addon.CommandRequest) (producerConfig, error) {
	p.mu.RLock()
	settings := p.config
	p.mu.RUnlock()

	var payload runPayload
	if len(request.PayloadJSON) > 0 {
		if err := json.Unmarshal(request.PayloadJSON, &payload); err != nil {
			return producerConfig{}, fmt.Errorf("decode producer schedule payload: %w", err)
		}
	}

	mergeString := func(field *string, keys ...string) {
		for _, key := range keys {
			if value := stringMapValue(payload.InputValues, key); value != "" {
				*field = value
				return
			}
		}
	}

	mergeString(&settings.Provider, "provider", "source")
	mergeString(&settings.FeedKey, "feed_key", "feed")
	mergeString(&settings.URL, "url", "source_url")
	mergeString(&settings.APIKey, "api_key")
	mergeString(&settings.APIToken, "api_token", "token")

	action := request.ActionID
	if action == "" {
		action = payload.ActionID
	}
	if settings.Provider == "" {
		settings.Provider = providerFromAction(action)
	}
	settings.Provider = strings.ToLower(strings.TrimSpace(settings.Provider))

	if settings.FeedKey == "" {
		settings.FeedKey = defaultFeedKey(settings.Provider)
	}
	if settings.URL == "" {
		settings.URL = defaultURL(settings.Provider)
	}
	settings = applyCredentialMaterial(settings)
	if settings.Provider == "" || settings.URL == "" {
		return producerConfig{}, errMissingProviderURL
	}

	return settings, nil
}

func applyCredentialMaterial(settings producerConfig) producerConfig {
	switch settings.Provider {
	case providerNVD:
		if settings.APIKey == "" {
			settings.APIKey = credentialValue(settings.Credentials, "nvd_api_key", "nvd", "api_key", "token")
		}
	case providerVulnCheck:
		if settings.APIToken == "" {
			settings.APIToken = credentialValue(settings.Credentials, "vulncheck_api_token", "vulncheck", "api_token", "token")
		}
	}

	return settings
}

func credentialValue(bundle addon.CredentialBundle, identifiers ...string) string {
	for _, identifier := range identifiers {
		credential, ok := bundle.Find(identifier)
		if !ok {
			continue
		}
		if value := strings.TrimSpace(credential.Value); value != "" {
			return value
		}
		for _, field := range []string{"api_key", "api_token", "token", "value"} {
			if value := strings.TrimSpace(credential.Fields[field]); value != "" {
				return value
			}
		}
	}

	return ""
}

func (p *advisoryProducer) fetch(ctx context.Context, settings producerConfig) ([]byte, string, error) {
	client := p.client
	if client == nil {
		client = &http.Client{Timeout: 90 * time.Second}
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, settings.URL, nil)
	if err != nil {
		return nil, "", err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "serviceradar-advisory-producer/"+addonVersion)
	if settings.APIKey != "" && settings.Provider == providerNVD {
		req.Header.Set("apiKey", settings.APIKey)
	}
	if settings.APIToken != "" && settings.Provider == providerVulnCheck {
		req.Header.Set("Authorization", "Bearer "+settings.APIToken)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, "", err
	}

	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		if err := resp.Body.Close(); err != nil {
			return nil, "", fmt.Errorf("%w: provider=%s status=%d: %w", errFetchHTTPStatus, settings.Provider, resp.StatusCode, err)
		}

		return nil, "", fmt.Errorf("%w: provider=%s status=%d", errFetchHTTPStatus, settings.Provider, resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 256<<20))
	closeErr := resp.Body.Close()
	if err != nil {
		return nil, "", err
	}
	if closeErr != nil {
		return nil, "", fmt.Errorf("%w: %w", errCloseResponseBody, closeErr)
	}

	return body, settings.URL, nil
}

func normalizeFeed(settings producerConfig, sourceURL string, body []byte, now time.Time) (addon.AdvisoryFeedBatch, error) {
	var raw any
	if err := json.Unmarshal(body, &raw); err != nil {
		return addon.AdvisoryFeedBatch{}, fmt.Errorf("decode %s feed: %w", settings.Provider, err)
	}

	advisories, err := normalizeRecords(settings.Provider, raw)
	if err != nil {
		return addon.AdvisoryFeedBatch{}, err
	}
	if len(advisories) == 0 {
		return addon.AdvisoryFeedBatch{}, fmt.Errorf("%w: provider=%s", errEmptyFeed, settings.Provider)
	}

	sum := sha256.Sum256(body)
	sha := hex.EncodeToString(sum[:])
	feedKey := settings.FeedKey
	if feedKey == "" {
		feedKey = defaultFeedKey(settings.Provider)
	}

	return addon.AdvisoryFeedBatch{
		SchemaVersion: addon.AdvisoryFeedContractVersion,
		ProducerID:    addonID,
		Source: addon.AdvisorySource{
			Provider:               settings.Provider,
			FeedKey:                feedKey,
			DisplayName:            displayName(settings.Provider, feedKey),
			FeedType:               feedKey,
			Enabled:                true,
			URL:                    sourceURL,
			RefreshIntervalSeconds: 86_400,
			LastMessage:            "advisory batch normalized by first-party producer",
			Metadata: map[string]any{
				"addon_id": addonID,
				"version":  addonVersion,
			},
		},
		Snapshot: addon.AdvisorySnapshot{
			ObjectKey:      fmt.Sprintf("vulnerability-feeds/%s/%s/%s.json", settings.Provider, feedKey, sha),
			SHA256:         sha,
			SourceURL:      sourceURL,
			ContentType:    "application/json",
			Format:         "json",
			SizeBytes:      int64(len(body)),
			StorageBackend: "producer-result",
			Accepted:       true,
			Status:         "normalized",
			FetchedAt:      now,
			AcceptedAt:     now,
		},
		Advisories: advisories,
	}, nil
}

func normalizeRecords(provider string, raw any) ([]addon.AdvisoryRecord, error) {
	switch provider {
	case providerCISA:
		return normalizeCISA(raw), nil
	case providerNVD:
		return normalizeNVD(raw), nil
	case providerVulnCheck:
		return normalizeVulnCheck(raw), nil
	default:
		return nil, fmt.Errorf("%w: %s", errUnsupportedFeed, provider)
	}
}

func normalizeCISA(raw any) []addon.AdvisoryRecord {
	root := asMap(raw)
	items := asMapSlice(root["vulnerabilities"])
	records := make([]addon.AdvisoryRecord, 0, len(items))

	for _, item := range items {
		cve := firstString(item, "cveID", "cve_id", "cve")
		vendor := firstString(item, "vendorProject", "vendor", "vendor_project")
		product := firstString(item, "product")
		coord := addon.AffectedCoordinate{
			Type:           addon.CoordinateTypeVendorProduct,
			Value:          vendorProductValue(vendor, product),
			Vendor:         vendor,
			Product:        product,
			MatchSemantics: "vendor_product",
		}

		record := addon.AdvisoryRecord{
			SourceObjectID:      firstNonEmpty(cve, vendorProductValue(vendor, product)),
			AdvisoryID:          cve,
			CVEID:               cve,
			Title:               firstString(item, "vulnerabilityName", "title"),
			Description:         firstString(item, "shortDescription", "description"),
			Severity:            "Known Exploited",
			PublishedAt:         parseTime(firstString(item, "dateAdded")),
			ModifiedAt:          parseTime(firstString(root, "dateReleased")),
			KEV:                 true,
			ExploitAvailable:    true,
			AffectedCoordinates: []addon.AffectedCoordinate{coord},
			References:          cisaReferences(item),
			Metadata: map[string]any{
				"required_action": firstString(item, "requiredAction"),
				"due_date":        firstString(item, "dueDate"),
				"ransomware_use":  firstString(item, "knownRansomwareCampaignUse"),
				"notes":           firstString(item, "notes"),
			},
		}

		if record.AdvisoryID != "" && coord.Value != "" {
			records = append(records, record)
		}
	}

	return records
}

func normalizeNVD(raw any) []addon.AdvisoryRecord {
	root := asMap(raw)
	items := asMapSlice(root["vulnerabilities"])
	records := make([]addon.AdvisoryRecord, 0, len(items))

	for _, item := range items {
		cveMap := asMap(item["cve"])
		id := firstString(cveMap, "id")
		coords := nvdCoordinates(cveMap)
		if id == "" || len(coords) == 0 {
			continue
		}

		score, severity, vector := nvdMetric(cveMap)
		records = append(records, addon.AdvisoryRecord{
			SourceObjectID:      id,
			AdvisoryID:          id,
			CVEID:               id,
			Title:               id,
			Description:         localizedDescription(cveMap["descriptions"]),
			Severity:            severity,
			CVSSScore:           score,
			CVSSVector:          vector,
			PublishedAt:         parseTime(firstString(cveMap, "published")),
			ModifiedAt:          parseTime(firstString(cveMap, "lastModified")),
			AffectedCoordinates: coords,
			References:          nvdReferences(cveMap),
			Metadata: map[string]any{
				"vuln_status": firstString(cveMap, "vulnStatus"),
			},
		})
	}

	return records
}

func normalizeVulnCheck(raw any) []addon.AdvisoryRecord {
	items := genericRecordItems(raw)
	records := make([]addon.AdvisoryRecord, 0, len(items))

	for _, item := range items {
		nestedCVE := asMap(item["cve"])
		cve := firstNonEmpty(
			firstString(item, "cve", "cve_id", "cveID"),
			firstString(nestedCVE, "id", "cve_id", "cveID"),
		)
		advisoryID := firstNonEmpty(firstString(item, "advisory_id", "id", "vulnerability_id"), cve)
		coords := genericCoordinates(item)
		if advisoryID == "" || len(coords) == 0 {
			continue
		}

		score, severity, vector := genericMetric(item)
		records = append(records, addon.AdvisoryRecord{
			SourceObjectID:      advisoryID,
			AdvisoryID:          advisoryID,
			CVEID:               cve,
			Title:               firstString(item, "title", "name", "vulnerabilityName"),
			Description:         firstString(item, "description", "shortDescription", "summary"),
			Severity:            severity,
			CVSSScore:           score,
			CVSSVector:          vector,
			PublishedAt:         parseTime(firstString(item, "published", "published_at", "dateAdded")),
			ModifiedAt:          parseTime(firstString(item, "modified", "lastModified", "modified_at")),
			KEV:                 firstBool(item, "kev", "known_exploited", "cisa_kev"),
			ExploitAvailable:    firstBool(item, "exploit_available", "exploited", "kev"),
			AffectedCoordinates: coords,
			References:          genericReferences(item),
			Metadata: map[string]any{
				"source": "vulncheck",
			},
		})
	}

	return records
}

func nvdCoordinates(cveMap map[string]any) []addon.AffectedCoordinate {
	var coords []addon.AffectedCoordinate
	for _, config := range asMapSlice(cveMap["configurations"]) {
		for _, node := range asMapSlice(config["nodes"]) {
			for _, match := range asMapSlice(node["cpeMatch"]) {
				criteria := firstString(match, "criteria")
				if criteria == "" || !firstBool(match, "vulnerable") {
					continue
				}
				coords = append(coords, addon.AffectedCoordinate{
					Type:           addon.CoordinateTypeCPE,
					Value:          criteria,
					MatchSemantics: "nvd_cpe_match",
					VersionRange: map[string]any{
						"versionStartIncluding": firstString(match, "versionStartIncluding"),
						"versionStartExcluding": firstString(match, "versionStartExcluding"),
						"versionEndIncluding":   firstString(match, "versionEndIncluding"),
						"versionEndExcluding":   firstString(match, "versionEndExcluding"),
					},
				})
			}
		}
	}
	return dedupeCoordinates(coords)
}

func genericCoordinates(item map[string]any) []addon.AffectedCoordinate {
	var coords []addon.AffectedCoordinate
	for _, purl := range stringList(item["purls"]) {
		coords = append(coords, addon.AffectedCoordinate{Type: addon.CoordinateTypePURL, Value: purl})
	}
	if purl := firstString(item, "purl"); purl != "" {
		coords = append(coords, addon.AffectedCoordinate{Type: addon.CoordinateTypePURL, Value: purl})
	}
	for _, cpe := range stringList(item["cpes"]) {
		coords = append(coords, addon.AffectedCoordinate{Type: addon.CoordinateTypeCPE, Value: cpe})
	}
	if cpe := firstString(item, "cpe"); cpe != "" {
		coords = append(coords, addon.AffectedCoordinate{Type: addon.CoordinateTypeCPE, Value: cpe})
	}

	vendor := firstString(item, "vendor", "vendorProject")
	product := firstString(item, "product")
	if vendor != "" && product != "" {
		coords = append(coords, addon.AffectedCoordinate{
			Type:           addon.CoordinateTypeVendorProduct,
			Value:          vendorProductValue(vendor, product),
			Vendor:         vendor,
			Product:        product,
			MatchSemantics: "vendor_product",
		})
	}

	return dedupeCoordinates(coords)
}

func nvdMetric(cveMap map[string]any) (float64, string, string) {
	metrics := asMap(cveMap["metrics"])
	for _, key := range []string{"cvssMetricV40", "cvssMetricV31", "cvssMetricV30", "cvssMetricV2"} {
		values := asMapSlice(metrics[key])
		if len(values) == 0 {
			continue
		}
		cvss := asMap(values[0]["cvssData"])
		return firstFloat(cvss, "baseScore"),
			firstString(cvss, "baseSeverity", "severity"),
			firstString(cvss, "vectorString")
	}
	return 0, "", ""
}

func genericMetric(item map[string]any) (float64, string, string) {
	metrics := asMap(item["metrics"])
	cvss := asMap(firstNonNil(item["cvss"], metrics["cvss"], metrics["cvss3"], metrics["cvss_v3"]))
	score := firstFloat(item, "cvss_score", "base_score")
	if score == 0 {
		score = firstFloat(cvss, "score", "baseScore")
	}
	severity := firstNonEmpty(firstString(item, "severity"), firstString(cvss, "severity", "baseSeverity"))
	vector := firstNonEmpty(firstString(item, "cvss_vector", "vector"), firstString(cvss, "vector", "vectorString"))
	return score, severity, vector
}

func localizedDescription(value any) string {
	for _, item := range asMapSlice(value) {
		if strings.EqualFold(firstString(item, "lang"), "en") {
			return firstString(item, "value")
		}
	}
	items := asMapSlice(value)
	if len(items) > 0 {
		return firstString(items[0], "value")
	}
	return ""
}

func nvdReferences(cveMap map[string]any) []string {
	var refs []string
	for _, item := range asMapSlice(cveMap["references"]) {
		if url := firstString(item, "url"); url != "" {
			refs = append(refs, url)
		}
	}
	return dedupeStrings(refs)
}

func genericReferences(item map[string]any) []string {
	refs := stringList(item["references"])
	for _, ref := range asMapSlice(item["references"]) {
		if url := firstString(ref, "url"); url != "" {
			refs = append(refs, url)
		}
	}
	if url := firstString(item, "url", "source_url"); url != "" {
		refs = append(refs, url)
	}
	return dedupeStrings(refs)
}

func cisaReferences(item map[string]any) []string {
	return dedupeStrings([]string{
		firstString(item, "notes"),
	})
}

func genericRecordItems(raw any) []map[string]any {
	root := asMap(raw)
	for _, key := range []string{"data", "vulnerabilities", "cves", "advisories", "results"} {
		if items := asMapSlice(root[key]); len(items) > 0 {
			return items
		}
	}
	if len(root) > 0 {
		return []map[string]any{root}
	}
	return nil
}

func asMap(value any) map[string]any {
	if value == nil {
		return map[string]any{}
	}
	if typed, ok := value.(map[string]any); ok {
		return typed
	}
	return map[string]any{}
}

func asMapSlice(value any) []map[string]any {
	values, ok := value.([]any)
	if !ok {
		return nil
	}
	out := make([]map[string]any, 0, len(values))
	for _, value := range values {
		if item := asMap(value); len(item) > 0 {
			out = append(out, item)
		}
	}
	return out
}

func firstString(values map[string]any, keys ...string) string {
	for _, key := range keys {
		switch value := values[key].(type) {
		case string:
			if trimmed := strings.TrimSpace(value); trimmed != "" {
				return trimmed
			}
		case fmt.Stringer:
			if trimmed := strings.TrimSpace(value.String()); trimmed != "" {
				return trimmed
			}
		case float64:
			return strconv.FormatFloat(value, 'f', -1, 64)
		}
	}
	return ""
}

func stringMapValue(values map[string]any, key string) string {
	if values == nil {
		return ""
	}
	return firstString(values, key)
}

func firstBool(values map[string]any, keys ...string) bool {
	for _, key := range keys {
		switch value := values[key].(type) {
		case bool:
			return value
		case string:
			normalized := strings.ToLower(strings.TrimSpace(value))
			if normalized == "true" || normalized == "yes" || normalized == "known" {
				return true
			}
		}
	}
	return false
}

func firstFloat(values map[string]any, keys ...string) float64 {
	for _, key := range keys {
		switch value := values[key].(type) {
		case float64:
			return value
		case string:
			parsed, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
			if err == nil {
				return parsed
			}
		}
	}
	return 0
}

func stringList(value any) []string {
	values, ok := value.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(values))
	for _, value := range values {
		if str, ok := value.(string); ok && strings.TrimSpace(str) != "" {
			out = append(out, strings.TrimSpace(str))
		}
	}
	return out
}

func parseTime(value string) time.Time {
	value = strings.TrimSpace(value)
	if value == "" {
		return time.Time{}
	}
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02"} {
		parsed, err := time.Parse(layout, value)
		if err == nil {
			return parsed
		}
	}
	return time.Time{}
}

func firstNonNil(values ...any) any {
	for _, value := range values {
		if value != nil {
			return value
		}
	}
	return nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func vendorProductValue(vendor, product string) string {
	parts := []string{strings.TrimSpace(vendor), strings.TrimSpace(product)}
	parts = compact(parts)
	return strings.Join(parts, "/")
}

func compact(values []string) []string {
	out := values[:0]
	for _, value := range values {
		if value != "" {
			out = append(out, value)
		}
	}
	return out
}

func dedupeStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	var out []string
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || !strings.HasPrefix(value, "http") {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	sort.Strings(out)
	return out
}

func dedupeCoordinates(values []addon.AffectedCoordinate) []addon.AffectedCoordinate {
	seen := make(map[string]struct{}, len(values))
	var out []addon.AffectedCoordinate
	for _, value := range values {
		key := value.Type + "\x00" + value.Value + "\x00" + value.Vendor + "\x00" + value.Product
		if value.Type == "" || (value.Value == "" && (value.Vendor == "" || value.Product == "")) {
			continue
		}
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		out = append(out, value)
	}
	return out
}

func providerFromAction(action string) string {
	action = strings.ToLower(action)
	switch {
	case strings.Contains(action, "cisa"):
		return providerCISA
	case strings.Contains(action, "nvd"):
		return providerNVD
	case strings.Contains(action, "vulncheck"):
		return providerVulnCheck
	default:
		return ""
	}
}

func defaultFeedKey(provider string) string {
	switch provider {
	case providerCISA:
		return "kev"
	case providerNVD:
		return "cve-2.0"
	case providerVulnCheck:
		return "vulncheck-nvd-kev"
	default:
		return provider
	}
}

func defaultURL(provider string) string {
	switch provider {
	case providerCISA:
		return defaultCISAKEVURL
	case providerNVD:
		return defaultNVDURL
	default:
		return ""
	}
}

func displayName(provider, feedKey string) string {
	switch provider {
	case providerCISA:
		return "CISA Known Exploited Vulnerabilities"
	case providerNVD:
		return "NVD CVE 2.0"
	case providerVulnCheck:
		return "VulnCheck NVD/KEV"
	default:
		return strings.ToUpper(provider) + " " + feedKey
	}
}

func main() {
	sdk.Serve(&advisoryProducer{client: &http.Client{Timeout: 90 * time.Second}})
}
