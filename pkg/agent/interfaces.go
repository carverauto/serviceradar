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

package agent

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

//go:generate mockgen -destination=mock_agent.go -package=agent github.com/carverauto/serviceradar/pkg/agent Service,SweepStatusProvider,KVStore,ObjectStore

// Service defines the interface for agent services that can be started, stopped, and configured.
type Service interface {
	Start(context.Context) error
	Stop(ctx context.Context) error
	Name() string
	UpdateConfig(config *models.Config) error // Added for dynamic config updates
}

// SweepStatusProvider is an interface for services that can provide sweep status.
type SweepStatusProvider interface {
	GetStatus(context.Context) (*proto.StatusResponse, error)
}

// KVStore defines the interface for key-value store operations.
type KVStore interface {
	Get(ctx context.Context, key string) (value []byte, found bool, err error)
	Put(ctx context.Context, key string, value []byte, ttl time.Duration) error
	Delete(ctx context.Context, key string) error
	Watch(ctx context.Context, key string) (<-chan []byte, error)
	Close() error
}

// ObjectStore defines read access to the JetStream-backed object store.
type ObjectStore interface {
	DownloadObject(ctx context.Context, key string) ([]byte, error)
}
