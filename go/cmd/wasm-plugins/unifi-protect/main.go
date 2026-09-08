package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

//export run_check
func run_check() {
	_ = sdk.Execute(func() (*sdk.Result, error) {
		var initCfg Config
		_ = json.Unmarshal([]byte(`{"host":"x"}`), &initCfg)

		cfg, err := loadConfig()
		if err != nil {
			sdk.Log.Warn("failed to load config: " + err.Error())
		}

		cfg.Host = strings.TrimSpace(cfg.Host)
		if cfg.Host == "" {
			return sdk.Unknown("configuration error: host is required"), nil
		}

		client, err := sdk.NewCameraHTTPClient(cfg.CameraPluginConfig, 10*time.Second)
		if err != nil {
			return sdk.Unknown("configuration error: " + err.Error()), nil
		}

		headers, authMode, err := protectSessionHeaders(context.Background(), cfg, client)
		if err != nil {
			return sdk.Unknown("protect auth error: " + err.Error()), nil
		}

		needLastUpdateID := cfg.CollectEvents && authMode != "api_key"
		bootstrap, endpointResults, snapshotErr := fetchProtectSnapshot(context.Background(), client, cfg, headers, authMode, needLastUpdateID)
		details := ResultDetails{
			ControllerHost: cfg.Host,
			Endpoints:      endpointResults,
			Metadata: map[string]interface{}{
				"plugin":             "unifi-protect-camera",
				"base_url":           client.BaseURL,
				"bootstrap_path":     cfg.normalizedBootstrapPath(),
				"auth_mode":          authMode,
				"collect_events":     cfg.CollectEvents,
				"event_sources":      cfg.EventSources,
				"collection_timeout": client.Timeout.String(),
			},
		}
		resultEvents := make([]sdk.OCSFEvent, 0, 4)

		if snapshotErr != "" {
			details.CollectionError = snapshotErr
		}

		networkClients, networkEndpoints := fetchUniFiNetworkClients(
			context.Background(),
			client,
			headers,
			cfg,
			bootstrap.Cameras,
		)
		details.Endpoints = append(details.Endpoints, networkEndpoints...)
		details.Cameras = bootstrap.Cameras
		details.Streams = buildProtectStreams(cfg, bootstrap.Cameras)
		details.CameraDescriptors = buildProtectCameraDescriptors(cfg, bootstrap.Cameras, networkClients)
		if len(networkClients) > 0 {
			details.Metadata["network_client_matches"] = len(networkClients)
		}
		if cfg.CollectEvents {
			events, eventRes := collectProtectEvents(cfg, headers, client.Timeout, bootstrap.LastUpdateID, authMode)
			details.Endpoints = append(details.Endpoints, eventRes)
			resultEvents = append(resultEvents, events...)
		}

		detailsJSON, err := json.Marshal(details)
		if err != nil {
			return nil, fmt.Errorf("marshal details: %w", err)
		}

		summary := fmt.Sprintf("UniFi Protect: %d cameras, %d streams", len(details.Cameras), len(details.Streams))
		status := sdk.StatusWarning
		if snapshotErr == "" && len(details.Cameras) > 0 {
			status = sdk.StatusOK
		}
		if snapshotErr != "" {
			status = sdk.StatusCritical
			if details.CollectionError != "" {
				summary += ": " + details.CollectionError
			}
		}
		if status == sdk.StatusOK && cfg.CollectEvents {
			lastEndpoint := details.Endpoints[len(details.Endpoints)-1]
			if lastEndpoint.Path == "/proxy/protect/ws/updates" && lastEndpoint.Error != "" {
				status = sdk.StatusWarning
				summary += ", events unavailable"
			}
		}

		result := sdk.NewResult().
			WithStatus(status).
			WithSummary(summary).
			WithDetails(string(detailsJSON)).
			WithLabel("controller_host", cfg.Host).
			WithLabel("camera_scheme", client.BaseURL[:strings.Index(client.BaseURL, "://")])
		emitProtectTelemetry(resultEvents, cfg.Host)
		emitProtectMetricTelemetry(cfg.Host, len(details.Cameras), len(details.Streams), len(resultEvents))

		return result, nil
	})
}

//export stream_camera
func stream_camera() {
	cfg, err := loadStreamConfig()
	if err != nil {
		sdk.Log.Warn("failed to load stream config: " + err.Error())
	}

	cfg.Host = strings.TrimSpace(cfg.Host)
	if cfg.Host == "" {
		sdk.Log.Error("stream_camera configuration error: host is required")
		return
	}

	client, err := sdk.NewCameraHTTPClient(cfg.CameraPluginConfig, 10*time.Second)
	if err != nil {
		sdk.Log.Error("stream_camera configuration error: " + err.Error())
		return
	}

	headers, _, err := protectSessionHeaders(context.Background(), cfg.Config, client)
	if err != nil {
		sdk.Log.Error("stream_camera auth error: " + err.Error())
		return
	}

	sourceURL, err := resolveProtectStreamSourceURL(context.Background(), cfg, client, headers)
	if err != nil {
		sdk.Log.Error("stream_camera source resolution failed: " + err.Error())
		return
	}

	if err := streamProtectRTSP(cfg, client.Timeout, sourceURL); err != nil {
		sdk.Log.Error("stream_camera rtsp path failed: " + err.Error())
		return
	}
}
func main() {}
