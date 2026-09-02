package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

const (
	defaultPageSize              = 1000
	defaultMaxRows               = 25000
	defaultMaxResultBytes        = 10 * 1024 * 1024
	defaultRequestTimeoutSeconds = 30
	defaultMaxRetries            = 2
	maxQueries                   = 8
	maxFilterStringBytes         = 512
	maxIDsPerQuery               = 1000
	maxPageSize                  = 5000
	maxInventoryRows             = 100000
	maxInventoryResultBytes      = 12 * 1024 * 1024
	nnmTokenPath                 = "/idp/oauth2/token"
	directNATokenPath            = "/nom-na/idp/oauth2/token"
	directNAClientID             = "id1"
	directNAClientSecret         = "secret1"
)

type tokenAuthMode string

const (
	tokenAuthNNM tokenAuthMode = "nnm"
	tokenAuthNA  tokenAuthMode = "na"
)

type Config struct {
	InstanceID            string       `json:"instance_id"`
	NNMURL                string       `json:"nnm_url,omitempty"`
	TokenURL              string       `json:"token_url,omitempty"`
	APIURL                string       `json:"api_url"`
	Queries               []Query      `json:"queries"`
	PageSize              int          `json:"page_size"`
	MaxRows               int          `json:"max_rows"`
	MaxResultBytes        int          `json:"max_result_bytes"`
	RequestTimeoutSeconds int          `json:"request_timeout_seconds"`
	MaxRetries            int          `json:"max_retries"`
	L2Endpoints           []L2Endpoint `json:"l2_endpoints,omitempty"`
	InsecureSkipVerify    bool         `json:"insecure_skip_verify,omitempty"`
	tokenAuthMode         tokenAuthMode
}

type L2Endpoint struct {
	MAC string `json:"mac,omitempty"`
	IP  string `json:"ip,omitempty"`
}

type Query struct {
	Name       string         `json:"name"`
	Parameters map[string]any `json:"parameters"`
}

