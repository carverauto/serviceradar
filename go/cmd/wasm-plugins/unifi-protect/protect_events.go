package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func collectProtectEvents(
	cfg Config,
	headers map[string]string,
	timeout time.Duration,
	lastUpdateID string,
	authMode string,
) ([]sdk.OCSFEvent, EndpointResult) {
	scheme, err := cfg.NormalizedScheme()
	if err != nil {
		return nil, EndpointResult{Error: err.Error()}
	}

	wsPath := "/proxy/protect/ws/updates"
	query := ""
	if authMode == "api_key" {
		wsPath = "/proxy/protect/integration/v1/subscribe/events"
	} else {
		lastUpdateID = strings.TrimSpace(lastUpdateID)
		if lastUpdateID == "" {
			return nil, EndpointResult{Path: wsPath, Error: "bootstrap payload missing lastUpdateId"}
		}
		query = "?lastUpdateId=" + url.QueryEscape(lastUpdateID)
	}

	result := EndpointResult{Path: wsPath}
	wsScheme := "ws"
	if scheme == "https" {
		wsScheme = "wss"
	}

	wsURL := fmt.Sprintf("%s://%s%s%s", wsScheme, strings.TrimSpace(cfg.Host), wsPath, query)
	conn, err := protectEventDial(wsURL, headers, cfg.InsecureSkipVerify, timeout)
	if err != nil {
		result.Error = "websocket connect failed: " + err.Error()
		return nil, result
	}
	defer func() { _ = conn.Close() }()

	events := make([]sdk.OCSFEvent, 0, 4)
	buf := make([]byte, 64*1024)
	for i := 0; i < 4; i++ {
		n, recvErr := conn.Recv(buf, 800*time.Millisecond)
		if recvErr != nil || n <= 0 {
			break
		}
		if evt := mapProtectWSEvent(buf[:n]); evt != nil {
			events = append(events, *evt)
		}
	}

	result.Status = http.StatusOK
	result.EventCount = len(events)
	return events, result
}

func mapProtectWSEvent(data []byte) *sdk.OCSFEvent {
	var payload map[string]interface{}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil
	}

	message, severity := describeProtectEvent(payload)
	event := sdk.NewOCSFEventLogActivity(message, severity)
	event.LogProvider = "unifi-protect-camera"
	event.RawData = string(data)
	if event.Unmapped == nil {
		event.Unmapped = map[string]interface{}{}
	}
	event.Unmapped["protect_ws_payload"] = payload

	if obj, ok := eventObject(payload); ok {
		device := map[string]any{}
		if id := mapString(obj, "id"); id != "" {
			device["uid"] = id
		}
		if name := firstNonEmpty(mapString(obj, "displayName"), mapString(obj, "name"), mapString(payload, "id")); name != "" {
			device["name"] = name
		}
		if mac := mapString(obj, "mac"); mac != "" {
			device["mac"] = mac
		}
		if len(device) > 0 {
			event.Device = device
		}
	}

	return &event
}

func describeProtectEvent(payload map[string]interface{}) (string, sdk.Severity) {
	modelKey := firstNonEmpty(mapString(payload, "modelKey"), mapStringFromNested(payload, "newObj", "modelKey"))
	action := strings.ToLower(firstNonEmpty(mapString(payload, "action"), "update"))
	deviceName := firstNonEmpty(
		mapStringFromNested(payload, "newObj", "displayName"),
		mapStringFromNested(payload, "newObj", "name"),
		mapString(payload, "id"),
	)

	message := "UniFi Protect event"
	if modelKey != "" {
		message = "UniFi Protect " + modelKey + " " + action
	}
	if deviceName != "" {
		message += " for " + deviceName
	}

	changed := mapNested(payload, "changedData")
	if len(changed) == 0 {
		changed = mapNested(payload, "newObj", "changedData")
	}

	severity := sdk.SeverityInfo
	switch {
	case mapHasKey(changed, "lastRing"):
		message = "UniFi Protect doorbell ring"
		if deviceName != "" {
			message += " for " + deviceName
		}
		severity = sdk.SeverityWarning
	case mapHasKey(changed, "smartDetectTypes") || mapHasKey(changed, "lastSmartDetect"):
		message = "UniFi Protect smart detection"
		if deviceName != "" {
			message += " for " + deviceName
		}
		severity = sdk.SeverityWarning
	case mapHasKey(changed, "lastMotion") || truthy(changed["isMotionDetected"]):
		message = "UniFi Protect motion event"
		if deviceName != "" {
			message += " for " + deviceName
		}
		severity = sdk.SeverityWarning
	}

	return message, severity
}

func eventObject(payload map[string]interface{}) (map[string]interface{}, bool) {
	if obj := mapNested(payload, "newObj"); len(obj) > 0 {
		return obj, true
	}
	if obj := mapNested(payload, "oldObj"); len(obj) > 0 {
		return obj, true
	}
	return nil, false
}
