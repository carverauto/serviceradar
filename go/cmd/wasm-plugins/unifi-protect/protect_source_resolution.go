package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
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

// protectSourceFailure is a resolution failure. detail is shown to operators
// and never holds an address, alias or credential.
type protectSourceFailure struct {
	class  string
	detail string
}

// handleProtectSourceResolution answers a camera source resolution request
// when the run carries one. It reports whether the run was a resolution run;
// such a run never falls through to inventory.
func handleProtectSourceResolution(raw []byte) bool {
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

	sourceURL, failure := resolveProtectCameraSource(context.Background(), raw, request)
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

func resolveProtectCameraSource(
	ctx context.Context,
	raw []byte,
	request sdk.CameraSourceResolutionRequest,
) (string, *protectSourceFailure) {
	cfg, err := decodeConfig(raw)
	if err != nil {
		return "", &protectSourceFailure{sdk.CameraSourceFailureConnectFailed, "the plugin configuration is not readable"}
	}
	cfg.Host = strings.TrimSpace(cfg.Host)
	client, err := sdk.NewCameraHTTPClient(cfg.CameraPluginConfig, 10*time.Second)
	if err != nil {
		return "", &protectSourceFailure{sdk.CameraSourceFailureConnectFailed, "the plugin configuration has no usable controller address"}
	}

	headers, _, err := protectSessionHeaders(ctx, cfg, client)
	if err != nil {
		return "", classifyProtectControllerError("login", err)
	}

	return resolveProtectSourceFromController(ctx, client, cfg, headers, request)
}

// resolveProtectSourceFromController reads the address of one camera profile
// from the controller with GET requests only; it never creates or enables a
// stream. A quality profile (the integration inventory path) is read from the
// camera's integration rtsps-stream document; a channel id (the bootstrap
// inventory path), or an integration request answered with HTTP 404, is read
// from the bootstrap channel alias.
func resolveProtectSourceFromController(
	ctx context.Context,
	client protectHTTPClient,
	cfg Config,
	headers map[string]string,
	request sdk.CameraSourceResolutionRequest,
) (string, *protectSourceFailure) {
	cameraID := strings.TrimSpace(request.VendorCameraID)
	profileID := strings.TrimSpace(request.VendorProfileID)

	if profileID == "" || isProtectIntegrationQuality(profileID) {
		streams, err := fetchProtectIntegrationRTSPSStreams(ctx, client, cameraID, headers)
		switch {
		case err == nil:
			return selectProtectIntegrationStream(streams, profileID)
		case !protectIntegrationMissing(err):
			return "", classifyProtectControllerError("rtsps-stream", err)
		}
	}

	snapshot, _, err := requestProtectBootstrap(ctx, client, cfg, headers)
	if err != nil {
		return "", classifyProtectControllerError("bootstrap", err)
	}
	return selectProtectBootstrapStream(cfg, snapshot.Cameras, cameraID, profileID)
}

func isProtectIntegrationQuality(profileID string) bool {
	for _, quality := range protectIntegrationQualities {
		if profileID == quality {
			return true
		}
	}
	return false
}

// protectIntegrationMissing reports an integration answer that sends the
// resolver to the bootstrap: HTTP 404, from a controller without the
// integration API or without this camera id. Every other failure is final.
func protectIntegrationMissing(err error) bool {
	var statusErr protectStatusError
	return errors.As(err, &statusErr) && statusErr.status == http.StatusNotFound
}

func selectProtectIntegrationStream(streams protectRTSPSStreams, profileID string) (string, *protectSourceFailure) {
	for _, channel := range buildProtectIntegrationChannels(streams) {
		if profileID == "" || channel.ID == profileID {
			return sanitizeProtectStreamURL(channel.RTSPSAlias), nil
		}
	}
	return "", &protectSourceFailure{
		sdk.CameraSourceFailureNotFound,
		"the controller reports no RTSP stream for this camera quality",
	}
}

func selectProtectBootstrapStream(
	cfg Config,
	cameras []ProtectCamera,
	cameraID, profileID string,
) (string, *protectSourceFailure) {
	for _, camera := range cameras {
		if !protectCameraMatches(camera, cameraID) {
			continue
		}
		for _, channel := range camera.Channels {
			if profileID != "" && strings.TrimSpace(channel.ID) != profileID {
				continue
			}
			if sourceURL := buildProtectStreamURL(cfg, camera, channel); sourceURL != "" {
				return sourceURL, nil
			}
		}
		return "", &protectSourceFailure{
			sdk.CameraSourceFailureNotFound,
			"the controller reports no RTSP stream for this camera channel",
		}
	}
	return "", &protectSourceFailure{sdk.CameraSourceFailureNotFound, "the controller does not know this camera"}
}

// protectCameraMatches accepts the camera id the inventory reports: the
// Protect id, or the MAC for a camera without one.
func protectCameraMatches(camera ProtectCamera, cameraID string) bool {
	if id := strings.TrimSpace(camera.ID); id != "" {
		return id == cameraID
	}
	mac := normalizeMACKey(camera.MAC)
	return mac != "" && mac == normalizeMACKey(cameraID)
}

func protectCredentialRejected(status int) bool {
	return status == http.StatusUnauthorized || status == http.StatusForbidden
}

// classifyProtectControllerError maps a failed controller request to a relay
// failure class. stage names the request in the operator detail.
func classifyProtectControllerError(stage string, err error) *protectSourceFailure {
	var statusErr protectStatusError
	if errors.As(err, &statusErr) {
		if protectCredentialRejected(statusErr.status) {
			return &protectSourceFailure{
				sdk.CameraSourceFailureAuthentication,
				fmt.Sprintf("the controller rejected the plugin credentials (%s, HTTP %d)", stage, statusErr.status),
			}
		}
		return &protectSourceFailure{
			sdk.CameraSourceFailureConnectFailed,
			fmt.Sprintf("the controller answered the %s request with HTTP %d", stage, statusErr.status),
		}
	}
	var syntaxErr *json.SyntaxError
	var typeErr *json.UnmarshalTypeError
	if errors.As(err, &syntaxErr) || errors.As(err, &typeErr) {
		return &protectSourceFailure{sdk.CameraSourceFailureConnectFailed, "the controller answered the " + stage + " request with an unreadable body"}
	}
	if errors.Is(err, errProtectLoginNoSessionCookie) {
		return &protectSourceFailure{sdk.CameraSourceFailureAuthentication, "the controller login returned no session"}
	}

	var hostErr sdk.HostError
	if errors.As(err, &hostErr) {
		switch hostErr.Code {
		case timeoutHostErrorCode:
			return &protectSourceFailure{sdk.CameraSourceFailureConnectTimeout, "the controller did not answer the " + stage + " request in time"}
		case deniedHostErrorCode:
			return &protectSourceFailure{sdk.CameraSourceFailureConnectFailed, "the agent did not permit the " + stage + " request to the controller"}
		}
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return &protectSourceFailure{sdk.CameraSourceFailureConnectTimeout, "the controller did not answer the " + stage + " request in time"}
	}
	return &protectSourceFailure{sdk.CameraSourceFailureConnectFailed, "the controller could not be reached for the " + stage + " request"}
}
