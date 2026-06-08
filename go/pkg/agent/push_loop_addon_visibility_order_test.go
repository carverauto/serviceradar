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

package agent

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/agent/sidecar"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/rs/zerolog"
)

type recordingAddonManager struct {
	applied []agentaddon.Spec
}

func (m *recordingAddonManager) Apply(_ context.Context, specs []agentaddon.Spec) error {
	m.applied = append([]agentaddon.Spec(nil), specs...)
	return nil
}

func (m *recordingAddonManager) Status() []agentaddon.Status {
	return nil
}

func (m *recordingAddonManager) Stop(context.Context) error {
	return nil
}

func TestApplyConfigResponseAppliesLocalAddonsBeforeVisibilityFailure(t *testing.T) {
	dir := t.TempDir()
	override := `{
	  "addons": [
	    {
	      "addon_id": "powerdns",
	      "version": "0.1.0",
	      "enabled": true,
	      "binary_path": "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon",
	      "delivery": "os_package",
	      "supervision": "agent_sidecar",
	      "capabilities": ["native-telemetry:v1", "dns-activity", "powerdns-rpz"],
	      "config_json": {"listen_addr": "127.0.0.1:6000"}
	    }
	  ]
	}`
	if err := os.WriteFile(filepath.Join(dir, "addons.local.json"), []byte(override), 0o600); err != nil {
		t.Fatalf("write local add-on override: %v", err)
	}

	netprobeSidecar := agentnetprobe.NewSidecar(agentnetprobe.SidecarConfig{Logger: zerolog.Nop()})
	sidecarManager, err := sidecar.NewManager(sidecar.Config{
		RuntimeDir:     filepath.Join(dir, "run"),
		ConfigDir:      filepath.Join(dir, "cfg"),
		HealthInterval: time.Hour,
		ClientFactory: sidecar.ClientFactory(func(context.Context, string) (sidecar.Client, error) {
			return nil, errNoExternalNetprobe
		}),
		Logger: zerolog.Nop(),
	}, netprobeSidecar)
	if err != nil {
		t.Fatalf("NewManager: %v", err)
	}
	defer func() {
		stopCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = sidecarManager.Stop(stopCtx)
	}()

	addons := &recordingAddonManager{}
	pl := NewPushLoop(&Server{
		configDir:       dir,
		addonManager:    addons,
		netprobeSidecar: netprobeSidecar,
		sidecarManager:  sidecarManager,
		sidecarStatus:   sidecarManager,
	}, nil, 30*time.Second, logger.NewTestLogger())
	pl.setConfigVersion("old-version")

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	ok := pl.applyConfigResponse(ctx, &proto.AgentConfigResponse{
		ConfigVersion:    "new-version",
		VisibilityConfig: &proto.VisibilityConfig{Enabled: true},
	}, "poll")

	if ok {
		t.Fatal("applyConfigResponse() = true, want false when visibility apply fails")
	}
	if got := pl.getConfigVersion(); got != "old-version" {
		t.Fatalf("config version = %q, want old-version", got)
	}
	if len(addons.applied) != 1 {
		t.Fatalf("applied add-on specs = %d, want 1", len(addons.applied))
	}
	if got := addons.applied[0].ID; got != "powerdns" {
		t.Fatalf("applied add-on ID = %q, want powerdns", got)
	}
	if got := addons.applied[0].BinaryPath; got != "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon" {
		t.Fatalf("applied binary path = %q", got)
	}
}
