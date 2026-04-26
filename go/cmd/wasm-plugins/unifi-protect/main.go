package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/sdk"
)

type Config struct {
	sdk.CameraPluginConfig
	APIKey        string `json:"api_key"`
	Cookie        string `json:"cookie"`
	BootstrapPath string `json:"bootstrap_path"`
	LoginPath     string `json:"login_path"`
	RTSPPort      int    `json:"rtsp_port"`
}

type EndpointResult struct {
	Path        string        `json:"path"`
	Status      int           `json:"status"`
	DurationMS  int64         `json:"duration_ms"`
	BodyBytes   int           `json:"body_bytes"`
	Error       string        `json:"error,omitempty"`
	CameraCount int           `json:"camera_count,omitempty"`
	EventCount  int           `json:"event_count,omitempty"`
	Body        string        `json:"body,omitempty"`
	Duration    time.Duration `json:"-"`
}

type StreamInfo struct {
	ID                 string `json:"id"`
	Protocol           string `json:"protocol"`
	URL                string `json:"url"`
	AuthMode           string `json:"auth_mode"`
	Source             string `json:"source"`
	InsecureSkipVerify bool   `json:"insecure_skip_verify,omitempty"`
}

type CameraDescriptor struct {
	DeviceUID          string                 `json:"device_uid"`
	Vendor             string                 `json:"vendor"`
	CameraID           string                 `json:"camera_id"`
	IP                 string                 `json:"ip,omitempty"`
	DisplayName        string                 `json:"display_name,omitempty"`
	AvailabilityStatus string                 `json:"availability_status,omitempty"`
	AvailabilityReason string                 `json:"availability_reason,omitempty"`
	SourceURL          string                 `json:"source_url,omitempty"`
	StreamProfiles     []CameraStreamProfile  `json:"stream_profiles,omitempty"`
	Identity           map[string]interface{} `json:"identity,omitempty"`
	Metadata           map[string]interface{} `json:"metadata,omitempty"`
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
	ControllerHost    string                 `json:"controller_host"`
	Cameras           []ProtectCamera        `json:"cameras,omitempty"`
	Streams           []StreamInfo           `json:"streams,omitempty"`
	CameraDescriptors []CameraDescriptor     `json:"camera_descriptors,omitempty"`
	Endpoints         []EndpointResult       `json:"endpoints"`
	CollectionError   string                 `json:"collection_error,omitempty"`
	Metadata          map[string]interface{} `json:"metadata,omitempty"`
}

type ProtectBootstrapResponse struct {
	Cameras      []ProtectCamera `json:"cameras"`
	LastUpdateID string          `json:"lastUpdateId"`
	Data         struct {
		Cameras      []ProtectCamera `json:"cameras"`
		LastUpdateID string          `json:"lastUpdateId"`
	} `json:"data"`
}

type ProtectBootstrapSnapshot struct {
	Cameras      []ProtectCamera
	LastUpdateID string
}

type protectRTSPSStreams map[string]*string

type protectHTTPClient interface {
	URL(string) string
	DoContext(context.Context, sdk.HTTPRequest) (*sdk.HTTPResponse, error)
}

type protectEventConn interface {
	Recv([]byte, time.Duration) (int, error)
	Close() error
}

var protectEventDial = func(rawURL string, headers map[string]string, insecureSkipVerify bool, timeout time.Duration) (protectEventConn, error) {
	return sdk.WebSocketDialRequestContext(context.Background(), sdk.WebSocketDialRequest{
		URL:                rawURL,
		Headers:            headers,
		InsecureSkipVerify: insecureSkipVerify,
	}, timeout)
}

type ProtectCamera struct {
	ID              string           `json:"id"`
	MAC             string           `json:"mac"`
	Host            string           `json:"host"`
	ConnectionHost  string           `json:"connectionHost"`
	Name            string           `json:"name"`
	DisplayName     string           `json:"displayName"`
	ModelKey        string           `json:"modelKey"`
	MarketName      string           `json:"marketName"`
	Type            string           `json:"type"`
	State           string           `json:"state"`
	FirmwareVersion string           `json:"firmwareVersion"`
	IsConnected     bool             `json:"isConnected"`
	Channels        []ProtectChannel `json:"channels"`
}

type ProtectChannel struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	RTSPAlias  string `json:"rtspAlias"`
	RTSPSAlias string `json:"rtspsAlias"`
	Width      int    `json:"width"`
	Height     int    `json:"height"`
	FPS        int    `json:"fps"`
	Bitrate    int    `json:"bitrate"`
}

type UniFiNetworkSite struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type uniFiNetworkSitesResponse struct {
	Data []UniFiNetworkSite `json:"data"`
}

type UniFiNetworkClient struct {
	ID          string `json:"id"`
	MACAddress  string `json:"macAddress"`
	MAC         string `json:"mac"`
	IPAddress   string `json:"ipAddress"`
	IP          string `json:"ip"`
	Hostname    string `json:"hostname"`
	Name        string `json:"name"`
	DisplayName string `json:"displayName"`
}

type uniFiNetworkClientsResponse struct {
	Offset     int                  `json:"offset"`
	Limit      int                  `json:"limit"`
	Count      int                  `json:"count"`
	TotalCount int                  `json:"totalCount"`
	Data       []UniFiNetworkClient `json:"data"`
}

