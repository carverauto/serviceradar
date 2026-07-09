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

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	defaultV3Endpoint     = "https://api.armis.com"
	defaultPageSize       = 100
	defaultMaxPages       = 1
	defaultMaxAssets      = 20
	maxResponseBytes      = 32 << 20
	defaultOutputDir      = "tmp/armis-api-probe"
	v1AccessTokenPath     = "/api/v1/access_token/"
	v1SearchPath          = "/api/v1/search/"
	v3OAuthTokenPath      = "/v3/oauth/token"
	v3AssetSearchPath     = "/v3/assets/_search"
	v3AssetFieldsPath     = "/v3/assets/_search/fields"
	defaultFieldMatchText = "access,switch,vlan,dhcp,connection,port,interface,wired,wireless"
)

var (
	errRequiredEnvMissing = errors.New("missing required env")
	errHTTPStatus         = errors.New("unexpected HTTP status")
	errInvalidLimits      = errors.New("invalid pagination limits")
	errV1TokenMissing     = errors.New("v1 token response missing data.access_token")
	errV3TokenMissing     = errors.New("v3 token response missing access_token")
)

type config struct {
	envFile      string
	endpoint     string
	v3Endpoint   string
	queryMode    string
	pageSize     int
	maxPages     int
	maxAssets    int
	outputDir    string
	fieldMatch   []string
	extraFields  []string
	writeRaw     bool
	skipV1       bool
	skipV3       bool
	managedAQL   string
	unmanagedAQL string
	secretKey    string
	v3ClientID   string
	v3Secret     string
	vendorID     string
	httpClient   *http.Client
}

type v1TokenResponse struct {
	Data struct {
		AccessToken string `json:"access_token"`
	} `json:"data"`
	Success bool `json:"success"`
}

type v1SearchResponse struct {
	Data struct {
		Count   int                      `json:"count"`
		Next    int                      `json:"next"`
		Results []map[string]interface{} `json:"results"`
		Total   int                      `json:"total"`
	} `json:"data"`
	Success bool `json:"success"`
}

type v3TokenResponse struct {
	AccessToken string `json:"access_token"`
	TokenType   string `json:"token_type"`
	ExpiresIn   int    `json:"expires_in"`
}

type v3AssetSearchResponse struct {
	Items []struct {
		AssetID interface{}            `json:"asset_id"`
		Fields  map[string]interface{} `json:"fields"`
	} `json:"items"`
	Next interface{} `json:"next"`
}

type sampledQuery struct {
	Label         string
	Count         int
	Total         int
	Next          int
	AssetIDs      []int
	MatchedKeys   []string
	AllSampleKeys []string
}

type probeSummary struct {
	Endpoint            string                   `json:"endpoint"`
	V3Endpoint          string                   `json:"v3_endpoint"`
	Queries             []sampledQuery           `json:"queries"`
	MatchedFieldCount   int                      `json:"matched_field_count"`
	MatchedFields       []string                 `json:"matched_fields"`
	V3AssetFieldSamples []map[string]interface{} `json:"v3_asset_field_samples"`
}

