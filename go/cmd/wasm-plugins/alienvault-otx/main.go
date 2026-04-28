package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/sdk"
)

const (
	defaultBaseURL       = "https://otx.alienvault.com"
	defaultLimit         = 10
	defaultPage          = 1
	defaultTimeoutMS     = 20000
	defaultMaxIndicators = 2000
	maxLimit             = 100
	maxIndicators        = 5000
	sourceAlienVaultOTX  = "alienvault_otx"
)

type Config struct {
	BaseURL         string `json:"base_url"`
	APIKeySecretRef string `json:"api_key_secret_ref"`
	APIKey          string `json:"api_key"`
	ModifiedSince   string `json:"modified_since"`
	Limit           int    `json:"limit"`
	Page            int    `json:"page"`
	TimeoutMS       int    `json:"timeout_ms"`
	MaxIndicators   int    `json:"max_indicators"`
}

type subscribedPulsesResponse struct {
	Count            int        `json:"count"`
	Next             *string    `json:"next"`
	Previous         *string    `json:"previous"`
	PrefetchPulseIDs bool       `json:"prefetch_pulse_ids"`
	T                float64    `json:"t"`
	T2               float64    `json:"t2"`
	T3               float64    `json:"t3"`
	Results          []otxPulse `json:"results"`
}

type otxPulse struct {
	ID                string         `json:"id"`
	Name              string         `json:"name"`
	Description       string         `json:"description"`
	AuthorName        string         `json:"author_name"`
	Adversary         string         `json:"adversary"`
	TLP               string         `json:"tlp"`
	Public            int            `json:"public"`
	Revision          int            `json:"revision"`
	Tags              []string       `json:"tags"`
	References        []string       `json:"references"`
	AttackIDs         []string       `json:"attack_ids"`
	Industries        []string       `json:"industries"`
	MalwareFamilies   []string       `json:"malware_families"`
	TargetedCountries []string       `json:"targeted_countries"`
	ExtractSource     []string       `json:"extract_source"`
	Created           string         `json:"created"`
	Modified          string         `json:"modified"`
	MoreIndicators    bool           `json:"more_indicators"`
	Indicators        []otxIndicator `json:"indicators"`
}

type otxIndicator struct {
	ID          int64   `json:"id"`
	Indicator   string  `json:"indicator"`
	Type        string  `json:"type"`
	Content     string  `json:"content"`
	Title       string  `json:"title"`
	Description string  `json:"description"`
	Created     string  `json:"created"`
	Expiration  *string `json:"expiration"`
	IsActive    int     `json:"is_active"`
	Role        *string `json:"role"`
}

type ctiPageEnvelope struct {
	ThreatIntel ctiPage `json:"threat_intel"`
}

type ctiPage struct {
	SchemaVersion int               `json:"schema_version"`
	Provider      string            `json:"provider"`
	Source        string            `json:"source"`
	CollectionID  string            `json:"collection_id"`
	Cursor        map[string]string `json:"cursor,omitempty"`
	Counts        ctiCounts         `json:"counts"`
	Indicators    []ctiIndicator    `json:"indicators"`
}

type ctiCounts struct {
	Objects       int            `json:"objects"`
	Indicators    int            `json:"indicators"`
	Skipped       int            `json:"skipped"`
	SkippedByType map[string]int `json:"skipped_by_type,omitempty"`
	Total         int            `json:"total,omitempty"`
}

type ctiIndicator struct {
	Indicator     string `json:"indicator"`
	Type          string `json:"type"`
	Source        string `json:"source"`
	Label         string `json:"label,omitempty"`
	Confidence    int    `json:"confidence,omitempty"`
	FirstSeenAt   string `json:"first_seen_at,omitempty"`
	LastSeenAt    string `json:"last_seen_at,omitempty"`
	ExpiresAt     string `json:"expires_at,omitempty"`
	SourceObject  string `json:"source_object_id,omitempty"`
	SourceContext string `json:"source_context,omitempty"`
}

