package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/sdk"
	"github.com/gorilla/websocket"
)

func TestBuildProtectStreamURL(t *testing.T) {
	cfg := Config{RTSPPort: 7447, CameraPluginConfig: sdk.CameraPluginConfig{Host: "udm.local"}}
	camera := ProtectCamera{Host: "camera-relay.local"}
	channel := ProtectChannel{RTSPAlias: "abcdef"}

	got := buildProtectStreamURL(cfg, camera, channel)
	want := "rtsp://camera-relay.local:7447/abcdef"
	if got != want {
		t.Fatalf("expected %q, got %q", want, got)
	}
}

func TestExtractSessionCookie(t *testing.T) {
	got := extractSessionCookie("TOKEN=abc123; Path=/; HttpOnly")
	if got != "TOKEN=abc123" {
		t.Fatalf("unexpected cookie: %q", got)
	}
}

func TestBuildProtectCameraDescriptors(t *testing.T) {
	cfg := Config{RTSPPort: 7447, CameraPluginConfig: sdk.CameraPluginConfig{Host: "udm.local"}}
	cameras := []ProtectCamera{
		{
			ID:          "camera-1",
			MAC:         "aa:bb:cc:dd:ee:ff",
			Name:        "Front Door",
			MarketName:  "G4 Bullet",
			ModelKey:    "uvc-g4-bullet",
			State:       "CONNECTED",
			IsConnected: true,
			Channels: []ProtectChannel{
				{ID: "0", Name: "High", RTSPAlias: "stream-alias", Width: 1920, Height: 1080, FPS: 24},
			},
		},
	}

	descriptors := buildProtectCameraDescriptors(cfg, cameras)
	if len(descriptors) != 1 {
		t.Fatalf("expected 1 descriptor, got %d", len(descriptors))
	}

	descriptor := descriptors[0]
	if descriptor.DeviceUID != "aa:bb:cc:dd:ee:ff" {
		t.Fatalf("unexpected device uid: %s", descriptor.DeviceUID)
	}
	if descriptor.Vendor != "ubiquiti" {
		t.Fatalf("unexpected vendor: %s", descriptor.Vendor)
	}
	if descriptor.SourceURL != "rtsp://udm.local:7447/stream-alias" {
		t.Fatalf("unexpected source URL: %s", descriptor.SourceURL)
	}
	if len(descriptor.StreamProfiles) != 1 {
		t.Fatalf("expected 1 stream profile, got %d", len(descriptor.StreamProfiles))
	}
}

func TestResolveProtectStreamSourceURLPrefersRelaySource(t *testing.T) {
	cfg := StreamConfig{
		Config: Config{CameraPluginConfig: sdk.CameraPluginConfig{Host: "udm.local"}},
		Relay:  RelayConfig{SourceURL: "rtsp://custom.local:7447/direct"},
	}

	got, err := resolveProtectStreamSourceURL(nil, cfg, nil, nil)
	if err != nil {
		t.Fatalf("expected direct source URL, got error %v", err)
	}
	if got != "rtsp://custom.local:7447/direct" {
		t.Fatalf("unexpected direct source URL: %s", got)
	}
}

func TestResolveProtectStreamSourceURLRequiresCameraSourceID(t *testing.T) {
	cfg := StreamConfig{
		Config: Config{CameraPluginConfig: sdk.CameraPluginConfig{Host: "udm.local"}},
		Relay:  RelayConfig{StreamProfileID: "high"},
	}

	_, err := resolveProtectStreamSourceURL(context.Background(), cfg, nil, nil)
	if err == nil || err.Error() != "camera_source_id is required when source_url is not provided" {
		t.Fatalf("unexpected error %v", err)
	}
}

func TestResolveProtectStreamSourceURLRequiresStreamProfileID(t *testing.T) {
	cfg := StreamConfig{
		Config: Config{CameraPluginConfig: sdk.CameraPluginConfig{Host: "udm.local"}},
		Relay:  RelayConfig{CameraSourceID: "camera-1"},
	}

	_, err := resolveProtectStreamSourceURL(context.Background(), cfg, nil, nil)
	if err == nil || err.Error() != "stream_profile_id is required when source_url is not provided" {
		t.Fatalf("unexpected error %v", err)
	}
}