func main() {
	if err := run(context.Background(), os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "armis api probe failed: %v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) error {
	cfg, err := loadConfig(args)
	if err != nil {
		return err
	}

	if cfg.outputDir != "" {
		if err := os.MkdirAll(cfg.outputDir, 0o700); err != nil {
			return fmt.Errorf("create output dir: %w", err)
		}
	}

	summary := probeSummary{
		Endpoint:   cfg.endpoint,
		V3Endpoint: cfg.v3Endpoint,
	}

	fmt.Printf("Armis probe endpoint=%s v3_endpoint=%s page_size=%d max_pages=%d max_assets=%d\n",
		cfg.endpoint, cfg.v3Endpoint, cfg.pageSize, cfg.maxPages, cfg.maxAssets)

	var assetIDs []int
	if !cfg.skipV1 {
		queries := configuredQueries(cfg)
		if len(queries) == 0 {
			return fmt.Errorf("%w: ARMIS_MANAGED_AQL or ARMIS_UNMANAGED_AQL", errRequiredEnvMissing)
		}

		for _, query := range queries {
			token, err := fetchV1Token(ctx, cfg)
			if err != nil {
				return err
			}

			sampled, err := sampleV1Query(ctx, cfg, token, query.label, query.aql)
			if err != nil {
				return err
			}

			fmt.Printf("v1 %s: sampled=%d total=%d next=%d asset_ids=%d matched_keys=%v\n",
				sampled.Label, sampled.Count, sampled.Total, sampled.Next, len(sampled.AssetIDs), sampled.MatchedKeys)
			summary.Queries = append(summary.Queries, sampled)
			assetIDs = append(assetIDs, sampled.AssetIDs...)
		}

		assetIDs = uniqueInts(assetIDs)
		if len(assetIDs) > cfg.maxAssets {
			assetIDs = assetIDs[:cfg.maxAssets]
		}
	}

	if !cfg.skipV3 {
		v3Token, err := fetchV3Token(ctx, cfg)
		if err != nil {
			return err
		}

		fieldsPayload, discoveredFields, err := listV3Fields(ctx, cfg, v3Token)
		if err != nil {
			return err
		}

		if cfg.outputDir != "" {
			if err := writeJSON(filepath.Join(cfg.outputDir, "v3-fields-response.json"), fieldsPayload); err != nil {
				return err
			}
		}

		matchedFields := filterFields(discoveredFields, cfg.fieldMatch)
		matchedFields = append(matchedFields, cfg.extraFields...)
		matchedFields = uniqueStrings(matchedFields)
		sort.Strings(matchedFields)
		summary.MatchedFields = matchedFields
		summary.MatchedFieldCount = len(matchedFields)

		fmt.Printf("v3 field discovery: discovered_strings=%d matched_fields=%d\n", len(discoveredFields), len(matchedFields))
		for _, field := range firstStrings(matchedFields, 80) {
			fmt.Printf("  field: %s\n", field)
		}

		if len(assetIDs) > 0 {
			searchFields := v3SearchFields(matchedFields)
			items, err := searchV3AssetsByID(ctx, cfg, v3Token, assetIDs, searchFields)
			if err != nil {
				return err
			}

			for _, item := range items {
				sample := sanitizeV3Item(item, cfg.fieldMatch)
				if len(sample) > 0 {
					summary.V3AssetFieldSamples = append(summary.V3AssetFieldSamples, sample)
				}
			}

			fmt.Printf("v3 asset lookup: requested_assets=%d returned_items=%d non_empty_attachment_samples=%d\n",
				len(assetIDs), len(items), len(summary.V3AssetFieldSamples))
			for _, sample := range firstMaps(summary.V3AssetFieldSamples, 20) {
				encoded, _ := json.Marshal(sample)
				fmt.Printf("  sample: %s\n", encoded)
			}
		}
	}

	if cfg.outputDir != "" {
		if err := writeJSON(filepath.Join(cfg.outputDir, "summary.json"), summary); err != nil {
			return err
		}
		fmt.Printf("wrote probe summary to %s\n", filepath.Join(cfg.outputDir, "summary.json"))
	}

	return nil
}

type query struct {
	label string
	aql   string
}

func loadConfig(args []string) (*config, error) {
	fs := flag.NewFlagSet("armis-api-probe", flag.ContinueOnError)
	envFile := fs.String("env-file", ".env", "dotenv file to load before reading ARMIS_* environment variables")
	endpointFlag := fs.String("endpoint", "", "Armis tenant endpoint, defaults to ARMIS_ENDPOINT/ARMIS_API_URL")
	v3EndpointFlag := fs.String("v3-endpoint", defaultV3Endpoint, "Armis v3 API endpoint")
	queryMode := fs.String("query", "both", "which env AQL to sample: managed, unmanaged, both")
	pageSize := fs.Int("page-size", defaultPageSize, "v1 page length")
	maxPages := fs.Int("max-pages", defaultMaxPages, "max v1 pages per query")
	maxAssets := fs.Int("max-assets", defaultMaxAssets, "max sampled asset IDs to enrich through v3")
	outputDir := fs.String("out", defaultOutputDir, "directory for JSON probe artifacts; empty disables writes")
	fieldMatch := fs.String("field-match", defaultFieldMatchText, "comma-separated substrings used to identify interesting fields")
	fields := fs.String("fields", "", "comma-separated extra v3 fields to request")
	writeRaw := fs.Bool("write-raw", false, "write raw v1 page samples; use carefully")
	skipV1 := fs.Bool("skip-v1", false, "skip v1 AQL sampling")
	skipV3 := fs.Bool("skip-v3", false, "skip v3 field discovery and enrichment")
	timeout := fs.Duration("timeout", 90*time.Second, "HTTP client timeout")

	if err := fs.Parse(args); err != nil {
		return nil, err
	}

	if *envFile != "" {
		if err := loadDotEnv(*envFile); err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
	}

	endpoint := strings.TrimRight(firstEnv("ARMIS_ENDPOINT", "ARMIS_API_URL", "SERVICERADAR_ARMIS_API_URL"), "/")
	if *endpointFlag != "" {
		endpoint = strings.TrimRight(*endpointFlag, "/")
	}

	cfg := &config{
		envFile:      *envFile,
		endpoint:     endpoint,
		v3Endpoint:   strings.TrimRight(*v3EndpointFlag, "/"),
		queryMode:    strings.ToLower(strings.TrimSpace(*queryMode)),
		pageSize:     *pageSize,
		maxPages:     *maxPages,
		maxAssets:    *maxAssets,
		outputDir:    *outputDir,
		fieldMatch:   splitCSV(*fieldMatch),
		extraFields:  splitCSV(*fields),
		writeRaw:     *writeRaw,
		skipV1:       *skipV1,
		skipV3:       *skipV3,
		managedAQL:   strings.TrimSpace(os.Getenv("ARMIS_MANAGED_AQL")),
		unmanagedAQL: strings.TrimSpace(os.Getenv("ARMIS_UNMANAGED_AQL")),
		secretKey:    strings.TrimSpace(firstEnv("ARMIS_SECRET_KEY", "ARMIS_API_SECRET", "SERVICERADAR_ARMIS_API_SECRET")),
		v3ClientID: strings.TrimSpace(firstEnv(
			"ARMIS_V3_CLIENT_ID",
			"ARMIS_CLIENT_ID",
			"ARMIS_API_KEY",
		)),
		v3Secret: strings.TrimSpace(firstEnv(
			"ARMIS_V3_CLIENT_SECRET",
			"ARMIS_CLIENT_SECRET",
			"ARMIS_SECRET_KEY",
			"ARMIS_API_SECRET",
			"SERVICERADAR_ARMIS_API_SECRET",
		)),
		vendorID:   strings.TrimSpace(os.Getenv("ARMIS_VENDOR_ID")),
		httpClient: &http.Client{Timeout: *timeout},
	}

	if cfg.pageSize <= 0 || cfg.maxPages <= 0 || cfg.maxAssets < 0 {
		return nil, errInvalidLimits
	}
	if cfg.endpoint == "" {
		return nil, fmt.Errorf("%w: ARMIS_ENDPOINT or --endpoint", errRequiredEnvMissing)
	}
	if !cfg.skipV1 && cfg.secretKey == "" {
		return nil, fmt.Errorf("%w: ARMIS_SECRET_KEY", errRequiredEnvMissing)
	}
	if !cfg.skipV3 {
		if cfg.v3ClientID == "" {
			return nil, fmt.Errorf("%w: ARMIS_V3_CLIENT_ID or ARMIS_CLIENT_ID", errRequiredEnvMissing)
		}
		if cfg.v3Secret == "" {
			return nil, fmt.Errorf("%w: ARMIS_V3_CLIENT_SECRET or ARMIS_CLIENT_SECRET", errRequiredEnvMissing)
		}
		if cfg.vendorID == "" {
			return nil, fmt.Errorf("%w: ARMIS_VENDOR_ID", errRequiredEnvMissing)
		}
	}

	return cfg, nil
}

func configuredQueries(cfg *config) []query {
	var queries []query

	switch cfg.queryMode {
	case "managed":
		if cfg.managedAQL != "" {
			queries = append(queries, query{label: "managed", aql: cfg.managedAQL})
		}
	case "unmanaged":
		if cfg.unmanagedAQL != "" {
			queries = append(queries, query{label: "unmanaged", aql: cfg.unmanagedAQL})
		}
	case "both", "":
		if cfg.managedAQL != "" {
			queries = append(queries, query{label: "managed", aql: cfg.managedAQL})
		}
		if cfg.unmanagedAQL != "" {
			queries = append(queries, query{label: "unmanaged", aql: cfg.unmanagedAQL})
		}
	default:
		if cfg.queryMode != "" {
			queries = append(queries, query{label: "custom", aql: cfg.queryMode})
		}
	}

	return queries
}

func fetchV1Token(ctx context.Context, cfg *config) (string, error) {
	form := url.Values{}
	form.Set("secret_key", cfg.secretKey)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, resolveURL(cfg.endpoint, v1AccessTokenPath), strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	body, err := doRequest(cfg.httpClient, req)
	if err != nil {
		return "", err
	}

	var parsed v1TokenResponse
	if err := json.Unmarshal(body, &parsed); err != nil {
		return "", err
	}
	if strings.TrimSpace(parsed.Data.AccessToken) == "" {
		return "", errV1TokenMissing
	}

	return parsed.Data.AccessToken, nil
}

func sampleV1Query(ctx context.Context, cfg *config, token, label, aql string) (sampledQuery, error) {
	var sampled sampledQuery
	sampled.Label = label

	for page := 0; page < cfg.maxPages; page++ {
		parsed, err := url.Parse(resolveURL(cfg.endpoint, v1SearchPath))
		if err != nil {
			return sampled, err
		}

		params := parsed.Query()
		params.Set("length", strconv.Itoa(cfg.pageSize))
		params.Set("aql", aql)
		if page > 0 {
			params.Set("from", strconv.Itoa(page*cfg.pageSize))
		}
		parsed.RawQuery = params.Encode()

		req, err := http.NewRequestWithContext(ctx, http.MethodGet, parsed.String(), nil)
		if err != nil {
			return sampled, err
		}
		req.Header.Set("Authorization", token)
		req.Header.Set("Accept", "application/json")

		body, err := doRequest(cfg.httpClient, req)
		if err != nil {
			return sampled, err
		}
		if cfg.writeRaw && cfg.outputDir != "" {
			path := filepath.Join(cfg.outputDir, fmt.Sprintf("v1-%s-page-%d.json", safeFilename(label), page))
			if err := os.WriteFile(path, body, 0o600); err != nil {
				return sampled, err
			}
		}

		var parsedResp v1SearchResponse
		if err := json.Unmarshal(body, &parsedResp); err != nil {
			return sampled, err
		}

		sampled.Count += len(parsedResp.Data.Results)
		sampled.Total = parsedResp.Data.Total
		sampled.Next = parsedResp.Data.Next

		for _, item := range parsedResp.Data.Results {
			if id := intField(item, "id", "device_id", "deviceId"); id > 0 {
				sampled.AssetIDs = append(sampled.AssetIDs, id)
			}
			sampled.AllSampleKeys = append(sampled.AllSampleKeys, mapKeys(item)...)
			sampled.MatchedKeys = append(sampled.MatchedKeys, matchingMapKeys(item, cfg.fieldMatch)...)
		}

		if parsedResp.Data.Next <= 0 {
			break
		}
	}

	sampled.AssetIDs = uniqueInts(sampled.AssetIDs)
	sampled.AllSampleKeys = uniqueStrings(sampled.AllSampleKeys)
	sampled.MatchedKeys = uniqueStrings(sampled.MatchedKeys)
	sort.Strings(sampled.AllSampleKeys)
	sort.Strings(sampled.MatchedKeys)

	return sampled, nil
}

func fetchV3Token(ctx context.Context, cfg *config) (string, error) {
	payload := map[string]interface{}{
		"audience":      trailingSlash(cfg.endpoint),
		"grant_type":    "client_credentials",
		"client_id":     cfg.v3ClientID,
		"client_secret": cfg.v3Secret,
		"vendor_id":     cfg.vendorID,
		"scopes": []string{
			"PERMISSION.DEVICE.READ",
			"PERMISSION.PII.DEVICE",
			"FULL_VISIBILITY",
		},
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, resolveURL(cfg.v3Endpoint, v3OAuthTokenPath), bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	respBody, err := doRequest(cfg.httpClient, req)
	if err != nil {
		return "", err
	}

	var parsed v3TokenResponse
	if err := json.Unmarshal(respBody, &parsed); err != nil {
		return "", err
	}
	if strings.TrimSpace(parsed.AccessToken) == "" {
		return "", errV3TokenMissing
	}

	return parsed.AccessToken, nil
}

func listV3Fields(ctx context.Context, cfg *config, token string) (interface{}, []string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, resolveURL(cfg.v3Endpoint, v3AssetFieldsPath), nil)
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")

	body, err := doRequest(cfg.httpClient, req)
	if err != nil {
		return nil, nil, err
	}

	var payload interface{}
	if err := json.Unmarshal(body, &payload); err != nil {
		return nil, nil, err
	}

	fields := extractStrings(payload)
	fields = uniqueStrings(fields)
	sort.Strings(fields)

	return payload, fields, nil
}

func searchV3AssetsByID(ctx context.Context, cfg *config, token string, assetIDs []int, fields []string) ([]map[string]interface{}, error) {
	ids := make([]interface{}, 0, len(assetIDs))
	for _, id := range assetIDs {
		ids = append(ids, id)
	}

	payload := map[string]interface{}{
		"asset_type": "DEVICE",
		"fields":     fields,
		"filter": map[string]interface{}{
			"filter_criteria": "ASSET_ID",
			"asset_id_source": "ASSET_ID",
			"asset_ids":       ids,
			"limit":           len(ids),
		},
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, resolveURL(cfg.v3Endpoint, v3AssetSearchPath), bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	respBody, err := doRequest(cfg.httpClient, req)
	if err != nil {
		return nil, err
	}

	var parsed v3AssetSearchResponse
	if err := json.Unmarshal(respBody, &parsed); err != nil {
		return nil, err
	}

	items := make([]map[string]interface{}, 0, len(parsed.Items))
	for _, item := range parsed.Items {
		items = append(items, map[string]interface{}{
			"asset_id": item.AssetID,
			"fields":   item.Fields,
		})
	}

	return items, nil
}

func doRequest(client *http.Client, req *http.Request) ([]byte, error) {
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return nil, err
	}

	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		trimmed := strings.TrimSpace(string(body))
		if len(trimmed) > 800 {
			trimmed = trimmed[:800] + "...<truncated>"
		}
		return nil, fmt.Errorf("%w: %s %s: HTTP %d: %s", errHTTPStatus, req.Method, req.URL.Path, resp.StatusCode, trimmed)
	}

	return body, nil
}