//export run_check
func run_check() {
	_ = sdk.Execute(func() (*sdk.Result, error) {
		var initCfg Config
		_ = json.Unmarshal([]byte(`{"host":"x"}`), &initCfg)

		cfg, err := loadConfig()
		if err != nil {
			sdk.Log.Warn("failed to load config: " + err.Error())
		}

		cfg.Host = strings.TrimSpace(cfg.Host)
		if cfg.Host == "" {
			return sdk.Unknown("configuration error: host is required"), nil
		}

		client, err := sdk.NewCameraHTTPClient(cfg.CameraPluginConfig, 10*time.Second)
		if err != nil {
			return sdk.Unknown("configuration error: " + err.Error()), nil
		}

		headers, authMode, err := protectSessionHeaders(context.Background(), cfg, client)
		if err != nil {
			return sdk.Unknown("protect auth error: " + err.Error()), nil
		}

		needLastUpdateID := cfg.CollectEvents && authMode != "api_key"
		bootstrap, endpointResults, snapshotErr := fetchProtectSnapshot(context.Background(), client, cfg, headers, authMode, needLastUpdateID)
		details := ResultDetails{
			ControllerHost: cfg.Host,
			Endpoints:      endpointResults,
			Metadata: map[string]interface{}{
				"plugin":             "unifi-protect-camera",
				"base_url":           client.BaseURL,
				"bootstrap_path":     cfg.normalizedBootstrapPath(),
				"auth_mode":          authMode,
				"collect_events":     cfg.CollectEvents,
				"event_sources":      cfg.EventSources,
				"collection_timeout": client.Timeout.String(),
			},
		}
		resultEvents := make([]sdk.OCSFEvent, 0, 4)

		if snapshotErr != "" {
			details.CollectionError = snapshotErr
		}

		networkClients, networkEndpoints := fetchUniFiNetworkClients(
			context.Background(),
			client,
			headers,
			cfg,
			bootstrap.Cameras,
		)
		details.Endpoints = append(details.Endpoints, networkEndpoints...)
		details.Cameras = bootstrap.Cameras
		details.Streams = buildProtectStreams(cfg, bootstrap.Cameras)
		details.CameraDescriptors = buildProtectCameraDescriptors(cfg, bootstrap.Cameras, networkClients)
		if len(networkClients) > 0 {
			details.Metadata["network_client_matches"] = len(networkClients)
		}
		if cfg.CollectEvents {
			events, eventRes := collectProtectEvents(cfg, headers, client.Timeout, bootstrap.LastUpdateID, authMode)
			details.Endpoints = append(details.Endpoints, eventRes)
			resultEvents = append(resultEvents, events...)
		}

		detailsJSON, err := json.Marshal(details)
		if err != nil {
			return nil, fmt.Errorf("marshal details: %w", err)
		}

		summary := fmt.Sprintf("UniFi Protect: %d cameras, %d streams", len(details.Cameras), len(details.Streams))
		status := sdk.StatusWarning
		if snapshotErr == "" && len(details.Cameras) > 0 {
			status = sdk.StatusOK
		}
		if snapshotErr != "" {
			status = sdk.StatusCritical
		}
		if status == sdk.StatusOK && cfg.CollectEvents {
			lastEndpoint := details.Endpoints[len(details.Endpoints)-1]
			if lastEndpoint.Path == "/proxy/protect/ws/updates" && lastEndpoint.Error != "" {
				status = sdk.StatusWarning
				summary += ", events unavailable"
			}
		}

		result := sdk.NewResult().
			WithStatus(status).
			WithSummary(summary).
			WithDetails(string(detailsJSON)).
			WithMetric("unifi_protect_camera_total", float64(len(details.Cameras)), "count", nil).
			WithMetric("unifi_protect_stream_total", float64(len(details.Streams)), "count", nil).
			WithMetric("unifi_protect_event_total", float64(len(resultEvents)), "count", nil).
			WithLabel("controller_host", cfg.Host).
			WithLabel("camera_scheme", client.BaseURL[:strings.Index(client.BaseURL, "://")])
		for _, event := range resultEvents {
			result.WithOCSFEvent(event)
		}

		return result, nil
	})
}

//export stream_camera
func stream_camera() {
	cfg, err := loadStreamConfig()
	if err != nil {
		sdk.Log.Warn("failed to load stream config: " + err.Error())
	}

	cfg.Host = strings.TrimSpace(cfg.Host)
	if cfg.Host == "" {
		sdk.Log.Error("stream_camera configuration error: host is required")
		return
	}

	client, err := sdk.NewCameraHTTPClient(cfg.CameraPluginConfig, 10*time.Second)
	if err != nil {
		sdk.Log.Error("stream_camera configuration error: " + err.Error())
		return
	}

	headers, _, err := protectSessionHeaders(context.Background(), cfg.Config, client)
	if err != nil {
		sdk.Log.Error("stream_camera auth error: " + err.Error())
		return
	}

	sourceURL, err := resolveProtectStreamSourceURL(context.Background(), cfg, client, headers)
	if err != nil {
		sdk.Log.Error("stream_camera source resolution failed: " + err.Error())
		return
	}

	if err := streamProtectRTSP(cfg, client.Timeout, sourceURL); err != nil {
		sdk.Log.Error("stream_camera rtsp path failed: " + err.Error())
		return
	}
}

func loadConfig() (Config, error) {
	cfg := Config{
		CameraPluginConfig: sdk.CameraPluginConfig{
			Scheme:          "https",
			DiscoverStreams: true,
			CollectEvents:   false,
			EventSources:    "updates",
			Timeout:         "10s",
		},
		BootstrapPath: "/proxy/protect/api/bootstrap",
		LoginPath:     "/api/auth/login",
		RTSPPort:      7447,
	}

	err := sdk.LoadConfig(&cfg)
	return cfg, err
}

