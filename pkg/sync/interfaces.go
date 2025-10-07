/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package sync

import (
	"context"
	"net/http"
	"time"

	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

//go:generate mockgen -destination=mock_sync.go -package=sync github.com/carverauto/serviceradar/pkg/sync KVClient,GRPCClient,Integration,SRQLQuerier
//go:generate mockgen -destination=mock_proto.go -package=sync github.com/carverauto/serviceradar/proto AgentService_StreamResultsServer

// KVClient defines the interface for interacting with the KV store.
type KVClient interface {
	Put(ctx context.Context, in *proto.PutRequest, opts ...grpc.CallOption) (*proto.PutResponse, error)
	PutIfAbsent(ctx context.Context, in *proto.PutRequest, opts ...grpc.CallOption) (*proto.PutResponse, error)
	PutMany(ctx context.Context, in *proto.PutManyRequest, opts ...grpc.CallOption) (*proto.PutManyResponse, error)
	Get(ctx context.Context, in *proto.GetRequest, opts ...grpc.CallOption) (*proto.GetResponse, error)
	Update(ctx context.Context, in *proto.UpdateRequest, opts ...grpc.CallOption) (*proto.UpdateResponse, error)
	Delete(ctx context.Context, in *proto.DeleteRequest, opts ...grpc.CallOption) (*proto.DeleteResponse, error)
	Watch(ctx context.Context, in *proto.WatchRequest, opts ...grpc.CallOption) (proto.KVService_WatchClient, error)
	Info(ctx context.Context, in *proto.InfoRequest, opts ...grpc.CallOption) (*proto.InfoResponse, error)
}

// GRPCClient defines the interface for gRPC client management.
type GRPCClient interface {
	GetConnection() *grpc.ClientConn
	Close() error
}

// Integration defines the interface for fetching data from external sources and reconciling state.
type Integration interface {
	// Fetch performs discovery operations, returning KV data for caching and sweep results for agents.
	// This method should focus purely on data discovery and should not perform any state reconciliation.
	Fetch(ctx context.Context) (map[string][]byte, []*models.DeviceUpdate, error)

	// Reconcile performs state reconciliation operations such as updating external systems
	// with current device availability status and handling device retractions.
	// This method should only be called after sweep operations have been completed.
	Reconcile(ctx context.Context) error
}

// IntegrationFactory defines a function type for creating integrations.
type IntegrationFactory func(ctx context.Context, config *models.SourceConfig, log logger.Logger) Integration

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

// HTTPClient defines the interface for making HTTP requests.
// This is used by integrations and the SRQL querier.
type HTTPClient interface {
	Do(req *http.Request) (*http.Response, error)
}

// SRQLQuerier defines the interface for querying device states from ServiceRadar.
type SRQLQuerier interface {
	GetDeviceStatesBySource(ctx context.Context, source string) ([]DeviceState, error)
}

// ResultSubmitter defines the interface for submitting sweep results and retraction events.
type ResultSubmitter interface {
	SubmitSweepResult(ctx context.Context, result *models.DeviceUpdate) error
	SubmitBatchSweepResults(ctx context.Context, results []*models.DeviceUpdate) error
}

// DeviceState represents the consolidated state of a device from the unified view.
// It's used by integrations to check for retractions.
type DeviceState struct {
	DeviceID    string
	IP          string
	IsAvailable bool
	Metadata    map[string]interface{}
}
