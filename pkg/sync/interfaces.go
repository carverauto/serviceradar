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
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

//go:generate mockgen -destination=mock_sync.go -package=sync github.com/carverauto/serviceradar/pkg/sync KVClient,GRPCClient,Integration,Clock,SyncerInterface,Ticker

// KVClient defines the interface for interacting with the KV store.
type KVClient interface {
	Put(ctx context.Context, in *proto.PutRequest, opts ...grpc.CallOption) (*proto.PutResponse, error)
	Get(ctx context.Context, in *proto.GetRequest, opts ...grpc.CallOption) (*proto.GetResponse, error)
	Delete(ctx context.Context, in *proto.DeleteRequest, opts ...grpc.CallOption) (*proto.DeleteResponse, error)
	Watch(ctx context.Context, in *proto.WatchRequest, opts ...grpc.CallOption) (proto.KVService_WatchClient, error)
}

// GRPCClient defines the interface for gRPC client management.
type GRPCClient interface {
	GetConnection() *grpc.ClientConn
	Close() error
}

// Integration defines the interface for fetching data from external sources.
type Integration interface {
	Fetch(ctx context.Context) (map[string][]byte, []models.Device, error)
}

// IntegrationFactory defines a function type for creating integrations.
type IntegrationFactory func(ctx context.Context, config *models.SourceConfig) Integration

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