func loadDotEnv(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}

	lines := strings.Split(string(data), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")

		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		if key == "" {
			continue
		}
		if _, exists := os.LookupEnv(key); exists {
			continue
		}

		value = strings.TrimSpace(value)
		value = strings.Trim(value, `"'`)
		_ = os.Setenv(key, value)
	}

	return nil
}

func firstEnv(keys ...string) string {
	for _, key := range keys {
		if value := strings.TrimSpace(os.Getenv(key)); value != "" {
			return value
		}
	}

	return ""
}

func resolveURL(base, path string) string {
	base = strings.TrimRight(base, "/")
	return base + path
}

func trailingSlash(value string) string {
	value = strings.TrimRight(value, "/")
	if value == "" {
		return value
	}

	return value + "/"
}

func splitCSV(value string) []string {
	fields := strings.FieldsFunc(value, func(r rune) bool {
		return r == ',' || r == '\n' || r == '\t'
	})
	out := make([]string, 0, len(fields))
	for _, field := range fields {
		field = strings.TrimSpace(field)
		if field != "" {
			out = append(out, field)
		}
	}

	return uniqueStrings(out)
}

func filterFields(fields []string, matches []string) []string {
	var out []string
	for _, field := range fields {
		normalized := strings.ToLower(field)
		for _, match := range matches {
			if match == "" {
				continue
			}
			if strings.Contains(normalized, strings.ToLower(match)) {
				out = append(out, field)
				break
			}
		}
	}

	return uniqueStrings(out)
}

