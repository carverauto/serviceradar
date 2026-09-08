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

	"github.com/stretchr/testify/require"

	monitoringpb "github.com/carverauto/serviceradar/proto"
)

const bumblebeeConfigTestCanonicalAgentID = "agent-canonical"

func TestResolveGatewayBumblebeeConfigPrefersTypedProto(t *testing.T) {
	cfg, err := resolveGatewayBumblebeeConfig(&monitoringpb.BumblebeeConfig{
		Enabled:           true,
		AgentId:           "agent-typed",
		RootDiscoveryMode: "home",
		ExplicitRoots:     []string{"/srv/app"},
		ExcludeRoots:      []string{"/home/skip"},
		Ecosystems:        []string{"npm"},
		ScanTimeout:       "5m",
		MaxFindings:       123,
		MaxOutputBytes:    456,
		Catalog: &monitoringpb.BumblebeeCatalogAssignment{
			SchemaVersion:  "serviceradar.bumblebee.catalog_assignment.v1",
			SnapshotRef:    "typed-snapshot",
			CatalogVersion: "v1",
			SourceRevision: "abc123",
			ObjectKey:      "bumblebee/catalogs/typed/catalog.json",
			Sha256:         "deadbeef",
			SizeBytes:      42,
		},
	}, []byte(`{"bumblebee":{"enabled":false,"device_uid":"sr:device-1"}}`))
	if err != nil {
		t.Fatalf("resolve config: %v", err)
	}
	require.NotNil(t, cfg, "expected config")
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
	if cfg.RootDiscoveryMode != "home" || cfg.ScanTimeout != "5m" || cfg.MaxFindings != 123 {
		t.Fatalf("typed scan profile fields were not retained: %#v", cfg)
	}

	profile := cfg.runtimeProfile(bumblebeeConfigTestCanonicalAgentID)
	if profile.AgentID != bumblebeeConfigTestCanonicalAgentID {
		t.Fatalf("runtime profile agent = %q, want canonical", profile.AgentID)
	}
	if profile.DeviceUID != "sr:device-1" {
		t.Fatalf("runtime profile device = %q, want sr:device-1", profile.DeviceUID)
	}
	if profile.IncludeHomeRoots == nil || !*profile.IncludeHomeRoots {
		t.Fatalf("expected home roots enabled in profile: %#v", profile)
	}
	if profile.IncludeRoot == nil || *profile.IncludeRoot {
		t.Fatalf("expected root disabled in profile: %#v", profile)
	}
	if profile.MaxFindings == nil || *profile.MaxFindings != 123 {
		t.Fatalf("max findings = %#v, want 123", profile.MaxFindings)
	}
}

func TestResolveGatewayBumblebeeConfigFallsBackToJSON(t *testing.T) {
	cfg, err := resolveGatewayBumblebeeConfig(nil, []byte(`{
		"bumblebee": {
			"enabled": true,
			"agent_id": "agent-json",
			"root_discovery_mode": "explicit",
			"explicit_roots": ["/opt/app"],
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
	if cfg.RootDiscoveryMode != "explicit" || len(cfg.ExplicitRoots) != 1 {
		t.Fatalf("json scan profile fields were not retained: %#v", cfg)
	}
}
