package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

// Every fixture value below is invented. fakeAxisMediaMarker is a media
// parameter value, so it appears in a stream address and nowhere else.
const (
	fakeAxisHost            = "192.0.2.20"
	fakeAxisProfileListPath = "/axis-cgi/streamprofile.cgi?list"
	fakeAxisUser            = "invented user"
	fakeAxisPassword        = "invented-p@ss:w/rd"
	fakeAxisMediaMarker     = "InventedMediaMarker"
	fakeAxisProfileList     = "root.StreamProfile.S0.Name=InventedMain\n" +
		"root.StreamProfile.S0.Parameters=videocodec=h264&resolution=1920x1080&inventedtoken=" + fakeAxisMediaMarker + "\n" +
		"root.StreamProfile.S1.Name=InventedSub\n" +
		"root.StreamProfile.S1.Parameters=videocodec=h265&resolution=640x360\n"
	fakeAxisDeviceInfo = "SerialNumber=INVENTED0001\nProductFullName=AXIS Invented Model\n"
	// fakeAxisMainURL is what the inventory reports for InventedMain without
	// the D8 key: rtsp://<host>/axis-media/media.amp with the profile
	// parameters sorted by key (see TestBuildRTSPURL).
	fakeAxisMainURL = "rtsp://192.0.2.20/axis-media/media.amp?inventedtoken=" + fakeAxisMediaMarker + "&resolution=1920x1080&videocodec=h264"
	fakeAxisSubURL  = "rtsp://192.0.2.20/axis-media/media.amp?resolution=640x360&videocodec=h265"
)

type fakeAxisRoute struct {
	status int
	body   string
	err    error
}

// fakeAxisCamera answers host-mediated HTTP requests from a route table keyed
// by "METHOD path?query" and records every request.
type fakeAxisCamera struct {
	routes map[string]fakeAxisRoute

	mu       sync.Mutex
	requests []string
}

func (c *fakeAxisCamera) handle(_ context.Context, req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	parsed, err := url.Parse(req.URL)
	if err != nil {
		return nil, err
	}
	key := strings.ToUpper(req.Method) + " " + parsed.RequestURI()
	c.mu.Lock()
	c.requests = append(c.requests, key)
	c.mu.Unlock()

	route, ok := c.routes[key]
	if !ok {
		return &sdk.HTTPResponse{Status: http.StatusNotFound}, nil
	}
	if route.err != nil {
		return nil, route.err
	}
	return &sdk.HTTPResponse{Status: route.status, Body: []byte(route.body)}, nil
}

func newFakeAxisCamera(overrides map[string]fakeAxisRoute) *fakeAxisCamera {
	routes := map[string]fakeAxisRoute{
		"GET " + fakeAxisProfileListPath:    {status: http.StatusOK, body: fakeAxisProfileList},
		"GET /axis-cgi/basicdeviceinfo.cgi": {status: http.StatusOK, body: fakeAxisDeviceInfo},
		"GET /axis-cgi/streamstatus.cgi":    {status: http.StatusOK, body: "Streams=0\n"},
		"GET /axis-cgi/apidiscovery.cgi":    {status: http.StatusOK, body: `{"apiVersion":"1.0"}`},
	}
	for key, route := range overrides {
		routes[key] = route
	}
	return &fakeAxisCamera{routes: routes}
}

func runAxisCheck(t *testing.T, config map[string]any, camera *fakeAxisCamera) sdk.LocalHostCapture {
	t.Helper()

	raw, err := json.Marshal(config)
	if err != nil {
		t.Fatalf("encode config: %v", err)
	}
	capture, err := sdk.RunLocalHost(sdk.LocalHostOptions{
		ConfigJSON:  raw,
		HTTPHandler: camera.handle,
	}, func() error {
		run_check()
		return nil
	})
	if err != nil {
		t.Fatalf("local host run: %v", err)
	}
	return capture
}

func axisConfig(withCredentials bool) map[string]any {
	config := map[string]any{"host": fakeAxisHost, "scheme": "https"}
	if withCredentials {
		config["username"] = fakeAxisUser
		config["password"] = fakeAxisPassword
	}
	return config
}

