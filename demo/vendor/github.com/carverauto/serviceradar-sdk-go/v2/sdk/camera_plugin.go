package sdk

import (
	"encoding/base64"
	"errors"
	"strings"
	"time"
)

var errInvalidCameraScheme = errors.New("scheme must be http or https")

// CameraPluginConfig defines the common config shape for HTTP-discoverable camera plugins.
type CameraPluginConfig struct {
	Host               string `json:"host"`
	Scheme             string `json:"scheme"`
	Username           string `json:"username"`
	Password           string `json:"password"`
	Timeout            string `json:"timeout"`
	InsecureSkipVerify bool   `json:"insecure_skip_verify"`
	DiscoverStreams    bool   `json:"discover_streams"`
	CollectEvents      bool   `json:"collect_events"`
	EventSources       string `json:"event_sources"`
}

// CameraStreamingConfig defines the common config shape for camera streaming plugins.
type CameraStreamingConfig struct {
	CameraPluginConfig
	Relay CameraRelayConfig `json:"relay"`
}

// DefaultCameraPluginConfig returns the shared defaults for camera plugins.
func DefaultCameraPluginConfig() CameraPluginConfig {
	return CameraPluginConfig{
		Scheme:          "http",
		DiscoverStreams: true,
		CollectEvents:   false,
		EventSources:    "events",
		Timeout:         "10s",
	}
}

// DefaultCameraStreamingConfig returns the shared defaults for camera streaming plugins.
func DefaultCameraStreamingConfig() CameraStreamingConfig {
	return CameraStreamingConfig{CameraPluginConfig: DefaultCameraPluginConfig()}
}

// LoadCameraPluginConfig loads a camera plugin config with shared defaults.
func LoadCameraPluginConfig() (CameraPluginConfig, error) {
	cfg := DefaultCameraPluginConfig()
	err := LoadConfig(&cfg)
	return cfg, err
}

// LoadCameraStreamingConfig loads a camera streaming config with shared defaults.
func LoadCameraStreamingConfig() (CameraStreamingConfig, error) {
	cfg := DefaultCameraStreamingConfig()
	err := LoadConfig(&cfg)
	return cfg, err
}

// NormalizedScheme validates and normalizes the configured HTTP scheme.
func (c CameraPluginConfig) NormalizedScheme() (string, error) {
	scheme := strings.ToLower(strings.TrimSpace(c.Scheme))
	if scheme == "" {
		scheme = "http"
	}
	if scheme != "http" && scheme != "https" {
		return "", errInvalidCameraScheme
	}

	return scheme, nil
}

// ParsedTimeout returns the configured timeout or the provided fallback.
func (c CameraPluginConfig) ParsedTimeout(fallback time.Duration) time.Duration {
	if strings.TrimSpace(c.Timeout) == "" {
		return fallback
	}

	parsed, err := time.ParseDuration(c.Timeout)
	if err != nil || parsed <= 0 {
		return fallback
	}

	return parsed
}

// BasicAuthHeader returns a basic auth header when credentials are configured.
func (c CameraPluginConfig) BasicAuthHeader() string {
	if c.Username == "" && c.Password == "" {
		return ""
	}

	return "Basic " + base64.StdEncoding.EncodeToString([]byte(c.Username+":"+c.Password))
}
