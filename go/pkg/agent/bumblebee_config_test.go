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
	"testing"

	monitoringpb "github.com/carverauto/serviceradar/proto"
)

func TestResolveGatewayBumblebeeConfigPrefersTypedProto(t *testing.T) {
	cfg, err := resolveGatewayBumblebeeConfig(&monitoringpb.BumblebeeConfig{
		Enabled: true,
		AgentId: "agent-typed",
		Catalog: &monitoringpb.BumblebeeCatalogAssignment{
			SchemaVersion:  "serviceradar.bumblebee.catalog_assignment.v1",
			SnapshotRef:    "typed-snapshot",
			CatalogVersion: "v1",
			SourceRevision: "abc123",
			ObjectKey:      "bumblebee/catalogs/typed/catalog.json",
			Sha256:         "deadbeef",
			SizeBytes:      42,
		},
	}, []byte(`{"bumblebee":{"enabled":false}}`))
	if err != nil {
		t.Fatalf("resolve config: %v", err)
	}
	if cfg == nil {
		t.Fatal("expected config")
	}
	if !cfg.Enabled {
		t.Fatal("expected typed proto config to be enabled")
	}
	if cfg.AgentID != "agent-typed" {
		t.Fatalf("agent id = %q, want agent-typed", cfg.AgentID)
	}
	if cfg.Catalog == nil {
		t.Fatal("expected catalog assignment")
	}
	if cfg.Catalog.SnapshotRef != "typed-snapshot" {
		t.Fatalf("snapshot ref = %q, want typed-snapshot", cfg.Catalog.SnapshotRef)
	}
	if cfg.Catalog.SizeBytes != 42 {
		t.Fatalf("size bytes = %d, want 42", cfg.Catalog.SizeBytes)
	}
}

func TestResolveGatewayBumblebeeConfigFallsBackToJSON(t *testing.T) {
	cfg, err := resolveGatewayBumblebeeConfig(nil, []byte(`{
		"bumblebee": {
			"enabled": true,
			"agent_id": "agent-json",
			"catalog": {
				"snapshot_ref": "json-snapshot",
				"object_key": "bumblebee/catalogs/json/catalog.json",
				"sha256": "beadfeed"
			}
		}
	}`))
	if err != nil {
		t.Fatalf("resolve config: %v", err)
	}
	if cfg == nil || !cfg.Enabled {
		t.Fatal("expected enabled JSON config")
	}
	if cfg.AgentID != "agent-json" {
		t.Fatalf("agent id = %q, want agent-json", cfg.AgentID)
	}
	if cfg.Catalog == nil || cfg.Catalog.SnapshotRef != "json-snapshot" {
		t.Fatalf("catalog = %#v, want json-snapshot", cfg.Catalog)
	}
}