func (c Config) normalizedBootstrapPath() string {
	path := strings.TrimSpace(c.BootstrapPath)
	if path == "" {
		return "/proxy/protect/api/bootstrap"
	}
	if strings.HasPrefix(path, "/") {
		return path
	}
	return "/" + path
}

func (c Config) normalizedLoginPath() string {
	path := strings.TrimSpace(c.LoginPath)
	if path == "" {
		return "/api/auth/login"
	}
	if strings.HasPrefix(path, "/") {
		return path
	}
	return "/" + path
}

func (c Config) normalizedRTSPPort() int {
	if c.RTSPPort > 0 && c.RTSPPort <= 65535 {
		return c.RTSPPort
	}
	return 7447
}

func protectSessionHeaders(ctx context.Context, cfg Config, client protectHTTPClient) (map[string]string, string, error) {
	if strings.TrimSpace(cfg.APIKey) != "" {
		return map[string]string{"X-API-Key": strings.TrimSpace(cfg.APIKey)}, "api_key", nil
	}

	if strings.TrimSpace(cfg.Cookie) != "" {
		return map[string]string{"Cookie": strings.TrimSpace(cfg.Cookie)}, "cookie", nil
	}

	if strings.TrimSpace(cfg.Username) == "" && strings.TrimSpace(cfg.Password) == "" {
		return nil, "none", nil
	}

	body, err := json.Marshal(map[string]interface{}{
		"username":   cfg.Username,
		"password":   cfg.Password,
		"rememberMe": true,
	})
	if err != nil {
		return nil, "", err
	}

	resp, err := client.DoContext(ctx, sdk.HTTPRequest{
		Method: "POST",
		URL:    client.URL(cfg.normalizedLoginPath()),
		Headers: map[string]string{
			"Content-Type": "application/json",
		},
		Body: body,
	})
	if err != nil {
		return nil, "", err
	}

	if resp.Status != http.StatusOK && resp.Status != http.StatusNoContent {
		return nil, "", fmt.Errorf("login failed with status %d", resp.Status)
	}

	setCookie := headerValue(resp.Headers, "Set-Cookie")
	cookie := extractSessionCookie(setCookie)
	if cookie == "" {
		return nil, "", fmt.Errorf("login response missing session cookie")
	}

	return map[string]string{"Cookie": cookie}, "session_cookie", nil
}

func fetchProtectBootstrap(ctx context.Context, client protectHTTPClient, cfg Config, headers map[string]string) (ProtectBootstrapSnapshot, EndpointResult) {
	path := cfg.normalizedBootstrapPath()
	resp, err := client.DoContext(ctx, sdk.HTTPRequest{
		Method:  "GET",
		URL:     client.URL(path),
		Headers: headers,
	})
	if err != nil {
		return ProtectBootstrapSnapshot{}, EndpointResult{Path: path, Error: err.Error()}
	}

	result := EndpointResult{
		Path:       path,
		Status:     resp.Status,
		DurationMS: resp.Duration.Milliseconds(),
		BodyBytes:  len(resp.Body),
		Body:       string(resp.Body),
		Duration:   resp.Duration,
	}

	if resp.Status != http.StatusOK {
		result.Error = fmt.Sprintf("bootstrap request failed with status %d", resp.Status)
		return ProtectBootstrapSnapshot{}, trimBody(result)
	}

	var payload ProtectBootstrapResponse
	if err := json.Unmarshal(resp.Body, &payload); err != nil {
		result.Error = "invalid bootstrap payload: " + err.Error()
		return ProtectBootstrapSnapshot{}, trimBody(result)
	}

	cameras := payload.Cameras
	if len(cameras) == 0 {
		cameras = payload.Data.Cameras
	}
	lastUpdateID := strings.TrimSpace(payload.LastUpdateID)
	if lastUpdateID == "" {
		lastUpdateID = strings.TrimSpace(payload.Data.LastUpdateID)
	}
	result.CameraCount = len(cameras)
	return ProtectBootstrapSnapshot{
		Cameras:      cameras,
		LastUpdateID: lastUpdateID,
	}, trimBody(result)
}

func fetchProtectSnapshot(
	ctx context.Context,
	client protectHTTPClient,
	cfg Config,
	headers map[string]string,
	authMode string,
	needLastUpdateID bool,
) (ProtectBootstrapSnapshot, []EndpointResult, string) {
	endpoints := make([]EndpointResult, 0, 2)

	integrationSnapshot, integrationResult := fetchProtectIntegrationSnapshot(ctx, client, cfg, headers)
	endpoints = append(endpoints, integrationResult)

	useIntegration := integrationResult.Error == "" && len(integrationSnapshot.Cameras) > 0
	if useIntegration && (authMode == "api_key" || !needLastUpdateID) {
		return integrationSnapshot, endpoints, ""
	}

	bootstrapSnapshot, bootstrapResult := fetchProtectBootstrap(ctx, client, cfg, headers)
	endpoints = append(endpoints, bootstrapResult)

	if bootstrapResult.Error == "" {
		if useIntegration {
			integrationSnapshot.LastUpdateID = bootstrapSnapshot.LastUpdateID
			return integrationSnapshot, endpoints, ""
		}

		return bootstrapSnapshot, endpoints, ""
	}

	if useIntegration {
		return integrationSnapshot, endpoints, ""
	}

	if integrationResult.Error != "" {
		return ProtectBootstrapSnapshot{}, endpoints, integrationResult.Error
	}

	if bootstrapResult.Error != "" {
		return ProtectBootstrapSnapshot{}, endpoints, bootstrapResult.Error
	}

	return bootstrapSnapshot, endpoints, ""
}

