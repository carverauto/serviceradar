package armis

import (
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

// ArmisIntegration manages the Armis API integration.
type ArmisIntegration struct {
	Config       models.SourceConfig
	KVClient     proto.KVServiceClient
	GRPCConn     *grpc.ClientConn
	ServerName   string
	BoundaryName string // To filter devices by boundary
	PageSize     int    // Number of devices to fetch per page

	// Interface implementations
	HTTPClient    HTTPClient
	TokenProvider TokenProvider
	DeviceFetcher DeviceFetcher
	KVWriter      KVWriter
}

// AccessTokenResponse represents the Armis API access token response.
type AccessTokenResponse struct {
	Data struct {
		AccessToken   string    `json:"access_token"`
		ExpirationUTC time.Time `json:"expiration_utc"`
	} `json:"data"`
	Success bool `json:"success"`
}

// SearchResponse represents the Armis API search response for devices.
type SearchResponse struct {
	Data struct {
		Count   int         `json:"count"`
		Next    int         `json:"next"`
		Prev    interface{} `json:"prev"`
		Results []Device    `json:"results"`
		Total   int         `json:"total"`
	} `json:"data"`
	Success bool `json:"success"`
}

// Device represents an Armis device as returned by the API.
type Device struct {
	ID               int         `json:"id"`
	IPAddress        string      `json:"ipAddress"`
	MacAddress       string      `json:"macAddress"`
	Name             string      `json:"name"`
	Type             string      `json:"type"`
	Category         string      `json:"category"`
	Manufacturer     string      `json:"manufacturer"`
	Model            string      `json:"model"`
	OperatingSystem  string      `json:"operatingSystem"`
	FirstSeen        time.Time   `json:"firstSeen"`
	LastSeen         time.Time   `json:"lastSeen"`
	RiskLevel        int         `json:"riskLevel"`
	Boundaries       string      `json:"boundaries"`
	Tags             []string    `json:"tags"`
	CustomProperties interface{} `json:"customProperties"`
	BusinessImpact   string      `json:"businessImpact"`
	Visibility       string      `json:"visibility"`
	Site             interface{} `json:"site"`
}

// DefaultArmisIntegration provides the default implementations for the interfaces.
type DefaultArmisIntegration struct {
	Config     models.SourceConfig
	HTTPClient HTTPClient
}

// DefaultKVWriter provides the default implementation for KVWriter.
type DefaultKVWriter struct {
	KVClient   proto.KVServiceClient
	ServerName string
}
