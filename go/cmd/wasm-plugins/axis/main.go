package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/sdk"

	"github.com/carverauto/serviceradar/contrib/plugins/go/axis/internal/axisref"
)

type Config struct {
	Host            string `json:"host"`
	Scheme          string `json:"scheme"`
	Username        string `json:"username"`
	Password        string `json:"password"`
	Timeout         string `json:"timeout"`
	DiscoverStreams bool   `json:"discover_streams"`
	CollectEvents   bool   `json:"collect_events"`
	EventSources    string `json:"event_sources"`
}

type EndpointResult struct {
	Path       string        `json:"path"`
	Status     int           `json:"status"`
	DurationMS int64         `json:"duration_ms"`
	BodyBytes  int           `json:"body_bytes"`
	Error      string        `json:"error,omitempty"`
	KVCount    int           `json:"kv_count,omitempty"`
	KVSample   []string      `json:"kv_sample,omitempty"`
	EventCount int           `json:"event_count,omitempty"`
	Body       string        `json:"body,omitempty"`
	Duration   time.Duration `json:"-"`
}

type StreamInfo struct {
	ID       string `json:"id"`
	Protocol string `json:"protocol"`
	URL      string `json:"url"`
	AuthMode string `json:"auth_mode"`
	Source   string `json:"source"`
}

type CameraDescriptor struct {
	DeviceUID      string                 `json:"device_uid"`
	Vendor         string                 `json:"vendor"`
	CameraID       string                 `json:"camera_id"`
	DisplayName    string                 `json:"display_name,omitempty"`
	SourceURL      string                 `json:"source_url,omitempty"`
	StreamProfiles []CameraStreamProfile  `json:"stream_profiles,omitempty"`
	Metadata       map[string]interface{} `json:"metadata,omitempty"`
}

type CameraStreamProfile struct {
	ProfileName       string                 `json:"profile_name"`
	VendorProfileID   string                 `json:"vendor_profile_id,omitempty"`
	SourceURLOverride string                 `json:"source_url_override,omitempty"`
	RTSPTransport     string                 `json:"rtsp_transport,omitempty"`
	CodecHint         string                 `json:"codec_hint,omitempty"`
	Metadata          map[string]interface{} `json:"metadata,omitempty"`
}

type ResultDetails struct {
	CameraHost        string                 `json:"camera_host"`
	DeviceInfo        map[string]string      `json:"device_info,omitempty"`
	DiscoveredAPIs    map[string]any         `json:"discovered_apis,omitempty"`
	Streams           []StreamInfo           `json:"streams,omitempty"`
	CameraDescriptors []CameraDescriptor     `json:"camera_descriptors,omitempty"`
	Endpoints         []EndpointResult       `json:"endpoints"`
	CollectionError   string                 `json:"collection_error,omitempty"`
	Enrichment        map[string]any         `json:"device_enrichment,omitempty"`
	Metadata          map[string]interface{} `json:"metadata,omitempty"`
}

type axisClient struct {
	baseURL    string
	authHeader string
	timeout    time.Duration
}

func (c *axisClient) get(ctx context.Context, path string) EndpointResult {
	req := sdk.HTTPRequest{
		Method:    "GET",
		URL:       c.baseURL + path,
		TimeoutMS: int(c.timeout.Milliseconds()),
	}

	if c.authHeader != "" {
		req.Headers = map[string]string{"Authorization": c.authHeader}
	}

	resp, err := sdk.HTTP.DoContext(ctx, req)
	if err != nil {
		return EndpointResult{Path: path, Error: err.Error()}
	}

	return EndpointResult{
		Path:       path,
		Status:     resp.Status,
		DurationMS: resp.Duration.Milliseconds(),
		BodyBytes:  len(resp.Body),
		Body:       string(resp.Body),
		Duration:   resp.Duration,
	}
}