func fetchProtectIntegrationSnapshot(
	ctx context.Context,
	client protectHTTPClient,
	cfg Config,
	headers map[string]string,
) (ProtectBootstrapSnapshot, EndpointResult) {
	path := "/proxy/protect/integration/v1/cameras"
	resp, err := client.DoContext(ctx, sdk.HTTPRequest{
		Method:  "GET",
		URL:     client.URL(path),
		Headers: headers,
	})
	if err != nil {
		return ProtectBootstrapSnapshot{}, EndpointResult{Path: path, Error: err.Error()}
	}

	result := EndpointResult{
		Path:       path,
		Status:     resp.Status,
		DurationMS: resp.Duration.Milliseconds(),
		BodyBytes:  len(resp.Body),
		Body:       string(resp.Body),
		Duration:   resp.Duration,
	}

	if resp.Status != http.StatusOK {
		result.Error = fmt.Sprintf("integration camera request failed with status %d", resp.Status)
		return ProtectBootstrapSnapshot{}, trimBody(result)
	}

	var cameras []ProtectCamera
	if err := json.Unmarshal(resp.Body, &cameras); err != nil {
		result.Error = "invalid integration camera payload: " + err.Error()
		return ProtectBootstrapSnapshot{}, trimBody(result)
	}

	for i := range cameras {
		camera := &cameras[i]
		if strings.TrimSpace(camera.Host) == "" {
			camera.Host = strings.TrimSpace(cfg.Host)
		}

		streams, streamErr := fetchProtectIntegrationRTSPSStreams(ctx, client, camera.ID, headers)
		if streamErr != nil {
			continue
		}
		camera.Channels = append(camera.Channels[:0], buildProtectIntegrationChannels(streams)...)
	}

	result.CameraCount = len(cameras)
	return ProtectBootstrapSnapshot{Cameras: cameras}, trimBody(result)
}

func fetchProtectIntegrationRTSPSStreams(
	ctx context.Context,
	client protectHTTPClient,
	cameraID string,
	headers map[string]string,
) (protectRTSPSStreams, error) {
	path := fmt.Sprintf("/proxy/protect/integration/v1/cameras/%s/rtsps-stream", url.PathEscape(strings.TrimSpace(cameraID)))
	resp, err := client.DoContext(ctx, sdk.HTTPRequest{
		Method:  "GET",
		URL:     client.URL(path),
		Headers: headers,
	})
	if err != nil {
		return nil, err
	}
	if resp.Status != http.StatusOK {
		return nil, fmt.Errorf("integration rtsps stream request failed with status %d", resp.Status)
	}

	var streams protectRTSPSStreams
	if err := json.Unmarshal(resp.Body, &streams); err != nil {
		return nil, err
	}
	return streams, nil
}

func buildProtectIntegrationChannels(streams protectRTSPSStreams) []ProtectChannel {
	qualities := []string{"high", "medium", "low", "package"}
	channels := make([]ProtectChannel, 0, len(qualities))
	for _, quality := range qualities {
		raw := streams[quality]
		if raw == nil || strings.TrimSpace(*raw) == "" {
			continue
		}
		channels = append(channels, ProtectChannel{
			ID:         quality,
			Name:       protectQualityLabel(quality),
			RTSPSAlias: strings.TrimSpace(*raw),
		})
	}
	return channels
}

func protectQualityLabel(quality string) string {
	if quality == "" {
		return ""
	}
	return strings.ToUpper(quality[:1]) + quality[1:]
}

func buildProtectStreams(cfg Config, cameras []ProtectCamera) []StreamInfo {
	streams := make([]StreamInfo, 0, len(cameras))
	for _, camera := range cameras {
		for _, channel := range camera.Channels {
			url := buildProtectStreamURL(cfg, camera, channel)
			if url == "" {
				continue
			}
			streamID := strings.TrimSpace(channel.Name)
			if streamID == "" {
				streamID = firstNonEmpty(channel.ID, camera.ID)
			}
			streams = append(streams, StreamInfo{
				ID:                 streamID,
				Protocol:           "rtsp",
				URL:                url,
				AuthMode:           "controller_alias",
				Source:             "protect-bootstrap",
				InsecureSkipVerify: cfg.InsecureSkipVerify,
			})
		}
	}
	return streams
}