type otxHTTPResponsePayload struct {
	Status       int    `json:"status"`
	BodyBase64   string `json:"body_base64"`
	BodyEncoding string `json:"body_encoding,omitempty"`
}

//export run_check
func run_check() {
	primeTinyGoJSON()

	status, summary, details := runOTXCheck()
	if err := submitPluginResult(status, summary, details); err != nil {
		sdk.Log.Error("failed to submit OTX plugin result")
	}
}

func runOTXCheck() (string, string, string) {
	cfg := defaultConfig()
	if err := sdk.LoadConfig(&cfg); err != nil {
		return string(sdk.StatusUnknown), "OTX configuration could not be loaded", ""
	}

	cfg.applyDefaults()
	if strings.TrimSpace(cfg.APIKey) == "" {
		return string(sdk.StatusUnknown), "OTX API key is not configured", ""
	}

	apiURL, err := subscribedPulsesURL(cfg)
	if err != nil {
		return string(sdk.StatusUnknown), "OTX base URL is invalid", ""
	}

	resp, err := doOTXHostHTTPRequest(apiURL, cfg.APIKey, cfg.TimeoutMS)
	if err != nil {
		return string(sdk.StatusCritical), "OTX request failed: " + sanitizeError(err), ""
	}

	if resp.Status < 200 || resp.Status >= 300 {
		return string(sdk.StatusCritical), httpFailureSummary(resp), ""
	}

	page, err := parseOTXPage(resp.Body, cfg)
	if err != nil {
		return string(sdk.StatusCritical), "OTX response could not be decoded", ""
	}
	details := ctiPageDetailsJSON(page)

	summary := fmt.Sprintf(
		"OTX pulses: %d objects, %d indicators, %d skipped",
		page.Counts.Objects,
		page.Counts.Indicators,
		page.Counts.Skipped,
	)

	return string(sdk.StatusOK), summary, details
}

func otxHTTPRequestPayload(apiURL, apiKey string, timeoutMS int) string {
	var b strings.Builder

	b.Grow(len(apiURL) + len(apiKey) + 160)
	b.WriteString(`{"method":"GET","url":`)
	writeJSONString(&b, apiURL)
	b.WriteString(`,"headers":{"accept":"application/json","X-OTX-API-KEY":`)
	writeJSONString(&b, apiKey)
	b.WriteByte('}')
	if timeoutMS > 0 {
		b.WriteString(`,"timeout_ms":`)
		b.WriteString(strconv.Itoa(timeoutMS))
	}
	b.WriteByte('}')

	return b.String()
}

