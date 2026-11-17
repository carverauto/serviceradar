/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package agent

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/proto"
)

const (
	resolverTestAlias     = "aliasInvented0001"
	resolverTestSourceURL = "rtsps://192.0.2.10:7441/" + resolverTestAlias + "?enableSrtp"
)

func resolverTestSpec(resolver *cameraRelaySourceResolver) cameraRelaySessionSpec {
	return cameraRelaySessionSpec{
		RelaySessionID:  "relay-resolver-1",
		AgentID:         "agent-example",
		CameraSourceID:  "camera-example",
		StreamProfileID: "high",
		LeaseToken:      "lease-example",
		SourceResolver:  resolver,
		// A stored address sent alongside a resolver must never be opened.
		SourceURL: "rtsp://198.51.100.9/stored",
	}
}

// The resolved address is handed to the native reader and to nothing else: not
// the session the manager keeps, and not any request sent to the gateway.
func TestCameraRelayResolvedSourceReachesOnlyTheReader(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	gateway := newFakeCameraRelayGateway()
	manager := newCameraRelayManager(gateway, createTestLogger())

	var asked cameraRelaySourceResolver
	manager.sourceResolver = func(_ context.Context, resolver cameraRelaySourceResolver) (string, error) {
		asked = resolver
		return resolverTestSourceURL, nil
	}
	var opened string
	manager.sourceFactory = func(spec cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
		opened = spec.SourceURL
		return &blockingCameraRelayStream{}, nil
	}

	spec := resolverTestSpec(&cameraRelaySourceResolver{
		PluginAssignmentID: " assignment-example ",
		VendorCameraID:     " camera-vendor-1 ",
		VendorProfileID:    "high",
	})
	if _, err := manager.Start(ctx, spec); err != nil {
		t.Fatalf("Start: %v", err)
	}

	if opened != resolverTestSourceURL {
		t.Fatalf("reader opened %q, want the resolved address", opened)
	}
	want := cameraRelaySourceResolver{PluginAssignmentID: "assignment-example", VendorCameraID: "camera-vendor-1", VendorProfileID: "high"}
	if asked != want {
		t.Fatalf("resolver asked for %+v, want %+v", asked, want)
	}

	if err := manager.Stop(ctx, cameraRelayStopPayload{RelaySessionID: spec.RelaySessionID}); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	select {
	case <-gateway.closeNotifyCh:
	case <-ctx.Done():
		t.Fatal("the relay never closed upstream")
	}
	assertGatewayNeverSaw(t, gateway, resolverTestAlias, "198.51.100.9")
}

func TestCameraRelaySourceResolverFailureClasses(t *testing.T) {
	t.Parallel()

	validResolver := &cameraRelaySourceResolver{PluginAssignmentID: "assignment-example", VendorCameraID: "camera-vendor-1"}
	cases := []struct {
		name      string
		resolver  *cameraRelaySourceResolver
		resolve   func(context.Context, cameraRelaySourceResolver) (string, error)
		wantClass string
	}{
		{
			name:     "assignment not loaded",
			resolver: validResolver,
			resolve: func(context.Context, cameraRelaySourceResolver) (string, error) {
				return "", errCameraRelaySourceResolverUnavailable
			},
			wantClass: "source_resolver_unavailable",
		},
		{
			name:      "no resolver wired",
			resolver:  validResolver,
			wantClass: "source_resolver_unavailable",
		},
		{
			name:     "plugin returned no resolution document",
			resolver: validResolver,
			resolve: func(context.Context, cameraRelaySourceResolver) (string, error) {
				return decodeCameraSourceResolution([]byte(`{"status":"OK"}`))
			},
			wantClass: "source_resolver_unsupported",
		},
		{
			name:     "camera unknown to the controller",
			resolver: validResolver,
			resolve: func(context.Context, cameraRelaySourceResolver) (string, error) {
				return decodeCameraSourceResolution([]byte(`{"schema":"serviceradar.camera_source_resolution.v1",` +
					`"failure_class":"source_not_found","failure_detail":"no stream at ` + resolverTestSourceURL + `"}`))
			},
			wantClass: "source_not_found",
		},
		{
			name:     "controller rejected the credential",
			resolver: validResolver,
			resolve: func(context.Context, cameraRelaySourceResolver) (string, error) {
				return decodeCameraSourceResolution([]byte(`{"schema":"serviceradar.camera_source_resolution.v1","failure_class":"authentication_failed"}`))
			},
			wantClass: "authentication_failed",
		},
		{
			name:     "plugin invented a class",
			resolver: validResolver,
			resolve: func(context.Context, cameraRelaySourceResolver) (string, error) {
				return decodeCameraSourceResolution([]byte(`{"schema":"serviceradar.camera_source_resolution.v1","failure_class":"made_up"}`))
			},
			wantClass: "unknown",
		},
		{
			name:      "resolver without a camera id",
			resolver:  &cameraRelaySourceResolver{PluginAssignmentID: "assignment-example"},
			resolve:   func(context.Context, cameraRelaySourceResolver) (string, error) { return resolverTestSourceURL, nil },
			wantClass: "invalid_source_config",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()

			gateway := newFakeCameraRelayGateway()
			manager := newCameraRelayManager(gateway, createTestLogger())
			manager.sourceResolver = tc.resolve
			manager.sourceFactory = func(cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
				t.Error("the reader must not open when resolution fails")
				return &blockingCameraRelayStream{}, nil
			}

			_, err := manager.Start(ctx, resolverTestSpec(tc.resolver))
			var startErr *cameraRelaySourceStartError
			if !errors.As(err, &startErr) {
				t.Fatalf("Start error = %v, want a source start failure", err)
			}
			if startErr.failure.Class != tc.wantClass {
				t.Fatalf("failure class = %q, want %q", startErr.failure.Class, tc.wantClass)
			}
			if strings.Contains(err.Error(), resolverTestAlias) {
				t.Fatalf("command error quotes the address: %q", err.Error())
			}

			gateway.mu.Lock()
			closes := append([]*proto.CloseRelaySessionRequest(nil), gateway.closeRequests...)
			gateway.mu.Unlock()
			if len(closes) != 1 {
				t.Fatalf("close requests = %d, want 1", len(closes))
			}
			if reason := closes[0].GetFailureReason(); !strings.HasPrefix(reason, tc.wantClass) {
				t.Fatalf("failure reason = %q, want class %q", reason, tc.wantClass)
			}
			assertGatewayNeverSaw(t, gateway, resolverTestAlias, "198.51.100.9")
		})
	}
}

