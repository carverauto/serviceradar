// netbox is the NetBox device-inventory WASM plugin for ServiceRadar.
//
// A scheduled `inventory_sync` assignment walks one or more NetBox instances'
// /api/dcim/devices/ listings (DRF pagination) and emits one DeviceDiscovery
// envelope per configured source into the existing agent -> gateway -> DIRE
// pipeline. Envelopes carry the generic inventory-snapshot contract
// (snapshot_complete + source_instance + collection_id + reference_hash) so
// core's DeviceSourceObservationIngestor can mark devices absent when a
// complete snapshot omits them; a source that fails during pagination emits
// nothing, and rows that fail to parse mark the snapshot incomplete, so a
// bad pull can never retire devices.
//
// This plugin replaces the native sync-source driver that was dropped in the
// Jan 2026 sync rearchitecture; integrations run as sandboxed wasm plugins
// rather than agent-baked drivers.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
	"github.com/tidwall/gjson"
)

const (
	sourceType = "netbox"

	devicesPath = "/api/dcim/devices/"

	defaultPageSize  = 100
	maxPageSize      = 1000
	defaultTimeoutMS = 30000

	// maxDevices bounds one source's snapshot. Scheduled submit_result
	// payloads are capped at 2 MiB by the agent runtime and a mapped device
	// serializes to ~700 bytes, so ~2900 devices is the hard ceiling; 2000
	// leaves headroom for the envelope, labels, and multi-source results.
	// Larger instances fail loudly on the first page rather than truncating.
	maxDevices = 2000
)

// netboxHTTP is package-level so tests can swap it for a fake.
var netboxHTTP httpClient = &sdk.HTTPClient{MaxResponseBytes: sdk.MaxHTTPResponseBytes}

// errNetboxRequestFailed is the only error allowed to cross the NetBox HTTP
// boundary; response text is never retained in a plugin result.
var errNetboxRequestFailed = errors.New("NetBox request failed")

type httpClient interface {
	Do(sdk.HTTPRequest) (*sdk.HTTPResponse, error)
}

// SourceConfig describes one NetBox instance to sync.
type SourceConfig struct {
	// SourceID scopes device identities and the snapshot source_instance;
	// it must stay stable for the lifetime of the source.
	SourceID   string `json:"source_id"`
	SourceName string `json:"source_name"`
	// BaseURL is the NetBox base URL, e.g. https://netbox.example.com or
	// https://tools.example.com/netbox (BASE_PATH deployments supported).
	BaseURL string `json:"base_url"`
	// APIToken is sent as `Authorization: Token <value>`.
	APIToken           string `json:"api_token"`
	PageSize           int    `json:"page_size"`
	TimeoutMS          int    `json:"timeout_ms"`
	InsecureSkipVerify bool   `json:"insecure_skip_verify"`
	// NetworkBlacklist drops devices whose primary IP falls in these CIDRs
	// (bare IPs are treated as single-host entries).
	NetworkBlacklist []string `json:"network_blacklist"`
}

// Config is what the agent runtime hands to the plugin via get_config. A
// sources list is the primary shape; the flat fields keep single-source
// manual assignments simple.
type Config struct {
	Sources []SourceConfig `json:"sources"`

	SourceID           string   `json:"source_id"`
	SourceName         string   `json:"source_name"`
	BaseURL            string   `json:"base_url"`
	APIToken           string   `json:"api_token"`
	PageSize           int      `json:"page_size"`
	TimeoutMS          int      `json:"timeout_ms"`
	InsecureSkipVerify bool     `json:"insecure_skip_verify"`
	NetworkBlacklist   []string `json:"network_blacklist"`
}

// sourceConfigs returns the sources to sync. A flat source counts as
// configured as soon as any of its identifying fields is set, so a source that
// is only half-configured reaches runInventorySyncSource and is reported by the
// field it is missing rather than as "no source configured".
func (c Config) sourceConfigs() []SourceConfig {
	if len(c.Sources) > 0 {
		return c.Sources
	}

	if c.BaseURL == "" && c.APIToken == "" && c.SourceID == "" && c.SourceName == "" {
		return nil
	}

	return []SourceConfig{{
		SourceID:           c.SourceID,
		SourceName:         c.SourceName,
		BaseURL:            c.BaseURL,
		APIToken:           c.APIToken,
		PageSize:           c.PageSize,
		TimeoutMS:          c.TimeoutMS,
		InsecureSkipVerify: c.InsecureSkipVerify,
		NetworkBlacklist:   c.NetworkBlacklist,
	}}
}

