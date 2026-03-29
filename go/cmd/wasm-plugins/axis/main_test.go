package main

import (
	"testing"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/sdk"
)

func TestBuildRTSPURL(t *testing.T) {
	url := buildRTSPURL("10.0.0.5", map[string]string{"resolution": "1280x720", "videocodec": "h264"})
	wantA := "rtsp://10.0.0.5/axis-media/media.amp?resolution=1280x720&videocodec=h264"
	wantB := "rtsp://10.0.0.5/axis-media/media.amp?videocodec=h264&resolution=1280x720"
	if url != wantA && url != wantB {
		t.Fatalf("unexpected URL: %s", url)
	}
}

func TestMapAxisWSEvent(t *testing.T) {
	payload := []byte(`{"params":{"notification":{"topic":"tns1:Device/IO/VirtualInput"}}}`)
	evt := mapAxisWSEvent(payload)
	if evt == nil {
		t.Fatalf("expected event, got nil")
	}
	if evt.Message == "" {
		t.Fatalf("expected non-empty event message")
	}
	if evt.Unmapped == nil {
		t.Fatalf("expected unmapped payload")
	}
}

func TestBuildCameraDescriptors(t *testing.T) {
	descriptors := buildCameraDescriptors(ResultDetails{
		CameraHost: "10.0.0.5",
		DeviceInfo: map[string]string{
			"SerialNumber":    "axis-serial-5",
			"ProductFullName": "AXIS Q1808-LE",
		},
		Streams: []StreamInfo{
			{
				ID:                    "main",
				Protocol:              "rtsp",
				URL:                   "rtsp://10.0.0.5/axis-media/media.amp?videocodec=h264",
				AuthMode:              "digest",
				CredentialReferenceID: "secretref:password:abc123",
				Source:                "streamprofile.cgi",
			},
		},
	})

	if len(descriptors) != 1 {
		t.Fatalf("expected 1 descriptor, got %d", len(descriptors))
	}

	descriptor := descriptors[0]
	if descriptor.DeviceUID != "axis-serial-5" {
		t.Fatalf("unexpected device uid: %s", descriptor.DeviceUID)
	}
	if descriptor.Vendor != "axis" {
		t.Fatalf("unexpected vendor: %s", descriptor.Vendor)
	}
	if descriptor.CameraID != "axis-serial-5" {
		t.Fatalf("unexpected camera id: %s", descriptor.CameraID)
	}
	if descriptor.SourceURL != "rtsp://10.0.0.5/axis-media/media.amp?videocodec=h264" {
		t.Fatalf("unexpected source url: %s", descriptor.SourceURL)
	}
	if len(descriptor.StreamProfiles) != 1 {
		t.Fatalf("expected 1 stream profile, got %d", len(descriptor.StreamProfiles))
	}
	if descriptor.StreamProfiles[0].CodecHint != "h264" {
		t.Fatalf("unexpected codec hint: %s", descriptor.StreamProfiles[0].CodecHint)
	}
	if descriptor.StreamProfiles[0].Metadata["auth_mode"] != "digest" {
		t.Fatalf("unexpected auth mode metadata: %#v", descriptor.StreamProfiles[0].Metadata["auth_mode"])
	}
	if descriptor.StreamProfiles[0].Metadata["credential_reference_id"] != "secretref:password:abc123" {
		t.Fatalf("unexpected credential_reference_id metadata: %#v", descriptor.StreamProfiles[0].Metadata["credential_reference_id"])
	}
	if descriptor.Metadata["plugin_id"] != "axis-camera" {
		t.Fatalf("unexpected plugin_id metadata: %#v", descriptor.Metadata["plugin_id"])
	}
}

func TestAxisEventHeaders(t *testing.T) {
	headers := axisEventHeaders("Basic cm9vdDpzZWNyZXQ=")
	if got := headers["Authorization"]; got != "Basic cm9vdDpzZWNyZXQ=" {
		t.Fatalf("unexpected authorization header: %q", got)
	}

	if got := axisEventHeaders(""); got != nil {
		t.Fatalf("expected nil headers for empty auth, got %#v", got)
	}
}

func TestCollectAxisEventsUsesCredentialFreeWebSocketURL(t *testing.T) {
	originalDial := axisEventWebSocketConnect
	defer func() { axisEventWebSocketConnect = originalDial }()

	var gotURL string
	var gotHeaders map[string]string
	axisEventWebSocketConnect = func(rawURL string, headers map[string]string, timeout time.Duration) (axisEventWebSocket, error) {
		gotURL = rawURL
		gotHeaders = headers
		return &stubAxisEventWebSocket{}, nil
	}

	events, result := collectAxisEvents(
		"https",
		"camera.local",
		"Basic cm9vdDpzZWNyZXQ=",
		"events",
		"",
		2*time.Second,
	)

	if len(events) != 0 {
		t.Fatalf("expected no events from stub connection, got %d", len(events))
	}
	if result.Error != "" {
		t.Fatalf("unexpected websocket result error: %s", result.Error)
	}
	if gotURL != "wss://camera.local/vapix/ws-data-stream?sources=events" {
		t.Fatalf("unexpected websocket url: %s", gotURL)
	}
	if gotHeaders["Authorization"] != "Basic cm9vdDpzZWNyZXQ=" {
		t.Fatalf("unexpected authorization header: %#v", gotHeaders)
	}
}

