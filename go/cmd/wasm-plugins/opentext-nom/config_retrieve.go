package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	// The plugin reads configs NA already stored; it never sends a device show
	// command such as "show running-config", which opens a live device session.
	// list config returns the device's stored revisions (oldest first), and
	// show config -mask returns one with passwords and SNMP communities masked
	// by NA, so no device secret leaves NA.
	listConfigCommand      = "list config"
	showConfigCommand      = "show config"
	configBlockType        = "configuration"
	maxRunningConfigBytes  = 2 * 1024 * 1024
	maxConfigListBytes     = 4 * 1024 * 1024
	configRetrieveActionID = "opentext-nom.config.retrieve"
)

// RunningConfig is the retrieved body plus identity. The plugin does not parse
// interface stanzas; core downparses this into network_config_revisions.
type RunningConfig struct {
	DeviceID  string
	DeviceUID string
	ConfigID  string
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

	listed, err := c.postCommand(ctx, cfg, listConfigCommand, map[string]any{"deviceid": deviceID}, maxConfigListBytes)
	if err != nil {
		return RunningConfig{}, err
	}
	configID, err := newestStoredConfigID(listed)
	if err != nil {
		return RunningConfig{}, err
	}

	// A valueless CLI flag is sent as an empty string: the wrapper renders
	// each parameter as "-key value", and "mask": true fails with
	// "Unformatted Entity true is not valid".
	shown, err := c.postCommand(ctx, cfg, showConfigCommand, map[string]any{"id": configID, "mask": ""}, maxRunningConfigBytes)
	if err != nil {
		return RunningConfig{}, err
	}
	body, err := decodeRunningConfigBody(shown)
	if err != nil {
		return RunningConfig{}, err
	}
	sum := sumSHA256([]byte(body))
	return RunningConfig{
		DeviceID:  deviceID,
		DeviceUID: deviceUID,
		ConfigID:  configID,
		Body:      body,
		Hash:      hex.EncodeToString(sum[:]),
	}, nil
}

// postCommand sends one wrapper command and returns the body of a 200.
func (c *Collector) postCommand(
	ctx context.Context,
	cfg Config,
	command string,
	parameters map[string]any,
	maxBytes int,
) ([]byte, error) {
	payload, err := json.Marshal(map[string]any{"command": command, "parameters": parameters})
	if err != nil {
		return nil, runError("opentext_nom_request_invalid")
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
		return nil, err
	}
	switch response.Status {
	case http.StatusOK:
	case http.StatusUnauthorized:
		return nil, runError("opentext_nom_auth_failed")
	case http.StatusForbidden:
		return nil, runError("opentext_nom_forbidden")
	case http.StatusBadRequest:
		// NA rejects the command itself, e.g. an unknown device or a bad
		// parameter, as distinct from the wrapper being unavailable.
		return nil, runError("opentext_nom_command_rejected")
	default:
		return nil, runError("opentext_nom_api_unavailable")
	}
	if len(response.Body) > maxBytes {
		return nil, runError("opentext_nom_config_too_large")
	}
	return response.Body, nil
}

type storedConfigRow struct {
	DeviceDataID json.Number `json:"deviceDataID"`
	BlockType    string      `json:"blockType"`
	CreateDate   string      `json:"createDate"`
}

// newestStoredConfigID picks the latest configuration revision. NA lists
// revisions oldest first, so order is not trusted: the newest createDate wins,
// and the higher revision ID breaks a tie or an unparseable date.
func newestStoredConfigID(raw []byte) (string, error) {
	var rows []storedConfigRow
	if err := json.Unmarshal(raw, &rows); err != nil {
		var envelope struct {
			Result []storedConfigRow `json:"result"`
		}
		if err := json.Unmarshal(raw, &envelope); err != nil {
			return "", runError("opentext_nom_config_list_invalid")
		}
		rows = envelope.Result
	}

	var (
		bestID   int64
		bestDate time.Time
		found    bool
	)
	for _, row := range rows {
		if !strings.EqualFold(strings.TrimSpace(row.BlockType), configBlockType) {
			continue
		}
		id, err := row.DeviceDataID.Int64()
		if err != nil || id <= 0 {
			continue
		}
		created := parseNATime(row.CreateDate)
		if !found || created.After(bestDate) || (created.Equal(bestDate) && id > bestID) {
			bestID, bestDate, found = id, created, true
		}
	}
	if !found {
		return "", runError("opentext_nom_config_not_found")
	}
	return strconv.FormatInt(bestID, 10), nil
}

// parseNATime reads NA's "2026-09-21T18:52:05.864Z[UTC]" timestamps. An
// unparseable value is the zero time, which never beats a parsed one.
func parseNATime(value string) time.Time {
	value = strings.TrimSpace(value)
	if i := strings.IndexByte(value, '['); i >= 0 {
		value = value[:i]
	}
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return time.Time{}
	}
	return parsed
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
	if strings.HasPrefix(trimmed, "\"") {
		var text string
		if err := json.Unmarshal([]byte(trimmed), &text); err != nil {
			return "", runError("opentext_nom_config_invalid")
		}
		if strings.TrimSpace(text) == "" || !utf8.ValidString(text) {
			return "", runError("opentext_nom_config_invalid")
		}
		return text, nil
	}
	if strings.HasPrefix(trimmed, "<") || json.Valid([]byte(trimmed)) {
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