//export run_check
func run_check() {
	_ = sdk.Execute(func() (*sdk.Result, error) {
		// TinyGo reflection metadata retention workaround.
		var initCfg Config
		_ = json.Unmarshal([]byte(`{"host":"x"}`), &initCfg)

		cfg := Config{Scheme: "http", DiscoverStreams: true, CollectEvents: false, EventSources: "events", Timeout: "10s"}
		if err := sdk.LoadConfig(&cfg); err != nil {
			sdk.Log.Warn("failed to load config: " + err.Error())
		}

		cfg.Host = strings.TrimSpace(cfg.Host)
		if cfg.Host == "" {
			return sdk.Unknown("configuration error: host is required"), nil
		}

		scheme := strings.ToLower(strings.TrimSpace(cfg.Scheme))
		if scheme == "" {
			scheme = "http"
		}
		if scheme != "http" && scheme != "https" {
			return sdk.Unknown("configuration error: scheme must be http or https"), nil
		}

		timeout := 10 * time.Second
		if cfg.Timeout != "" {
			if parsed, err := time.ParseDuration(cfg.Timeout); err == nil && parsed > 0 {
				timeout = parsed
			}
		}

		client := &axisClient{
			baseURL: fmt.Sprintf("%s://%s", scheme, cfg.Host),
			timeout: timeout,
		}
		if cfg.Username != "" || cfg.Password != "" {
			client.authHeader = "Basic " + base64.StdEncoding.EncodeToString([]byte(cfg.Username+":"+cfg.Password))
		}

		ctx := context.Background()
		details := ResultDetails{
			CameraHost: cfg.Host,
			Endpoints:  make([]EndpointResult, 0, 6),
			Metadata: map[string]interface{}{
				"plugin":             "axis-camera",
				"base_url":           client.baseURL,
				"discover_streams":   cfg.DiscoverStreams,
				"collect_events":     cfg.CollectEvents,
				"auth_configured":    client.authHeader != "",
				"collection_timeout": timeout.String(),
			},
		}
		resultEvents := make([]sdk.OCSFEvent, 0, 4)

		basicInfo, basicRes := collectBasicDeviceInfo(ctx, client)
		details.Endpoints = append(details.Endpoints, basicRes...)
		if len(basicInfo) > 0 {
			details.DeviceInfo = basicInfo
		}

		apis, apiRes := collectAPIDiscovery(ctx, client)
		details.Endpoints = append(details.Endpoints, apiRes...)
		if len(apis) > 0 {
			details.DiscoveredAPIs = apis
		}

		if cfg.DiscoverStreams {
			streams, streamRes := collectStreamInfo(ctx, client, cfg.Host, client.authHeader != "")
			details.Endpoints = append(details.Endpoints, streamRes...)
			details.Streams = streams
		}
		if cfg.CollectEvents {
			events, eventRes := collectAxisEvents(scheme, cfg.Host, cfg.Username, cfg.Password, cfg.EventSources, timeout)
			details.Endpoints = append(details.Endpoints, eventRes)
			resultEvents = append(resultEvents, events...)
		}

		details.Enrichment = buildEnrichment(details)
		details.CameraDescriptors = buildCameraDescriptors(details)
		summary := buildSummary(details)
		status := deriveStatus(details)

		detailsJSON, err := json.Marshal(details)
		if err != nil {
			return nil, fmt.Errorf("marshal details: %w", err)
		}

		result := sdk.NewResult().
			WithStatus(status).
			WithSummary(summary).
			WithDetails(string(detailsJSON)).
			WithMetric("axis_endpoint_success_total", float64(countSuccessfulEndpoints(details.Endpoints)), "count", nil).
			WithMetric("axis_endpoint_total", float64(len(details.Endpoints)), "count", nil).
			WithMetric("axis_stream_total", float64(len(details.Streams)), "count", nil).
			WithLabel("camera_host", cfg.Host).
			WithLabel("camera_scheme", scheme)

		if model := firstNonEmpty(details.DeviceInfo, "ProdNbr", "ProductFullName", "Brand"); model != "" {
			result.WithLabel("camera_model", model)
		}
		for _, evt := range resultEvents {
			result.WithOCSFEvent(evt)
		}

		return result, nil
	})
}