func buildProtectCameraDescriptors(
	cfg Config,
	cameras []ProtectCamera,
	networkClients map[string]UniFiNetworkClient,
) []CameraDescriptor {
	descriptors := make([]CameraDescriptor, 0, len(cameras))
	for _, camera := range cameras {
		deviceUID := firstNonEmpty(camera.MAC, camera.ID)
		cameraID := firstNonEmpty(camera.ID, camera.MAC)
		networkClient := networkClients[normalizeMACKey(camera.MAC)]
		cameraHost := firstNonEmpty(
			protectCameraInventoryHost(cfg, camera),
			uniFiNetworkClientInventoryHost(networkClient),
		)
		availabilityStatus, availabilityReason := protectCameraAvailability(camera)
		if deviceUID == "" || cameraID == "" {
			continue
		}

		descriptor := CameraDescriptor{
			DeviceUID:          deviceUID,
			Vendor:             "ubiquiti",
			CameraID:           cameraID,
			IP:                 cameraHost,
			DisplayName:        firstNonEmpty(camera.DisplayName, camera.Name, camera.MarketName, camera.ModelKey, cameraID),
			AvailabilityStatus: availabilityStatus,
			AvailabilityReason: availabilityReason,
			Identity: map[string]interface{}{
				"mac": strings.TrimSpace(camera.MAC),
			},
			Metadata: map[string]interface{}{
				"controller_host":      cfg.Host,
				"plugin_id":            "unifi-protect-camera",
				"camera_state":         camera.State,
				"firmware_version":     camera.FirmwareVersion,
				"is_connected":         camera.IsConnected,
				"insecure_skip_verify": cfg.InsecureSkipVerify,
			},
		}
		if cameraHost != "" {
			descriptor.Metadata["camera_host"] = cameraHost
		}
		if networkClient.ID != "" {
			descriptor.Metadata["network_client_id"] = strings.TrimSpace(networkClient.ID)
		}
		if networkClient.Name != "" || networkClient.DisplayName != "" {
			descriptor.Metadata["network_client_name"] = firstNonEmpty(
				networkClient.DisplayName,
				networkClient.Name,
			)
		}

		for _, channel := range camera.Channels {
			sourceURL := buildProtectStreamURL(cfg, camera, channel)
			if descriptor.SourceURL == "" {
				descriptor.SourceURL = sourceURL
			}
			profileName := strings.TrimSpace(channel.Name)
			if profileName == "" {
				profileName = firstNonEmpty(channel.ID, "default")
			}
			descriptor.StreamProfiles = append(descriptor.StreamProfiles, CameraStreamProfile{
				ProfileName:       profileName,
				VendorProfileID:   strings.TrimSpace(channel.ID),
				SourceURLOverride: sourceURL,
				RTSPTransport:     "tcp",
				CodecHint:         "h264",
				Metadata: map[string]interface{}{
					"source":               "protect-bootstrap",
					"width":                channel.Width,
					"height":               channel.Height,
					"fps":                  channel.FPS,
					"bitrate":              channel.Bitrate,
					"rtsp_alias":           channel.RTSPAlias,
					"rtsps_alias":          channel.RTSPSAlias,
					"insecure_skip_verify": cfg.InsecureSkipVerify,
				},
			})
		}

		descriptors = append(descriptors, descriptor)
	}
	return descriptors
}

func fetchUniFiNetworkClients(
	ctx context.Context,
	client protectHTTPClient,
	headers map[string]string,
	cfg Config,
	cameras []ProtectCamera,
) (map[string]UniFiNetworkClient, []EndpointResult) {
	needed := neededCameraMACsForNetworkLookup(cfg, cameras)
	if len(needed) == 0 {
		return nil, nil
	}

	sites, siteResult, err := fetchUniFiNetworkSites(ctx, client, headers)
	endpoints := []EndpointResult{siteResult}
	if err != nil || len(sites) == 0 {
		return nil, endpoints
	}

	matches := make(map[string]UniFiNetworkClient, len(needed))
	for _, site := range sites {
		siteMatches, siteEndpoints := fetchUniFiNetworkSiteClientMatches(ctx, client, headers, site.ID, needed)
		endpoints = append(endpoints, siteEndpoints...)
		for mac, networkClient := range siteMatches {
			existing, exists := matches[mac]
			if !exists || uniFiNetworkClientScore(networkClient) > uniFiNetworkClientScore(existing) {
				matches[mac] = networkClient
			}
		}
	}

	if len(matches) == 0 {
		return nil, endpoints
	}

	return matches, endpoints
}

func fetchUniFiNetworkSites(
	ctx context.Context,
	client protectHTTPClient,
	headers map[string]string,
) ([]UniFiNetworkSite, EndpointResult, error) {
	path := "/proxy/network/integration/v1/sites"
	resp, err := client.DoContext(ctx, sdk.HTTPRequest{
		Method:  "GET",
		URL:     client.URL(path),
		Headers: headers,
	})
	if err != nil {
		return nil, EndpointResult{Path: path, Error: err.Error()}, err
	}

	result := EndpointResult{
		Path:       path,
		Status:     resp.Status,
		DurationMS: resp.Duration.Milliseconds(),
		BodyBytes:  len(resp.Body),
		Body:       string(resp.Body),
		Duration:   resp.Duration,
	}

	if resp.Status != http.StatusOK {
		result.Error = fmt.Sprintf("network sites request failed with status %d", resp.Status)
		return nil, trimBody(result), fmt.Errorf("%s", result.Error)
	}

	var payload uniFiNetworkSitesResponse
	if err := json.Unmarshal(resp.Body, &payload); err != nil {
		result.Error = "invalid network sites payload: " + err.Error()
		return nil, trimBody(result), err
	}

	return payload.Data, trimBody(result), nil
}

func fetchUniFiNetworkSiteClientMatches(
	ctx context.Context,
	client protectHTTPClient,
	headers map[string]string,
	siteID string,
	needed map[string]struct{},
) (map[string]UniFiNetworkClient, []EndpointResult) {
	const limit = 200

	matches := make(map[string]UniFiNetworkClient, len(needed))
	endpoints := make([]EndpointResult, 0, 4)

	for offset := 0; ; offset += limit {
		page, pageResult, err := fetchUniFiNetworkClientPage(ctx, client, headers, siteID, offset, limit)
		endpoints = append(endpoints, pageResult)
		if err != nil {
			return matches, endpoints
		}

		for _, summary := range page.Data {
			mac := normalizeMACKey(firstNonEmpty(summary.MACAddress, summary.MAC))
			if mac == "" {
				continue
			}
			if _, wanted := needed[mac]; !wanted {
				continue
			}

			networkClient := summary
			if uniFiNetworkClientInventoryHost(networkClient) == "" && strings.TrimSpace(networkClient.ID) != "" {
				detail, detailResult, detailErr := fetchUniFiNetworkClientDetail(ctx, client, headers, siteID, networkClient.ID)
				endpoints = append(endpoints, detailResult)
				if detailErr == nil {
					networkClient = mergeUniFiNetworkClient(summary, detail)
				}
			}

			existing, exists := matches[mac]
			if !exists || uniFiNetworkClientScore(networkClient) > uniFiNetworkClientScore(existing) {
				matches[mac] = networkClient
			}
		}

		if len(page.Data) == 0 || len(page.Data) < limit || offset+len(page.Data) >= page.TotalCount {
			break
		}
	}

	return matches, endpoints
}

