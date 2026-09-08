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

	"github.com/carverauto/serviceradar/go/pkg/config/kv"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
)

//go:generate mockgen -destination=mock_agent.go -package=agent github.com/carverauto/serviceradar/go/pkg/agent Service,SweepStatusProvider,KVStore,ObjectStore

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

// SweepStatusMetricPayloadProvider lets metric-producing status services return
// a typed metric payload beside the normal JSON status payload. This avoids
// reparsing status JSON just to build the canonical MetricBatch.
type SweepStatusMetricPayloadProvider interface {
	GetStatusWithMetricPayload(context.Context) (*proto.StatusResponse, map[string]any, error)
}

// StatusRoutingProvider lets status-producing services override the default
// sweep/status routing metadata used by the push loop.
type StatusRoutingProvider interface {
	StatusServiceType() string
	StatusSource() string
}

// StatusAddonTelemetryProvider lets native systemd-timer add-ons derive
// first-class add-on telemetry from the same spooled status payload they report.
type StatusAddonTelemetryProvider interface {
	AddonTelemetryBatch(*proto.StatusResponse) (string, *addonpb.TelemetryBatch)
}

// SweepResultsProvider provides sweep results with sequence tracking.
type SweepResultsProvider interface {
	GetSweepResults(context.Context, string) (*proto.ResultsResponse, error)
	GetConfigHash() string
}

// SweepGroupConfigUpdater applies multi-group sweep configurations.
type SweepGroupConfigUpdater interface {
	UpdateSweepGroups(*SweepGroupsConfig) error
}

// SweepGroupConfigContextUpdater applies multi-group sweep configurations with
// the caller's lifecycle context.
type SweepGroupConfigContextUpdater interface {
	UpdateSweepGroupsContext(context.Context, *SweepGroupsConfig) error
}

// KVStore defines the interface for key-value store operations.
// It embeds the shared configuration KV interface so agent stores remain compatible
// with the config loader while allowing optional extensions (e.g. PutIfAbsent).
type KVStore interface {
	kv.KVStore
}

// ObjectStore defines read access to the JetStream-backed object store.
type ObjectStore interface {
	DownloadObject(ctx context.Context, key string) ([]byte, error)
}
