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

// Every fixture value below is invented. The aliases share the prefix
// fakeAliasMarker so a test can search a whole serialized document for any of
// them.
const (
	fakeAliasMarker       = "InventedAlias"
	fakeControllerHost    = "192.0.2.10"
	fakeAPIKey            = "invented-protect-api-key"
	fakeOperatorPhrase    = "invented-operator-phrase"
	fakeIntegrationCamID  = "65f0c0ffee00000000000a01"
	fakeBootstrapCamID    = "65f0c0ffee00000000000b02"
	fakeBootstrapCamMAC   = "02:00:00:00:0B:02"
	fakeMACOnlyCamMAC     = "02:00:00:00:0C:03"
	fakeRTSPSStreamsPath  = "/proxy/protect/integration/v1/cameras/" + fakeIntegrationCamID + "/rtsps-stream"
	fakeIntegrationList   = "/proxy/protect/integration/v1/cameras"
	fakeBootstrapPath     = "/proxy/protect/api/bootstrap"
	fakeLoginPath         = "/api/auth/login"
	fakeIntegrationCamera = `[{"id":"` + fakeIntegrationCamID + `","mac":"02:00:00:00:0A:01","host":"192.0.2.10","name":"Lobby","state":"CONNECTED","isConnected":true}]`
	fakeRTSPSStreams      = `{"high":"rtsps://192.0.2.10:7441/InventedAliasHigh?enableSrtp","medium":null,"low":"rtsps://192.0.2.10:7441/InventedAliasLow?enableSrtp"}`
	fakeBootstrap         = `{"cameras":[` +
		`{"id":"` + fakeBootstrapCamID + `","mac":"` + fakeBootstrapCamMAC + `","host":"192.0.2.10","connectionHost":"192.0.2.22","name":"Dock","state":"CONNECTED","isConnected":true,` +
		`"channels":[{"id":"0","name":"High","rtspAlias":"InventedAliasBootHigh","rtspsAlias":"InventedAliasBootHighS"},{"id":"1","name":"Medium","rtspAlias":""}]},` +
		`{"mac":"` + fakeMACOnlyCamMAC + `","host":"192.0.2.23","name":"Yard","state":"CONNECTED","isConnected":true,` +
		`"channels":[{"id":"0","name":"High","rtspAlias":"InventedAliasYard"}]}` +
		`],"lastUpdateId":"invented-update-id"}`
)

type fakeProtectRoute struct {
	status int
	body   string
	err    error
}

// fakeProtectController answers host-mediated HTTP requests from a route
// table keyed by "METHOD path" and records every request. Unknown routes are
// 404, as on a controller without that API.
type fakeProtectController struct {
	routes map[string]fakeProtectRoute

	mu       sync.Mutex
	requests []sdk.HTTPRequest
}

func (c *fakeProtectController) handle(_ context.Context, req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	c.mu.Lock()
	c.requests = append(c.requests, req)
	c.mu.Unlock()

	parsed, err := url.Parse(req.URL)
	if err != nil {
		return nil, err
	}
	route, ok := c.routes[strings.ToUpper(req.Method)+" "+parsed.Path]
	if !ok {
		return &sdk.HTTPResponse{Status: http.StatusNotFound, Body: []byte(`{"error":"not found"}`)}, nil
	}
	if route.err != nil {
		return nil, route.err
	}
	return &sdk.HTTPResponse{Status: route.status, Body: []byte(route.body)}, nil
}

func (c *fakeProtectController) requestedPaths() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	paths := make([]string, 0, len(c.requests))
	for _, req := range c.requests {
		parsed, err := url.Parse(req.URL)
		if err != nil {
			paths = append(paths, req.URL)
			continue
		}
		paths = append(paths, strings.ToUpper(req.Method)+" "+parsed.Path)
	}
	return paths
}

func defaultFakeProtectRoutes() map[string]fakeProtectRoute {
	return map[string]fakeProtectRoute{
		"GET " + fakeIntegrationList:  {status: http.StatusOK, body: fakeIntegrationCamera},
		"GET " + fakeRTSPSStreamsPath: {status: http.StatusOK, body: fakeRTSPSStreams},
		"GET " + fakeBootstrapPath:    {status: http.StatusOK, body: fakeBootstrap},
	}
}