func fetchUniFiNetworkClientPage(
	ctx context.Context,
	client protectHTTPClient,
	headers map[string]string,
	siteID string,
	offset int,
	limit int,
) (uniFiNetworkClientsResponse, EndpointResult, error) {
	path := fmt.Sprintf(
		"/proxy/network/integration/v1/sites/%s/clients?offset=%d&limit=%d",
		url.PathEscape(strings.TrimSpace(siteID)),
		offset,
		limit,
	)
	resp, err := client.DoContext(ctx, sdk.HTTPRequest{
		Method:  "GET",
		URL:     client.URL(path),
		Headers: headers,
	})
	if err != nil {
		return uniFiNetworkClientsResponse{}, EndpointResult{Path: path, Error: err.Error()}, err
	}

	result := EndpointResult{
		Path:       path,
		Status:     resp.Status,
		DurationMS: resp.Duration.Milliseconds(),
		BodyBytes:  len(resp.Body),
		Body:       string(resp.Body),
		Duration:   resp.Duration,
	}

	if resp.Status != http.StatusOK {
		result.Error = fmt.Sprintf("network clients request failed with status %d", resp.Status)
		return uniFiNetworkClientsResponse{}, trimBody(result), fmt.Errorf("%s", result.Error)
	}

	var payload uniFiNetworkClientsResponse
	if err := json.Unmarshal(resp.Body, &payload); err != nil {
		result.Error = "invalid network clients payload: " + err.Error()
		return uniFiNetworkClientsResponse{}, trimBody(result), err
	}

	return payload, trimBody(result), nil
}

func fetchUniFiNetworkClientDetail(
	ctx context.Context,
	client protectHTTPClient,
	headers map[string]string,
	siteID string,
	clientID string,
) (UniFiNetworkClient, EndpointResult, error) {
	path := fmt.Sprintf(
		"/proxy/network/integration/v1/sites/%s/clients/%s",
		url.PathEscape(strings.TrimSpace(siteID)),
		url.PathEscape(strings.TrimSpace(clientID)),
	)
	resp, err := client.DoContext(ctx, sdk.HTTPRequest{
		Method:  "GET",
		URL:     client.URL(path),
		Headers: headers,
	})
	if err != nil {
		return UniFiNetworkClient{}, EndpointResult{Path: path, Error: err.Error()}, err
	}

	result := EndpointResult{
		Path:       path,
		Status:     resp.Status,
		DurationMS: resp.Duration.Milliseconds(),
		BodyBytes:  len(resp.Body),
		Body:       string(resp.Body),
		Duration:   resp.Duration,
	}

	if resp.Status != http.StatusOK {
		result.Error = fmt.Sprintf("network client detail request failed with status %d", resp.Status)
		return UniFiNetworkClient{}, trimBody(result), fmt.Errorf("%s", result.Error)
	}

	var payload UniFiNetworkClient
	if err := json.Unmarshal(resp.Body, &payload); err != nil {
		result.Error = "invalid network client detail payload: " + err.Error()
		return UniFiNetworkClient{}, trimBody(result), err
	}

	return payload, trimBody(result), nil
}

func neededCameraMACsForNetworkLookup(cfg Config, cameras []ProtectCamera) map[string]struct{} {
	needed := make(map[string]struct{})
	for _, camera := range cameras {
		if protectCameraInventoryHost(cfg, camera) != "" {
			continue
		}
		mac := normalizeMACKey(camera.MAC)
		if mac == "" {
			continue
		}
		needed[mac] = struct{}{}
	}
	return needed
}

func mergeUniFiNetworkClient(summary, detail UniFiNetworkClient) UniFiNetworkClient {
	return UniFiNetworkClient{
		ID:          firstNonEmpty(detail.ID, summary.ID),
		MACAddress:  firstNonEmpty(detail.MACAddress, summary.MACAddress),
		MAC:         firstNonEmpty(detail.MAC, summary.MAC),
		IPAddress:   firstNonEmpty(detail.IPAddress, summary.IPAddress),
		IP:          firstNonEmpty(detail.IP, summary.IP),
		Hostname:    firstNonEmpty(detail.Hostname, summary.Hostname),
		Name:        firstNonEmpty(detail.Name, summary.Name),
		DisplayName: firstNonEmpty(detail.DisplayName, summary.DisplayName),
	}
}

func uniFiNetworkClientInventoryHost(networkClient UniFiNetworkClient) string {
	return firstNonEmpty(networkClient.IPAddress, networkClient.IP)
}

func uniFiNetworkClientScore(networkClient UniFiNetworkClient) int {
	score := 0
	if uniFiNetworkClientInventoryHost(networkClient) != "" {
		score += 10
	}
	if firstNonEmpty(networkClient.Hostname, networkClient.Name, networkClient.DisplayName) != "" {
		score++
	}
	return score
}

func protectCameraAvailability(camera ProtectCamera) (string, string) {
	state := strings.ToUpper(strings.TrimSpace(camera.State))

	switch {
	case state == "CONNECTED" || (state == "" && camera.IsConnected):
		return "available", "UniFi Protect state CONNECTED"
	case state == "DISCONNECTED" || (!camera.IsConnected && state == ""):
		return "unavailable", "UniFi Protect state DISCONNECTED"
	case state == "":
		return "degraded", "UniFi Protect camera state is unknown"
	default:
		return "degraded", fmt.Sprintf("UniFi Protect state %s", state)
	}
}

