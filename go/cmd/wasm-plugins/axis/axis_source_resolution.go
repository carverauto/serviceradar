package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"

	"github.com/carverauto/serviceradar/contrib/plugins/go/axis/internal/axisref"
)

// Host ABI error codes the SDK reports as sdk.HostError for http_request. The
// agent returns timeoutHostErrorCode when the request deadline passed and
// deniedHostErrorCode when its egress or credential policy refused the
// request. Every other transport failure (DNS, refused, unreachable, TLS) is
// one internal error code and cannot be told apart.
const (
	deniedHostErrorCode  int32 = -2
	timeoutHostErrorCode int32 = -6
)

const axisStreamProfileListPath = "/axis-cgi/streamprofile.cgi?list"

// axisSourceFailure is a resolution failure. detail is shown to operators and
// never holds an address or credential.
type axisSourceFailure struct {
	class  string
	detail string
}

// handleAxisSourceResolution answers a camera source resolution request when
// the run carries one. It reports whether the run was a resolution run; such a
// run never falls through to inventory.
func handleAxisSourceResolution(raw []byte) bool {
	request, requested, err := sdk.ParseCameraSourceResolutionRequest(raw)
	if err != nil {
		_ = sdk.Execute(func() (*sdk.Result, error) {
			return sdk.Unknown("camera source resolution request rejected: " + err.Error()), nil
		})
		return true
	}
	if !requested {
		return false
	}

	sourceURL, failure := resolveAxisCameraSource(context.Background(), raw, request)
	if failure != nil {
		err = sdk.SubmitCameraSourceFailure(failure.class, failure.detail)
	} else {
		err = sdk.SubmitCameraSourceURL(sourceURL)
	}
	if err != nil {
		sdk.Log.Error("failed to submit camera source resolution")
	}
	return true
}

func resolveAxisCameraSource(ctx context.Context, raw []byte, request sdk.CameraSourceResolutionRequest) (string, *axisSourceFailure) {
	cfg, err := decodeConfig(raw)
	if err != nil {
		return "", &axisSourceFailure{sdk.CameraSourceFailureConnectFailed, "the plugin configuration is not readable"}
	}
	cfg.Host = strings.TrimSpace(cfg.Host)
	client, err := sdk.NewCameraHTTPClient(cfg.CameraPluginConfig, 10*1e9)
	if err != nil {
		return "", &axisSourceFailure{sdk.CameraSourceFailureConnectFailed, "the plugin configuration has no usable camera address"}
	}

	return resolveAxisSourceFromCamera(ctx, client, cfg, request.VendorProfileID)
}

// resolveAxisSourceFromCamera rebuilds the RTSP address the inventory reports
// for one stream profile. The media parameters live on the camera, so it reads
// the stream profile list (one GET), then adds the plugin's credentials as
// userinfo. An empty profile id selects the first profile, as the inventory's
// camera source_url does.
func resolveAxisSourceFromCamera(
	ctx context.Context,
	client cameraHTTPGetter,
	cfg Config,
	profileID string,
) (string, *axisSourceFailure) {
	resp, err := client.GetContext(ctx, axisStreamProfileListPath)
	if err != nil {
		return "", classifyAxisTransportError(err)
	}
	if resp.Status == http.StatusUnauthorized || resp.Status == http.StatusForbidden {
		return "", &axisSourceFailure{
			sdk.CameraSourceFailureAuthentication,
			fmt.Sprintf("the camera rejected the plugin credentials (HTTP %d)", resp.Status),
		}
	}
	if resp.Status != http.StatusOK {
		return "", &axisSourceFailure{
			sdk.CameraSourceFailureConnectFailed,
			fmt.Sprintf("the camera answered the stream profile request with HTTP %d", resp.Status),
		}
	}
	kv, err := axisref.ParseKeyValueBody(string(resp.Body))
	if err != nil {
		return "", &axisSourceFailure{sdk.CameraSourceFailureConnectFailed, "the camera returned an unreadable stream profile list"}
	}

	profileID = strings.TrimSpace(profileID)
	for _, profile := range axisref.ParseStreamProfiles(kv) {
		if profileID != "" && axisStreamProfileID(profile) != profileID {
			continue
		}
		sourceURL, ok := withAxisStreamCredentials(buildRTSPURL(axisRTSPHost(cfg), profile.Parameters), cfg.Username, cfg.Password)
		if !ok {
			return "", &axisSourceFailure{sdk.CameraSourceFailureNotFound, "the camera stream profile does not form a valid RTSP address"}
		}
		return sourceURL, nil
	}
	return "", &axisSourceFailure{sdk.CameraSourceFailureNotFound, "the camera has no such stream profile"}
}

// withAxisStreamCredentials puts the plugin's credentials in the URL userinfo,
// percent-encoded, for the agent's RTSP reader. Without credentials the URL is
// returned unchanged.
func withAxisStreamCredentials(rawURL, username, password string) (string, bool) {
	if strings.TrimSpace(username) == "" && strings.TrimSpace(password) == "" {
		return rawURL, true
	}
	if _, err := url.Parse(rawURL); err != nil {
		return "", false
	}
	return sdk.WithURLUserInfo(rawURL, username, password), true
}

func classifyAxisTransportError(err error) *axisSourceFailure {
	var hostErr sdk.HostError
	if errors.As(err, &hostErr) {
		switch hostErr.Code {
		case timeoutHostErrorCode:
			return &axisSourceFailure{sdk.CameraSourceFailureConnectTimeout, "the camera did not answer in time"}
		case deniedHostErrorCode:
			return &axisSourceFailure{sdk.CameraSourceFailureConnectFailed, "the agent did not permit the request to the camera"}
		}
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return &axisSourceFailure{sdk.CameraSourceFailureConnectTimeout, "the camera did not answer in time"}
	}
	return &axisSourceFailure{sdk.CameraSourceFailureConnectFailed, "the camera could not be reached"}
}