func runProtectCheck(t *testing.T, config map[string]any, controller *fakeProtectController) sdk.LocalHostCapture {
	t.Helper()

	raw, err := json.Marshal(config)
	if err != nil {
		t.Fatalf("encode config: %v", err)
	}
	capture, err := sdk.RunLocalHost(sdk.LocalHostOptions{
		ConfigJSON:  raw,
		HTTPHandler: controller.handle,
	}, func() error {
		run_check()
		return nil
	})
	if err != nil {
		t.Fatalf("local host run: %v", err)
	}
	return capture
}

func protectAPIKeyConfig() map[string]any {
	return map[string]any{
		"host":    fakeControllerHost,
		"scheme":  "https",
		"api_key": fakeAPIKey,
	}
}

func resolutionRequest(cameraID, profileID string) map[string]any {
	return map[string]any{
		"schema":            sdk.CameraSourceResolutionRequestSchemaV1,
		"vendor_camera_id":  cameraID,
		"vendor_profile_id": profileID,
	}
}

func TestProtectCameraSourceResolution(t *testing.T) {
	transportErr := errors.New("dial tcp: connection refused")

	cases := []struct {
		name         string
		config       map[string]any
		cameraID     string
		profileID    string
		routes       map[string]fakeProtectRoute
		wantURL      string
		wantClass    string
		wantRequests []string
	}{
		{
			name:         "integration rtsps-stream answers the requested quality",
			cameraID:     fakeIntegrationCamID,
			profileID:    "high",
			wantURL:      "rtsps://192.0.2.10:7441/InventedAliasHigh",
			wantRequests: []string{"GET " + fakeRTSPSStreamsPath},
		},
		{
			name:      "integration API missing falls back to the bootstrap channel",
			cameraID:  fakeBootstrapCamID,
			profileID: "",
			wantURL:   "rtsp://192.0.2.22:7447/InventedAliasBootHigh",
			wantRequests: []string{
				"GET /proxy/protect/integration/v1/cameras/" + fakeBootstrapCamID + "/rtsps-stream",
				"GET " + fakeBootstrapPath,
			},
		},
		{
			name:         "bootstrap channel id resolves from the bootstrap only",
			cameraID:     fakeBootstrapCamID,
			profileID:    "0",
			wantURL:      "rtsp://192.0.2.22:7447/InventedAliasBootHigh",
			wantRequests: []string{"GET " + fakeBootstrapPath},
		},
		{
			name:      "camera reported by MAC resolves from the bootstrap",
			cameraID:  fakeMACOnlyCamMAC,
			profileID: "0",
			wantURL:   "rtsp://192.0.2.23:7447/InventedAliasYard",
		},
		{
			name:      "quality with RTSP disabled is source_not_found",
			cameraID:  fakeIntegrationCamID,
			profileID: "medium",
			wantClass: sdk.CameraSourceFailureNotFound,
		},
		{
			name:      "bootstrap channel without an alias is source_not_found",
			cameraID:  fakeBootstrapCamID,
			profileID: "1",
			wantClass: sdk.CameraSourceFailureNotFound,
		},
		{
			name:      "unknown camera is source_not_found",
			cameraID:  "65f0c0ffee00000000000f0f",
			profileID: "high",
			wantClass: sdk.CameraSourceFailureNotFound,
		},
		{
			name:      "unknown profile is source_not_found",
			cameraID:  fakeBootstrapCamID,
			profileID: "7",
			wantClass: sdk.CameraSourceFailureNotFound,
		},
		{
			name:      "integration 401 is authentication_failed",
			cameraID:  fakeIntegrationCamID,
			profileID: "high",
			routes: map[string]fakeProtectRoute{
				"GET " + fakeRTSPSStreamsPath: {status: http.StatusUnauthorized, body: `{"error":"unauthorized"}`},
			},
			wantClass:    sdk.CameraSourceFailureAuthentication,
			wantRequests: []string{"GET " + fakeRTSPSStreamsPath},
		},
		{
			name:      "bootstrap 403 is authentication_failed",
			cameraID:  fakeBootstrapCamID,
			profileID: "0",
			routes: map[string]fakeProtectRoute{
				"GET " + fakeBootstrapPath: {status: http.StatusForbidden, body: `{"error":"forbidden"}`},
			},
			wantClass: sdk.CameraSourceFailureAuthentication,
		},
		{
			name: "rejected session login is authentication_failed",
			config: map[string]any{
				"host":     fakeControllerHost,
				"scheme":   "https",
				"username": "invented-operator",
				"password": fakeOperatorPhrase,
			},
			cameraID:  fakeIntegrationCamID,
			profileID: "high",
			routes: map[string]fakeProtectRoute{
				"POST " + fakeLoginPath: {status: http.StatusUnauthorized, body: `{"error":"bad credentials"}`},
			},
			wantClass:    sdk.CameraSourceFailureAuthentication,
			wantRequests: []string{"POST " + fakeLoginPath},
		},
		{
			name:      "transport failure is connect_failed",
			cameraID:  fakeIntegrationCamID,
			profileID: "high",
			routes: map[string]fakeProtectRoute{
				"GET " + fakeRTSPSStreamsPath: {err: transportErr},
			},
			wantClass:    sdk.CameraSourceFailureConnectFailed,
			wantRequests: []string{"GET " + fakeRTSPSStreamsPath},
		},
		{
			name:      "controller timeout is connect_timeout",
			cameraID:  fakeBootstrapCamID,
			profileID: "0",
			routes: map[string]fakeProtectRoute{
				"GET " + fakeBootstrapPath: {err: context.DeadlineExceeded},
			},
			wantClass: sdk.CameraSourceFailureConnectTimeout,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			routes := defaultFakeProtectRoutes()
			for key, route := range tc.routes {
				routes[key] = route
			}
			controller := &fakeProtectController{routes: routes}

			config := tc.config
			if config == nil {
				config = protectAPIKeyConfig()
			}
			config[sdk.CameraSourceResolutionRequestConfigKey] = resolutionRequest(tc.cameraID, tc.profileID)

			capture := runProtectCheck(t, config, controller)

			var resolution sdk.CameraSourceResolution
			if err := json.Unmarshal(capture.ResultJSON, &resolution); err != nil {
				t.Fatalf("result is not a resolution document: %v", err)
			}
			if resolution.Schema != sdk.CameraSourceResolutionSchemaV1 {
				t.Fatalf("result schema = %q, want %q", resolution.Schema, sdk.CameraSourceResolutionSchemaV1)
			}
			if resolution.URL != tc.wantURL {
				t.Fatalf("url = %q, want %q", resolution.URL, tc.wantURL)
			}
			if resolution.FailureClass != tc.wantClass {
				t.Fatalf("failure_class = %q, want %q (detail %q)", resolution.FailureClass, tc.wantClass, resolution.FailureDetail)
			}

			paths := controller.requestedPaths()
			if tc.wantRequests != nil && strings.Join(paths, "\n") != strings.Join(tc.wantRequests, "\n") {
				t.Fatalf("requests = %q, want %q", paths, tc.wantRequests)
			}
			for _, path := range paths {
				if !strings.HasPrefix(path, "GET ") && path != "POST "+fakeLoginPath {
					t.Fatalf("resolution made a mutating request %q", path)
				}
			}

			if tc.wantClass != "" {
				for _, secret := range []string{fakeAliasMarker, fakeAPIKey, fakeOperatorPhrase, "192.0.2."} {
					if strings.Contains(string(capture.ResultJSON), secret) {
						t.Fatalf("failure document carries %q: %s", secret, capture.ResultJSON)
					}
				}
			}
			for _, entry := range capture.Logs {
				if strings.Contains(entry.Message, fakeAliasMarker) || strings.Contains(entry.Message, fakeAPIKey) {
					t.Fatalf("log carries a secret: %q", entry.Message)
				}
			}
			if len(capture.TelemetryJSON) != 0 {
				t.Fatalf("resolution emitted telemetry: %d batches", len(capture.TelemetryJSON))
			}
		})
	}
}