func TestProtectChannelMatchesRelay(t *testing.T) {
	channel := ProtectChannel{ID: "channel-high", Name: "High"}

	if !protectChannelMatchesRelay(RelayConfig{}, channel) {
		t.Fatalf("expected empty relay profile to match")
	}
	if !protectChannelMatchesRelay(RelayConfig{StreamProfileID: "channel-high"}, channel) {
		t.Fatalf("expected channel id match")
	}
	if !protectChannelMatchesRelay(RelayConfig{StreamProfileID: "High"}, channel) {
		t.Fatalf("expected channel name match")
	}
	if protectChannelMatchesRelay(RelayConfig{StreamProfileID: "Low"}, channel) {
		t.Fatalf("expected mismatched profile to fail")
	}
}

func TestMapProtectWSEventMotion(t *testing.T) {
	payload := []byte(`{
		"action":"update",
		"modelKey":"camera",
		"id":"camera-1",
		"newObj":{"id":"camera-1","name":"Front Door","mac":"aa:bb:cc"},
		"changedData":{"lastMotion":1710000000,"isMotionDetected":true}
	}`)

	event := mapProtectWSEvent(payload)
	if event == nil {
		t.Fatalf("expected event")
	}
	if event.Message != "UniFi Protect motion event for Front Door" {
		t.Fatalf("unexpected message %q", event.Message)
	}
	if event.Severity != "Medium" {
		t.Fatalf("unexpected severity %q", event.Severity)
	}
	if event.Device["uid"] != "camera-1" {
		t.Fatalf("unexpected device uid %#v", event.Device["uid"])
	}
	if event.LogProvider != "unifi-protect-camera" {
		t.Fatalf("unexpected log provider %q", event.LogProvider)
	}
}

func TestMapProtectWSEventInvalidJSON(t *testing.T) {
	if event := mapProtectWSEvent([]byte("not-json")); event != nil {
		t.Fatalf("expected nil event for invalid payload")
	}
}

func TestProtectBootstrapResponseParsesLastUpdateID(t *testing.T) {
	var payload ProtectBootstrapResponse
	if err := json.Unmarshal([]byte(`{
		"lastUpdateId":"update-123",
		"cameras":[{"id":"camera-1"}]
	}`), &payload); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if payload.LastUpdateID != "update-123" {
		t.Fatalf("unexpected lastUpdateId %q", payload.LastUpdateID)
	}
	if len(payload.Cameras) != 1 {
		t.Fatalf("unexpected camera count %d", len(payload.Cameras))
	}
}

type gorillaProtectEventConn struct {
	conn *websocket.Conn
}

func (c *gorillaProtectEventConn) Recv(buf []byte, timeout time.Duration) (int, error) {
	if err := c.conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		return 0, err
	}
	_, data, err := c.conn.ReadMessage()
	if err != nil {
		return 0, err
	}
	copy(buf, data)
	return len(data), nil
}

func (c *gorillaProtectEventConn) Close() error {
	return c.conn.Close()
}

