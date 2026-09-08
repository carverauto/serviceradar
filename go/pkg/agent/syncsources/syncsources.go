/*
 * Copyright 2026 Carver Automation Corporation.
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

// Package syncsources defines the integration-agnostic contract between the
// agent sync runtime and the source drivers that talk to third-party
// inventory APIs. The runtime schedules runs, streams emitted device updates
// to the gateway, and applies generic update hygiene; drivers only fetch from
// their API and map raw records to update maps.
//
// Drivers live in subpackages (for example syncsources/armis; a future NetBox
// driver would live in syncsources/netbox) and are wired into the registry
// from a single neutral registration point in the agent package.
package syncsources

import (
	"context"
	"fmt"
	"strings"
	"sync"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

// EmitFunc streams a batch (typically one API page) of device updates to the
// gateway. The runtime owns chunking, sync_meta bookkeeping, and final-page
// marking; drivers just call Emit once per fetched batch.
type EmitFunc func(updates []map[string]any) error

// PopulationStats describes one source collection in source-object terms.
// Drivers that can identify stable source objects report these counters so the
// runtime can attach exact accounting to the final sync chunk. Counts are
// source rows/IDs, not canonical ServiceRadar device rows.
type PopulationStats struct {
	RawRows                   int
	ExcludedRows              int
	InvalidRows               int
	ValidOccurrences          int
	DistinctSourceIDs         int
	DuplicateOccurrences      int
	DuplicateSourceIDExamples []string
	InvalidRowExamples        []string
	ConflictingDuplicateIDs   []string
}

// ReportPopulationFunc publishes the latest accounting snapshot for a run.
// The runtime serializes the last value onto sync_meta; partial runs never
// activate it because they do not emit a run-final chunk.
type ReportPopulationFunc func(PopulationStats)

// RunContext carries everything a driver needs for a single sync run.
type RunContext struct {
	// RunID uniquely identifies this sync run.
	RunID string
	// SourceKey is the configured source label (the key in the sources map).
	SourceKey string
	// AgentID, GatewayID, and Partition are the resolved identity values the
	// driver must stamp on every update it emits.
	AgentID   string
	GatewayID string
	Partition string
	// Source is the integration source configuration delivered via GetConfig.
	Source models.SourceConfig
	// Logger is the agent logger scoped to the sync runtime.
	Logger logger.Logger
	// Emit streams a batch of device updates to the gateway.
	Emit EmitFunc
	// ReportPopulation optionally records exact source-row/source-ID counts.
	ReportPopulation ReportPopulationFunc
}

// SourceDriver executes one sync run against an integration source.
type SourceDriver interface {
	Sync(ctx context.Context, run RunContext) (updates int, err error)
}

// Constructor builds a new driver instance for a sync run.
type Constructor func() SourceDriver

//nolint:gochecknoglobals // Driver registration is process-wide by design.
var (
	registryMu sync.RWMutex
	registry   = make(map[string]Constructor)
)

// NormalizeType canonicalizes a source-type string for registry lookups.
func NormalizeType(sourceType string) string {
	return strings.ToLower(strings.TrimSpace(sourceType))
}

// Register adds a driver constructor for a source type. It panics on empty
// types, nil constructors, or duplicate registrations, all of which are
// programmer errors at wiring time.
func Register(sourceType string, ctor Constructor) {
	key := NormalizeType(sourceType)
	if key == "" {
		panic("syncsources: cannot register empty source type")
	}
	if ctor == nil {
		panic(fmt.Sprintf("syncsources: nil constructor for source type %q", key))
	}

	registryMu.Lock()
	defer registryMu.Unlock()

	if _, exists := registry[key]; exists {
		panic(fmt.Sprintf("syncsources: driver already registered for source type %q", key))
	}
	registry[key] = ctor
}

// Lookup returns the registered constructor for a source type.
func Lookup(sourceType string) (Constructor, bool) {
	registryMu.RLock()
	defer registryMu.RUnlock()

	ctor, ok := registry[NormalizeType(sourceType)]
	return ctor, ok
}

// IsSupported reports whether a driver is registered for the source type.
func IsSupported(sourceType string) bool {
	_, ok := Lookup(sourceType)
	return ok
}