func TestAxisCameraSourceResolution(t *testing.T) {
	cases := []struct {
		name      string
		config    map[string]any
		profileID string
		routes    map[string]fakeAxisRoute
		wantURL   string
		wantClass string
	}{
		{
			name:      "profile resolves with percent-encoded plugin credentials",
			config:    axisConfig(true),
			profileID: "InventedMain",
			wantURL: (&url.URL{
				Scheme:   "rtsp",
				User:     url.UserPassword(fakeAxisUser, fakeAxisPassword),
				Host:     fakeAxisHost,
				Path:     "/axis-media/media.amp",
				RawQuery: "inventedtoken=" + fakeAxisMediaMarker + "&resolution=1920x1080&videocodec=h264",
			}).String(),
		},
		{
			name:      "no configured credentials leaves the address without userinfo",
			config:    axisConfig(false),
			profileID: "InventedSub",
			wantURL:   fakeAxisSubURL,
		},
		{
			name:      "empty profile selects the first profile",
			config:    axisConfig(false),
			profileID: "",
			wantURL:   fakeAxisMainURL,
		},
		{
			name:      "non-default rtsp_port is kept",
			config:    map[string]any{"host": fakeAxisHost, "scheme": "https", "rtsp_port": 8554},
			profileID: "InventedSub",
			wantURL:   "rtsp://192.0.2.20:8554/axis-media/media.amp?resolution=640x360&videocodec=h265",
		},
		{
			name:      "unknown profile is source_not_found",
			config:    axisConfig(true),
			profileID: "InventedMissing",
			wantClass: sdk.CameraSourceFailureNotFound,
		},
		{
			name:      "camera 401 is authentication_failed",
			config:    axisConfig(true),
			profileID: "InventedMain",
			routes: map[string]fakeAxisRoute{
				"GET " + fakeAxisProfileListPath: {status: http.StatusUnauthorized},
			},
			wantClass: sdk.CameraSourceFailureAuthentication,
		},
		{
			name:      "transport failure is connect_failed",
			config:    axisConfig(true),
			profileID: "InventedMain",
			routes: map[string]fakeAxisRoute{
				"GET " + fakeAxisProfileListPath: {err: errors.New("dial tcp: no route to host")},
			},
			wantClass: sdk.CameraSourceFailureConnectFailed,
		},
		{
			name:      "camera timeout is connect_timeout",
			config:    axisConfig(true),
			profileID: "InventedMain",
			routes: map[string]fakeAxisRoute{
				"GET " + fakeAxisProfileListPath: {err: context.DeadlineExceeded},
			},
			wantClass: sdk.CameraSourceFailureConnectTimeout,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			camera := newFakeAxisCamera(tc.routes)
			config := tc.config
			config[sdk.CameraSourceResolutionRequestConfigKey] = map[string]any{
				"schema":            sdk.CameraSourceResolutionRequestSchemaV1,
				"vendor_camera_id":  "INVENTED0001",
				"vendor_profile_id": tc.profileID,
			}

			capture := runAxisCheck(t, config, camera)

			var resolution sdk.CameraSourceResolution
			if err := json.Unmarshal(capture.ResultJSON, &resolution); err != nil {
				t.Fatalf("result is not a resolution document: %v", err)
			}
			if resolution.Schema != sdk.CameraSourceResolutionSchemaV1 {
				t.Fatalf("result schema = %q", resolution.Schema)
			}
			if resolution.URL != tc.wantURL {
				t.Fatalf("url = %q, want %q", resolution.URL, tc.wantURL)
			}
			if resolution.FailureClass != tc.wantClass {
				t.Fatalf("failure_class = %q, want %q (detail %q)", resolution.FailureClass, tc.wantClass, resolution.FailureDetail)
			}
			if got := strings.Join(camera.requests, ","); got != "GET "+fakeAxisProfileListPath {
				t.Fatalf("requests = %q, want one stream profile GET", got)
			}
			if tc.wantClass != "" {
				for _, secret := range []string{fakeAxisMediaMarker, "invented-p", "192.0.2."} {
					if strings.Contains(string(capture.ResultJSON), secret) {
						t.Fatalf("failure document carries %q: %s", secret, capture.ResultJSON)
					}
				}
			}
			for _, entry := range capture.Logs {
				if strings.Contains(entry.Message, fakeAxisMediaMarker) || strings.Contains(entry.Message, "invented-p") {
					t.Fatalf("log carries a secret: %q", entry.Message)
				}
			}
		})
	}
}

func TestAxisRejectedResolutionRequestDoesNotRunInventory(t *testing.T) {
	camera := newFakeAxisCamera(nil)
	config := axisConfig(true)
	config[sdk.CameraSourceResolutionRequestConfigKey] = map[string]any{
		"schema":           "serviceradar.camera_source_resolution_request.v9",
		"vendor_camera_id": "INVENTED0001",
	}

	capture := runAxisCheck(t, config, camera)

	if len(camera.requests) != 0 {
		t.Fatalf("rejected request contacted the camera: %q", camera.requests)
	}
	if len(capture.TelemetryJSON) != 0 {
		t.Fatalf("rejected request emitted telemetry: %d batches", len(capture.TelemetryJSON))
	}
	var result struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(capture.ResultJSON, &result); err != nil {
		t.Fatalf("decode result: %v", err)
	}
	if result.Status != string(sdk.StatusUnknown) || strings.Contains(string(capture.ResultJSON), "camera_descriptors") {
		t.Fatalf("rejected request produced an inventory result: %s", capture.ResultJSON)
	}
}