func TestProtectRejectedResolutionRequestDoesNotRunInventory(t *testing.T) {
	controller := &fakeProtectController{routes: defaultFakeProtectRoutes()}
	config := protectAPIKeyConfig()
	config[sdk.CameraSourceResolutionRequestConfigKey] = map[string]any{
		"schema":           "serviceradar.camera_source_resolution_request.v9",
		"vendor_camera_id": fakeIntegrationCamID,
	}

	capture := runProtectCheck(t, config, controller)

	if paths := controller.requestedPaths(); len(paths) != 0 {
		t.Fatalf("rejected request contacted the controller: %q", paths)
	}
	if len(capture.TelemetryJSON) != 0 {
		t.Fatalf("rejected request emitted telemetry: %d batches", len(capture.TelemetryJSON))
	}
	var result struct {
		Status  string `json:"status"`
		Details string `json:"details"`
	}
	if err := json.Unmarshal(capture.ResultJSON, &result); err != nil {
		t.Fatalf("decode result: %v", err)
	}
	if result.Status != string(sdk.StatusUnknown) {
		t.Fatalf("status = %q, want %q", result.Status, sdk.StatusUnknown)
	}
	if strings.Contains(string(capture.ResultJSON), "camera_descriptors") {
		t.Fatalf("rejected request produced an inventory result: %s", capture.ResultJSON)
	}
}