func TestProtectControllerFixtureLoginBootstrapAndEvents(t *testing.T) {
	upgrader := websocket.Upgrader{}
	var sawLogin bool
	var sawBootstrap bool
	var sawUpdates bool

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/auth/login":
			if r.Method != http.MethodPost {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			sawLogin = true
			http.SetCookie(w, &http.Cookie{Name: "TOKEN", Value: "fixture-token", Path: "/"})
			w.WriteHeader(http.StatusOK)
		case "/proxy/protect/api/bootstrap":
			if got := r.Header.Get("Cookie"); got != "TOKEN=fixture-token" {
				http.Error(w, "missing cookie", http.StatusUnauthorized)
				return
			}
			sawBootstrap = true
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{
				"lastUpdateId":"update-42",
				"cameras":[{
					"id":"camera-1",
					"mac":"aa:bb:cc:dd:ee:ff",
					"host":"camera-relay.local",
					"name":"Front Door",
					"displayName":"Front Door",
					"modelKey":"camera",
					"marketName":"G5 Bullet",
					"state":"CONNECTED",
					"isConnected":true,
					"channels":[{"id":"0","name":"High","rtspAlias":"high-stream","width":1920,"height":1080,"fps":24}]
				}]
			}`))
		case "/proxy/protect/ws/updates":
			if got := r.Header.Get("Cookie"); got != "TOKEN=fixture-token" {
				http.Error(w, "missing cookie", http.StatusUnauthorized)
				return
			}
			if got := r.URL.Query().Get("lastUpdateId"); got != "update-42" {
				http.Error(w, "bad lastUpdateId", http.StatusBadRequest)
				return
			}
			sawUpdates = true
			conn, err := upgrader.Upgrade(w, r, nil)
			if err != nil {
				t.Fatalf("upgrade failed: %v", err)
			}
			defer func() { _ = conn.Close() }()
			_ = conn.WriteJSON(map[string]any{
				"action":   "update",
				"modelKey": "camera",
				"id":       "camera-1",
				"newObj": map[string]any{
					"id":          "camera-1",
					"displayName": "Front Door",
					"mac":         "aa:bb:cc:dd:ee:ff",
				},
				"changedData": map[string]any{
					"lastMotion":       1710000000,
					"isMotionDetected": true,
				},
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	serverURL, err := url.Parse(server.URL)
	if err != nil {
		t.Fatalf("parse server url: %v", err)
	}

	cfg := Config{
		CameraPluginConfig: sdk.CameraPluginConfig{
			Host:            serverURL.Host,
			Scheme:          "http",
			Username:        "local-admin",
			Password:        "secret",
			DiscoverStreams: true,
			CollectEvents:   true,
			EventSources:    "updates",
			Timeout:         "2s",
		},
		BootstrapPath: "/proxy/protect/api/bootstrap",
		LoginPath:     "/api/auth/login",
		RTSPPort:      7447,
	}

	client := &testProtectHTTPClient{
		BaseURL: server.URL,
		Timeout: 2 * time.Second,
		HTTPClient: &http.Client{
			Timeout: 2 * time.Second,
		},
	}

	origDial := protectEventDial
	t.Cleanup(func() {
		protectEventDial = origDial
	})
	protectEventDial = func(rawURL string, headers map[string]string, insecureSkipVerify bool, timeout time.Duration) (protectEventConn, error) {
		if insecureSkipVerify {
			t.Fatalf("expected insecure TLS to default false")
		}
		dialer := websocket.Dialer{HandshakeTimeout: timeout}
		reqHeaders := make(http.Header, len(headers))
		for key, value := range headers {
			reqHeaders.Set(key, value)
		}
		conn, _, err := dialer.Dial(rawURL, reqHeaders)
		if err != nil {
			return nil, err
		}
		return &gorillaProtectEventConn{conn: conn}, nil
	}

	headers, authMode, err := protectSessionHeaders(context.Background(), cfg, client)
	if err != nil {
		t.Fatalf("protectSessionHeaders error: %v", err)
	}
	if authMode != "session_cookie" {
		t.Fatalf("unexpected auth mode %q", authMode)
	}

	bootstrap, bootstrapRes := fetchProtectSnapshot(context.Background(), client, cfg, headers, authMode)
	if bootstrapRes.Error != "" {
		t.Fatalf("bootstrap failed: %s", bootstrapRes.Error)
	}
	if bootstrap.LastUpdateID != "update-42" {
		t.Fatalf("unexpected lastUpdateId %q", bootstrap.LastUpdateID)
	}
	if len(bootstrap.Cameras) != 1 {
		t.Fatalf("unexpected camera count %d", len(bootstrap.Cameras))
	}

	streams := buildProtectStreams(cfg, bootstrap.Cameras)
	if len(streams) != 1 || streams[0].URL != "rtsp://camera-relay.local:7447/high-stream" {
		t.Fatalf("unexpected streams %#v", streams)
	}

	events, eventRes := collectProtectEvents(cfg, headers, 2*time.Second, bootstrap.LastUpdateID, authMode)
	if eventRes.Error != "" {
		t.Fatalf("event collection failed: %s", eventRes.Error)
	}
	if len(events) != 1 {
		t.Fatalf("unexpected event count %d", len(events))
	}
	if events[0].Message != "UniFi Protect motion event for Front Door" {
		t.Fatalf("unexpected event message %q", events[0].Message)
	}

	if !sawLogin || !sawBootstrap || !sawUpdates {
		t.Fatalf("expected full controller fixture flow, got login=%t bootstrap=%t updates=%t", sawLogin, sawBootstrap, sawUpdates)
	}
}

func TestProtectControllerFixtureAPIKeyAndStreamSelection(t *testing.T) {
	t.Parallel()

	var sawBootstrap bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/proxy/protect/integration/v1/cameras":
			if got := r.Header.Get("X-API-Key"); got != "protect-api-key" {
				http.Error(w, "missing api key", http.StatusUnauthorized)
				return
			}
			sawBootstrap = true
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`[
					{
						"id":"camera-1",
						"mac":"aa:bb:cc:dd:ee:ff",
						"host":"camera-a.local",
						"name":"Front Door"
					},
					{
						"id":"camera-2",
						"mac":"11:22:33:44:55:66",
						"host":"camera-b.local",
						"name":"Garage"
					}
				]`))
		case "/proxy/protect/integration/v1/cameras/camera-1/rtsps-stream":
			if got := r.Header.Get("X-API-Key"); got != "protect-api-key" {
				http.Error(w, "missing api key", http.StatusUnauthorized)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"low":"rtsps://camera-a.local:7441/low-stream","high":"rtsps://camera-a.local:7441/high-stream"}`))
		case "/proxy/protect/integration/v1/cameras/camera-2/rtsps-stream":
			if got := r.Header.Get("X-API-Key"); got != "protect-api-key" {
				http.Error(w, "missing api key", http.StatusUnauthorized)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"high":"rtsps://camera-b.local:7441/garage-high"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	serverURL, err := url.Parse(server.URL)
	if err != nil {
		t.Fatalf("parse server url: %v", err)
	}

	cfg := Config{
		CameraPluginConfig: sdk.CameraPluginConfig{
			Host:    serverURL.Host,
			Scheme:  "http",
			Timeout: "2s",
		},
		APIKey:        "protect-api-key",
		BootstrapPath: "/proxy/protect/api/bootstrap",
		RTSPPort:      7447,
	}

	client := &testProtectHTTPClient{
		BaseURL: server.URL,
		Timeout: 2 * time.Second,
		HTTPClient: &http.Client{
			Timeout: 2 * time.Second,
		},
	}

	headers, authMode, err := protectSessionHeaders(context.Background(), cfg, client)
	if err != nil {
		t.Fatalf("protectSessionHeaders error: %v", err)
	}
	if authMode != "api_key" {
		t.Fatalf("unexpected auth mode %q", authMode)
	}

	sourceURL, err := resolveProtectStreamSourceURL(context.Background(), StreamConfig{
		Config: cfg,
		Relay: RelayConfig{
			CameraSourceID:  "camera-1",
			StreamProfileID: "high",
		},
	}, client, headers)
	if err != nil {
		t.Fatalf("resolveProtectStreamSourceURL error: %v", err)
	}
	if sourceURL != "rtsps://camera-a.local:7441/high-stream" {
		t.Fatalf("unexpected selected source URL %q", sourceURL)
	}
	if !sawBootstrap {
		t.Fatalf("expected bootstrap request")
	}
}

