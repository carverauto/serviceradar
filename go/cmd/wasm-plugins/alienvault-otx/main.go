package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

const (
	defaultBaseURL       = "https://otx.alienvault.com"
	defaultLimit         = 100
	defaultPage          = 1
	defaultTimeoutMS     = 120000
	defaultMaxIndicators = 50000
	defaultMaxPages      = 500
	defaultMaxRetries    = 3
	defaultBackoffMS     = 1000
	maxLimit             = 100
	maxIndicators        = 500000
	maxPages             = 10000
	maxRetries           = 5
	maxBackoffMS         = 30000
	sourceAlienVaultOTX  = "alienvault_otx"
)

var (
	errJSONField = errors.New("json field not found")
	errJSONParse = errors.New("json parse failed")
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
	MaxPages        int    `json:"max_pages"`
	MaxRetries      int    `json:"max_retries"`
	BackoffMS       int    `json:"backoff_ms"`
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
	SchemaVersion int            `json:"schema_version"`
	Provider      string         `json:"provider"`
	Source        string         `json:"source"`
	CollectionID  string         `json:"collection_id"`
	Cursor        ctiCursor      `json:"cursor,omitempty"`
	Counts        ctiCounts      `json:"counts"`
	Indicators    []ctiIndicator `json:"indicators"`
}

type ctiCursor struct {
	Next          string `json:"next,omitempty"`
	ModifiedSince string `json:"modified_since,omitempty"`
	StartPage     string `json:"start_page,omitempty"`
	Limit         string `json:"limit,omitempty"`
	MaxPages      string `json:"max_pages,omitempty"`
	PagesFetched  string `json:"pages_fetched,omitempty"`
	LastPage      string `json:"last_page,omitempty"`
	NextPage      string `json:"next_page,omitempty"`
	Complete      string `json:"complete,omitempty"`
}

type ctiCounts struct {
	Objects       int              `json:"objects"`
	Indicators    int              `json:"indicators"`
	Skipped       int              `json:"skipped"`
	SkippedByType ctiSkippedCounts `json:"skipped_by_type,omitempty"`
	Total         int              `json:"total,omitempty"`
}

type ctiSkippedCounts struct {
	Domain        int
	URL           int
	Hostname      int
	MaxIndicators int
	PageBudget    int
	Empty         int
	Unknown       int
	Other         int
}

type jsonBuilder struct {
	buf []byte
}

func (b *jsonBuilder) WriteString(value string) {
	b.buf = append(b.buf, value...)
}

func (b *jsonBuilder) WriteByte(value byte) {
	b.buf = append(b.buf, value)
}

