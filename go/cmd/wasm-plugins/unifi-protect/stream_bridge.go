package main

import "github.com/carverauto/serviceradar-sdk-go/sdk"

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
	cfg := StreamConfig{
		Config: Config{
			CameraPluginConfig: sdk.CameraPluginConfig{
				Scheme:          "https",
				DiscoverStreams: true,
				CollectEvents:   false,
				EventSources:    "updates",
				Timeout:         "10s",
			},
			BootstrapPath: "/proxy/protect/api/bootstrap",
			LoginPath:     "/api/auth/login",
			RTSPPort:      7447,
		},
	}

	err := sdk.LoadConfig(&cfg)
	return cfg, err
}