func TestProtectControllerFixtureCookieBootstrap(t *testing.T) {
	t.Parallel()

	var sawBootstrap bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/proxy/protect/api/bootstrap":
			if got := r.Header.Get("Cookie"); got != "TOKEN=cookie-fixture" {
				http.Error(w, "missing cookie", http.StatusUnauthorized)
				return
			}
			sawBootstrap = true
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{
				"lastUpdateId":"cookie-update",
				"cameras":[{"id":"camera-1","channels":[{"id":"high","name":"High","rtspAlias":"high-stream"}]}]
			}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	serverURL, err := url.Parse(server.URL)
	if err != nil {
		t.Fatalf("parse server url: %v", err)
	}

	cfg := Config{
		CameraPluginConfig: sdk.CameraPluginConfig{
			Host:   serverURL.Host,
			Scheme: "http",
		},
		Cookie:        "TOKEN=cookie-fixture",
		BootstrapPath: "/proxy/protect/api/bootstrap",
	}
	client := &testProtectHTTPClient{BaseURL: server.URL, Timeout: 2 * time.Second}

	headers, authMode, err := protectSessionHeaders(context.Background(), cfg, client)
	if err != nil {
		t.Fatalf("protectSessionHeaders error: %v", err)
	}
	if authMode != "cookie" {
		t.Fatalf("unexpected auth mode %q", authMode)
	}

	bootstrap, bootstrapRes := fetchProtectSnapshot(context.Background(), client, cfg, headers, authMode)
	if bootstrapRes.Error != "" {
		t.Fatalf("bootstrap failed: %s", bootstrapRes.Error)
	}
	if bootstrap.LastUpdateID != "cookie-update" {
		t.Fatalf("unexpected lastUpdateId %q", bootstrap.LastUpdateID)
	}
	if !sawBootstrap {
		t.Fatalf("expected bootstrap request")
	}
}

func TestFetchProtectBootstrapUnauthorized(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	}))
	defer server.Close()

	serverURL, err := url.Parse(server.URL)
	if err != nil {
		t.Fatalf("parse server url: %v", err)
	}

	cfg := Config{
		CameraPluginConfig: sdk.CameraPluginConfig{
			Host:   serverURL.Host,
			Scheme: "http",
		},
		BootstrapPath: "/proxy/protect/api/bootstrap",
	}
	client := &testProtectHTTPClient{BaseURL: server.URL, Timeout: 2 * time.Second}

	_, result := fetchProtectBootstrap(context.Background(), client, cfg, map[string]string{"Cookie": "TOKEN=bad"})
	if result.Error != "bootstrap request failed with status 401" {
		t.Fatalf("unexpected bootstrap error %q", result.Error)
	}
}