func protectCameraInventoryHost(cfg Config, camera ProtectCamera) string {
	host := firstNonEmpty(
		strings.TrimSpace(camera.ConnectionHost),
		strings.TrimSpace(camera.Host),
	)
	controllerHost := strings.TrimSpace(cfg.Host)

	if host == "" || strings.EqualFold(host, controllerHost) {
		return ""
	}

	return host
}

func resolveProtectStreamSourceURL(ctx context.Context, cfg StreamConfig, client protectHTTPClient, headers map[string]string) (string, error) {
	if strings.TrimSpace(cfg.Relay.SourceURL) != "" {
		return strings.TrimSpace(cfg.Relay.SourceURL), nil
	}
	if strings.TrimSpace(cfg.Relay.CameraSourceID) == "" {
		return "", fmt.Errorf("camera_source_id is required when source_url is not provided")
	}
	if strings.TrimSpace(cfg.Relay.StreamProfileID) == "" {
		return "", fmt.Errorf("stream_profile_id is required when source_url is not provided")
	}

	authMode := "none"
	if strings.TrimSpace(cfg.Config.APIKey) != "" {
		authMode = "api_key"
	}
	bootstrap, _, snapshotErr := fetchProtectSnapshot(ctx, client, cfg.Config, headers, authMode, false)
	if snapshotErr != "" {
		return "", fmt.Errorf("%s", snapshotErr)
	}

	for _, camera := range bootstrap.Cameras {
		if cfg.Relay.CameraSourceID != "" && cfg.Relay.CameraSourceID != camera.ID && cfg.Relay.CameraSourceID != camera.MAC {
			continue
		}
		for _, channel := range camera.Channels {
			if !protectChannelMatchesRelay(cfg.Relay, channel) {
				continue
			}
			if url := buildProtectStreamURL(cfg.Config, camera, channel); url != "" {
				return url, nil
			}
		}
	}

	return "", fmt.Errorf("no RTSP stream URL available for requested Protect camera")
}

func buildProtectStreamURL(cfg Config, camera ProtectCamera, channel ProtectChannel) string {
	alias := strings.TrimSpace(channel.RTSPAlias)
	if alias == "" {
		if direct := strings.TrimSpace(channel.RTSPSAlias); direct != "" {
			return sanitizeProtectStreamURL(direct)
		}
		return ""
	}
	host := firstNonEmpty(
		strings.TrimSpace(camera.ConnectionHost),
		strings.TrimSpace(camera.Host),
	)
	if host == "" {
		host = strings.TrimSpace(cfg.Host)
	}
	if host == "" {
		return ""
	}
	return sanitizeProtectStreamURL(
		fmt.Sprintf("rtsp://%s:%d/%s", host, cfg.normalizedRTSPPort(), strings.TrimPrefix(alias, "/")),
	)
}

func sanitizeProtectStreamURL(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}

	parsed, err := url.Parse(raw)
	if err != nil {
		return raw
	}

	query := parsed.Query()
	query.Del("enableSrtp")
	parsed.RawQuery = query.Encode()

	return parsed.String()
}

func protectChannelMatchesRelay(relay RelayConfig, channel ProtectChannel) bool {
	profileID := strings.TrimSpace(relay.StreamProfileID)
	if profileID == "" {
		return true
	}

	if profileID == strings.TrimSpace(channel.ID) {
		return true
	}
	if profileID == strings.TrimSpace(channel.Name) {
		return true
	}

	return false
}

func collectProtectEvents(
	cfg Config,
	headers map[string]string,
	timeout time.Duration,
	lastUpdateID string,
	authMode string,
) ([]sdk.OCSFEvent, EndpointResult) {
	scheme, err := cfg.NormalizedScheme()
	if err != nil {
		return nil, EndpointResult{Error: err.Error()}
	}

	wsPath := "/proxy/protect/ws/updates"
	query := ""
	if authMode == "api_key" {
		wsPath = "/proxy/protect/integration/v1/subscribe/events"
	} else {
		lastUpdateID = strings.TrimSpace(lastUpdateID)
		if lastUpdateID == "" {
			return nil, EndpointResult{Path: wsPath, Error: "bootstrap payload missing lastUpdateId"}
		}
		query = "?lastUpdateId=" + url.QueryEscape(lastUpdateID)
	}

	result := EndpointResult{Path: wsPath}
	wsScheme := "ws"
	if scheme == "https" {
		wsScheme = "wss"
	}

	wsURL := fmt.Sprintf("%s://%s%s%s", wsScheme, strings.TrimSpace(cfg.Host), wsPath, query)
	conn, err := protectEventDial(wsURL, headers, cfg.InsecureSkipVerify, timeout)
	if err != nil {
		result.Error = "websocket connect failed: " + err.Error()
		return nil, result
	}
	defer func() { _ = conn.Close() }()

	events := make([]sdk.OCSFEvent, 0, 4)
	buf := make([]byte, 64*1024)
	for i := 0; i < 4; i++ {
		n, recvErr := conn.Recv(buf, 800*time.Millisecond)
		if recvErr != nil || n <= 0 {
			break
		}
		if evt := mapProtectWSEvent(buf[:n]); evt != nil {
			events = append(events, *evt)
		}
	}

	result.Status = http.StatusOK
	result.EventCount = len(events)
	return events, result
}

type testProtectHTTPClient struct {
	BaseURL    string
	Timeout    time.Duration
	AuthHeader string
	HTTPClient *http.Client
}

func (c *testProtectHTTPClient) URL(path string) string {
	return c.BaseURL + path
}

