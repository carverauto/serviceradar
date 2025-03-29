package netbox

import (
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

// NetboxIntegration manages the NetBox API integration.
type NetboxIntegration struct {
	Config        models.SourceConfig
	KvClient      proto.KVServiceClient // For writing sweep Config
	GrpcConn      *grpc.ClientConn      // Connection to reuse
	ServerName    string
	ExpandSubnets bool
}

// Device represents a NetBox device as returned by the API.
type Device struct {
	ID         int    `json:"id"`
	Name       string `json:"name"`
	DeviceType struct {
		ID           int `json:"id"`
		Manufacturer struct {
			ID   int    `json:"id"`
			Name string `json:"name"`
		} `json:"manufacturer"`
		Model string `json:"model"`
	} `json:"device_type"`
	Role struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	} `json:"role"`
	Tenant struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	} `json:"tenant"`
	Site struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	} `json:"site"`
	Status struct {
		Value string `json:"value"`
		Label string `json:"label"`
	} `json:"status"`
	PrimaryIP4 struct {
		ID      int    `json:"id"`
		Address string `json:"address"`
	} `json:"primary_ip4"`
	PrimaryIP6  interface{} `json:"primary_ip6"` // Can be null or an object
	Description string      `json:"description"`
	Created     string      `json:"created"`
	LastUpdated string      `json:"last_updated"`
}

// DeviceResponse represents the NetBox API response.
type DeviceResponse struct {
	Results  []Device `json:"results"`
	Count    int      `json:"count"`
	Next     string   `json:"next"`     // Pagination URL
	Previous string   `json:"previous"` // Pagination URL
}