func collectBasicDeviceInfo(ctx context.Context, client *axisClient) (map[string]string, []EndpointResult) {
	paths := []string{
		"/axis-cgi/basicdeviceinfo.cgi",
		"/axis-cgi/basicdeviceinfo.cgi?method=getAllProperties",
	}

	results := make([]EndpointResult, 0, len(paths))
	for _, p := range paths {
		res := client.get(ctx, p)
		if res.Status == 200 {
			if kv, err := axisref.ParseKeyValueBody(res.Body); err == nil {
				res.KVCount = len(kv)
				res.KVSample = sampleKeys(kv, 8)
				results = append(results, trimBody(res))
				return kv, results
			}
		}
		results = append(results, trimBody(res))
	}

	return nil, results
}

func collectAPIDiscovery(ctx context.Context, client *axisClient) (map[string]any, []EndpointResult) {
	res := client.get(ctx, "/axis-cgi/apidiscovery.cgi")
	if res.Status != 200 {
		return nil, []EndpointResult{trimBody(res)}
	}

	var payload map[string]any
	if err := json.Unmarshal([]byte(res.Body), &payload); err != nil {
		res.Error = "invalid JSON: " + err.Error()
		return nil, []EndpointResult{trimBody(res)}
	}

	res.KVCount = len(payload)
	return payload, []EndpointResult{trimBody(res)}
}

func collectStreamInfo(ctx context.Context, client *axisClient, host string, authConfigured bool) ([]StreamInfo, []EndpointResult) {
	profileRes := trimBody(client.get(ctx, "/axis-cgi/streamprofile.cgi?list"))
	statusRes := trimBody(client.get(ctx, "/axis-cgi/streamstatus.cgi"))
	results := []EndpointResult{profileRes, statusRes}

	if profileRes.Status != 200 || strings.TrimSpace(profileRes.Body) == "" {
		return nil, results
	}

	kv, err := axisref.ParseKeyValueBody(profileRes.Body)
	if err != nil {
		results[0].Error = "stream profile parse failed: " + err.Error()
		return nil, results
	}

	results[0].KVCount = len(kv)
	results[0].KVSample = sampleKeys(kv, 8)

	profiles := axisref.ParseStreamProfiles(kv)
	if len(profiles) == 0 {
		return nil, results
	}

	authMode := "unknown"
	if authConfigured {
		authMode = "basic_or_digest"
	}

	streams := make([]StreamInfo, 0, len(profiles))
	for _, profile := range profiles {
		streamID := profile.ID
		if strings.TrimSpace(profile.Name) != "" {
			streamID = profile.Name
		}
		streams = append(streams, StreamInfo{
			ID:       streamID,
			Protocol: "rtsp",
			URL:      buildRTSPURL(host, profile.Parameters),
			AuthMode: authMode,
			Source:   "streamprofile.cgi",
		})
	}

	return streams, results
}

