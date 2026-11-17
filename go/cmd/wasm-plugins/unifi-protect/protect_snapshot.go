package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func fetchProtectBootstrap(ctx context.Context, client protectHTTPClient, cfg Config, headers map[string]string) (ProtectBootstrapSnapshot, EndpointResult) {
	path := cfg.normalizedBootstrapPath()
	snapshot, resp, err := requestProtectBootstrap(ctx, client, cfg, headers)
	if resp == nil {
		return ProtectBootstrapSnapshot{}, EndpointResult{Path: path, Error: err.Error()}
	}

	result := EndpointResult{
		Path:       path,
		Status:     resp.Status,
		DurationMS: resp.Duration.Milliseconds(),
		BodyBytes:  len(resp.Body),
		Body:       string(resp.Body),
		Duration:   resp.Duration,
	}
	if err != nil {
		result.Error = err.Error()
		return ProtectBootstrapSnapshot{}, trimBody(result)
	}

	result.CameraCount = len(snapshot.Cameras)
	return snapshot, trimBody(result)
}

// requestProtectBootstrap reads the bootstrap document. A nil response means
// the request never got an HTTP answer; otherwise err reports a non-200
// status (protectStatusError) or an undecodable payload.
func requestProtectBootstrap(
	ctx context.Context,
	client protectHTTPClient,
	cfg Config,
	headers map[string]string,
) (ProtectBootstrapSnapshot, *sdk.HTTPResponse, error) {
	resp, err := client.DoContext(ctx, sdk.HTTPRequest{
		Method:  "GET",
		URL:     client.URL(cfg.normalizedBootstrapPath()),
		Headers: headers,
	})
	if err != nil {
		return ProtectBootstrapSnapshot{}, nil, err
	}
	if resp.Status != http.StatusOK {
		return ProtectBootstrapSnapshot{}, resp, protectStatusError{request: "bootstrap request", status: resp.Status}
	}

	var payload ProtectBootstrapResponse
	if err := json.Unmarshal(resp.Body, &payload); err != nil {
		return ProtectBootstrapSnapshot{}, resp, fmt.Errorf("invalid bootstrap payload: %w", err)
	}

	cameras := payload.Cameras
	if len(cameras) == 0 {
		cameras = payload.Data.Cameras
	}
	lastUpdateID := strings.TrimSpace(payload.LastUpdateID)
	if lastUpdateID == "" {
		lastUpdateID = strings.TrimSpace(payload.Data.LastUpdateID)
	}
	return ProtectBootstrapSnapshot{
		Cameras:      cameras,
		LastUpdateID: lastUpdateID,
	}, resp, nil
}

func fetchProtectSnapshot(
	ctx context.Context,
	client protectHTTPClient,
	cfg Config,
	headers map[string]string,
	authMode string,
	needLastUpdateID bool,
) (ProtectBootstrapSnapshot, []EndpointResult, string) {
	endpoints := make([]EndpointResult, 0, 2)

	integrationSnapshot, integrationResult := fetchProtectIntegrationSnapshot(ctx, client, cfg, headers)
	endpoints = append(endpoints, integrationResult)

	useIntegration := integrationResult.Error == "" && len(integrationSnapshot.Cameras) > 0
	if useIntegration && (authMode == "api_key" || !needLastUpdateID) {
		return integrationSnapshot, endpoints, ""
	}

	bootstrapSnapshot, bootstrapResult := fetchProtectBootstrap(ctx, client, cfg, headers)
	endpoints = append(endpoints, bootstrapResult)

	if bootstrapResult.Error == "" {
		if useIntegration {
			integrationSnapshot.LastUpdateID = bootstrapSnapshot.LastUpdateID
			return integrationSnapshot, endpoints, ""
		}

		return bootstrapSnapshot, endpoints, ""
	}

	if useIntegration {
		return integrationSnapshot, endpoints, ""
	}

	if integrationResult.Error != "" {
		return ProtectBootstrapSnapshot{}, endpoints, integrationResult.Error
	}

	if bootstrapResult.Error != "" {
		return ProtectBootstrapSnapshot{}, endpoints, bootstrapResult.Error
	}

	return bootstrapSnapshot, endpoints, ""
}

