package armis

import (
	"context"
	"net/http"
)

//go:generate mockgen -destination=mock_armis.go -package=armis github.com/carverauto/serviceradar/pkg/sync/integrations/armis HTTPClient,TokenProvider,DeviceFetcher,KVWriter

// HTTPClient defines the interface for making HTTP requests.
type HTTPClient interface {
	Do(req *http.Request) (*http.Response, error)
}

// TokenProvider defines the interface for obtaining access tokens.
type TokenProvider interface {
	GetAccessToken(ctx context.Context) (string, error)
}

// DeviceFetcher defines the interface for fetching devices.
type DeviceFetcher interface {
	FetchDevicesPage(ctx context.Context, accessToken, query string, from, length int) (*SearchResponse, error)
}

// KVWriter defines the interface for writing to KV store.
type KVWriter interface {
	WriteSweepConfig(ctx context.Context, ips []string) error
}