//export inventory_sync
func inventory_sync() {
	primeTinyGoJSON()

	_ = sdk.Execute(func() (*sdk.Result, error) {
		raw, err := loadRawConfigBytes()
		if err != nil {
			return sdk.Unknown("NetBox configuration could not be loaded"), nil
		}

		return inventorySyncFromRawConfig(raw), nil
	})
}

// inventorySyncFromRawConfig is the entrypoint body minus the host config
// read, so the parse-failure branch is reachable from a test without a wasm
// host.
func inventorySyncFromRawConfig(raw []byte) *sdk.Result {
	cfg, err := decodeConfig(raw)
	if err != nil {
		return sdk.Unknown("NetBox configuration could not be parsed")
	}

	return runInventorySync(cfg)
}

func runInventorySync(cfg Config) *sdk.Result {
	sources := cfg.sourceConfigs()
	if len(sources) == 0 {
		return sdk.Unknown(
			"NetBox inventory_sync has no source configured: set base_url and api_token, " +
				"or attach a NetBox credential rule",
		)
	}

	if len(sources) == 1 {
		return runInventorySyncSource(sources[0])
	}

	totalDevices := 0
	criticals := 0
	misconfigured := 0
	result := sdk.Ok("")

	for i := range sources {
		sourceResult := runInventorySyncSource(sources[i])
		switch sourceResult.Status {
		case sdk.StatusCritical:
			criticals++
			continue
		case sdk.StatusOK:
		default:
			// Unknown: misconfigured source (missing url/token). It emits
			// no snapshot and must not read as healthy.
			misconfigured++
			continue
		}

		for _, discovery := range sourceResult.DeviceDiscovery {
			totalDevices += len(discovery.Devices)
			result.AddDeviceDiscovery(discovery)
		}
	}

	healthy := len(sources) - criticals - misconfigured
	summary := fmt.Sprintf(
		"NetBox inventory_sync: %d devices on %d/%d sources",
		totalDevices, healthy, len(sources),
	)

	switch {
	case healthy == 0 && criticals > 0:
		result = sdk.Critical(summary)
	case healthy == 0:
		result = sdk.Unknown(summary)
	default:
		// Partial success stays StatusOK so the healthy sources'
		// DeviceDiscovery is never gated out of ingestion by a non-OK
		// status; the degradation is surfaced via the summary and labels.
		result.SetSummary(summary)
	}

	result.WithLabel("sources", strconv.Itoa(len(sources)))
	result.WithLabel("sources_failed", strconv.Itoa(criticals))
	result.WithLabel("sources_misconfigured", strconv.Itoa(misconfigured))
	result.WithLabel("devices", strconv.Itoa(totalDevices))
	return result
}