type protectInventoryReport struct {
	Cameras []struct {
		Channels []map[string]any `json:"channels"`
	} `json:"cameras"`
	Streams []struct {
		ID           string `json:"id"`
		URL          string `json:"url"`
		SourceOrigin string `json:"source_origin"`
	} `json:"streams"`
	CameraDescriptors []struct {
		CameraID       string `json:"camera_id"`
		SourceURL      string `json:"source_url"`
		StreamProfiles []struct {
			VendorProfileID   string         `json:"vendor_profile_id"`
			SourceURLOverride string         `json:"source_url_override"`
			SourceOrigin      string         `json:"source_origin"`
			Metadata          map[string]any `json:"metadata"`
		} `json:"stream_profiles"`
	} `json:"camera_descriptors"`
}

func decodeProtectInventory(t *testing.T, capture sdk.LocalHostCapture) protectInventoryReport {
	t.Helper()
	var result struct {
		Details string `json:"details"`
	}
	if err := json.Unmarshal(capture.ResultJSON, &result); err != nil {
		t.Fatalf("decode result: %v", err)
	}
	var report protectInventoryReport
	if err := json.Unmarshal([]byte(result.Details), &report); err != nil {
		t.Fatalf("decode details: %v", err)
	}
	return report
}

// protectInventoryFixture selects which controller API the inventory reads
// streams from: the integration API (api key) or the bootstrap (cookie, with
// the integration API absent).
func protectInventoryFixture(path string) (map[string]any, *fakeProtectController) {
	routes := defaultFakeProtectRoutes()
	config := protectAPIKeyConfig()
	if path == "bootstrap" {
		delete(routes, "GET "+fakeIntegrationList)
		delete(config, "api_key")
		config["cookie"] = "TOKEN=invented-session"
	}
	return config, &fakeProtectController{routes: routes}
}

