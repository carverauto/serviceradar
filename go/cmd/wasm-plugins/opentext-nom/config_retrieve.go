package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"unicode/utf8"
)

const (
	runningConfigCommand   = "show running-config"
	maxRunningConfigBytes  = 2 * 1024 * 1024
	configRetrieveActionID = "opentext-nom.config.retrieve"
)

// RunningConfig is the retrieved body plus identity. The plugin does not parse
// interface stanzas; core downparses this into network_config_revisions.
type RunningConfig struct {
	DeviceID  string
	DeviceUID string
	Body      string
	Hash      string
}

func (c *Collector) RetrieveRunningConfig(
	ctx context.Context,
	cfg Config,
	deviceID string,
	deviceUID string,
) (RunningConfig, error) {
	if c == nil || c.HTTP == nil {
		return RunningConfig{}, runError("opentext_nom_transport_unavailable")
	}
	if err := cfg.Validate(); err != nil {
		return RunningConfig{}, runError("opentext_nom_config_invalid")
	}
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		return RunningConfig{}, runError("opentext_nom_config_device_id_invalid")
	}
	// Core records the revision against device_uid; without one the result
	// could only be rejected downstream.
	deviceUID = strings.TrimSpace(deviceUID)
	if deviceUID == "" {
		return RunningConfig{}, runError("opentext_nom_config_device_uid_invalid")
	}

	payload, err := json.Marshal(map[string]any{
		"command": runningConfigCommand,
		"parameters": map[string]any{
			"id": deviceID,
		},
	})
	if err != nil {
		return RunningConfig{}, runError("opentext_nom_request_invalid")
	}

	response, err := c.doWithRetry(ctx, cfg, HTTPRequest{
		Method: http.MethodPost,
		URL:    cfg.APIURL,
		Headers: map[string]string{
			"Accept":       "application/json",
			"Content-Type": "application/json",
		},
		Body:      payload,
		TimeoutMS: cfg.RequestTimeoutSeconds * 1000,
	})
	if err != nil {
		return RunningConfig{}, err
	}
	if response.Status == http.StatusUnauthorized {
		return RunningConfig{}, runError("opentext_nom_auth_failed")
	}
	if response.Status == http.StatusForbidden {
		return RunningConfig{}, runError("opentext_nom_forbidden")
	}
	if response.Status != http.StatusOK {
		return RunningConfig{}, runError("opentext_nom_api_unavailable")
	}
	if len(response.Body) > maxRunningConfigBytes {
		return RunningConfig{}, runError("opentext_nom_config_too_large")
	}

	body, err := decodeRunningConfigBody(response.Body)
	if err != nil {
		return RunningConfig{}, err
	}
	sum := sha256.Sum256([]byte(body))
	return RunningConfig{
		DeviceID:  deviceID,
		DeviceUID: strings.TrimSpace(deviceUID),
		Body:      body,
		Hash:      hex.EncodeToString(sum[:]),
	}, nil
}

func decodeRunningConfigBody(raw []byte) (string, error) {
	trimmed := strings.TrimSpace(string(raw))
	if trimmed == "" {
		return "", runError("opentext_nom_config_empty")
	}
	if strings.HasPrefix(trimmed, "{") {
		var envelope map[string]any
		if err := json.Unmarshal(raw, &envelope); err != nil {
			return "", runError("opentext_nom_config_invalid")
		}
		if text, ok := runningConfigText(envelope); ok {
			return text, nil
		}
		// The automation wrapper nests its payload the same way list device
		// responses do (see decodeDeviceRows).
		for _, key := range []string{"result", "data"} {
			switch value := envelope[key].(type) {
			case string:
				if strings.TrimSpace(value) != "" && utf8.ValidString(value) {
					return value, nil
				}
			case map[string]any:
				if text, ok := runningConfigText(value); ok {
					return text, nil
				}
			}
		}
		return "", runError("opentext_nom_config_invalid")
	}
	if !utf8.ValidString(trimmed) {
		return "", runError("opentext_nom_config_invalid")
	}
	return trimmed, nil
}

func runningConfigText(envelope map[string]any) (string, bool) {
	for _, key := range []string{"config", "output", "runningConfig", "running_config", "body"} {
		if text, ok := envelope[key].(string); ok && strings.TrimSpace(text) != "" && utf8.ValidString(text) {
			return text, true
		}
	}
	return "", false
}
