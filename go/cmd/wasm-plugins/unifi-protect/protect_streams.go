package main

import (
	"context"
	"fmt"
	"net/url"
	"strings"
)

func resolveProtectStreamSourceURL(ctx context.Context, cfg StreamConfig, client protectHTTPClient, headers map[string]string) (string, error) {
	if strings.TrimSpace(cfg.Relay.SourceURL) != "" {
		return strings.TrimSpace(cfg.Relay.SourceURL), nil
	}
	if strings.TrimSpace(cfg.Relay.CameraSourceID) == "" {
		return "", fmt.Errorf("camera_source_id is required when source_url is not provided")
	}
	if strings.TrimSpace(cfg.Relay.StreamProfileID) == "" {
		return "", fmt.Errorf("stream_profile_id is required when source_url is not provided")
	}

	authMode := "none"
	if strings.TrimSpace(cfg.Config.APIKey) != "" {
		authMode = "api_key"
	}
	bootstrap, _, snapshotErr := fetchProtectSnapshot(ctx, client, cfg.Config, headers, authMode, false)
	if snapshotErr != "" {
		return "", fmt.Errorf("%s", snapshotErr)
	}

	for _, camera := range bootstrap.Cameras {
		if cfg.Relay.CameraSourceID != "" && cfg.Relay.CameraSourceID != camera.ID && cfg.Relay.CameraSourceID != camera.MAC {
			continue
		}
		for _, channel := range camera.Channels {
			if !protectChannelMatchesRelay(cfg.Relay, channel) {
				continue
			}
			if url := buildProtectStreamURL(cfg.Config, camera, channel); url != "" {
				return url, nil
			}
		}
	}

	return "", fmt.Errorf("no RTSP stream URL available for requested Protect camera")
}

func buildProtectStreamURL(cfg Config, camera ProtectCamera, channel ProtectChannel) string {
	alias := strings.TrimSpace(channel.RTSPAlias)
	if alias == "" {
		if direct := strings.TrimSpace(channel.RTSPSAlias); direct != "" {
			return sanitizeProtectStreamURL(direct)
		}
		return ""
	}
	host := firstNonEmpty(
		strings.TrimSpace(camera.ConnectionHost),
		strings.TrimSpace(camera.Host),
	)
	if host == "" {
		host = strings.TrimSpace(cfg.Host)
	}
	if host == "" {
		return ""
	}
	return sanitizeProtectStreamURL(
		fmt.Sprintf("rtsp://%s:%d/%s", host, cfg.normalizedRTSPPort(), strings.TrimPrefix(alias, "/")),
	)
}

func sanitizeProtectStreamURL(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}

	parsed, err := url.Parse(raw)
	if err != nil {
		return raw
	}

	query := parsed.Query()
	query.Del("enableSrtp")
	parsed.RawQuery = query.Encode()

	return parsed.String()
}

func protectChannelMatchesRelay(relay RelayConfig, channel ProtectChannel) bool {
	profileID := strings.TrimSpace(relay.StreamProfileID)
	if profileID == "" {
		return true
	}

	if profileID == strings.TrimSpace(channel.ID) {
		return true
	}
	if profileID == strings.TrimSpace(channel.Name) {
		return true
	}

	return false
}