// The addresses below are what the inventory reported before the D8 key
// existed (see TestBuildProtectStreamURL and
// TestBuildProtectStreamURLStripsEnableSrtpFromDirectAlias): the integration
// rtsps URL without enableSrtp, and rtsp://<connection host>:7447/<alias>.
func TestProtectInventoryReportsAddressesWithoutOmitKey(t *testing.T) {
	cases := []struct {
		path           string
		wantStreamURLs []string
		wantProfiles   map[string]string
		wantAliasKeys  map[string]string
	}{
		{
			path: "integration",
			wantStreamURLs: []string{
				"rtsps://192.0.2.10:7441/InventedAliasHigh",
				"rtsps://192.0.2.10:7441/InventedAliasLow",
			},
			wantProfiles: map[string]string{
				"high": "rtsps://192.0.2.10:7441/InventedAliasHigh",
				"low":  "rtsps://192.0.2.10:7441/InventedAliasLow",
			},
			wantAliasKeys: map[string]string{
				"high": "rtsps://192.0.2.10:7441/InventedAliasHigh?enableSrtp",
			},
		},
		{
			path: "bootstrap",
			wantStreamURLs: []string{
				"rtsp://192.0.2.22:7447/InventedAliasBootHigh",
				"rtsp://192.0.2.23:7447/InventedAliasYard",
			},
			wantProfiles: map[string]string{
				"0": "rtsp://192.0.2.22:7447/InventedAliasBootHigh",
				"1": "",
			},
			wantAliasKeys: map[string]string{
				"0": "InventedAliasBootHighS",
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.path, func(t *testing.T) {
			config, controller := protectInventoryFixture(tc.path)
			capture := runProtectCheck(t, config, controller)
			report := decodeProtectInventory(t, capture)

			if strings.Contains(string(capture.ResultJSON), "source_origin") {
				t.Fatalf("inventory without the D8 key reports source_origin: %s", capture.ResultJSON)
			}
			gotURLs := make([]string, 0, len(report.Streams))
			for _, stream := range report.Streams {
				gotURLs = append(gotURLs, stream.URL)
			}
			if strings.Join(gotURLs, " ") != strings.Join(tc.wantStreamURLs, " ") {
				t.Fatalf("streams[].url = %q, want %q", gotURLs, tc.wantStreamURLs)
			}

			descriptor := report.CameraDescriptors[0]
			if descriptor.SourceURL != tc.wantStreamURLs[0] {
				t.Fatalf("source_url = %q, want %q", descriptor.SourceURL, tc.wantStreamURLs[0])
			}
			for _, profile := range descriptor.StreamProfiles {
				want, ok := tc.wantProfiles[profile.VendorProfileID]
				if !ok {
					continue
				}
				if profile.SourceURLOverride != want {
					t.Fatalf("profile %q source_url_override = %q, want %q", profile.VendorProfileID, profile.SourceURLOverride, want)
				}
				if alias, ok := tc.wantAliasKeys[profile.VendorProfileID]; ok && profile.Metadata["rtsps_alias"] != alias {
					t.Fatalf("profile %q rtsps_alias = %#v, want %q", profile.VendorProfileID, profile.Metadata["rtsps_alias"], alias)
				}
			}
			if len(report.Cameras) == 0 || len(report.Cameras[0].Channels) == 0 {
				t.Fatalf("cameras[].channels missing without the D8 key: %s", capture.ResultJSON)
			}
		})
	}
}

func TestProtectInventoryOmitsAddressesWithOmitKey(t *testing.T) {
	cases := []struct {
		path        string
		wantOrigins map[string]string
	}{
		{
			path: "integration",
			wantOrigins: map[string]string{
				"high": "rtsps://192.0.2.10:7441",
				"low":  "rtsps://192.0.2.10:7441",
			},
		},
		{
			path: "bootstrap",
			wantOrigins: map[string]string{
				"0": "rtsp://192.0.2.22:7447",
				"1": "",
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.path, func(t *testing.T) {
			config, controller := protectInventoryFixture(tc.path)
			config[sdk.CameraStreamAddressesConfigKey] = sdk.CameraStreamAddressesOmit
			capture := runProtectCheck(t, config, controller)

			serialized := string(capture.ResultJSON)
			for _, forbidden := range []string{
				fakeAliasMarker, "source_url", "rtsp_alias", "rtsps_alias", "rtspAlias", "rtspsAlias", `"url"`, `\"url\"`,
			} {
				if strings.Contains(serialized, forbidden) {
					t.Fatalf("result with the D8 key carries %q: %s", forbidden, serialized)
				}
			}

			report := decodeProtectInventory(t, capture)
			if len(report.Streams) == 0 {
				t.Fatalf("no streams reported")
			}
			for _, stream := range report.Streams {
				if !strings.HasPrefix(stream.SourceOrigin, "rtsp") || strings.Count(stream.SourceOrigin, "/") != 2 {
					t.Fatalf("stream %q source_origin = %q, want an origin", stream.ID, stream.SourceOrigin)
				}
			}
			profiles := 0
			for _, profile := range report.CameraDescriptors[0].StreamProfiles {
				want, ok := tc.wantOrigins[profile.VendorProfileID]
				if !ok {
					continue
				}
				profiles++
				if profile.SourceOrigin != want {
					t.Fatalf("profile %q source_origin = %q, want %q", profile.VendorProfileID, profile.SourceOrigin, want)
				}
			}
			if profiles != len(tc.wantOrigins) {
				t.Fatalf("matched %d of %d expected profiles", profiles, len(tc.wantOrigins))
			}
			for _, camera := range report.Cameras {
				if len(camera.Channels) != 0 {
					t.Fatalf("cameras[].channels reported with the D8 key: %#v", camera.Channels)
				}
			}
		})
	}
}