func (q *Query) UnmarshalJSON(data []byte) error {
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(data, &envelope); err != nil {
		return err
	}
	for key := range envelope {
		if key != "name" && key != "parameters" {
			return fmt.Errorf("query field %q is not allowed", key)
		}
	}
	var parameterKeys map[string]json.RawMessage
	if parameters := envelope["parameters"]; len(parameters) > 0 {
		if err := json.Unmarshal(parameters, &parameterKeys); err != nil {
			return errors.New("parameters must be an object")
		}
	}
	for key := range parameterKeys {
		if key != "ids" && !isAllowedBooleanFilter(key) && !isAllowedStringFilter(key) {
			return fmt.Errorf("parameter %q is not allowed", key)
		}
	}

	var raw struct {
		Name       string              `json:"name"`
		Parameters queryParametersJSON `json:"parameters"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}

	parameters := make(map[string]any, 16)
	for key, value := range map[string]*string{
		"software":  raw.Parameters.Software,
		"vendor":    raw.Parameters.Vendor,
		"type":      raw.Parameters.Type,
		"model":     raw.Parameters.Model,
		"family":    raw.Parameters.Family,
		"group":     raw.Parameters.Group,
		"hierarchy": raw.Parameters.Hierarchy,
		"host":      raw.Parameters.Host,
		"ip":        raw.Parameters.IP,
		"realm":     raw.Parameters.Realm,
		"vtpdomain": raw.Parameters.VTPDomain,
		"context":   raw.Parameters.Context,
	} {
		if value != nil {
			parameters[key] = *value
		}
	}
	if raw.Parameters.Disabled != nil {
		parameters["disabled"] = *raw.Parameters.Disabled
	}
	if raw.Parameters.PollExcluded != nil {
		parameters["pollexcluded"] = *raw.Parameters.PollExcluded
	}
	if raw.Parameters.IDs != nil {
		ids := make([]any, len(raw.Parameters.IDs))
		for i, id := range raw.Parameters.IDs {
			ids[i] = json.Number(fmt.Sprintf("%d", id))
		}
		parameters["ids"] = ids
	}

	q.Name = raw.Name
	q.Parameters = parameters
	return nil
}

type queryParametersJSON struct {
	Software     *string `json:"software"`
	Vendor       *string `json:"vendor"`
	Type         *string `json:"type"`
	Model        *string `json:"model"`
	Family       *string `json:"family"`
	Group        *string `json:"group"`
	Hierarchy    *string `json:"hierarchy"`
	Host         *string `json:"host"`
	IP           *string `json:"ip"`
	Realm        *string `json:"realm"`
	VTPDomain    *string `json:"vtpdomain"`
	Context      *string `json:"context"`
	Disabled     *bool   `json:"disabled"`
	PollExcluded *bool   `json:"pollexcluded"`
	IDs          []int64 `json:"ids"`
}

func ParseConfig(data []byte) (Config, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	decoder.UseNumber()

	var cfg Config
	if err := decoder.Decode(&cfg); err != nil {
		return Config{}, fmt.Errorf("invalid configuration: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return Config{}, errors.New("invalid configuration: trailing data")
	}

	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return Config{}, fmt.Errorf("invalid configuration: %w", err)
	}
	if err := cfg.applyDefaults(fields); err != nil {
		return Config{}, err
	}
	if err := cfg.resolveTokenEndpoint(); err != nil {
		return Config{}, err
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func (c Config) UsesDirectNAToken() bool {
	if c.tokenAuthMode == tokenAuthNA {
		return true
	}
	if c.tokenAuthMode == tokenAuthNNM {
		return false
	}
	return strings.Contains(c.TokenURL, "/nom-na/")
}

func (c *Config) applyDefaults(fields map[string]json.RawMessage) error {
	defaultable := []string{
		"queries",
		"page_size",
		"max_rows",
		"max_result_bytes",
		"request_timeout_seconds",
		"max_retries",
	}
	for _, field := range defaultable {
		if raw, ok := fields[field]; ok && bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			return fmt.Errorf("%s must not be null", field)
		}
	}

	if _, ok := fields["queries"]; !ok {
		c.Queries = []Query{{Name: "switches", Parameters: map[string]any{"type": "Switch"}}}
	}
	if _, ok := fields["page_size"]; !ok {
		c.PageSize = defaultPageSize
	}
	if _, ok := fields["max_rows"]; !ok {
		c.MaxRows = defaultMaxRows
	}
	if _, ok := fields["max_result_bytes"]; !ok {
		c.MaxResultBytes = defaultMaxResultBytes
	}
	if _, ok := fields["request_timeout_seconds"]; !ok {
		c.RequestTimeoutSeconds = defaultRequestTimeoutSeconds
	}
	if _, ok := fields["max_retries"]; !ok {
		c.MaxRetries = defaultMaxRetries
	}
	return nil
}

func (c *Config) resolveTokenEndpoint() error {
	c.NNMURL = strings.TrimSpace(c.NNMURL)
	c.TokenURL = strings.TrimSpace(c.TokenURL)
	c.APIURL = strings.TrimSpace(c.APIURL)

	if c.NNMURL != "" {
		if err := validateHTTPSOrigin("nnm_url", c.NNMURL); err != nil {
			return err
		}
		derived, err := joinHTTPSOriginPath(c.NNMURL, nnmTokenPath)
		if err != nil {
			return err
		}
		if c.TokenURL != "" && c.TokenURL != derived {
			return errors.New("token_url must match nnm_url when both are set")
		}
		c.TokenURL = derived
		c.tokenAuthMode = tokenAuthNNM
		return nil
	}
	if c.TokenURL != "" {
		c.tokenAuthMode = inferTokenAuthMode(c.TokenURL)
		return nil
	}
	if c.APIURL == "" {
		return errors.New("api_url must be an absolute HTTPS URL")
	}
	derived, err := joinHTTPSOriginPath(c.APIURL, directNATokenPath)
	if err != nil {
		return err
	}
	c.TokenURL = derived
	c.tokenAuthMode = tokenAuthNA
	return nil
}

func inferTokenAuthMode(tokenURL string) tokenAuthMode {
	if strings.Contains(tokenURL, "/nom-na/") {
		return tokenAuthNA
	}
	return tokenAuthNNM
}

func (c Config) Validate() error {
	if !validIdentifier(c.InstanceID, 128) {
		return errors.New("instance_id must be a non-empty stable identifier")
	}
	if c.NNMURL != "" {
		if err := validateHTTPSOrigin("nnm_url", c.NNMURL); err != nil {
			return err
		}
	}
	if err := validateHTTPSURL("token_url", c.TokenURL); err != nil {
		return err
	}
	if err := validateHTTPSURL("api_url", c.APIURL); err != nil {
		return err
	}
	if len(c.Queries) == 0 || len(c.Queries) > maxQueries {
		return fmt.Errorf("queries must contain between 1 and %d entries", maxQueries)
	}
	if c.PageSize < 1 || c.PageSize > maxPageSize {
		return fmt.Errorf("page_size must be between 1 and %d", maxPageSize)
	}
	if c.MaxRows < c.PageSize || c.MaxRows > maxInventoryRows {
		return fmt.Errorf("max_rows must be between page_size and %d", maxInventoryRows)
	}
	if c.MaxResultBytes < 64*1024 || c.MaxResultBytes > maxInventoryResultBytes {
		return fmt.Errorf("max_result_bytes must be between 65536 and %d", maxInventoryResultBytes)
	}
	if c.RequestTimeoutSeconds < 1 || c.RequestTimeoutSeconds > 300 {
		return errors.New("request_timeout_seconds must be between 1 and 300")
	}
	if c.MaxRetries < 0 || c.MaxRetries > 5 {
		return errors.New("max_retries must be between 0 and 5")
	}

	seenNames := make(map[string]struct{}, len(c.Queries))
	for i, query := range c.Queries {
		name := strings.TrimSpace(query.Name)
		if !validIdentifier(name, 80) {
			return fmt.Errorf("queries[%d].name is invalid", i)
		}
		if _, exists := seenNames[name]; exists {
			return fmt.Errorf("queries[%d].name is duplicated", i)
		}
		seenNames[name] = struct{}{}
		if err := validateQueryParameters(query.Parameters); err != nil {
			return fmt.Errorf("queries[%d]: %w", i, err)
		}
	}

	return nil
}

func validateHTTPSURL(field, raw string) error {
	parsed, err := parseHTTPSURL(field, raw)
	if err != nil {
		return err
	}
	if parsed.Path == "" || parsed.Path == "/" || strings.HasSuffix(parsed.Path, "/") || parsed.RawPath != "" {
		return fmt.Errorf("%s must identify one exact non-root endpoint without a trailing slash", field)
	}
	return nil
}

func validateHTTPSOrigin(field, raw string) error {
	parsed, err := parseHTTPSURL(field, raw)
	if err != nil {
		return err
	}
	if parsed.Path != "" && parsed.Path != "/" {
		return fmt.Errorf("%s must be an HTTPS origin without a path", field)
	}
	return nil
}

func parseHTTPSURL(field, raw string) (*url.URL, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed == nil || parsed.Scheme != "https" || !validEndpointHost(parsed.Hostname()) {
		return nil, fmt.Errorf("%s must be an absolute HTTPS URL", field)
	}
	if parsed.User != nil || parsed.Fragment != "" || parsed.RawQuery != "" || parsed.Opaque != "" {
		return nil, fmt.Errorf("%s must not contain credentials, query parameters, or a fragment", field)
	}
	if portText := parsed.Port(); portText != "" {
		port, err := strconv.Atoi(portText)
		if err != nil || port < 1 || port > 65535 {
			return nil, fmt.Errorf("%s contains an invalid port", field)
		}
	}
	return parsed, nil
}

func joinHTTPSOriginPath(raw, path string) (string, error) {
	parsed, err := parseHTTPSURL("url", raw)
	if err != nil {
		return "", err
	}
	origin := parsed.Scheme + "://" + parsed.Host
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	return origin + path, nil
}

func validEndpointHost(host string) bool {
	if host == "" || host != strings.TrimSpace(host) {
		return false
	}
	for _, char := range host {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') || char == '.' || char == '_' || char == '-' || char == ':' {
			continue
		}
		return false
	}
	return true
}

func validateQueryParameters(parameters map[string]any) error {
	if len(parameters) == 0 {
		return errors.New("parameters must not be empty")
	}
	if len(parameters) > 16 {
		return errors.New("parameters contains too many filters")
	}

	for key, value := range parameters {
		key = strings.TrimSpace(key)
		switch {
		case key == "ids":
			if err := validateIDs(value); err != nil {
				return err
			}
		case isAllowedBooleanFilter(key):
			if _, ok := value.(bool); !ok {
				return fmt.Errorf("parameter %q must be boolean", key)
			}
		case isAllowedStringFilter(key):
			if err := validateFilterString(key, value); err != nil {
				return err
			}
		default:
			return fmt.Errorf("parameter %q is not allowed", key)
		}
	}

	if _, hasContext := parameters["context"]; hasContext {
		if _, hasIP := parameters["ip"]; !hasIP {
			return errors.New("parameter \"context\" requires parameter \"ip\"")
		}
	}
	return nil
}

func validateFilterString(key string, value any) error {
	text, ok := value.(string)
	if !ok {
		return fmt.Errorf("parameter %q must be a string", key)
	}
	text = strings.TrimSpace(text)
	if text == "" || len(text) > maxFilterStringBytes || !utf8.ValidString(text) || hasControl(text) {
		return fmt.Errorf("parameter %q contains an invalid string", key)
	}
	return nil
}

func validateIDs(value any) error {
	values, ok := value.([]any)
	if !ok || len(values) == 0 || len(values) > maxIDsPerQuery {
		return fmt.Errorf("parameter \"ids\" must be an array of 1 to %d positive integers", maxIDsPerQuery)
	}
	seen := make(map[int64]struct{}, len(values))
	for _, value := range values {
		id, ok := positiveInteger(value)
		if !ok {
			return errors.New("parameter \"ids\" must contain only positive integers")
		}
		if _, exists := seen[id]; exists {
			return errors.New("parameter \"ids\" must not contain duplicates")
		}
		seen[id] = struct{}{}
	}
	return nil
}

func positiveInteger(value any) (int64, bool) {
	switch typed := value.(type) {
	case json.Number:
		parsed, err := typed.Int64()
		return parsed, err == nil && parsed > 0
	case int:
		return int64(typed), typed > 0
	case int64:
		return typed, typed > 0
	case float64:
		parsed := int64(typed)
		return parsed, typed == float64(parsed) && parsed > 0
	default:
		return 0, false
	}
}

func wireQueryParameters(parameters map[string]any) map[string]any {
	result := normalizedQueryParameters(parameters)
	if ids, ok := result["ids"].([]int64); ok {
		parts := make([]string, len(ids))
		for i, id := range ids {
			parts[i] = strconv.FormatInt(id, 10)
		}
		result["ids"] = strings.Join(parts, ",")
	}
	return result
}

func normalizedQueryParameters(parameters map[string]any) map[string]any {
	result := make(map[string]any, len(parameters))
	for key, value := range parameters {
		switch typed := value.(type) {
		case string:
			result[key] = strings.TrimSpace(typed)
		case []any:
			ids := make([]int64, 0, len(typed))
			for _, raw := range typed {
				if id, ok := positiveInteger(raw); ok {
					ids = append(ids, id)
				}
			}
			sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
			result[key] = ids
		default:
			result[key] = value
		}
	}
	return result
}

func validIdentifier(value string, max int) bool {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > max || !utf8.ValidString(value) {
		return false
	}
	for _, char := range value {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') || char == '.' || char == '_' || char == '-' {
			continue
		}
		return false
	}
	return true
}

func hasControl(value string) bool {
	for _, char := range value {
		if char < 0x20 || char == 0x7f {
			return true
		}
	}
	return false
}

func isAllowedStringFilter(key string) bool {
	switch key {
	case "software", "vendor", "type", "model", "family", "group", "hierarchy",
		"host", "ip", "realm", "vtpdomain", "context":
		return true
	default:
		return false
	}
}

func isAllowedBooleanFilter(key string) bool {
	return key == "disabled" || key == "pollexcluded"
}