func collectAxisEvents(scheme, host, username, password, sources string, timeout time.Duration) ([]sdk.OCSFEvent, EndpointResult) {
	sources = strings.TrimSpace(sources)
	if sources == "" {
		sources = "events"
	}

	wsScheme := "ws"
	if scheme == "https" {
		wsScheme = "wss"
	}

	wsURL := fmt.Sprintf("%s://%s/vapix/ws-data-stream?sources=%s", wsScheme, host, sources)
	wsURL = withWebSocketCredentials(wsURL, username, password)

	result := EndpointResult{Path: "/vapix/ws-data-stream"}
	conn, err := sdk.WebSocketConnect(wsURL, timeout)
	if err != nil {
		result.Error = "websocket connect failed: " + err.Error()
		return nil, result
	}
	defer func() { _ = conn.Close() }()

	configReq := map[string]interface{}{
		"apiVersion": "1.0",
		"method":     "events:configure",
		"params": map[string]interface{}{
			"eventFilterList": []map[string]string{{"topicFilter": ""}},
		},
	}

	reqBytes, _ := json.Marshal(configReq)
	if sendErr := conn.Send(reqBytes, timeout); sendErr != nil {
		result.Error = "websocket configure failed: " + sendErr.Error()
		return nil, result
	}

	events := make([]sdk.OCSFEvent, 0, 4)
	buf := make([]byte, 16384)
	for i := 0; i < 4; i++ {
		n, recvErr := conn.Recv(buf, 800*time.Millisecond)
		if recvErr != nil || n <= 0 {
			break
		}
		if evt := mapAxisWSEvent(buf[:n]); evt != nil {
			events = append(events, *evt)
		}
	}

	result.Status = 200
	result.EventCount = len(events)
	return events, result
}

func mapAxisWSEvent(data []byte) *sdk.OCSFEvent {
	var payload map[string]interface{}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil
	}

	message := "AXIS event received"
	if params, ok := payload["params"].(map[string]interface{}); ok {
		if notification, ok := params["notification"].(map[string]interface{}); ok {
			if topic, ok := notification["topic"].(string); ok && strings.TrimSpace(topic) != "" {
				message = "AXIS event: " + topic
			}
		}
	}

	event := sdk.NewOCSFEventLogActivity(message, sdk.SeverityInfo)
	if event.Unmapped == nil {
		event.Unmapped = map[string]interface{}{}
	}
	event.Unmapped["axis_ws_payload"] = payload
	return &event
}

func buildEnrichment(details ResultDetails) map[string]any {
	if len(details.Streams) == 0 && len(details.DeviceInfo) == 0 {
		return nil
	}

	identity := map[string]string{}
	if serial := firstNonEmpty(details.DeviceInfo, "S.Nbr", "SerialNumber", "Serial"); serial != "" {
		identity["serial"] = serial
	}
	if mac := firstNonEmpty(details.DeviceInfo, "MACAddress", "Network.HWaddress", "root.Network.HWaddress"); mac != "" {
		identity["mac"] = mac
	}

	enrichment := map[string]any{
		"identity": identity,
		"camera": map[string]any{
			"model":    firstNonEmpty(details.DeviceInfo, "ProdNbr", "ProductFullName"),
			"firmware": firstNonEmpty(details.DeviceInfo, "Version", "FirmwareVersion"),
			"vendor":   "AXIS",
		},
		"streams": details.Streams,
		"source": map[string]any{
			"plugin_id": "axis-camera",
		},
	}

	return enrichment
}

func buildCameraDescriptors(details ResultDetails) []CameraDescriptor {
	deviceUID := firstNonEmpty(
		details.DeviceInfo,
		"S.Nbr",
		"SerialNumber",
		"Serial",
		"MACAddress",
		"Network.HWaddress",
		"root.Network.HWaddress",
	)
	if deviceUID == "" {
		deviceUID = strings.TrimSpace(details.CameraHost)
	}

	cameraID := firstNonEmpty(details.DeviceInfo, "S.Nbr", "SerialNumber", "Serial")
	if cameraID == "" {
		cameraID = strings.TrimSpace(details.CameraHost)
	}

	if deviceUID == "" || cameraID == "" {
		return nil
	}

	descriptor := CameraDescriptor{
		DeviceUID:   deviceUID,
		Vendor:      "axis",
		CameraID:    cameraID,
		DisplayName: firstNonEmpty(details.DeviceInfo, "ProductFullName", "ProdNbr", "Brand", "ProdShortName"),
		SourceURL:   firstStreamURL(details.Streams),
		Metadata: map[string]interface{}{
			"camera_host": details.CameraHost,
			"plugin_id":   "axis-camera",
		},
	}

	if descriptor.DisplayName == "" {
		descriptor.DisplayName = details.CameraHost
	}

	for _, stream := range details.Streams {
		profile := CameraStreamProfile{
			ProfileName:       strings.TrimSpace(stream.ID),
			VendorProfileID:   strings.TrimSpace(stream.ID),
			SourceURLOverride: strings.TrimSpace(stream.URL),
			RTSPTransport:     "tcp",
			CodecHint:         codecFromRTSPURL(stream.URL),
			Metadata: map[string]interface{}{
				"auth_mode": stream.AuthMode,
				"source":    stream.Source,
			},
		}
		if profile.ProfileName == "" {
			profile.ProfileName = "default"
		}
		descriptor.StreamProfiles = append(descriptor.StreamProfiles, profile)
	}

	return []CameraDescriptor{descriptor}
}

