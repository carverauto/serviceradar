package sdk

import (
	"net/url"
	"strings"
)

// CameraRelayConfig defines the relay/session metadata injected into a streaming plugin config.
type CameraRelayConfig struct {
	RelaySessionID     string `json:"relay_session_id"`
	AgentID            string `json:"agent_id"`
	GatewayID          string `json:"gateway_id"`
	CameraSourceID     string `json:"camera_source_id"`
	StreamProfileID    string `json:"stream_profile_id"`
	LeaseToken         string `json:"lease_token"`
	PluginAssignmentID string `json:"plugin_assignment_id,omitempty"`
	SourceURL          string `json:"source_url,omitempty"`
	RTSPTransport      string `json:"rtsp_transport,omitempty"`
	CodecHint          string `json:"codec_hint,omitempty"`
	ContainerHint      string `json:"container_hint,omitempty"`
}

// WithURLUserInfo injects URL userinfo credentials when either username or password is present.
func WithURLUserInfo(rawURL, username, password string) string {
	if strings.TrimSpace(username) == "" && strings.TrimSpace(password) == "" {
		return rawURL
	}

	parsed, err := url.Parse(rawURL)
	if err != nil {
		return rawURL
	}

	parsed.User = url.UserPassword(username, password)
	return parsed.String()
}
