package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/sdk"
	"github.com/gorilla/websocket"
)

func TestProtectLiveControllerSmoke(t *testing.T) {
	host := strings.TrimSpace(os.Getenv("UNIFI_PROTECT_LIVE_HOST"))
	if host == "" {
		t.Skip("set UNIFI_PROTECT_LIVE_HOST to run live Protect smoke validation")
	}

	cfg := Config{
		CameraPluginConfig: sdk.CameraPluginConfig{
			Host:               host,
			Scheme:             envOrDefault("UNIFI_PROTECT_LIVE_SCHEME", "https"),
			Username:           os.Getenv("UNIFI_PROTECT_LIVE_USERNAME"),
			Password:           os.Getenv("UNIFI_PROTECT_LIVE_PASSWORD"),
			InsecureSkipVerify: envBool("UNIFI_PROTECT_LIVE_INSECURE"),
			DiscoverStreams:    true,
			CollectEvents:      envBool("UNIFI_PROTECT_LIVE_COLLECT_EVENTS"),
			EventSources:       envOrDefault("UNIFI_PROTECT_LIVE_EVENT_SOURCES", "updates"),
			Timeout:            envOrDefault("UNIFI_PROTECT_LIVE_TIMEOUT", "10s"),
		},
		APIKey:        os.Getenv("UNIFI_PROTECT_LIVE_API_KEY"),
		Cookie:        os.Getenv("UNIFI_PROTECT_LIVE_COOKIE"),
		BootstrapPath: envOrDefault("UNIFI_PROTECT_LIVE_BOOTSTRAP_PATH", "/proxy/protect/api/bootstrap"),
		LoginPath:     envOrDefault("UNIFI_PROTECT_LIVE_LOGIN_PATH", "/api/auth/login"),
		RTSPPort:      envIntOrDefault("UNIFI_PROTECT_LIVE_RTSP_PORT", 7447),
	}

	if strings.TrimSpace(cfg.APIKey) == "" &&
		strings.TrimSpace(cfg.Cookie) == "" &&
		(strings.TrimSpace(cfg.Username) == "" || strings.TrimSpace(cfg.Password) == "") {
		t.Fatal("configure api key, cookie, or username/password for live Protect validation")
	}

	scheme, err := cfg.NormalizedScheme()
	if err != nil {
		t.Fatalf("invalid scheme: %v", err)
	}

	insecureTLS := envBool("UNIFI_PROTECT_LIVE_INSECURE")
	baseURL := fmt.Sprintf("%s://%s", scheme, host)
	httpClient := &http.Client{
		Timeout: cfg.ParsedTimeout(10 * time.Second),
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: insecureTLS}, //nolint:gosec
		},
	}
	client := &testProtectHTTPClient{
		BaseURL:    baseURL,
		Timeout:    cfg.ParsedTimeout(10 * time.Second),
		HTTPClient: httpClient,
	}

	headers, authMode, err := protectSessionHeaders(context.Background(), cfg, client)
	if err != nil {
		t.Fatalf("auth bootstrap failed: %v", err)
	}
	t.Logf("Protect auth mode: %s", authMode)

	needLastUpdateID := cfg.CollectEvents && authMode != "api_key"
	bootstrap, _, snapshotErr := fetchProtectSnapshot(context.Background(), client, cfg, headers, authMode, needLastUpdateID)
	if snapshotErr != "" {
		t.Fatalf("bootstrap failed: %s", snapshotErr)
	}
	if len(bootstrap.Cameras) == 0 {
		t.Fatal("expected at least one camera from Protect bootstrap")
	}
	t.Logf("Protect bootstrap returned %d cameras, lastUpdateId=%s", len(bootstrap.Cameras), bootstrap.LastUpdateID)

	descriptors := buildProtectCameraDescriptors(cfg, bootstrap.Cameras)
	if len(descriptors) == 0 {
		t.Fatal("expected at least one camera descriptor")
	}

	cameraSourceID := strings.TrimSpace(os.Getenv("UNIFI_PROTECT_LIVE_CAMERA_SOURCE_ID"))
	streamProfileID := strings.TrimSpace(os.Getenv("UNIFI_PROTECT_LIVE_STREAM_PROFILE_ID"))
	if cameraSourceID != "" && streamProfileID != "" {
		sourceURL, err := resolveProtectStreamSourceURL(context.Background(), StreamConfig{
			Config: cfg,
			Relay: RelayConfig{
				CameraSourceID:  cameraSourceID,
				StreamProfileID: streamProfileID,
			},
		}, client, headers)
		if err != nil {
			t.Fatalf("stream resolution failed: %v", err)
		}
		t.Logf("Resolved live stream source: %s", sourceURL)
	}

	if cfg.CollectEvents {
		origDial := protectEventDial
		t.Cleanup(func() {
			protectEventDial = origDial
		})
		protectEventDial = func(rawURL string, headers map[string]string, insecureSkipVerify bool, timeout time.Duration) (protectEventConn, error) {
			dialer := websocket.Dialer{
				HandshakeTimeout: timeout,
				TLSClientConfig:  &tls.Config{InsecureSkipVerify: insecureSkipVerify}, //nolint:gosec
			}
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

		events, eventResult := collectProtectEvents(cfg, headers, client.Timeout, bootstrap.LastUpdateID, authMode)
		if eventResult.Error != "" {
			t.Fatalf("event collection failed: %s", eventResult.Error)
		}
		t.Logf("Protect websocket sample returned %d events", len(events))
	}
}

func envOrDefault(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func envBool(key string) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(key))) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

func envIntOrDefault(key string, fallback int) int {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	var parsed int
	if _, err := fmt.Sscanf(value, "%d", &parsed); err != nil || parsed <= 0 {
		return fallback
	}
	return parsed
}