func buildSummary(details ResultDetails) string {
	success := countSuccessfulEndpoints(details.Endpoints)
	model := firstNonEmpty(details.DeviceInfo, "ProdNbr", "ProductFullName")
	if model == "" {
		model = "unknown-model"
	}

	return fmt.Sprintf("AXIS %s: %d/%d endpoint checks ok, %d streams", model, success, len(details.Endpoints), len(details.Streams))
}

func deriveStatus(details ResultDetails) sdk.Status {
	total := len(details.Endpoints)
	if total == 0 {
		return sdk.StatusUnknown
	}
	success := countSuccessfulEndpoints(details.Endpoints)
	if success == 0 {
		return sdk.StatusCritical
	}
	if success < total {
		return sdk.StatusWarning
	}
	return sdk.StatusOK
}

func countSuccessfulEndpoints(results []EndpointResult) int {
	total := 0
	for _, r := range results {
		if r.Status >= 200 && r.Status < 300 && r.Error == "" {
			total++
		}
	}
	return total
}

func firstNonEmpty(m map[string]string, keys ...string) string {
	for _, k := range keys {
		if v := strings.TrimSpace(m[k]); v != "" {
			return v
		}
	}
	return ""
}

func sampleKeys(m map[string]string, limit int) []string {
	if len(m) == 0 || limit <= 0 {
		return nil
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if len(keys) > limit {
		keys = keys[:limit]
	}
	return keys
}

func buildRTSPURL(host string, params map[string]string) string {
	base := fmt.Sprintf("rtsp://%s/axis-media/media.amp", host)
	if len(params) == 0 {
		return base
	}
	keys := make([]string, 0, len(params))
	for key := range params {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, key+"="+params[key])
	}
	return base + "?" + strings.Join(parts, "&")
}

func firstStreamURL(streams []StreamInfo) string {
	for _, stream := range streams {
		if url := strings.TrimSpace(stream.URL); url != "" {
			return url
		}
	}
	return ""
}

func codecFromRTSPURL(url string) string {
	parts := strings.SplitN(url, "?", 2)
	if len(parts) != 2 || strings.TrimSpace(parts[1]) == "" {
		return ""
	}

	for _, pair := range strings.Split(parts[1], "&") {
		key, value, ok := strings.Cut(pair, "=")
		if !ok {
			continue
		}
		if key == "videocodec" {
			return value
		}
	}

	return ""
}

func withWebSocketCredentials(rawURL, username, password string) string {
	if strings.TrimSpace(username) == "" && strings.TrimSpace(password) == "" {
		return rawURL
	}

	parsed, err := url.Parse(rawURL)
	if err != nil {
		return rawURL
	}

	parsed.User = url.UserPassword(username, password)
	return parsed.String()
}

func trimBody(in EndpointResult) EndpointResult {
	out := in
	const maxBody = 256
	if len(out.Body) > maxBody {
		out.Body = out.Body[:maxBody]
	}
	return out
}

func main() {}