func runInventorySyncSource(src SourceConfig) *sdk.Result {
	sourceID := normalizeSourceInstance(src.SourceID, src.BaseURL)
	if strings.TrimSpace(src.BaseURL) == "" {
		return sdk.Unknown("NetBox source " + sourceID + " has no base_url configured")
	}

	origin, basePath, err := splitBaseURL(src.BaseURL)
	if err != nil {
		return sdk.Unknown("NetBox source " + sourceID + " has an invalid base_url: " + err.Error())
	}
	if strings.TrimSpace(src.APIToken) == "" {
		return sdk.Unknown("NetBox source " + sourceID + " has no api_token configured")
	}

	now := time.Now().UTC()
	discovery := sdk.NewDeviceDiscovery(sourceType)
	discovery.ObservedAt = now.Format(time.RFC3339Nano)
	discovery.CollectionID = fmt.Sprintf("netbox-%s-%d", sourceID, now.UnixNano())
	discovery.Metadata = map[string]any{
		"source_instance": sourceID,
		"source_id":       sourceID,
	}
	if src.SourceName != "" {
		discovery.Metadata["source_name"] = src.SourceName
	}

	rows, err := listDevices(src, origin, basePath)
	if err != nil {
		// Never emit a partial snapshot: with no envelope, the previous
		// complete snapshot's observations stay authoritative.
		return sdk.Critical("NetBox inventory_sync failed for " + sourceID + ": " + err.Error())
	}

	blacklist, invalidBlacklist := parseBlacklist(src.NetworkBlacklist)
	for _, entry := range invalidBlacklist {
		sdk.Log.Warn("NetBox source " + sourceID + " ignoring invalid network_blacklist entry: " + entry)
	}

	complete := true
	skippedNoIP := 0

	for _, row := range rows {
		item := gjson.ParseBytes(row)
		id := item.Get("id").Int()
		if id <= 0 {
			complete = false
			continue
		}

		ip := primaryIP(item)
		if ip == "" {
			// Devices without a primary IP are a normal NetBox state,
			// not a snapshot defect; they are consistently omitted.
			skippedNoIP++
			continue
		}

		if ipBlacklisted(ip, blacklist) {
			continue
		}

		discovery.AddDevice(buildDiscoveredDevice(sourceID, item, id, ip))
	}

	// reference_hash is the snapshot content hash the observation ingestor
	// requires for complete snapshots (bare 64-hex sha256).
	discovery.ReferenceHash = snapshotHash(sourceID, discovery.Devices)
	discovery.Metadata["snapshot_complete"] = complete
	discovery.Metadata["device_count"] = len(discovery.Devices)
	discovery.Metadata["devices_without_primary_ip"] = skippedNoIP
	if len(invalidBlacklist) > 0 {
		discovery.Metadata["invalid_blacklist_entries"] = len(invalidBlacklist)
	}

	summary := fmt.Sprintf(
		"NetBox inventory_sync: %d devices from %s",
		len(discovery.Devices), nonEmpty(src.SourceName, sourceID),
	)

	result := sdk.Ok(summary)
	result.WithDeviceDiscovery(*discovery)
	result.WithLabel("source_id", sourceID)
	result.WithLabel("devices", strconv.Itoa(len(discovery.Devices)))
	result.WithLabel("snapshot_complete", strconv.FormatBool(complete))
	return result
}

// splitBaseURL separates the configured base URL into its origin
// (scheme://host[:port]) and optional path prefix (BASE_PATH deployments).
// Pagination links carry the full server path, so follow-up requests join
// origin + link path; only the first request appends basePath itself.
func splitBaseURL(baseURL string) (origin, basePath string, err error) {
	trimmed := strings.TrimSpace(baseURL)
	if trimmed == "" {
		return "", "", errors.New("empty base url")
	}

	parsed, err := url.Parse(trimmed)
	if err != nil {
		return "", "", err
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", "", errors.New("base url must be http or https")
	}
	if parsed.Host == "" {
		return "", "", errors.New("base url has no host")
	}

	return parsed.Scheme + "://" + parsed.Host, strings.TrimRight(parsed.Path, "/"), nil
}

// listDevices walks the DRF-paginated device listing, returning every result
// row. Any transport, status, decode, or consistency failure aborts the walk;
// the caller treats that as "emit nothing".
func listDevices(src SourceConfig, origin, basePath string) ([]json.RawMessage, error) {
	size := src.PageSize
	if size <= 0 {
		size = defaultPageSize
	}
	if size > maxPageSize {
		size = maxPageSize
	}

	// Bound pages proportionally to the device bound so small page sizes
	// cannot starve legitimate inventories, while a hostile server that
	// keeps returning next links still terminates.
	pageBound := maxDevices/size + 2

	var (
		all   []json.RawMessage
		total int64
	)

	next := basePath + devicesPath + "?limit=" + strconv.Itoa(size)
	pagesWalked := 0

	for next != "" {
		if pagesWalked >= pageBound {
			return nil, fmt.Errorf("pagination exceeded %d pages", pageBound)
		}

		body, err := getJSON(src, origin+next)
		if err != nil {
			return nil, err
		}

		page := gjson.ParseBytes(body)
		if !page.Get("results").Exists() {
			return nil, errors.New("device listing response has no results field")
		}

		count := page.Get("count").Int()
		if pagesWalked == 0 {
			total = count
			if total > maxDevices {
				return nil, fmt.Errorf("device count %d exceeds bound %d", total, maxDevices)
			}
		} else if count != total {
			return nil, errors.New("device count changed during pagination")
		}

		results := page.Get("results").Array()
		if int64(len(all)+len(results)) > total {
			return nil, errors.New("device results exceed the reported count")
		}

		rawNext := page.Get("next").String()
		if len(results) == 0 && rawNext != "" {
			return nil, errors.New("empty non-terminal device page")
		}

		for _, row := range results {
			all = append(all, json.RawMessage(row.Raw))
		}
		pagesWalked++

		// NetBox returns `next` absolute ("https://host/netbox/api/...")
		// or null. The origin is always stripped so the walk can never be
		// redirected off the configured instance; the retained path keeps
		// any BASE_PATH prefix.
		next = relativizePath(rawNext)
		if rawNext != "" && next == "" {
			return nil, errors.New("invalid pagination link")
		}
	}

	if int64(len(all)) != total {
		return nil, fmt.Errorf("pagination returned %d of %d devices", len(all), total)
	}

	return all, nil
}

