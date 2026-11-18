package sdk

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// Camera source resolution lets ServiceRadar open a camera stream without
// storing its address. A stream address is a secret: an RTSP path alias works
// as a bearer token and other addresses carry credentials. When a stream
// opens, the agent runs the camera inventory plugin that discovered the camera
// with a resolution request in its config, and the plugin answers with the
// address. The agent hands that address to its stream reader and keeps it
// nowhere else.
//
// A plugin's entrypoint checks for the request before doing anything else:
//
//	request, ok, err := sdk.CameraSourceResolutionRequested()
//	if err != nil { return err }
//	if ok { return resolve(request) } // SubmitCameraSourceURL or SubmitCameraSourceFailure
//
// A resolver never creates or enables a stream on the camera or controller,
// and never logs the address.

const (
	// CameraSourceResolutionRequestConfigKey is the host-owned config key
	// carrying a resolution request.
	CameraSourceResolutionRequestConfigKey = "_serviceradar_camera_source_resolution_request"
	// CameraSourceResolutionRequestSchemaV1 identifies the request document.
	CameraSourceResolutionRequestSchemaV1 = "serviceradar.camera_source_resolution_request.v1"
	// CameraSourceResolutionSchemaV1 identifies the plugin's answer.
	CameraSourceResolutionSchemaV1 = "serviceradar.camera_source_resolution.v1"

	// CameraStreamAddressesConfigKey is the host-owned config key that tells
	// a camera inventory plugin how to report stream addresses.
	CameraStreamAddressesConfigKey = "_serviceradar_camera_stream_addresses"
	// CameraStreamAddressesOmit is the value that asks the plugin to leave
	// stream addresses out of inventory results and report only each
	// profile's origin (scheme, host and port).
	CameraStreamAddressesOmit = "omit"
)

var (
	errCameraSourceRequestSchema   = errors.New("unsupported camera source resolution request schema")
	errCameraSourceRequestCameraID = errors.New("camera source resolution request has no vendor_camera_id")
	errCameraSourceResolutionShape = errors.New("camera source resolution needs exactly one of url and failure_class")
	errCameraStreamAddressesNotStr = errors.New(CameraStreamAddressesConfigKey + " is not a string")
)

// Failure classes a resolver may report. The host reports any other class as
// unknown.
const (
	// CameraSourceFailureNotFound: the camera or profile is unknown to the
	// controller, or streaming is disabled for it.
	CameraSourceFailureNotFound           = "source_not_found"
	CameraSourceFailureAuthentication     = "authentication_failed"
	CameraSourceFailureDNS                = "dns_failure"
	CameraSourceFailureConnectRefused     = "connect_refused"
	CameraSourceFailureConnectTimeout     = "connect_timeout"
	CameraSourceFailureHostUnreachable    = "host_unreachable"
	CameraSourceFailureConnectFailed      = "connect_failed"
	CameraSourceFailureTLSCertificate     = "tls_certificate_invalid"
	CameraSourceFailureTLSHandshakeFailed = "tls_handshake_failed"
)

// CameraSourceResolutionRequest names the camera and stream profile whose
// address the host needs, by the ids the plugin reported in its inventory.
type CameraSourceResolutionRequest struct {
	Schema          string `json:"schema"`
	VendorCameraID  string `json:"vendor_camera_id"`
	VendorProfileID string `json:"vendor_profile_id,omitempty"`
}

// CameraSourceResolution is the plugin's answer: an address, or a failure.
type CameraSourceResolution struct {
	Schema string `json:"schema"`
	// URL is the full stream address and may carry userinfo.
	URL           string `json:"url,omitempty"`
	FailureClass  string `json:"failure_class,omitempty"`
	FailureDetail string `json:"failure_detail,omitempty"`
}

// CameraSourceResolutionRequested returns the resolution request delivered to
// the current run. ok is false for an ordinary run.
func CameraSourceResolutionRequested() (request CameraSourceResolutionRequest, ok bool, err error) {
	data, err := getConfigBytes()
	if err != nil {
		return CameraSourceResolutionRequest{}, false, err
	}
	return ParseCameraSourceResolutionRequest(data)
}

