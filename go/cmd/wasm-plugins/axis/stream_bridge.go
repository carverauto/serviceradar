package main

import (
	"time"

	"github.com/carverauto/serviceradar-sdk-go/sdk"
)

type RelayConfig = sdk.CameraRelayConfig

type StreamConfig struct {
	Config
	Relay RelayConfig `json:"relay"`
}

type axisMediaOpenRequest = sdk.CameraMediaOpenRequest
type axisMediaChunkMetadata = sdk.CameraMediaChunkMetadata
type axisMediaHeartbeat = sdk.CameraMediaHeartbeat

func webSocketConnect(rawURL string, timeout time.Duration) (*sdk.WebSocketConn, error) {
	return sdk.WebSocketDial(rawURL, timeout)
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
	cfg, err := sdk.LoadCameraStreamingConfig()
	if err != nil {
		return StreamConfig{Config: cfg.CameraPluginConfig, Relay: cfg.Relay}, err
	}

	return StreamConfig{Config: cfg.CameraPluginConfig, Relay: cfg.Relay}, nil
}

func buildAxisStreamSourceURL(cfg StreamConfig) string {
	if cfg.Relay.SourceURL != "" {
		return cfg.Relay.SourceURL
	}

	return buildRTSPURL(cfg.Host, nil)
}