func decodeOTXHTTPResponse(payload []byte) (*sdk.HTTPResponse, error) {
	var status int
	var bodyBase64 string

	scanner := otxJSONScanner{data: payload}
	if err := scanner.consumeObject(func(key string) error {
		switch key {
		case "status":
			value, err := scanner.readInt()
			if err != nil {
				return err
			}
			status = value
		case "body_base64":
			value, err := scanner.readStringOrNull()
			if err != nil {
				return err
			}
			bodyBase64 = value
		default:
			if err := scanner.skipValue(); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		return nil, err
	}

	body, err := base64.StdEncoding.DecodeString(bodyBase64)
	if err != nil {
		if bodyBase64 == "" {
			body = nil
		} else {
			return nil, err
		}
	}

	return &sdk.HTTPResponse{
		Status: status,
		Body:   body,
	}, nil
}

func sanitizeError(err error) string {
	if err == nil {
		return "unknown"
	}

	message := strings.TrimSpace(err.Error())
	if message == "" {
		return "unknown"
	}
	if len(message) > 180 {
		message = message[:180]
	}

	return message
}

func httpFailureSummary(resp *sdk.HTTPResponse) string {
	if resp == nil {
		return "OTX request failed: empty response"
	}

	body := strings.TrimSpace(string(resp.Body))
	if body == "" {
		return fmt.Sprintf("OTX request returned HTTP %d", resp.Status)
	}
	if len(body) > 180 {
		body = body[:180]
	}

	return fmt.Sprintf("OTX request returned HTTP %d: %s", resp.Status, body)
}

func defaultConfig() Config {
	return Config{
		BaseURL:       defaultBaseURL,
		Limit:         defaultLimit,
		Page:          defaultPage,
		TimeoutMS:     defaultTimeoutMS,
		MaxIndicators: defaultMaxIndicators,
	}
}

func (c *Config) applyDefaults() {
	if strings.TrimSpace(c.BaseURL) == "" {
		c.BaseURL = defaultBaseURL
	}
	if c.Limit <= 0 {
		c.Limit = defaultLimit
	}
	if c.Limit > maxLimit {
		c.Limit = maxLimit
	}
	if c.Page <= 0 {
		c.Page = defaultPage
	}
	if c.TimeoutMS <= 0 {
		c.TimeoutMS = defaultTimeoutMS
	}
	if c.MaxIndicators <= 0 {
		c.MaxIndicators = defaultMaxIndicators
	}
	if c.MaxIndicators > maxIndicators {
		c.MaxIndicators = maxIndicators
	}
}

func subscribedPulsesURL(cfg Config) (string, error) {
	base, err := url.Parse(strings.TrimRight(cfg.BaseURL, "/"))
	if err != nil {
		return "", err
	}

	base.Path = strings.TrimRight(base.Path, "/") + "/api/v1/pulses/subscribed"
	query := base.Query()
	query.Set("limit", fmt.Sprintf("%d", cfg.Limit))
	query.Set("page", fmt.Sprintf("%d", cfg.Page))
	if strings.TrimSpace(cfg.ModifiedSince) != "" {
		query.Set("modified_since", strings.TrimSpace(cfg.ModifiedSince))
	}
	base.RawQuery = query.Encode()

	return base.String(), nil
}

func buildCTIPage(resp subscribedPulsesResponse, cfg Config) ctiPage {
	page := ctiPage{
		SchemaVersion: 1,
		Provider:      sourceAlienVaultOTX,
		Source:        sourceAlienVaultOTX,
		CollectionID:  "otx:pulses:subscribed",
		Cursor: map[string]string{
			"next":           stringPtrValue(resp.Next),
			"modified_since": cfg.ModifiedSince,
		},
		Counts: ctiCounts{
			Objects:       len(resp.Results),
			SkippedByType: make(map[string]int),
			Total:         resp.Count,
		},
		Indicators: make([]ctiIndicator, 0),
	}

	for _, pulse := range resp.Results {
		for _, indicator := range pulse.Indicators {
			if len(page.Indicators) >= cfg.MaxIndicators {
				page.Counts.addSkipped("max_indicators")
				continue
			}

			normalized, ok := normalizeIndicator(pulse, indicator)
			if !ok {
				page.Counts.addSkipped(skipType(indicator))
				continue
			}

			page.Indicators = append(page.Indicators, normalized)
		}
	}

	page.Counts.Indicators = len(page.Indicators)
	return page
}

func parseOTXPage(data []byte, cfg Config) (ctiPage, error) {
	page := ctiPage{
		SchemaVersion: 1,
		Provider:      sourceAlienVaultOTX,
		Source:        sourceAlienVaultOTX,
		CollectionID:  "otx:pulses:subscribed",
		Cursor: map[string]string{
			"modified_since": cfg.ModifiedSince,
		},
		Counts: ctiCounts{
			SkippedByType: make(map[string]int),
		},
		Indicators: make([]ctiIndicator, 0),
	}

	scanner := otxJSONScanner{data: data}
	if err := scanner.consumeObject(func(key string) error {
		switch key {
		case "count":
			value, err := scanner.readInt()
			if err != nil {
				return err
			}
			page.Counts.Total = value
		case "next":
			value, err := scanner.readStringOrNull()
			if err != nil {
				return err
			}
			page.Cursor["next"] = value
		case "results":
			if err := parsePulseArray(&scanner, &page, cfg); err != nil {
				return err
			}
		default:
			if err := scanner.skipValue(); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		return ctiPage{}, err
	}

	page.Counts.Indicators = len(page.Indicators)
	return page, nil
}

func parsePulseArray(scanner *otxJSONScanner, page *ctiPage, cfg Config) error {
	if err := scanner.expectByte('['); err != nil {
		return err
	}
	if scanner.consumeByte(']') {
		return nil
	}

	for {
		pulse, err := parsePulse(scanner)
		if err != nil {
			return err
		}
		page.Counts.Objects++

		for _, indicator := range pulse.Indicators {
			if len(page.Indicators) >= cfg.MaxIndicators {
				page.Counts.addSkipped("max_indicators")
				continue
			}

			normalized, ok := normalizeIndicator(pulse, indicator)
			if !ok {
				page.Counts.addSkipped(skipType(indicator))
				continue
			}

			page.Indicators = append(page.Indicators, normalized)
		}

		if scanner.consumeByte(']') {
			return nil
		}
		if err := scanner.expectByte(','); err != nil {
			return err
		}
	}
}

func parsePulse(scanner *otxJSONScanner) (otxPulse, error) {
	var pulse otxPulse

	err := scanner.consumeObject(func(key string) error {
		switch key {
		case "id":
			return scanner.readStringField(&pulse.ID)
		case "name":
			return scanner.readStringField(&pulse.Name)
		case "author_name":
			return scanner.readStringField(&pulse.AuthorName)
		case "created":
			return scanner.readStringField(&pulse.Created)
		case "modified":
			return scanner.readStringField(&pulse.Modified)
		case "indicators":
			indicators, err := parseIndicatorArray(scanner)
			if err != nil {
				return err
			}
			pulse.Indicators = indicators
		default:
			return scanner.skipValue()
		}
		return nil
	})

	return pulse, err
}

func parseIndicatorArray(scanner *otxJSONScanner) ([]otxIndicator, error) {
	if err := scanner.expectByte('['); err != nil {
		return nil, err
	}
	if scanner.consumeByte(']') {
		return nil, nil
	}

	indicators := make([]otxIndicator, 0)
	for {
		indicator, err := parseIndicator(scanner)
		if err != nil {
			return nil, err
		}
		indicators = append(indicators, indicator)

		if scanner.consumeByte(']') {
			return indicators, nil
		}
		if err := scanner.expectByte(','); err != nil {
			return nil, err
		}
	}
}

func parseIndicator(scanner *otxJSONScanner) (otxIndicator, error) {
	var indicator otxIndicator

	err := scanner.consumeObject(func(key string) error {
		switch key {
		case "indicator":
			return scanner.readStringField(&indicator.Indicator)
		case "type":
			return scanner.readStringField(&indicator.Type)
		case "title":
			return scanner.readStringField(&indicator.Title)
		case "created":
			return scanner.readStringField(&indicator.Created)
		case "expiration":
			value, err := scanner.readStringOrNull()
			if err != nil {
				return err
			}
			if value != "" {
				indicator.Expiration = &value
			}
		default:
			return scanner.skipValue()
		}
		return nil
	})

	return indicator, err
}

type otxJSONScanner struct {
	data []byte
	pos  int
}

func (scanner *otxJSONScanner) consumeObject(handle func(string) error) error {
	if err := scanner.expectByte('{'); err != nil {
		return err
	}
	if scanner.consumeByte('}') {
		return nil
	}

	for {
		key, err := scanner.readString()
		if err != nil {
			return err
		}
		if err := scanner.expectByte(':'); err != nil {
			return err
		}
		if err := handle(key); err != nil {
			return err
		}
		if scanner.consumeByte('}') {
			return nil
		}
		if err := scanner.expectByte(','); err != nil {
			return err
		}
	}
}

func (scanner *otxJSONScanner) readStringField(target *string) error {
	value, err := scanner.readStringOrNull()
	if err != nil {
		return err
	}
	*target = value
	return nil
}

func (scanner *otxJSONScanner) readStringOrNull() (string, error) {
	scanner.skipWhitespace()
	if scanner.hasPrefix("null") {
		scanner.pos += len("null")
		return "", nil
	}
	return scanner.readString()
}

func (scanner *otxJSONScanner) readString() (string, error) {
	scanner.skipWhitespace()
	if scanner.pos >= len(scanner.data) || scanner.data[scanner.pos] != '"' {
		return "", fmt.Errorf("expected json string at byte %d", scanner.pos)
	}
	scanner.pos++

	var b strings.Builder
	for scanner.pos < len(scanner.data) {
		ch := scanner.data[scanner.pos]
		scanner.pos++
		switch ch {
		case '"':
			return b.String(), nil
		case '\\':
			if scanner.pos >= len(scanner.data) {
				return "", fmt.Errorf("unterminated json escape at byte %d", scanner.pos)
			}
			esc := scanner.data[scanner.pos]
			scanner.pos++
			switch esc {
			case '"', '\\', '/':
				b.WriteByte(esc)
			case 'b':
				b.WriteByte('\b')
			case 'f':
				b.WriteByte('\f')
			case 'n':
				b.WriteByte('\n')
			case 'r':
				b.WriteByte('\r')
			case 't':
				b.WriteByte('\t')
			case 'u':
				if scanner.pos+4 > len(scanner.data) {
					return "", fmt.Errorf("short unicode escape at byte %d", scanner.pos)
				}
				b.WriteByte('?')
				scanner.pos += 4
			default:
				return "", fmt.Errorf("invalid json escape at byte %d", scanner.pos)
			}
		default:
			b.WriteByte(ch)
		}
	}

	return "", fmt.Errorf("unterminated json string")
}

func (scanner *otxJSONScanner) readInt() (int, error) {
	scanner.skipWhitespace()
	start := scanner.pos
	if scanner.pos < len(scanner.data) && scanner.data[scanner.pos] == '-' {
		scanner.pos++
	}
	for scanner.pos < len(scanner.data) && scanner.data[scanner.pos] >= '0' && scanner.data[scanner.pos] <= '9' {
		scanner.pos++
	}
	if start == scanner.pos {
		return 0, fmt.Errorf("expected json integer at byte %d", start)
	}
	return strconv.Atoi(string(scanner.data[start:scanner.pos]))
}

func (scanner *otxJSONScanner) skipValue() error {
	scanner.skipWhitespace()
	if scanner.pos >= len(scanner.data) {
		return fmt.Errorf("unexpected end of json")
	}

	switch scanner.data[scanner.pos] {
	case '{':
		return scanner.skipObject()
	case '[':
		return scanner.skipArray()
	case '"':
		_, err := scanner.readString()
		return err
	case 't':
		return scanner.consumeLiteral("true")
	case 'f':
		return scanner.consumeLiteral("false")
	case 'n':
		return scanner.consumeLiteral("null")
	default:
		return scanner.skipNumber()
	}
}

func (scanner *otxJSONScanner) skipObject() error {
	return scanner.consumeObject(func(_ string) error {
		return scanner.skipValue()
	})
}

func (scanner *otxJSONScanner) skipArray() error {
	if err := scanner.expectByte('['); err != nil {
		return err
	}
	if scanner.consumeByte(']') {
		return nil
	}
	for {
		if err := scanner.skipValue(); err != nil {
			return err
		}
		if scanner.consumeByte(']') {
			return nil
		}
		if err := scanner.expectByte(','); err != nil {
			return err
		}
	}
}

func (scanner *otxJSONScanner) skipNumber() error {
	scanner.skipWhitespace()
	start := scanner.pos
	if scanner.pos < len(scanner.data) && scanner.data[scanner.pos] == '-' {
		scanner.pos++
	}
	for scanner.pos < len(scanner.data) {
		ch := scanner.data[scanner.pos]
		if (ch >= '0' && ch <= '9') || ch == '.' || ch == 'e' || ch == 'E' || ch == '+' || ch == '-' {
			scanner.pos++
			continue
		}
		break
	}
	if start == scanner.pos {
		return fmt.Errorf("expected json value at byte %d", start)
	}
	return nil
}

func (scanner *otxJSONScanner) consumeLiteral(literal string) error {
	if !scanner.hasPrefix(literal) {
		return fmt.Errorf("expected %s at byte %d", literal, scanner.pos)
	}
	scanner.pos += len(literal)
	return nil
}

func (scanner *otxJSONScanner) expectByte(want byte) error {
	scanner.skipWhitespace()
	if scanner.pos >= len(scanner.data) || scanner.data[scanner.pos] != want {
		return fmt.Errorf("expected %q at byte %d", want, scanner.pos)
	}
	scanner.pos++
	return nil
}

func (scanner *otxJSONScanner) consumeByte(want byte) bool {
	scanner.skipWhitespace()
	if scanner.pos < len(scanner.data) && scanner.data[scanner.pos] == want {
		scanner.pos++
		return true
	}
	return false
}

func (scanner *otxJSONScanner) hasPrefix(prefix string) bool {
	return len(scanner.data)-scanner.pos >= len(prefix) && string(scanner.data[scanner.pos:scanner.pos+len(prefix)]) == prefix
}

func (scanner *otxJSONScanner) skipWhitespace() {
	for scanner.pos < len(scanner.data) {
		switch scanner.data[scanner.pos] {
		case ' ', '\n', '\r', '\t':
			scanner.pos++
		default:
			return
		}
	}
}

func (c *ctiCounts) addSkipped(kind string) {
	c.Skipped++
	kind = strings.ToLower(strings.TrimSpace(kind))
	if kind == "" {
		kind = "unknown"
	}
	if c.SkippedByType == nil {
		c.SkippedByType = make(map[string]int)
	}
	c.SkippedByType[kind]++
}

func normalizeIndicator(pulse otxPulse, indicator otxIndicator) (ctiIndicator, bool) {
	value := strings.TrimSpace(indicator.Indicator)
	if value == "" || !supportedIndicatorType(indicator.Type) {
		return ctiIndicator{}, false
	}

	label := pulse.Name
	if label == "" {
		label = indicator.Title
	}

	return ctiIndicator{
		Indicator:     value,
		Type:          "cidr",
		Source:        sourceAlienVaultOTX,
		Label:         label,
		Confidence:    50,
		FirstSeenAt:   firstNonEmpty(indicator.Created, pulse.Created),
		LastSeenAt:    firstNonEmpty(pulse.Modified, indicator.Created, pulse.Created),
		ExpiresAt:     stringPtrValue(indicator.Expiration),
		SourceObject:  pulse.ID,
		SourceContext: pulse.AuthorName,
	}, true
}

func supportedIndicatorType(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "ipv4", "ipv6", "cidr", "ipv4-cidr", "ipv6-cidr":
		return true
	default:
		return false
	}
}

func skipType(indicator otxIndicator) string {
	if strings.TrimSpace(indicator.Indicator) == "" {
		return "empty"
	}
	if strings.TrimSpace(indicator.Type) == "" {
		return "unknown"
	}
	return indicator.Type
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func stringPtrValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func ctiPageDetailsJSON(page ctiPage) string {
	var b strings.Builder
	b.Grow(512 + len(page.Indicators)*180)
	b.WriteString(`{"threat_intel":{`)
	writeJSONIntField(&b, "schema_version", page.SchemaVersion, false)
	writeJSONStringField(&b, "provider", page.Provider, true)
	writeJSONStringField(&b, "source", page.Source, true)
	writeJSONStringField(&b, "collection_id", page.CollectionID, true)
	writeCursorJSON(&b, page.Cursor)
	writeCountsJSON(&b, page.Counts)
	writeIndicatorsJSON(&b, page.Indicators)
	b.WriteString(`}}`)
	return b.String()
}

func submitPluginResult(status, summary, details string) error {
	return sdk.SubmitResult([]byte(pluginResultJSON(status, summary, details)))
}

func pluginResultJSON(status, summary, details string) string {
	var b strings.Builder
	b.Grow(128 + len(summary) + len(details))
	b.WriteByte('{')
	writeJSONIntField(&b, "schema_version", 1, false)
	writeJSONStringField(&b, "status", status, true)
	writeJSONStringField(&b, "summary", summary, true)
	if details != "" {
		writeJSONStringField(&b, "details", details, true)
	}
	b.WriteByte('}')
	return b.String()
}

func writeCursorJSON(b *strings.Builder, cursor map[string]string) {
	b.WriteString(`,"cursor":{`)
	i := 0
	for _, key := range []string{"next", "modified_since"} {
		value := cursor[key]
		if value == "" {
			continue
		}
		if i > 0 {
			b.WriteByte(',')
		}
		writeJSONString(b, key)
		b.WriteByte(':')
		writeJSONString(b, value)
		i++
	}
	b.WriteByte('}')
}

func writeCountsJSON(b *strings.Builder, counts ctiCounts) {
	b.WriteString(`,"counts":{`)
	writeJSONIntField(b, "objects", counts.Objects, false)
	writeJSONIntField(b, "indicators", counts.Indicators, true)
	writeJSONIntField(b, "skipped", counts.Skipped, true)
	writeJSONIntField(b, "total", counts.Total, true)
	b.WriteString(`,"skipped_by_type":{`)
	i := 0
	for kind, count := range counts.SkippedByType {
		if i > 0 {
			b.WriteByte(',')
		}
		writeJSONString(b, kind)
		b.WriteByte(':')
		b.WriteString(strconv.Itoa(count))
		i++
	}
	b.WriteString(`}}`)
}

func writeIndicatorsJSON(b *strings.Builder, indicators []ctiIndicator) {
	b.WriteString(`,"indicators":[`)
	for i, indicator := range indicators {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteByte('{')
		writeJSONStringField(b, "indicator", indicator.Indicator, false)
		writeJSONStringField(b, "type", indicator.Type, true)
		writeJSONStringField(b, "source", indicator.Source, true)
		writeJSONStringField(b, "label", indicator.Label, true)
		writeJSONIntField(b, "confidence", indicator.Confidence, true)
		writeJSONStringField(b, "first_seen_at", indicator.FirstSeenAt, true)
		writeJSONStringField(b, "last_seen_at", indicator.LastSeenAt, true)
		writeJSONStringField(b, "expires_at", indicator.ExpiresAt, true)
		writeJSONStringField(b, "source_object_id", indicator.SourceObject, true)
		writeJSONStringField(b, "source_context", indicator.SourceContext, true)
		b.WriteByte('}')
	}
	b.WriteByte(']')
}

func writeJSONStringField(b *strings.Builder, key, value string, comma bool) {
	if comma {
		b.WriteByte(',')
	}
	writeJSONString(b, key)
	b.WriteByte(':')
	writeJSONString(b, value)
}

func writeJSONIntField(b *strings.Builder, key string, value int, comma bool) {
	if comma {
		b.WriteByte(',')
	}
	writeJSONString(b, key)
	b.WriteByte(':')
	b.WriteString(strconv.Itoa(value))
}

func writeJSONString(b *strings.Builder, value string) {
	b.WriteByte('"')
	for i := 0; i < len(value); i++ {
		switch value[i] {
		case '\\', '"':
			b.WriteByte('\\')
			b.WriteByte(value[i])
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if value[i] < 0x20 {
				b.WriteString(`\u00`)
				const hex = "0123456789abcdef"
				b.WriteByte(hex[value[i]>>4])
				b.WriteByte(hex[value[i]&0x0f])
			} else {
				b.WriteByte(value[i])
			}
		}
	}
	b.WriteByte('"')
}

func primeTinyGoJSON() {
	var cfg Config
	_ = json.Unmarshal([]byte(`{"base_url":"https://otx.alienvault.com","api_key":"x"}`), &cfg)
	var resp subscribedPulsesResponse
	_ = json.Unmarshal([]byte(`{"results":[{"id":"p","indicators":[{"indicator":"192.0.2.1","type":"IPv4"}]}]}`), &resp)
}

func main() {}