type axisInventoryReport struct {
	Streams []struct {
		ID           string `json:"id"`
		URL          string `json:"url"`
		SourceOrigin string `json:"source_origin"`
	} `json:"streams"`
	CameraDescriptors []struct {
		SourceURL      string `json:"source_url"`
		StreamProfiles []struct {
			VendorProfileID   string `json:"vendor_profile_id"`
			SourceURLOverride string `json:"source_url_override"`
			SourceOrigin      string `json:"source_origin"`
			CodecHint         string `json:"codec_hint"`
		} `json:"stream_profiles"`
	} `json:"camera_descriptors"`
	Enrichment struct {
		Streams []struct {
			URL          string `json:"url"`
			SourceOrigin string `json:"source_origin"`
		} `json:"streams"`
	} `json:"device_enrichment"`
}

func decodeAxisInventory(t *testing.T, capture sdk.LocalHostCapture) axisInventoryReport {
	t.Helper()
	var result struct {
		Details string `json:"details"`
	}
	if err := json.Unmarshal(capture.ResultJSON, &result); err != nil {
		t.Fatalf("decode result: %v", err)
	}
	var report axisInventoryReport
	if err := json.Unmarshal([]byte(result.Details), &report); err != nil {
		t.Fatalf("decode details: %v", err)
	}
	return report
}

func TestAxisInventoryStreamAddresses(t *testing.T) {
	cases := []struct {
		name       string
		omit       bool
		keyValue   any
		wantURLs   []string
		wantOrigin string
	}{
		{name: "without the D8 key", wantURLs: []string{fakeAxisMainURL, fakeAxisSubURL}},
		{
			name: "with the D8 key", omit: true, keyValue: sdk.CameraStreamAddressesOmit,
			wantURLs: []string{"", ""}, wantOrigin: "rtsp://192.0.2.20",
		},
		{
			name: "with a null D8 key", omit: true, keyValue: nil,
			wantURLs: []string{"", ""}, wantOrigin: "rtsp://192.0.2.20",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			config := axisConfig(true)
			if tc.omit {
				config[sdk.CameraStreamAddressesConfigKey] = tc.keyValue
			}
			capture := runAxisCheck(t, config, newFakeAxisCamera(nil))
			serialized := string(capture.ResultJSON)
			report := decodeAxisInventory(t, capture)

			if strings.Contains(serialized, "invented-p") {
				t.Fatalf("inventory carries the stream password: %s", serialized)
			}
			if tc.omit {
				for _, forbidden := range []string{fakeAxisMediaMarker, "axis-media", "source_url", `\"url\"`} {
					if strings.Contains(serialized, forbidden) {
						t.Fatalf("result with the D8 key carries %q: %s", forbidden, serialized)
					}
				}
			} else if strings.Contains(serialized, "source_origin") {
				t.Fatalf("result without the D8 key reports source_origin: %s", serialized)
			}

			if len(report.Streams) != len(tc.wantURLs) || len(report.CameraDescriptors) != 1 {
				t.Fatalf("streams = %d, descriptors = %d", len(report.Streams), len(report.CameraDescriptors))
			}
			descriptor := report.CameraDescriptors[0]
			if descriptor.SourceURL != tc.wantURLs[0] {
				t.Fatalf("source_url = %q, want %q", descriptor.SourceURL, tc.wantURLs[0])
			}
			for i, want := range tc.wantURLs {
				stream := report.Streams[i]
				profile := descriptor.StreamProfiles[i]
				if stream.URL != want || profile.SourceURLOverride != want || report.Enrichment.Streams[i].URL != want {
					t.Fatalf("stream %q addresses = %q / %q / %q, want %q",
						stream.ID, stream.URL, profile.SourceURLOverride, report.Enrichment.Streams[i].URL, want)
				}
				if stream.SourceOrigin != tc.wantOrigin || profile.SourceOrigin != tc.wantOrigin ||
					report.Enrichment.Streams[i].SourceOrigin != tc.wantOrigin {
					t.Fatalf("stream %q origins = %q / %q / %q, want %q",
						stream.ID, stream.SourceOrigin, profile.SourceOrigin, report.Enrichment.Streams[i].SourceOrigin, tc.wantOrigin)
				}
			}
			if descriptor.StreamProfiles[0].CodecHint != "h264" || descriptor.StreamProfiles[1].CodecHint != "h265" {
				t.Fatalf("codec hints = %q, %q", descriptor.StreamProfiles[0].CodecHint, descriptor.StreamProfiles[1].CodecHint)
			}
		})
	}
}