func v3SearchFields(matchedFields []string) []string {
	fields := []string{
		"device_id",
		"display",
		"name",
		"ipAddress",
		"ipv4_addresses",
		"macAddress",
		"mac_addresses",
		"site",
		"tags",
		"boundaries",
		"Access Switch",
		"accessSwitch",
		"access_switch",
		"VLAN",
		"vlan",
		"connectionType",
		"Connection Type",
		"dhcpLeaseType",
		"DHCP Lease Type",
	}
	fields = append(fields, matchedFields...)
	fields = uniqueStrings(fields)
	sort.Strings(fields)

	if len(fields) > 120 {
		fields = fields[:120]
	}

	return fields
}

func sanitizeV3Item(item map[string]interface{}, matches []string) map[string]interface{} {
	fields, _ := item["fields"].(map[string]interface{})
	if len(fields) == 0 {
		return nil
	}

	out := map[string]interface{}{
		"asset_id": item["asset_id"],
	}
	for key, value := range fields {
		if value == nil || value == "" {
			continue
		}
		if matchesField(key, matches) || isBaseField(key) {
			out[key] = value
		}
	}

	if len(out) == 1 {
		return nil
	}

	return out
}

func matchesField(key string, matches []string) bool {
	normalized := strings.ToLower(key)
	for _, match := range matches {
		if match != "" && strings.Contains(normalized, strings.ToLower(match)) {
			return true
		}
	}

	return false
}

