// Package discovery pkg/discovery/interfaces.go
package discovery

import "context"

// DiscoveryEngine is the main interface for network discovery operations
type DiscoveryEngine interface {
	// Start initializes and starts the discovery engine
	Start(ctx context.Context) error

	// Stop gracefully shuts down the discovery engine
	Stop(ctx context.Context) error

	// StartDiscovery initiates a discovery operation with the given parameters
	StartDiscovery(ctx context.Context, params *DiscoveryParams) (string, error)

	// GetDiscoveryStatus retrieves the status of a discovery operation
	GetDiscoveryStatus(ctx context.Context, discoveryID string) (*DiscoveryStatus, error)

	// GetDiscoveryResults retrieves the results of a completed discovery operation
	GetDiscoveryResults(ctx context.Context, discoveryID string, includeRawData bool) (*DiscoveryResults, error)

	// CancelDiscovery cancels an in-progress discovery operation
	CancelDiscovery(ctx context.Context, discoveryID string) error
}

// Publisher defines the interface for publishing discovered data to streams
type Publisher interface {
	// PublishDevice publishes a discovered device to the appropriate stream
	PublishDevice(ctx context.Context, device *DiscoveredDevice) error

	// PublishInterface publishes a discovered interface to the appropriate stream
	PublishInterface(ctx context.Context, iface *DiscoveredInterface) error

	// PublishTopologyLink publishes a discovered topology link to the appropriate stream
	PublishTopologyLink(ctx context.Context, link *TopologyLink) error
}