func TestCollectProtectEventsReportsStaleLastUpdateID(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/proxy/protect/ws/updates":
			http.Error(w, "stale update id", http.StatusBadRequest)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	serverURL, err := url.Parse(server.URL)
	if err != nil {
		t.Fatalf("parse server url: %v", err)
	}

	cfg := Config{CameraPluginConfig: sdk.CameraPluginConfig{Host: serverURL.Host, Scheme: "http"}}

	origDial := protectEventDial
	t.Cleanup(func() {
		protectEventDial = origDial
	})
	protectEventDial = func(rawURL string, headers map[string]string, insecureSkipVerify bool, timeout time.Duration) (protectEventConn, error) {
		if insecureSkipVerify {
			t.Fatalf("expected insecure TLS to default false")
		}
		dialer := websocket.Dialer{HandshakeTimeout: timeout}
		reqHeaders := make(http.Header, len(headers))
		for key, value := range headers {
			reqHeaders.Set(key, value)
		}
		conn, _, err := dialer.Dial(rawURL, reqHeaders)
		if err != nil {
			return nil, err
		}
		return &gorillaProtectEventConn{conn: conn}, nil
	}

	events, result := collectProtectEvents(cfg, map[string]string{"Cookie": "TOKEN=fixture"}, 2*time.Second, "stale-update", "session_cookie")
	if len(events) != 0 {
		t.Fatalf("expected no events, got %d", len(events))
	}
	if result.Error == "" {
		t.Fatalf("expected websocket connect failure for stale update id")
	}
}

func TestResolveProtectStreamSourceURLErrorsOnMissingRequestedProfile(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/proxy/protect/api/bootstrap":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{
				"lastUpdateId":"update-88",
				"cameras":[
					{
						"id":"camera-1",
						"host":"camera-a.local",
						"channels":[{"id":"low","name":"Low","rtspAlias":"low-stream"}]
					}
				]
			}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	serverURL, err := url.Parse(server.URL)
	if err != nil {
		t.Fatalf("parse server url: %v", err)
	}

	cfg := Config{
		CameraPluginConfig: sdk.CameraPluginConfig{
			Host:   serverURL.Host,
			Scheme: "http",
		},
		APIKey:        "protect-api-key",
		BootstrapPath: "/proxy/protect/api/bootstrap",
		RTSPPort:      7447,
	}
	client := &testProtectHTTPClient{BaseURL: server.URL, Timeout: 2 * time.Second}

	sourceURL, err := resolveProtectStreamSourceURL(context.Background(), StreamConfig{
		Config: cfg,
		Relay: RelayConfig{
			CameraSourceID:  "camera-1",
			StreamProfileID: "high",
		},
	}, client, map[string]string{"X-API-Key": "protect-api-key"})
	if err == nil {
		t.Fatalf("expected missing profile error, got source URL %q", sourceURL)
	}
}

func TestResolveProtectStreamSourceURLFallsBackToControllerHost(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/proxy/protect/api/bootstrap":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{
				"lastUpdateId":"update-99",
				"cameras":[
					{
						"id":"camera-1",
						"channels":[{"id":"high","name":"High","rtspAlias":"high-stream"}]
					}
				]
			}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	serverURL, err := url.Parse(server.URL)
	if err != nil {
		t.Fatalf("parse server url: %v", err)
	}

	cfg := Config{
		CameraPluginConfig: sdk.CameraPluginConfig{
			Host:   serverURL.Hostname(),
			Scheme: "http",
		},
		BootstrapPath: "/proxy/protect/api/bootstrap",
		RTSPPort:      7447,
	}
	client := &testProtectHTTPClient{BaseURL: server.URL, Timeout: 2 * time.Second}

	sourceURL, err := resolveProtectStreamSourceURL(context.Background(), StreamConfig{
		Config: cfg,
		Relay: RelayConfig{
			CameraSourceID:  "camera-1",
			StreamProfileID: "high",
		},
	}, client, nil)
	if err != nil {
		t.Fatalf("resolveProtectStreamSourceURL error: %v", err)
	}
	if sourceURL != "rtsp://"+serverURL.Hostname()+":7447/high-stream" {
		t.Fatalf("unexpected fallback source URL %q", sourceURL)
	}
}