type stubAxisEventWebSocket struct{}

func (s *stubAxisEventWebSocket) Send([]byte, time.Duration) error { return nil }

func (s *stubAxisEventWebSocket) Recv([]byte, time.Duration) (int, error) { return 0, nil }

func (s *stubAxisEventWebSocket) Close() error { return nil }

func TestBuildAxisStreamSourceURLPrefersRelaySource(t *testing.T) {
	cfg := StreamConfig{
		Config: Config{CameraPluginConfig: sdk.CameraPluginConfig{Host: "10.0.0.5"}},
		Relay: RelayConfig{
			SourceURL: "rtsp://10.0.0.5/axis-media/media.amp?videocodec=h264&stream=1",
		},
	}

	if got := buildAxisStreamSourceURL(cfg); got != cfg.Relay.SourceURL {
		t.Fatalf("expected relay source url, got %s", got)
	}
}

func TestBuildAxisStreamSourceURLFallsBackToDefaultRTSP(t *testing.T) {
	cfg := StreamConfig{Config: Config{CameraPluginConfig: sdk.CameraPluginConfig{Host: "10.0.0.5"}}}

	got := buildAxisStreamSourceURL(cfg)
	want := "rtsp://10.0.0.5/axis-media/media.amp"

	if got != want {
		t.Fatalf("unexpected fallback source url: %s", got)
	}
}

func TestParseAxisTopicFilters(t *testing.T) {
	got := parseAxisTopicFilters("tns1:VideoSource/Motion, tns1:Device/IO/VirtualInput\n tns1:VideoSource/Motion ")

	if len(got) != 2 {
		t.Fatalf("expected 2 unique filters, got %d (%v)", len(got), got)
	}
	if got[0] != "tns1:VideoSource/Motion" {
		t.Fatalf("unexpected first filter: %q", got[0])
	}
	if got[1] != "tns1:Device/IO/VirtualInput" {
		t.Fatalf("unexpected second filter: %q", got[1])
	}
}

func TestBuildHealthMetrics(t *testing.T) {
	metrics := buildHealthMetrics(ResultDetails{
		DeviceInfo: map[string]string{
			"Uptime":      "3600",
			"FreeStorage": "1.5GB",
		},
		Streams: []StreamInfo{
			{ID: "main"},
			{ID: "substream"},
		},
		Endpoints: []EndpointResult{
			{Path: "/axis-cgi/basicdeviceinfo.cgi", Status: 200},
			{Path: "/axis-cgi/apidiscovery.cgi", Status: 200},
			{Path: "/axis-cgi/streamstatus.cgi", Status: 200, Body: "Streams=2\n"},
		},
	}, 1)

	if got := metrics["endpoint_success_total"].Value; got != 3 {
		t.Fatalf("unexpected endpoint_success_total: %v", got)
	}
	if got := metrics["stream_total"].Value; got != 2 {
		t.Fatalf("unexpected stream_total: %v", got)
	}
	if got := metrics["event_total"].Value; got != 1 {
		t.Fatalf("unexpected event_total: %v", got)
	}
	if got := metrics["stream_status_total"].Value; got != 2 {
		t.Fatalf("unexpected stream_status_total: %v", got)
	}
	if got := metrics["uptime_seconds"].Value; got != 3600 {
		t.Fatalf("unexpected uptime_seconds: %v", got)
	}
	if got := metrics["storage_free_bytes"].Value; got != 1610612736 {
		t.Fatalf("unexpected storage_free_bytes: %v", got)
	}
}

func TestDeriveStatusWarnsWhenStreamDiscoveryReturnsNoStreams(t *testing.T) {
	details := ResultDetails{
		DeviceInfo: map[string]string{
			"SerialNumber": "axis-serial-1",
		},
		Endpoints: []EndpointResult{
			{Path: "/axis-cgi/basicdeviceinfo.cgi", Status: 200},
			{Path: "/axis-cgi/streamprofile.cgi?list", Status: 200},
			{Path: "/axis-cgi/streamstatus.cgi", Status: 200, Body: "Streams=0\n"},
		},
	}

	metrics := buildHealthMetrics(details, 0)
	if got := deriveStatus(details, metrics); got != sdk.StatusWarning {
		t.Fatalf("expected warning status, got %v", got)
	}
}

func TestNormalizeStreamAuthMode(t *testing.T) {
	if got := normalizeStreamAuthMode("", ""); got != "none" {
		t.Fatalf("expected none for unauthenticated default, got %q", got)
	}
	if got := normalizeStreamAuthMode("", "secretref:password:abc"); got != "unknown" {
		t.Fatalf("expected unknown when secret ref is present without explicit mode, got %q", got)
	}
	if got := normalizeStreamAuthMode("basic_or_digest", "secretref:password:abc"); got != "unknown" {
		t.Fatalf("expected unknown for legacy basic_or_digest, got %q", got)
	}
	if got := normalizeStreamAuthMode("digest", "secretref:password:abc"); got != "digest" {
		t.Fatalf("expected digest auth mode, got %q", got)
	}
}