func TestDecodeCameraSourceResolutionReturnsTheAddress(t *testing.T) {
	t.Parallel()

	got, err := decodeCameraSourceResolution([]byte(
		`{"schema":"serviceradar.camera_source_resolution.v1","url":" rtsp://viewer:invented-pass@192.0.2.20/axis-media/media.amp "}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if want := "rtsp://viewer:invented-pass@192.0.2.20/axis-media/media.amp"; got != want {
		t.Fatalf("url = %q, want %q", got, want)
	}

	for _, result := range []string{
		``,
		`not json`,
		`{"schema":"serviceradar.camera_source_resolution.v1"}`,
		`{"schema":"serviceradar.plugin_result.v1","url":"rtsp://192.0.2.20/stream"}`,
	} {
		if _, err := decodeCameraSourceResolution([]byte(result)); !errors.Is(err, errCameraRelaySourceResolverUnsupported) {
			t.Errorf("decode(%q) error = %v, want unsupported", result, err)
		}
	}
}

// The plugin must see the assignment's own params, which carry the credential a
// scheduled run uses, plus the request.
func TestBuildCameraSourceResolutionConfigKeepsAssignmentParams(t *testing.T) {
	t.Parallel()

	params := []byte(`{"host":"192.0.2.30","api_key":"invented-key","verify_tls":false}`)
	config, err := buildCameraSourceResolutionConfig(params, cameraRelaySourceResolver{
		PluginAssignmentID: "assignment-example", VendorCameraID: "camera-vendor-1", VendorProfileID: "high",
	})
	if err != nil {
		t.Fatalf("build: %v", err)
	}

	var decoded map[string]any
	if err := json.Unmarshal(config, &decoded); err != nil {
		t.Fatalf("decode config: %v", err)
	}
	if decoded["host"] != "192.0.2.30" || decoded["api_key"] != "invented-key" || decoded["verify_tls"] != false {
		t.Fatalf("assignment params changed: %s", config)
	}
	request, _ := decoded["_serviceradar_camera_source_resolution_request"].(map[string]any)
	want := map[string]any{
		"schema":            "serviceradar.camera_source_resolution_request.v1",
		"vendor_camera_id":  "camera-vendor-1",
		"vendor_profile_id": "high",
	}
	if len(request) != len(want) {
		t.Fatalf("request = %v, want %v", request, want)
	}
	for key, value := range want {
		if request[key] != value {
			t.Fatalf("request[%s] = %v, want %v", key, request[key], value)
		}
	}

	if _, err := buildCameraSourceResolutionConfig([]byte(`["not","an","object"]`), cameraRelaySourceResolver{}); !errors.Is(err, errCameraSourceResolverParams) {
		t.Fatalf("non-object params error = %v, want params error", err)
	}
}

func TestPluginManagerResolveCameraSourceUnknownAssignment(t *testing.T) {
	t.Parallel()

	manager := NewPluginManager(t.Context(), PluginManagerConfig{Logger: createTestLogger(), CacheDir: t.TempDir()})
	defer manager.Stop()

	_, err := manager.ResolveCameraSource(t.Context(), cameraRelaySourceResolver{
		PluginAssignmentID: "assignment-missing", VendorCameraID: "camera-vendor-1",
	})
	if !errors.Is(err, errCameraRelaySourceResolverUnavailable) {
		t.Fatalf("error = %v, want resolver unavailable", err)
	}
}

func assertGatewayNeverSaw(t *testing.T, gateway *fakeCameraRelayGateway, secrets ...string) {
	t.Helper()

	gateway.mu.Lock()
	defer gateway.mu.Unlock()

	var messages []gproto.Message
	for _, request := range gateway.openRequests {
		messages = append(messages, request)
	}
	for _, request := range gateway.closeRequests {
		messages = append(messages, request)
	}
	for _, request := range gateway.heartbeatReqs {
		messages = append(messages, request)
	}

	for _, message := range messages {
		wire, err := gproto.Marshal(message)
		if err != nil {
			t.Fatalf("marshal gateway request: %v", err)
		}
		for _, secret := range secrets {
			if strings.Contains(string(wire), secret) {
				t.Fatalf("gateway request %T carries %q", message, secret)
			}
		}
	}
}
