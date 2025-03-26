package sync

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

// KVClient defines the interface for interacting with the KV store.
type KVClient interface {
	Put(ctx context.Context, in *proto.PutRequest, opts ...grpc.CallOption) (*proto.PutResponse, error)
	// Add other methods (Get, Delete, Watch) if needed in the future
}

// GRPCClient defines the interface for gRPC client management.
type GRPCClient interface {
	GetConnection() *grpc.ClientConn
	Close() error
}

// Integration defines the interface for fetching data from external sources.
type Integration interface {
	Fetch(ctx context.Context) (map[string][]byte, error)
}

// IntegrationFactory defines a function type for creating integrations.
type IntegrationFactory func(ctx context.Context, config models.SourceConfig) Integration

// SyncerInterface defines the interface for the Syncer itself (for completeness).
type SyncerInterface interface {
	Start(ctx context.Context) error
	Stop(ctx context.Context) error
	Sync(ctx context.Context) error // Exposed for testing
}

// Clock defines an interface for time-related operations (to mock ticker).
type Clock interface {
	Now() time.Time
	Ticker(d time.Duration) Ticker
}

// Ticker defines an interface for the ticker used in polling.
type Ticker interface {
	Chan() <-chan time.Time
	Stop()
}