func isBaseField(key string) bool {
	switch key {
	case "device_id", "display", "name", "site":
		return true
	default:
		return false
	}
}

func extractStrings(value interface{}) []string {
	var out []string
	switch typed := value.(type) {
	case string:
		if strings.TrimSpace(typed) != "" {
			out = append(out, typed)
		}
	case []interface{}:
		for _, item := range typed {
			out = append(out, extractStrings(item)...)
		}
	case map[string]interface{}:
		for key, item := range typed {
			if strings.TrimSpace(key) != "" {
				out = append(out, key)
			}
			out = append(out, extractStrings(item)...)
		}
	}

	return out
}

func matchingMapKeys(item map[string]interface{}, matches []string) []string {
	var out []string
	for key := range item {
		if matchesField(key, matches) {
			out = append(out, key)
		}
	}

	return out
}

func mapKeys(item map[string]interface{}) []string {
	keys := make([]string, 0, len(item))
	for key := range item {
		keys = append(keys, key)
	}

	return keys
}

func intField(item map[string]interface{}, keys ...string) int {
	for _, key := range keys {
		switch value := item[key].(type) {
		case float64:
			return int(value)
		case int:
			return value
		case json.Number:
			parsed, _ := value.Int64()
			return int(parsed)
		case string:
			parsed, _ := strconv.Atoi(strings.TrimSpace(value))
			return parsed
		}
	}

	return 0
}

func uniqueInts(values []int) []int {
	seen := make(map[int]struct{}, len(values))
	out := make([]int, 0, len(values))
	for _, value := range values {
		if value <= 0 {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}

	return out
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	out := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}

	return out
}

func firstStrings(values []string, n int) []string {
	if len(values) <= n {
		return values
	}

	return values[:n]
}

func firstMaps(values []map[string]interface{}, n int) []map[string]interface{} {
	if len(values) <= n {
		return values
	}

	return values[:n]
}

func writeJSON(path string, value interface{}) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(path, append(data, '\n'), 0o600)
}

func safeFilename(value string) string {
	var builder strings.Builder
	for _, r := range value {
		switch {
		case r >= 'a' && r <= 'z':
			builder.WriteRune(r)
		case r >= 'A' && r <= 'Z':
			builder.WriteRune(r)
		case r >= '0' && r <= '9':
			builder.WriteRune(r)
		default:
			builder.WriteRune('-')
		}
	}

	return strings.Trim(builder.String(), "-")
}