func getJSON(src SourceConfig, requestURL string) ([]byte, error) {
	timeoutMS := src.TimeoutMS
	if timeoutMS <= 0 {
		timeoutMS = defaultTimeoutMS
	}

	req := sdk.HTTPRequest{
		Method: http.MethodGet,
		URL:    requestURL,
		Headers: map[string]string{
			"Authorization": "Token " + src.APIToken,
			"Accept":        "application/json",
		},
		TimeoutMS:          timeoutMS,
		InsecureSkipVerify: src.InsecureSkipVerify,
	}

	resp, err := netboxHTTP.Do(req)
	if err != nil {
		return nil, errNetboxRequestFailed
	}
	if resp.Status < 200 || resp.Status >= 300 {
		return nil, fmt.Errorf("%w: status %d", errNetboxRequestFailed, resp.Status)
	}

	return resp.Body, nil
}

// relativizePath turns a pagination link into an origin-relative path
// (retaining any BASE_PATH prefix the server includes).
func relativizePath(next string) string {
	switch {
	case next == "":
		return ""
	case strings.HasPrefix(next, "/") && !strings.HasPrefix(next, "//"):
		return next
	case strings.HasPrefix(next, "https://"):
		i := strings.Index(next[len("https://"):], "/")
		if i < 0 {
			return ""
		}
		return next[len("https://")+i:]
	case strings.HasPrefix(next, "http://"):
		i := strings.Index(next[len("http://"):], "/")
		if i < 0 {
			return ""
		}
		return next[len("http://")+i:]
	default:
		return ""
	}
}

// primaryIP returns the device's primary IP as a bare address, preferring
// IPv4. NetBox reports addresses in CIDR form ("10.0.0.5/24").
func primaryIP(item gjson.Result) string {
	for _, field := range []string{"primary_ip4.address", "primary_ip6.address"} {
		address := strings.TrimSpace(item.Get(field).String())
		if address == "" {
			continue
		}

		if prefix, err := netip.ParsePrefix(address); err == nil {
			return prefix.Addr().String()
		}
		if addr, err := netip.ParseAddr(address); err == nil {
			return addr.String()
		}
	}

	return ""
}

// parseBlacklist accepts CIDRs and bare addresses (treated as single-host
// prefixes). Entries that parse as neither are returned so the caller can
// surface them instead of silently ingesting devices the operator excluded.
func parseBlacklist(entries []string) (prefixes []netip.Prefix, invalid []string) {
	prefixes = make([]netip.Prefix, 0, len(entries))
	for _, raw := range entries {
		trimmed := strings.TrimSpace(raw)
		if trimmed == "" {
			continue
		}

		if prefix, err := netip.ParsePrefix(trimmed); err == nil {
			prefixes = append(prefixes, prefix)
			continue
		}
		if addr, err := netip.ParseAddr(trimmed); err == nil {
			prefixes = append(prefixes, netip.PrefixFrom(addr, addr.BitLen()))
			continue
		}

		invalid = append(invalid, trimmed)
	}

	return prefixes, invalid
}

func ipBlacklisted(ip string, blacklist []netip.Prefix) bool {
	if len(blacklist) == 0 {
		return false
	}

	addr, err := netip.ParseAddr(ip)
	if err != nil {
		return false
	}

	for _, prefix := range blacklist {
		if prefix.Contains(addr) {
			return true
		}
	}

	return false
}

