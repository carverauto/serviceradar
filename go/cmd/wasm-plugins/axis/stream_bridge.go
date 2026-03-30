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
	type rawConfig struct {
		sdk.CameraStreamingConfig
		EventTopicFilters string `json:"event_topic_filters"`
	}

	cfg := rawConfig{CameraStreamingConfig: sdk.DefaultCameraStreamingConfig()}
	err := sdk.LoadConfig(&cfg)

	return StreamConfig{
		Config: Config{
			CameraPluginConfig: cfg.CameraPluginConfig,
			EventTopicFilters:  cfg.EventTopicFilters,
		},
		Relay: cfg.Relay,
	}, err
}

func buildAxisStreamSourceURL(cfg StreamConfig) string {
	if cfg.Relay.SourceURL != "" {
		return cfg.Relay.SourceURL
	}

	return buildRTSPURL(cfg.Host, nil)
}
