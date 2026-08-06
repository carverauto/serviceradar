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
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/k8sinventory"
)

func TestK8sPublicEndpointsSpoolServiceGetStatus(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	latest := filepath.Join(dir, k8sinventory.LatestFileName)
	snap := map[string]any{
		"cluster_id":   "acme-prod",
		"generated_at": "2026-08-05T00:00:00Z",
		"endpoints":    []any{},
	}
	raw, err := json.Marshal(snap)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(latest, raw, 0o640); err != nil {
		t.Fatal(err)
	}

	svc := NewK8sPublicEndpointsSpoolService(bumblebeeSpoolTestAgentID, &K8sPublicEndpointsStatusConfig{
		Enabled:   true,
		SpoolDir:  dir,
		ClusterID: "acme-prod",
	})
	if svc.Name() != K8sPublicEndpointsServiceName {
		t.Fatalf("name=%s", svc.Name())
	}
	if svc.StatusServiceType() != K8sPublicEndpointsServiceType {
		t.Fatalf("type=%s", svc.StatusServiceType())
	}
	if svc.StatusSource() != K8sPublicEndpointsSourceResults {
		t.Fatalf("source=%s", svc.StatusSource())
	}

	status, err := svc.GetStatus(context.Background())
	if err != nil {
		t.Fatalf("GetStatus: %v", err)
	}
	if !status.Available {
		t.Fatal("expected available")
	}
	var body map[string]any
	if err := json.Unmarshal(status.Message, &body); err != nil {
		t.Fatal(err)
	}
	if body["agent_id"] != bumblebeeSpoolTestAgentID {
		t.Fatalf("agent_id=%v", body["agent_id"])
	}
	if body["cluster_id"] != "acme-prod" {
		t.Fatalf("cluster_id=%v", body["cluster_id"])
	}
	if body["schema_version"] != K8sPublicEndpointsSchemaVersion {
		t.Fatalf("schema=%v", body["schema_version"])
	}
}

func TestK8sPublicEndpointsSpoolServiceMissingSpool(t *testing.T) {
	t.Parallel()
	svc := NewK8sPublicEndpointsSpoolService(bumblebeeSpoolTestAgentID, &K8sPublicEndpointsStatusConfig{
		Enabled:  true,
		SpoolDir: filepath.Join(t.TempDir(), "missing"),
	})
	status, err := svc.GetStatus(context.Background())
	if err != nil {
		t.Fatalf("GetStatus: %v", err)
	}
	if status.Available {
		t.Fatal("expected unavailable")
	}
}
