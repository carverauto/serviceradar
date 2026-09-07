package main

import (
	"encoding/json"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

type RelayConfig = sdk.CameraRelayConfig

type StreamConfig struct {
	Config
	Relay RelayConfig `json:"relay"`
}

type protectMediaOpenRequest = sdk.CameraMediaOpenRequest
type protectMediaChunkMetadata = sdk.CameraMediaChunkMetadata
type protectMediaHeartbeat = sdk.CameraMediaHeartbeat

func openProtectMediaSession(req protectMediaOpenRequest) (*sdk.CameraMediaStream, error) {
	return sdk.OpenCameraMediaStream(req)
}

func writeProtectMedia(stream *sdk.CameraMediaStream, meta protectMediaChunkMetadata, payload []byte) error {
	return stream.Write(meta, payload)
}

func heartbeatProtectMedia(stream *sdk.CameraMediaStream, heartbeat protectMediaHeartbeat) error {
	return stream.Heartbeat(heartbeat)
}

func closeProtectMedia(stream *sdk.CameraMediaStream, reason string) error {
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
// envelope), then injects the controller host from the relay source URL when no
// host was supplied inline or via the per-target envelope.
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
