package main

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

type RelayConfig = sdk.CameraRelayConfig

type StreamConfig struct {
	Config
	Relay RelayConfig `json:"relay"`
}

type axisMediaOpenRequest = sdk.CameraMediaOpenRequest
type axisMediaChunkMetadata = sdk.CameraMediaChunkMetadata
type axisMediaHeartbeat = sdk.CameraMediaHeartbeat

func webSocketConnect(rawURL string, headers map[string]string, timeout time.Duration) (*sdk.WebSocketConn, error) {
	if len(headers) == 0 {
		return sdk.WebSocketDial(rawURL, timeout)
	}

	return sdk.WebSocketDialWithHeaders(rawURL, headers, timeout)
}

func openAxisMediaSession(req axisMediaOpenRequest) (*sdk.CameraMediaStream, error) {
	return sdk.OpenCameraMediaStream(req)
}

func writeAxisMedia(stream *sdk.CameraMediaStream, meta axisMediaChunkMetadata, payload []byte) error {
	return stream.Write(meta, payload)
}

func heartbeatAxisMedia(stream *sdk.CameraMediaStream, heartbeat axisMediaHeartbeat) error {
	return stream.Heartbeat(heartbeat)
}

func closeAxisMedia(stream *sdk.CameraMediaStream, reason string) error {
	return stream.Close(reason)
}

func loadStreamConfig() (StreamConfig, error) {
	raw, err := loadRawConfigBytes()
	if err != nil {
		return StreamConfig{Config: defaultConfig()}, err
	}
	return decodeStreamConfig(raw)
}

// decodeStreamConfig parses the streaming config (flat or plugin_inputs
// envelope), then injects the camera host from the relay source URL when no host
// was supplied inline or via the per-target envelope.
func decodeStreamConfig(raw []byte) (StreamConfig, error) {
	cfg, err := decodeConfig(raw)
	stream := StreamConfig{Config: cfg}
	if err != nil {
		return stream, err
	}

	if len(strings.TrimSpace(string(raw))) > 0 {
		var relayHolder struct {
			Relay RelayConfig `json:"relay"`
		}
		if unmarshalErr := json.Unmarshal(raw, &relayHolder); unmarshalErr == nil {
			stream.Relay = relayHolder.Relay
		}
	}

	if strings.TrimSpace(stream.Host) == "" {
		if host := hostFromRelaySourceURL(stream.Relay.SourceURL); host != "" {
			stream.Host = host
		}
	}

	return stream, nil
}

func buildAxisStreamSourceURL(cfg StreamConfig) string {
	if cfg.Relay.SourceURL != "" {
		return cfg.Relay.SourceURL
	}

	return buildRTSPURL(axisRTSPHost(cfg.Config), nil)
}