// buildDiscoveredDevice maps one NetBox device row to a DiscoveredDevice.
//
// Identity metadata is source-scoped on purpose: two NetBox instances both
// containing device id 42 must never mint the same strong identifier (the
// armis_device_id over-merge class). integration_id carries the required
// "netbox:" source prefix for snapshot activation; the bare metadata keys
// (role, site, status) feed the device UI provenance card.
func buildDiscoveredDevice(sourceID string, item gjson.Result, id int64, ip string) sdk.DiscoveredDevice {
	netboxID := strconv.FormatInt(id, 10)
	deviceID := fmt.Sprintf("netbox:%s:device:%s", sourceID, netboxID)
	role := firstString(item, "role.name", "device_role.name")
	site := item.Get("site.name").String()
	status := item.Get("status.value").String()
	manufacturer := item.Get("device_type.manufacturer.name").String()
	model := item.Get("device_type.model").String()

	metadata := map[string]any{
		"integration_type": sourceType,
		"integration_id":   deviceID,
		"netbox_device_id": sourceID + ":" + netboxID,
	}
	putNonEmpty(metadata, "role", role)
	putNonEmpty(metadata, "site", site)
	putNonEmpty(metadata, "status", status)
	putNonEmpty(metadata, "manufacturer", manufacturer)
	putNonEmpty(metadata, "model", model)
	putNonEmpty(metadata, "description", item.Get("description").String())
	putNonEmpty(metadata, "netbox_created", item.Get("created").String())
	putNonEmpty(metadata, "netbox_last_updated", item.Get("last_updated").String())

	device := sdk.DiscoveredDevice{
		DeviceID:   deviceID,
		Hostname:   item.Get("name").String(),
		IP:         ip,
		VendorName: manufacturer,
		Model:      model,
		Type:       "device",
		Role:       role,
		Status:     status,
		Labels: map[string]string{
			"provider":  sourceType,
			"source_id": sourceID,
		},
		Metadata: metadata,
	}

	if site != "" {
		device.Location = &sdk.DeviceLocation{SiteName: site}
	}

	return device
}

func firstString(item gjson.Result, paths ...string) string {
	for _, path := range paths {
		if value := item.Get(path).String(); value != "" {
			return value
		}
	}

	return ""
}

func putNonEmpty(metadata map[string]any, key, value string) {
	if value != "" {
		metadata[key] = value
	}
}

// normalizeSourceInstance produces a stable identifier matching core's
// source_instance constraint (^[a-z0-9][a-z0-9_.-]{0,127}$).
func normalizeSourceInstance(sourceID, baseURL string) string {
	raw := strings.ToLower(strings.TrimSpace(sourceID))
	if raw == "" {
		raw = strings.ToLower(strings.TrimSpace(baseURL))
		raw = strings.TrimPrefix(raw, "https://")
		raw = strings.TrimPrefix(raw, "http://")
	}

	var b strings.Builder
	for _, r := range raw {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '_', r == '.', r == '-':
			b.WriteRune(r)
		default:
			b.WriteByte('-')
		}
	}

	normalized := strings.Trim(b.String(), "-.")
	if normalized == "" || !isAlnum(rune(normalized[0])) {
		normalized = "netbox-" + normalized
		normalized = strings.Trim(normalized, "-.")
	}
	if len(normalized) > 128 {
		normalized = normalized[:128]
	}

	return normalized
}

func isAlnum(r rune) bool {
	return (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')
}

// snapshotHash is the envelope reference_hash: a bare 64-hex sha256 over the
// device set, order independent, as required by the observation ingestor's
// content-hash pattern.
func snapshotHash(sourceID string, devices []sdk.DiscoveredDevice) string {
	ordered := append([]sdk.DiscoveredDevice(nil), devices...)
	sort.Slice(ordered, func(i, j int) bool {
		return ordered[i].DeviceID < ordered[j].DeviceID
	})

	canonical, err := json.Marshal(struct {
		SourceID string                 `json:"source_id"`
		Devices  []sdk.DiscoveredDevice `json:"devices"`
	}{SourceID: sourceID, Devices: ordered})
	if err != nil {
		canonical = []byte(sourceID)
	}
	digest := sha256.Sum256(canonical)

	return fmt.Sprintf("%x", digest[:])
}

func nonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}

	return ""
}

// primeTinyGoJSON registers types we'll marshal so TinyGo's reflection-free
// JSON support pulls them in. Mirrors the awx/proxmox plugin pattern.
func primeTinyGoJSON() {
	_, _ = json.Marshal(map[string]any{"n": 0})
	_, _ = json.Marshal(sdk.DiscoveredDevice{})
}

func main() {}
