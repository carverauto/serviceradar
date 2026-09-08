package main

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

type Config struct {
	sdk.CameraPluginConfig
	APIKey        string `json:"api_key"`
	Cookie        string `json:"cookie"`
	BootstrapPath string `json:"bootstrap_path"`
	LoginPath     string `json:"login_path"`
	RTSPPort      int    `json:"rtsp_port"`
	// TimeoutMS is the canonical request timeout in milliseconds emitted by the
	// credential materializer (params_template). It takes precedence over the
	// legacy string Timeout when set. See config_envelope.go normalizeTimeout.
	TimeoutMS int `json:"timeout_ms"`
}

type EndpointResult struct {
	Path        string        `json:"path"`
	Status      int           `json:"status"`
	DurationMS  int64         `json:"duration_ms"`
	BodyBytes   int           `json:"body_bytes"`
	Error       string        `json:"error,omitempty"`
	CameraCount int           `json:"camera_count,omitempty"`
	EventCount  int           `json:"event_count,omitempty"`
	Body        string        `json:"body,omitempty"`
	Duration    time.Duration `json:"-"`
}

type StreamInfo struct {
	ID                 string `json:"id"`
	Protocol           string `json:"protocol"`
	URL                string `json:"url"`
	AuthMode           string `json:"auth_mode"`
	Source             string `json:"source"`
	InsecureSkipVerify bool   `json:"insecure_skip_verify,omitempty"`
}

type CameraDescriptor struct {
	DeviceUID          string                 `json:"device_uid"`
	Vendor             string                 `json:"vendor"`
	CameraID           string                 `json:"camera_id"`
	IP                 string                 `json:"ip,omitempty"`
	DisplayName        string                 `json:"display_name,omitempty"`
	AvailabilityStatus string                 `json:"availability_status,omitempty"`
	AvailabilityReason string                 `json:"availability_reason,omitempty"`
	SourceURL          string                 `json:"source_url,omitempty"`
	StreamProfiles     []CameraStreamProfile  `json:"stream_profiles,omitempty"`
	Identity           map[string]interface{} `json:"identity,omitempty"`
	Metadata           map[string]interface{} `json:"metadata,omitempty"`
}

type CameraStreamProfile struct {
	ProfileName       string                 `json:"profile_name"`
	VendorProfileID   string                 `json:"vendor_profile_id,omitempty"`
	SourceURLOverride string                 `json:"source_url_override,omitempty"`
	RTSPTransport     string                 `json:"rtsp_transport,omitempty"`
	CodecHint         string                 `json:"codec_hint,omitempty"`
	Metadata          map[string]interface{} `json:"metadata,omitempty"`
}

type ResultDetails struct {
	ControllerHost    string                 `json:"controller_host"`
	Cameras           []ProtectCamera        `json:"cameras,omitempty"`
	Streams           []StreamInfo           `json:"streams,omitempty"`
	CameraDescriptors []CameraDescriptor     `json:"camera_descriptors,omitempty"`
	Endpoints         []EndpointResult       `json:"endpoints"`
	CollectionError   string                 `json:"collection_error,omitempty"`
	Metadata          map[string]interface{} `json:"metadata,omitempty"`
}

type ProtectBootstrapResponse struct {
	Cameras      []ProtectCamera `json:"cameras"`
	LastUpdateID string          `json:"lastUpdateId"`
	Data         struct {
		Cameras      []ProtectCamera `json:"cameras"`
		LastUpdateID string          `json:"lastUpdateId"`
	} `json:"data"`
}

type ProtectBootstrapSnapshot struct {
	Cameras      []ProtectCamera
	LastUpdateID string
}

type protectRTSPSStreams map[string]*string

type protectHTTPClient interface {
	URL(string) string
	DoContext(context.Context, sdk.HTTPRequest) (*sdk.HTTPResponse, error)
}

type protectEventConn interface {
	Recv([]byte, time.Duration) (int, error)
	Close() error
}

var protectEventDial = func(rawURL string, headers map[string]string, insecureSkipVerify bool, timeout time.Duration) (protectEventConn, error) {
	return sdk.WebSocketDialRequestContext(context.Background(), sdk.WebSocketDialRequest{
		URL:                rawURL,
		Headers:            headers,
		InsecureSkipVerify: insecureSkipVerify,
	}, timeout)
}

type ProtectCamera struct {
	ID              string           `json:"id"`
	MAC             string           `json:"mac"`
	Host            string           `json:"host"`
	ConnectionHost  string           `json:"connectionHost"`
	Name            string           `json:"name"`
	DisplayName     string           `json:"displayName"`
	ModelKey        string           `json:"modelKey"`
	MarketName      string           `json:"marketName"`
	Type            string           `json:"type"`
	State           string           `json:"state"`
	FirmwareVersion string           `json:"firmwareVersion"`
	IsConnected     bool             `json:"isConnected"`
	Channels        []ProtectChannel `json:"channels"`
}

type ProtectChannel struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	RTSPAlias  string `json:"rtspAlias"`
	RTSPSAlias string `json:"rtspsAlias"`
	Width      int    `json:"width"`
	Height     int    `json:"height"`
	FPS        int    `json:"fps"`
	Bitrate    int    `json:"bitrate"`
}

type UniFiNetworkSite struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type uniFiNetworkSitesResponse struct {
	Data []UniFiNetworkSite `json:"data"`
}

type UniFiNetworkClient struct {
	ID          string `json:"id"`
	MACAddress  string `json:"macAddress"`
	MAC         string `json:"mac"`
	IPAddress   string `json:"ipAddress"`
	IP          string `json:"ip"`
	Hostname    string `json:"hostname"`
	Name        string `json:"name"`
	DisplayName string `json:"displayName"`
}

type uniFiNetworkClientsResponse struct {
	Offset     int                  `json:"offset"`
	Limit      int                  `json:"limit"`
	Count      int                  `json:"count"`
	TotalCount int                  `json:"totalCount"`
	Data       []UniFiNetworkClient `json:"data"`
}