func fetchProtectIntegrationSnapshot(
	ctx context.Context,
	client protectHTTPClient,
	cfg Config,
	headers map[string]string,
) (ProtectBootstrapSnapshot, EndpointResult) {
	path := "/proxy/protect/integration/v1/cameras"
	resp, err := client.DoContext(ctx, sdk.HTTPRequest{
		Method:  "GET",
		URL:     client.URL(path),
		Headers: headers,
	})
	if err != nil {
		return ProtectBootstrapSnapshot{}, EndpointResult{Path: path, Error: err.Error()}
	}

	result := EndpointResult{
		Path:       path,
		Status:     resp.Status,
		DurationMS: resp.Duration.Milliseconds(),
		BodyBytes:  len(resp.Body),
		Body:       string(resp.Body),
		Duration:   resp.Duration,
	}

	if resp.Status != http.StatusOK {
		result.Error = fmt.Sprintf("integration camera request failed with status %d", resp.Status)
		return ProtectBootstrapSnapshot{}, trimBody(result)
	}

	var cameras []ProtectCamera
	if err := json.Unmarshal(resp.Body, &cameras); err != nil {
		result.Error = "invalid integration camera payload: " + err.Error()
		return ProtectBootstrapSnapshot{}, trimBody(result)
	}

	for i := range cameras {
		camera := &cameras[i]
		if strings.TrimSpace(camera.Host) == "" {
			camera.Host = strings.TrimSpace(cfg.Host)
		}

		streams, streamErr := fetchProtectIntegrationRTSPSStreams(ctx, client, camera.ID, headers)
		if streamErr != nil {
			continue
		}
		camera.Channels = append(camera.Channels[:0], buildProtectIntegrationChannels(streams)...)
	}

	result.CameraCount = len(cameras)
	return ProtectBootstrapSnapshot{Cameras: cameras}, trimBody(result)
}

func fetchProtectIntegrationRTSPSStreams(
	ctx context.Context,
	client protectHTTPClient,
	cameraID string,
	headers map[string]string,
) (protectRTSPSStreams, error) {
	path := fmt.Sprintf("/proxy/protect/integration/v1/cameras/%s/rtsps-stream", url.PathEscape(strings.TrimSpace(cameraID)))
	resp, err := client.DoContext(ctx, sdk.HTTPRequest{
		Method:  "GET",
		URL:     client.URL(path),
		Headers: headers,
	})
	if err != nil {
		return nil, err
	}
	if resp.Status != http.StatusOK {
		return nil, protectStatusError{request: "integration rtsps stream request", status: resp.Status}
	}

	var streams protectRTSPSStreams
	if err := json.Unmarshal(resp.Body, &streams); err != nil {
		return nil, err
	}
	return streams, nil
}

// protectStatusError is a controller answer with an unexpected HTTP status.
type protectStatusError struct {
	request string
	status  int
}

func (e protectStatusError) Error() string {
	return fmt.Sprintf("%s failed with status %d", e.request, e.status)
}

// protectIntegrationQualities are the rtsps-stream qualities, in the order the
// inventory reports them as profiles (vendor_profile_id is the quality).
var protectIntegrationQualities = []string{"high", "medium", "low", "package"}

func buildProtectIntegrationChannels(streams protectRTSPSStreams) []ProtectChannel {
	channels := make([]ProtectChannel, 0, len(protectIntegrationQualities))
	for _, quality := range protectIntegrationQualities {
		raw := streams[quality]
		if raw == nil || strings.TrimSpace(*raw) == "" {
			continue
		}
		channels = append(channels, ProtectChannel{
			ID:         quality,
			Name:       protectQualityLabel(quality),
			RTSPSAlias: strings.TrimSpace(*raw),
		})
	}
	return channels
}

func protectQualityLabel(quality string) string {
	if quality == "" {
		return ""
	}
	return strings.ToUpper(quality[:1]) + quality[1:]
}