func (b *jsonBuilder) String() string {
	return string(b.buf)
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

//export run_check
func run_check() {
	primeTinyGoJSON()

	if err := runOTXCheckAndSubmit(); err != nil {
		sdk.Log.Error("failed to submit OTX plugin result")
	}
}

func runOTXCheckAndSubmit() error {
	cfg := defaultConfig()
	if err := sdk.LoadConfig(&cfg); err != nil {
		return submitPluginResult(string(sdk.StatusUnknown), "OTX configuration could not be loaded", "")
	}

	cfg.applyDefaults()
	if strings.TrimSpace(cfg.APIKey) == "" {
		return submitPluginResult(string(sdk.StatusUnknown), "OTX API key is not configured", "")
	}

	pages, err := fetchAndSubmitOTXExportPages(cfg, func(page ctiPage) error {
		return submitPluginResult(string(sdk.StatusOK), otxPageSummary(page), ctiPageDetailsJSON(page))
	})
	if err != nil {
		return submitPluginResult(string(sdk.StatusCritical), sanitizeError(err), "")
	}

	if pages == 0 {
		return submitPluginResult(string(sdk.StatusOK), "OTX export: 0 pages, 0 rows, 0 indicators, 0 skipped", "")
	}

	return nil
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

	page, err := fetchOTXExportPages(cfg)
	if err != nil {
		return string(sdk.StatusCritical), sanitizeError(err), ""
	}

	details := ctiPageDetailsJSON(page)

	summary := "OTX export: " + page.Cursor.PagesFetched + " pages, " +
		strconv.Itoa(page.Counts.Objects) + " rows, " +
		strconv.Itoa(page.Counts.Indicators) + " indicators, " +
		strconv.Itoa(page.Counts.Skipped) + " skipped"

	return string(sdk.StatusOK), summary, details
}

type otxPageEmitter func(ctiPage) error

func fetchAndSubmitOTXExportPages(cfg Config, emit otxPageEmitter) (int, error) {
	currentPage := cfg.Page
	pagesFetched := 0
	indicatorsEmitted := 0

	for pagesFetched < cfg.MaxPages && indicatorsEmitted < cfg.MaxIndicators {
		pageCfg := cfg
		pageCfg.Page = currentPage
		pageCfg.MaxIndicators = cfg.MaxIndicators - indicatorsEmitted

		page, err := fetchSingleOTXExportPageWithRetry(pageCfg)
		if err != nil {
			return pagesFetched, err
		}

		pagesFetched++
		indicatorsEmitted += len(page.Indicators)

		next := strings.TrimSpace(page.Cursor.Next)
		nextPage := pageFromURL(next)
		if nextPage <= currentPage {
			nextPage = currentPage + 1
		}

		page.Cursor.StartPage = strconv.Itoa(cfg.Page)
		page.Cursor.Limit = strconv.Itoa(cfg.Limit)
		page.Cursor.MaxPages = strconv.Itoa(cfg.MaxPages)
		page.Cursor.PagesFetched = strconv.Itoa(pagesFetched)
		page.Cursor.LastPage = strconv.Itoa(currentPage)

		switch {
		case next == "":
			page.Cursor.Complete = "true"
		case pagesFetched >= cfg.MaxPages:
			page.Cursor.Complete = "false"
			page.Cursor.Next = next
			page.Cursor.NextPage = strconv.Itoa(nextPage)
			page.Counts.addSkipped("page_budget")
		case indicatorsEmitted >= cfg.MaxIndicators:
			page.Cursor.Complete = "false"
			page.Cursor.Next = next
			page.Cursor.NextPage = strconv.Itoa(nextPage)
		default:
			page.Cursor.Complete = "false"
			page.Cursor.Next = next
			page.Cursor.NextPage = strconv.Itoa(nextPage)
		}

		if err := emit(page); err != nil {
			return pagesFetched, err
		}

		if next == "" || pagesFetched >= cfg.MaxPages || indicatorsEmitted >= cfg.MaxIndicators {
			break
		}

		currentPage = nextPage
	}

	return pagesFetched, nil
}

func otxPageSummary(page ctiPage) string {
	pages := page.Cursor.PagesFetched
	if pages == "" {
		pages = "1"
	}

	return "OTX export: " + pages + " pages, " +
		strconv.Itoa(page.Counts.Objects) + " rows, " +
		strconv.Itoa(page.Counts.Indicators) + " indicators, " +
		strconv.Itoa(page.Counts.Skipped) + " skipped"
}

func fetchOTXExportPages(cfg Config) (ctiPage, error) {
	aggregate := newCTIPage(cfg)
	currentPage := cfg.Page
	pagesFetched := 0

	for pagesFetched < cfg.MaxPages && len(aggregate.Indicators) < cfg.MaxIndicators {
		pageCfg := cfg
		pageCfg.Page = currentPage
		pageCfg.MaxIndicators = cfg.MaxIndicators - len(aggregate.Indicators)

		page, err := fetchSingleOTXExportPageWithRetry(pageCfg)
		if err != nil {
			return ctiPage{}, err
		}

		pagesFetched++
		mergeCTIPage(&aggregate, page)
		aggregate.Cursor.PagesFetched = strconv.Itoa(pagesFetched)
		aggregate.Cursor.LastPage = strconv.Itoa(currentPage)

		next := strings.TrimSpace(page.Cursor.Next)
		aggregate.Cursor.Next = next
		if next == "" {
			aggregate.Cursor.Complete = "true"
			break
		}

		nextPage := pageFromURL(next)
		if nextPage <= currentPage {
			nextPage = currentPage + 1
		}
		currentPage = nextPage
		aggregate.Cursor.NextPage = strconv.Itoa(currentPage)
	}

	if pagesFetched == cfg.MaxPages && aggregate.Cursor.Next != "" {
		aggregate.Cursor.Complete = "false"
		aggregate.Counts.addSkipped("page_budget")
	}
	if len(aggregate.Indicators) >= cfg.MaxIndicators && aggregate.Cursor.Next != "" {
		aggregate.Cursor.Complete = "false"
	}
	if aggregate.Cursor.PagesFetched == "" {
		aggregate.Cursor.PagesFetched = "0"
	}

	aggregate.Counts.Indicators = len(aggregate.Indicators)
	return aggregate, nil
}

func fetchSingleOTXExportPage(cfg Config) (ctiPage, error) {
	apiURL, err := subscribedPulsesURL(cfg)
	if err != nil {
		return ctiPage{}, errors.New("OTX base URL is invalid")
	}

	resp, err := doOTXHostHTTPRequest(apiURL, cfg.APIKey, cfg.TimeoutMS)
	if err != nil {
		return ctiPage{}, errors.New("OTX request failed: " + sanitizeError(err))
	}

	if resp.Status < 200 || resp.Status >= 300 {
		return ctiPage{}, errors.New(httpFailureSummary(resp))
	}

	page, err := parseOTXExportPage(resp.Body, cfg)
	if err != nil {
		return ctiPage{}, errors.New("OTX response could not be decoded")
	}

	return page, nil
}

func fetchSingleOTXExportPageWithRetry(cfg Config) (ctiPage, error) {
	attempts := cfg.MaxRetries + 1
	if attempts < 1 {
		attempts = 1
	}

	var lastErr error
	for attempt := 1; attempt <= attempts; attempt++ {
		page, err := fetchSingleOTXExportPage(cfg)
		if err == nil {
			return page, nil
		}

		lastErr = err
		if attempt == attempts || !retryableOTXError(err) {
			break
		}

		sleepMS := cfg.BackoffMS * attempt
		if sleepMS <= 0 {
			sleepMS = defaultBackoffMS
		}
		if sleepMS > maxBackoffMS {
			sleepMS = maxBackoffMS
		}
		time.Sleep(time.Duration(sleepMS) * time.Millisecond)
	}

	return ctiPage{}, lastErr
}

func retryableOTXError(err error) bool {
	if err == nil {
		return false
	}

	message := err.Error()
	return strings.Contains(message, "host error -6") ||
		strings.Contains(message, "host error -5") ||
		strings.Contains(message, "HTTP 500") ||
		strings.Contains(message, "HTTP 502") ||
		strings.Contains(message, "HTTP 503") ||
		strings.Contains(message, "HTTP 504")
}

func extractJSONStringOrNull(payload []byte, field string) (string, error) {
	pos, err := fieldValueOffset(payload, field)
	if err != nil {
		return "", err
	}

	scanner := otxJSONScanner{data: payload, pos: pos}
	return scanner.readStringOrNull()
}

func extractJSONIntField(payload []byte, field string) (int, error) {
	pos, err := fieldValueOffset(payload, field)
	if err != nil {
		return 0, err
	}

	scanner := otxJSONScanner{data: payload, pos: pos}
	return scanner.readInt()
}

func fieldValueOffset(payload []byte, field string) (int, error) {
	pattern := []byte(`"` + field + `"`)
	pos := indexBytes(payload, pattern)
	if pos < 0 {
		return 0, errJSONField
	}

	pos += len(pattern)
	for pos < len(payload) {
		switch payload[pos] {
		case ' ', '\n', '\r', '\t':
			pos++
		case ':':
			return pos + 1, nil
		default:
			return 0, errJSONField
		}
	}

	return 0, errJSONField
}

func indexBytes(haystack, needle []byte) int {
	if len(needle) == 0 {
		return 0
	}
	if len(needle) > len(haystack) {
		return -1
	}
	last := len(haystack) - len(needle)
	for i := 0; i <= last; i++ {
		matched := true
		for j := range needle {
			if haystack[i+j] != needle[j] {
				matched = false
				break
			}
		}
		if matched {
			return i
		}
	}
	return -1
}

func previewBytes(value []byte, limit int) string {
	if limit <= 0 || len(value) <= limit {
		return string(value)
	}
	return string(value[:limit])
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
		MaxPages:      defaultMaxPages,
		MaxRetries:    defaultMaxRetries,
		BackoffMS:     defaultBackoffMS,
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
	if c.MaxPages <= 0 {
		c.MaxPages = defaultMaxPages
	}
	if c.MaxPages > maxPages {
		c.MaxPages = maxPages
	}
	if c.MaxRetries < 0 {
		c.MaxRetries = defaultMaxRetries
	}
	if c.MaxRetries > maxRetries {
		c.MaxRetries = maxRetries
	}
	if c.BackoffMS <= 0 {
		c.BackoffMS = defaultBackoffMS
	}
	if c.BackoffMS > maxBackoffMS {
		c.BackoffMS = maxBackoffMS
	}
}

func subscribedPulsesURL(cfg Config) (string, error) {
	base := strings.TrimRight(strings.TrimSpace(cfg.BaseURL), "/")
	if base == "" || !(strings.HasPrefix(base, "http://") || strings.HasPrefix(base, "https://")) {
		return "", errJSONParse
	}
	b := jsonBuilder{buf: make([]byte, 0, 512)}
	b.WriteString(base)
	b.WriteString("/api/v1/indicators/export?limit=")
	b.WriteString(strconv.Itoa(cfg.Limit))
	b.WriteString("&page=")
	b.WriteString(strconv.Itoa(cfg.Page))
	if strings.TrimSpace(cfg.ModifiedSince) != "" {
		b.WriteString("&modified_since=")
		writeQueryEscaped(&b, strings.TrimSpace(cfg.ModifiedSince))
	}

	return b.String(), nil
}

func pageFromURL(rawURL string) int {
	key := "page="
	idx := strings.Index(rawURL, key)
	if idx < 0 {
		return 0
	}
	start := idx + len(key)
	end := start
	for end < len(rawURL) && rawURL[end] >= '0' && rawURL[end] <= '9' {
		end++
	}
	page, err := strconv.Atoi(rawURL[start:end])
	if err != nil || page < 1 {
		return 0
	}

	return page
}

func writeQueryEscaped(b *jsonBuilder, value string) {
	const hex = "0123456789ABCDEF"
	for i := 0; i < len(value); i++ {
		ch := value[i]
		if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
			ch == '-' || ch == '_' || ch == '.' || ch == '~' {
			b.WriteByte(ch)
			continue
		}
		b.WriteByte('%')
		b.WriteByte(hex[ch>>4])
		b.WriteByte(hex[ch&0x0f])
	}
}

func buildCTIPage(resp subscribedPulsesResponse, cfg Config) ctiPage {
	page := ctiPage{
		SchemaVersion: 1,
		Provider:      sourceAlienVaultOTX,
		Source:        sourceAlienVaultOTX,
		CollectionID:  "otx:pulses:subscribed",
		Counts: ctiCounts{
			Objects: len(resp.Results),
			Total:   resp.Count,
		},
		Indicators: make([]ctiIndicator, 0),
	}
	page.Cursor.Next = stringPtrValue(resp.Next)
	page.Cursor.ModifiedSince = cfg.ModifiedSince

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
	page := newCTIPage(cfg)
	page.CollectionID = "otx:pulses:subscribed"

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
			page.Cursor.Next = value
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

func parseOTXExportPage(data []byte, cfg Config) (ctiPage, error) {
	page := newCTIPage(cfg)
	page.CollectionID = "otx:indicators:export"
	if total, err := extractJSONIntField(data, "count"); err == nil {
		page.Counts.Total = total
	}
	if next, err := extractJSONStringOrNull(data, "next"); err == nil {
		page.Cursor.Next = next
	}

	resultsOffset, err := fieldValueOffset(data, "results")
	if err != nil {
		return ctiPage{}, err
	}

	scanner := otxJSONScanner{data: data, pos: resultsOffset}
	if err := scanner.expectByte('['); err != nil {
		return ctiPage{}, err
	}
	if scanner.consumeByte(']') {
		return page, nil
	}

	pulse := otxPulse{
		ID:         "otx:indicators:export",
		Name:       "AlienVault OTX indicator export",
		AuthorName: sourceAlienVaultOTX,
	}

	for {
		objectStart, objectEnd, err := scanner.nextObjectBytes()
		if err != nil {
			return ctiPage{}, err
		}
		indicator := parseFlatExportIndicator(data[objectStart:objectEnd])

		page.Counts.Objects++
		if len(page.Indicators) >= cfg.MaxIndicators {
			page.Counts.addSkipped("max_indicators")
		} else if normalized, ok := normalizeIndicator(pulse, indicator); ok {
			page.Indicators = append(page.Indicators, normalized)
		} else {
			page.Counts.addSkipped(skipType(indicator))
		}

		if scanner.consumeByte(']') {
			break
		}
		if err := scanner.expectByte(','); err != nil {
			return ctiPage{}, err
		}
	}

	page.Counts.Indicators = len(page.Indicators)
	return page, nil
}

func parseFlatExportIndicator(data []byte) otxIndicator {
	indicator := otxIndicator{}
	if id, err := extractJSONIntField(data, "id"); err == nil {
		indicator.ID = int64(id)
	}
	indicator.Indicator, _ = extractJSONStringOrNull(data, "indicator")
	indicator.Type, _ = extractJSONStringOrNull(data, "type")
	indicator.Content, _ = extractJSONStringOrNull(data, "content")
	indicator.Title, _ = extractJSONStringOrNull(data, "title")
	indicator.Description, _ = extractJSONStringOrNull(data, "description")
	indicator.Created, _ = extractJSONStringOrNull(data, "created")
	if expiration, err := extractJSONStringOrNull(data, "expiration"); err == nil && expiration != "" {
		indicator.Expiration = &expiration
	}
	if isActive, err := extractJSONIntField(data, "is_active"); err == nil {
		indicator.IsActive = isActive
	}
	if role, err := extractJSONStringOrNull(data, "role"); err == nil && role != "" {
		indicator.Role = &role
	}

	return indicator
}

func newCTIPage(cfg Config) ctiPage {
	page := ctiPage{
		SchemaVersion: 1,
		Provider:      sourceAlienVaultOTX,
		Source:        sourceAlienVaultOTX,
		CollectionID:  "otx:indicators:export",
		Counts:        ctiCounts{},
		Indicators:    make([]ctiIndicator, 0),
	}
	page.Cursor.ModifiedSince = cfg.ModifiedSince
	page.Cursor.StartPage = strconv.Itoa(cfg.Page)
	page.Cursor.Limit = strconv.Itoa(cfg.Limit)
	page.Cursor.MaxPages = strconv.Itoa(cfg.MaxPages)
	return page
}

func mergeCTIPage(dst *ctiPage, src ctiPage) {
	dst.Counts.Objects += src.Counts.Objects
	dst.Counts.Skipped += src.Counts.Skipped
	if src.Counts.Total > 0 {
		dst.Counts.Total = src.Counts.Total
	}
	dst.Counts.SkippedByType.merge(src.Counts.SkippedByType)

	dst.Indicators = append(dst.Indicators, src.Indicators...)
	dst.Counts.Indicators = len(dst.Indicators)
}

func parseExportIndicatorArray(scanner *otxJSONScanner, page *ctiPage, cfg Config) error {
	if err := scanner.expectByte('['); err != nil {
		return err
	}
	if scanner.consumeByte(']') {
		return nil
	}

	pulse := otxPulse{
		ID:         "otx:indicators:export",
		Name:       "AlienVault OTX indicator export",
		AuthorName: sourceAlienVaultOTX,
	}

	for {
		indicator, err := parseIndicator(scanner)
		if err != nil {
			return err
		}
		page.Counts.Objects++

		if len(page.Indicators) >= cfg.MaxIndicators {
			page.Counts.addSkipped("max_indicators")
		} else if normalized, ok := normalizeIndicator(pulse, indicator); ok {
			page.Indicators = append(page.Indicators, normalized)
		} else {
			page.Counts.addSkipped(skipType(indicator))
		}

		if scanner.consumeByte(']') {
			return nil
		}
		if err := scanner.expectByte(','); err != nil {
			return err
		}
	}
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
		case "id":
			_, err := scanner.readInt()
			return err
		case "indicator":
			return scanner.readStringField(&indicator.Indicator)
		case "type":
			return scanner.readStringField(&indicator.Type)
		case "title":
			return scanner.readStringField(&indicator.Title)
		case "description", "content":
			_, err := scanner.readStringOrNull()
			return err
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

func (scanner *otxJSONScanner) readRawStringBytes() ([]byte, error) {
	scanner.skipWhitespace()
	if scanner.pos >= len(scanner.data) || scanner.data[scanner.pos] != '"' {
		return nil, errJSONParse
	}
	scanner.pos++

	start := scanner.pos
	for scanner.pos < len(scanner.data) {
		ch := scanner.data[scanner.pos]
		switch ch {
		case '"':
			value := scanner.data[start:scanner.pos]
			scanner.pos++
			return value, nil
		case '\\':
			scanner.pos = start - 1
			value, err := scanner.readString()
			if err != nil {
				return nil, err
			}
			return []byte(value), nil
		default:
			scanner.pos++
		}
	}

	return nil, errJSONParse
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
		return "", errJSONParse
	}
	scanner.pos++

	start := scanner.pos
	var b []byte
	for scanner.pos < len(scanner.data) {
		ch := scanner.data[scanner.pos]
		scanner.pos++
		switch ch {
		case '"':
			if b == nil {
				return string(scanner.data[start : scanner.pos-1]), nil
			}
			return string(b), nil
		case '\\':
			if b == nil {
				b = append([]byte{}, scanner.data[start:scanner.pos-1]...)
			}
			if scanner.pos >= len(scanner.data) {
				return "", errJSONParse
			}
			esc := scanner.data[scanner.pos]
			scanner.pos++
			switch esc {
			case '"', '\\', '/':
				b = append(b, esc)
			case 'b':
				b = append(b, '\b')
			case 'f':
				b = append(b, '\f')
			case 'n':
				b = append(b, '\n')
			case 'r':
				b = append(b, '\r')
			case 't':
				b = append(b, '\t')
			case 'u':
				if scanner.pos+4 > len(scanner.data) {
					return "", errJSONParse
				}
				b = append(b, '?')
				scanner.pos += 4
			default:
				return "", errJSONParse
			}
		default:
			if b != nil {
				b = append(b, ch)
			}
		}
	}

	return "", errJSONParse
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
		return 0, errJSONParse
	}
	return strconv.Atoi(string(scanner.data[start:scanner.pos]))
}

func (scanner *otxJSONScanner) skipValue() error {
	scanner.skipWhitespace()
	if scanner.pos >= len(scanner.data) {
		return errJSONParse
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

func (scanner *otxJSONScanner) nextObjectBytes() (int, int, error) {
	scanner.skipWhitespace()
	if scanner.pos >= len(scanner.data) || scanner.data[scanner.pos] != '{' {
		return 0, 0, errJSONParse
	}

	start := scanner.pos
	depth := 0
	inString := false
	escaped := false

	for scanner.pos < len(scanner.data) {
		ch := scanner.data[scanner.pos]
		scanner.pos++

		if inString {
			if escaped {
				escaped = false
				continue
			}
			switch ch {
			case '\\':
				escaped = true
			case '"':
				inString = false
			}
			continue
		}

		switch ch {
		case '"':
			inString = true
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return start, scanner.pos, nil
			}
		}
	}

	return 0, 0, errJSONParse
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
		return errJSONParse
	}
	return nil
}

func (scanner *otxJSONScanner) consumeLiteral(literal string) error {
	if !scanner.hasPrefix(literal) {
		return errJSONParse
	}
	scanner.pos += len(literal)
	return nil
}

func (scanner *otxJSONScanner) expectByte(want byte) error {
	scanner.skipWhitespace()
	if scanner.pos >= len(scanner.data) || scanner.data[scanner.pos] != want {
		return errJSONParse
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
	kind = lowerASCII(strings.TrimSpace(kind))
	if kind == "" {
		kind = "unknown"
	}
	c.SkippedByType.add(kind, 1)
}

func (counts *ctiSkippedCounts) add(kind string, count int) {
	if count <= 0 {
		return
	}
	switch kind {
	case "domain":
		counts.Domain += count
	case "url":
		counts.URL += count
	case "hostname":
		counts.Hostname += count
	case "max_indicators":
		counts.MaxIndicators += count
	case "page_budget":
		counts.PageBudget += count
	case "empty":
		counts.Empty += count
	case "unknown":
		counts.Unknown += count
	default:
		counts.Other += count
	}
}

func (counts ctiSkippedCounts) get(kind string) int {
	switch kind {
	case "domain":
		return counts.Domain
	case "url":
		return counts.URL
	case "hostname":
		return counts.Hostname
	case "max_indicators":
		return counts.MaxIndicators
	case "page_budget":
		return counts.PageBudget
	case "empty":
		return counts.Empty
	case "unknown":
		return counts.Unknown
	default:
		return counts.Other
	}
}

func (counts *ctiSkippedCounts) UnmarshalJSON(data []byte) error {
	var raw map[string]int
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	*counts = ctiSkippedCounts{}
	for kind, count := range raw {
		counts.add(kind, count)
	}
	return nil
}

func (counts *ctiSkippedCounts) merge(other ctiSkippedCounts) {
	counts.Domain += other.Domain
	counts.URL += other.URL
	counts.Hostname += other.Hostname
	counts.MaxIndicators += other.MaxIndicators
	counts.PageBudget += other.PageBudget
	counts.Empty += other.Empty
	counts.Unknown += other.Unknown
	counts.Other += other.Other
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
	switch lowerASCII(strings.TrimSpace(value)) {
	case "ipv4", "ipv6", "cidr", "ipv4-cidr", "ipv6-cidr":
		return true
	default:
		return false
	}
}

func lowerASCII(value string) string {
	var out []byte
	for i := 0; i < len(value); i++ {
		ch := value[i]
		if ch >= 'A' && ch <= 'Z' {
			if out == nil {
				out = append([]byte{}, value[:i]...)
			}
			ch += 'a' - 'A'
		}
		if out != nil {
			out = append(out, ch)
		}
	}
	if out == nil {
		return value
	}
	return string(out)
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
	b := jsonBuilder{buf: make([]byte, 0, 64*1024)}
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
	b := jsonBuilder{buf: make([]byte, 0, len(details)+len(summary)+128)}
	b.WriteString(`{"schema_version":1`)
	writeJSONStringField(&b, "status", status, true)
	writeJSONStringField(&b, "summary", summary, true)
	if details != "" {
		writeJSONStringField(&b, "details", details, true)
	}
	b.WriteByte('}')
	return b.String()
}

func writeCursorJSON(b *jsonBuilder, cursor ctiCursor) {
	b.WriteString(`,"cursor":{`)
	i := 0
	for _, entry := range []struct {
		key   string
		value string
	}{
		{"next", cursor.Next},
		{"modified_since", cursor.ModifiedSince},
		{"start_page", cursor.StartPage},
		{"limit", cursor.Limit},
		{"max_pages", cursor.MaxPages},
		{"pages_fetched", cursor.PagesFetched},
		{"last_page", cursor.LastPage},
		{"next_page", cursor.NextPage},
		{"complete", cursor.Complete},
	} {
		value := entry.value
		if value == "" {
			continue
		}
		if i > 0 {
			b.WriteByte(',')
		}
		writeJSONString(b, entry.key)
		b.WriteByte(':')
		writeJSONString(b, value)
		i++
	}
	b.WriteByte('}')
}

func writeCountsJSON(b *jsonBuilder, counts ctiCounts) {
	b.WriteString(`,"counts":{`)
	writeJSONIntField(b, "objects", counts.Objects, false)
	writeJSONIntField(b, "indicators", counts.Indicators, true)
	writeJSONIntField(b, "skipped", counts.Skipped, true)
	writeJSONIntField(b, "total", counts.Total, true)
	b.WriteString(`,"skipped_by_type":{`)
	i := 0
	for _, skipped := range []struct {
		kind  string
		count int
	}{
		{"domain", counts.SkippedByType.Domain},
		{"url", counts.SkippedByType.URL},
		{"hostname", counts.SkippedByType.Hostname},
		{"max_indicators", counts.SkippedByType.MaxIndicators},
		{"page_budget", counts.SkippedByType.PageBudget},
		{"empty", counts.SkippedByType.Empty},
		{"unknown", counts.SkippedByType.Unknown},
		{"other", counts.SkippedByType.Other},
	} {
		if skipped.count == 0 {
			continue
		}
		if i > 0 {
			b.WriteByte(',')
		}
		writeJSONString(b, skipped.kind)
		b.WriteByte(':')
		b.WriteString(strconv.Itoa(skipped.count))
		i++
	}
	b.WriteString(`}}`)
}

func writeIndicatorsJSON(b *jsonBuilder, indicators []ctiIndicator) {
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

func writeJSONStringField(b *jsonBuilder, key, value string, comma bool) {
	if comma {
		b.WriteByte(',')
	}
	writeJSONString(b, key)
	b.WriteByte(':')
	writeJSONString(b, value)
}

func writeJSONIntField(b *jsonBuilder, key string, value int, comma bool) {
	if comma {
		b.WriteByte(',')
	}
	writeJSONString(b, key)
	b.WriteByte(':')
	b.WriteString(strconv.Itoa(value))
}

func writeJSONString(b *jsonBuilder, value string) {
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