// ParseCameraSourceResolutionRequest extracts the resolution request from a
// run config document. ok is false when the config carries none.
func ParseCameraSourceResolutionRequest(configJSON []byte) (request CameraSourceResolutionRequest, ok bool, err error) {
	raw, ok, err := hostConfigValue(configJSON, CameraSourceResolutionRequestConfigKey)
	if err != nil || !ok {
		return CameraSourceResolutionRequest{}, false, err
	}

	if err := json.Unmarshal(raw, &request); err != nil {
		return CameraSourceResolutionRequest{}, false, fmt.Errorf("decode camera source resolution request: %w", err)
	}
	if request.Schema != CameraSourceResolutionRequestSchemaV1 {
		return CameraSourceResolutionRequest{}, false,
			fmt.Errorf("%w %q", errCameraSourceRequestSchema, request.Schema)
	}
	if strings.TrimSpace(request.VendorCameraID) == "" {
		return CameraSourceResolutionRequest{}, false, errCameraSourceRequestCameraID
	}
	return request, true, nil
}

// SubmitCameraSourceURL answers a resolution request with the stream address.
func SubmitCameraSourceURL(url string) error {
	return submitCameraSourceResolution(CameraSourceResolution{URL: url})
}

// SubmitCameraSourceFailure answers a resolution request with a failure. Use
// one of the CameraSourceFailure classes. The detail is shown to operators, so
// it must not contain the address or a credential.
func SubmitCameraSourceFailure(class, detail string) error {
	return submitCameraSourceResolution(CameraSourceResolution{FailureClass: class, FailureDetail: detail})
}

func submitCameraSourceResolution(resolution CameraSourceResolution) error {
	payload, err := resolution.Serialize()
	if err != nil {
		return err
	}
	return SubmitResult(payload)
}

// Serialize encodes the resolution document. A resolution holds exactly one of
// an address and a failure class.
func (r CameraSourceResolution) Serialize() ([]byte, error) {
	r.Schema = CameraSourceResolutionSchemaV1
	r.URL = strings.TrimSpace(r.URL)
	r.FailureClass = strings.TrimSpace(r.FailureClass)
	if (r.URL == "") == (r.FailureClass == "") {
		return nil, errCameraSourceResolutionShape
	}
	if r.URL != "" {
		r.FailureDetail = ""
	}
	return json.Marshal(r)
}

// OmitCameraStreamAddresses reports whether the host asked the current run to
// leave stream addresses out of its inventory result. When it is true, report
// each profile's origin (scheme, host and port) and no stream URL, path or
// alias. When it is false, report addresses as before.
func OmitCameraStreamAddresses() (bool, error) {
	data, err := getConfigBytes()
	if err != nil {
		return false, err
	}
	return ParseOmitCameraStreamAddresses(data)
}

// ParseOmitCameraStreamAddresses reads CameraStreamAddressesConfigKey from a
// run config document. A missing key reads as false; a value that is not a
// string, including null, is an error.
func ParseOmitCameraStreamAddresses(configJSON []byte) (bool, error) {
	raw, ok, err := hostConfigValue(configJSON, CameraStreamAddressesConfigKey)
	if err != nil || !ok {
		return false, err
	}

	// A pointer tells JSON null apart from a string: null decodes without an
	// error and must not read as "report addresses".
	var value *string
	if err := json.Unmarshal(raw, &value); err != nil {
		return false, fmt.Errorf("decode %s: %w", CameraStreamAddressesConfigKey, err)
	}
	if value == nil {
		return false, errCameraStreamAddressesNotStr
	}
	return *value == CameraStreamAddressesOmit, nil
}

func hostConfigValue(configJSON []byte, key string) (json.RawMessage, bool, error) {
	if len(configJSON) == 0 {
		return nil, false, nil
	}

	var config map[string]json.RawMessage
	if err := json.Unmarshal(configJSON, &config); err != nil {
		return nil, false, fmt.Errorf("decode run config: %w", err)
	}
	raw, ok := config[key]
	return raw, ok, nil
}
