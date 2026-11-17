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
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// The camera source resolution contract between the agent and a camera
// inventory plugin. The request reaches the plugin as a host-owned key in its
// assignment config; the plugin submits the resolution document as its result.
const (
	cameraSourceResolutionRequestSchema    = "serviceradar.camera_source_resolution_request.v1"
	cameraSourceResolutionSchema           = "serviceradar.camera_source_resolution.v1"
	cameraSourceResolutionRequestConfigKey = "_serviceradar_camera_source_resolution_request"
)

var (
	errCameraRelaySourceResolverInvalid     = errors.New("source_resolver requires plugin_assignment_id and vendor_camera_id")
	errCameraRelaySourceResolverUnavailable = errors.New("the discovering plugin assignment is not loaded on this agent")
	errCameraRelaySourceResolverUnsupported = errors.New("the plugin did not return a camera source resolution")
	errCameraSourceResolverParams           = errors.New("plugin assignment params are not a JSON object")
)

// cameraRelaySourceResolver names the plugin assignment that discovered a
// camera and the vendor ids its plugin needs to derive the stream address.
type cameraRelaySourceResolver struct {
	PluginAssignmentID string `json:"plugin_assignment_id"`
	VendorCameraID     string `json:"vendor_camera_id"`
	VendorProfileID    string `json:"vendor_profile_id,omitempty"`
}

type cameraSourceResolutionRequest struct {
	Schema          string `json:"schema"`
	VendorCameraID  string `json:"vendor_camera_id"`
	VendorProfileID string `json:"vendor_profile_id,omitempty"`
}

type cameraSourceResolution struct {
	Schema        string `json:"schema"`
	URL           string `json:"url"`
	FailureClass  string `json:"failure_class"`
	FailureDetail string `json:"failure_detail"`
}

// cameraSourceResolutionError is a failure the plugin reported instead of an
// address. Its class is one of cameraSourceResolutionFailureClasses.
type cameraSourceResolutionError struct {
	class  string
	detail string
}

func (e *cameraSourceResolutionError) Error() string {
	if e.detail == "" {
		return "camera source resolution failed"
	}
	return e.detail
}

// The classes a plugin resolver may report. Anything else is reported as
// unknown, so a plugin cannot invent operator-facing classes.
var cameraSourceResolutionFailureClasses = map[string]struct{}{
	cameraRelayFailureSourceNotFound:  {},
	cameraRelayFailureAuthentication:  {},
	cameraRelayFailureDNS:             {},
	cameraRelayFailureConnectRefused:  {},
	cameraRelayFailureConnectTimeout:  {},
	cameraRelayFailureHostUnreachable: {},
	cameraRelayFailureConnectFailed:   {},
	cameraRelayFailureTLSCertificate:  {},
	cameraRelayFailureTLSHandshake:    {},
}

func normalizeCameraRelaySourceResolver(resolver cameraRelaySourceResolver) (cameraRelaySourceResolver, error) {
	resolver.PluginAssignmentID = strings.TrimSpace(resolver.PluginAssignmentID)
	resolver.VendorCameraID = strings.TrimSpace(resolver.VendorCameraID)
	resolver.VendorProfileID = strings.TrimSpace(resolver.VendorProfileID)
	if resolver.PluginAssignmentID == "" || resolver.VendorCameraID == "" {
		return resolver, errCameraRelaySourceResolverInvalid
	}
	return resolver, nil
}

// buildCameraSourceResolutionConfig returns the assignment's own params with
// the resolution request added, so the plugin authenticates to its controller
// exactly as a scheduled run does.
func buildCameraSourceResolutionConfig(paramsJSON []byte, resolver cameraRelaySourceResolver) ([]byte, error) {
	config := map[string]json.RawMessage{}
	if len(bytes.TrimSpace(paramsJSON)) > 0 {
		if err := json.Unmarshal(paramsJSON, &config); err != nil || config == nil {
			return nil, errCameraSourceResolverParams
		}
	}

	request, err := json.Marshal(cameraSourceResolutionRequest{
		Schema:          cameraSourceResolutionRequestSchema,
		VendorCameraID:  resolver.VendorCameraID,
		VendorProfileID: resolver.VendorProfileID,
	})
	if err != nil {
		return nil, fmt.Errorf("encode camera source resolution request: %w", err)
	}

	config[cameraSourceResolutionRequestConfigKey] = request
	return json.Marshal(config)
}

// decodeCameraSourceResolution reads a plugin's answer. A result that is not a
// resolution document (an older plugin answers with its ordinary inventory
// result) is errCameraRelaySourceResolverUnsupported. Errors never quote the
// result, which may hold the address.
func decodeCameraSourceResolution(result []byte) (string, error) {
	var resolution cameraSourceResolution
	if err := json.Unmarshal(result, &resolution); err != nil || resolution.Schema != cameraSourceResolutionSchema {
		return "", errCameraRelaySourceResolverUnsupported
	}

	if class := strings.TrimSpace(resolution.FailureClass); class != "" {
		if _, known := cameraSourceResolutionFailureClasses[class]; !known {
			class = cameraRelayFailureUnknown
		}
		return "", &cameraSourceResolutionError{class: class, detail: strings.TrimSpace(resolution.FailureDetail)}
	}

	url := strings.TrimSpace(resolution.URL)
	if url == "" {
		return "", errCameraRelaySourceResolverUnsupported
	}
	return url, nil
}

// ResolveCameraSource asks the assignment's plugin for one camera's stream
// address. The address is returned to the caller and held nowhere else.
func (m *PluginManager) ResolveCameraSource(ctx context.Context, resolver cameraRelaySourceResolver) (string, error) {
	if m == nil {
		return "", errCameraRelaySourceResolverUnavailable
	}

	assignment, ok := m.lookupRunnerAssignment(resolver.PluginAssignmentID)
	if !ok {
		return "", errCameraRelaySourceResolverUnavailable
	}

	configJSON, err := buildCameraSourceResolutionConfig(assignment.ParamsJSON, resolver)
	if err != nil {
		return "", err
	}

	result, err := m.runAssignmentOnDemand(ctx, assignment, configJSON, nil, nil, nil, 0)
	if err != nil {
		return "", cameraSourceResolverRunError(ctx, err)
	}
	return decodeCameraSourceResolution(result)
}

// cameraSourceResolverRunError classifies a plugin run that produced no
// result. A run cut short by the relay's own deadline or cancellation keeps
// that cause; the plugin's error text is dropped because it is not sanitized.
func cameraSourceResolverRunError(ctx context.Context, err error) error {
	switch {
	case ctx.Err() != nil:
		return ctx.Err()
	case errors.Is(err, errPluginAdmissionDenied), errors.Is(err, errPluginWasmUnavailable):
		return errCameraRelaySourceResolverUnavailable
	case errors.Is(err, context.DeadlineExceeded):
		return &cameraSourceResolutionError{class: cameraRelayFailureResponseTimeout, detail: "the plugin did not answer in time"}
	default:
		return errCameraRelaySourceResolverUnsupported
	}
}