func (c *testProtectHTTPClient) DoContext(ctx context.Context, req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	client := c.HTTPClient
	if client == nil {
		client = http.DefaultClient
	}

	body := io.Reader(nil)
	if len(req.Body) > 0 {
		body = strings.NewReader(string(req.Body))
	}

	httpReq, err := http.NewRequestWithContext(ctx, req.Method, req.URL, body)
	if err != nil {
		return nil, err
	}
	for key, value := range req.Headers {
		httpReq.Header.Set(key, value)
	}
	if c.AuthHeader != "" && httpReq.Header.Get("Authorization") == "" {
		httpReq.Header.Set("Authorization", c.AuthHeader)
	}

	start := time.Now()
	resp, err := client.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	headers := make(map[string]string, len(resp.Header))
	for key, values := range resp.Header {
		headers[key] = strings.Join(values, ", ")
	}

	return &sdk.HTTPResponse{
		Status:   resp.StatusCode,
		Headers:  headers,
		Body:     respBody,
		Duration: time.Since(start),
	}, nil
}

func mapProtectWSEvent(data []byte) *sdk.OCSFEvent {
	var payload map[string]interface{}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil
	}

	message, severity := describeProtectEvent(payload)
	event := sdk.NewOCSFEventLogActivity(message, severity)
	event.LogProvider = "unifi-protect-camera"
	event.RawData = string(data)
	if event.Unmapped == nil {
		event.Unmapped = map[string]interface{}{}
	}
	event.Unmapped["protect_ws_payload"] = payload

	if obj, ok := eventObject(payload); ok {
		device := map[string]any{}
		if id := mapString(obj, "id"); id != "" {
			device["uid"] = id
		}
		if name := firstNonEmpty(mapString(obj, "displayName"), mapString(obj, "name"), mapString(payload, "id")); name != "" {
			device["name"] = name
		}
		if mac := mapString(obj, "mac"); mac != "" {
			device["mac"] = mac
		}
		if len(device) > 0 {
			event.Device = device
		}
	}

	return &event
}

func describeProtectEvent(payload map[string]interface{}) (string, sdk.Severity) {
	modelKey := firstNonEmpty(mapString(payload, "modelKey"), mapStringFromNested(payload, "newObj", "modelKey"))
	action := strings.ToLower(firstNonEmpty(mapString(payload, "action"), "update"))
	deviceName := firstNonEmpty(
		mapStringFromNested(payload, "newObj", "displayName"),
		mapStringFromNested(payload, "newObj", "name"),
		mapString(payload, "id"),
	)

	message := "UniFi Protect event"
	if modelKey != "" {
		message = "UniFi Protect " + modelKey + " " + action
	}
	if deviceName != "" {
		message += " for " + deviceName
	}

	changed := mapNested(payload, "changedData")
	if len(changed) == 0 {
		changed = mapNested(payload, "newObj", "changedData")
	}

	severity := sdk.SeverityInfo
	switch {
	case mapHasKey(changed, "lastRing"):
		message = "UniFi Protect doorbell ring"
		if deviceName != "" {
			message += " for " + deviceName
		}
		severity = sdk.SeverityWarning
	case mapHasKey(changed, "smartDetectTypes") || mapHasKey(changed, "lastSmartDetect"):
		message = "UniFi Protect smart detection"
		if deviceName != "" {
			message += " for " + deviceName
		}
		severity = sdk.SeverityWarning
	case mapHasKey(changed, "lastMotion") || truthy(changed["isMotionDetected"]):
		message = "UniFi Protect motion event"
		if deviceName != "" {
			message += " for " + deviceName
		}
		severity = sdk.SeverityWarning
	}

	return message, severity
}

func eventObject(payload map[string]interface{}) (map[string]interface{}, bool) {
	if obj := mapNested(payload, "newObj"); len(obj) > 0 {
		return obj, true
	}
	if obj := mapNested(payload, "oldObj"); len(obj) > 0 {
		return obj, true
	}
	return nil, false
}

func extractSessionCookie(header string) string {
	header = strings.TrimSpace(header)
	if header == "" {
		return ""
	}

	parts := strings.Split(header, ";")
	if len(parts) == 0 {
		return ""
	}
	return strings.TrimSpace(parts[0])
}

func headerValue(headers map[string]string, key string) string {
	for candidate, value := range headers {
		if strings.EqualFold(strings.TrimSpace(candidate), key) {
			return value
		}
	}
	return ""
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			return value
		}
	}
	return ""
}

func normalizeMACKey(value string) string {
	value = strings.ToUpper(strings.TrimSpace(value))
	if value == "" {
		return ""
	}
	replacer := strings.NewReplacer(":", "", "-", "", ".", "")
	return replacer.Replace(value)
}

func mapString(m map[string]interface{}, key string) string {
	if m == nil {
		return ""
	}
	value, ok := m[key]
	if !ok {
		return ""
	}
	text, _ := value.(string)
	return strings.TrimSpace(text)
}

func mapStringFromNested(m map[string]interface{}, keys ...string) string {
	return mapString(mapNested(m, keys[:len(keys)-1]...), keys[len(keys)-1])
}

func mapNested(m map[string]interface{}, keys ...string) map[string]interface{} {
	current := m
	for _, key := range keys {
		if current == nil {
			return nil
		}
		next, ok := current[key].(map[string]interface{})
		if !ok {
			return nil
		}
		current = next
	}
	return current
}

func mapHasKey(m map[string]interface{}, key string) bool {
	if m == nil {
		return false
	}
	_, ok := m[key]
	return ok
}

func truthy(value interface{}) bool {
	boolean, ok := value.(bool)
	return ok && boolean
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
