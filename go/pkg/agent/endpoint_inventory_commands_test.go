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
	"errors"
	"path/filepath"
	"testing"
)

func TestEndpointInventoryForceFreshSingleFlight(t *testing.T) {
	pl := NewPushLoop(&Server{}, nil, 0, nil)

	if !pl.tryAcquireEndpointInventoryFreshScanSlot() {
		t.Fatal("first endpoint inventory force-fresh slot acquisition failed")
	}
	if pl.tryAcquireEndpointInventoryFreshScanSlot() {
		t.Fatal("second endpoint inventory force-fresh slot acquisition should fail")
	}

	pl.releaseEndpointInventoryFreshScanSlot()
	if !pl.tryAcquireEndpointInventoryFreshScanSlot() {
		t.Fatal("endpoint inventory force-fresh slot should be reusable after release")
	}
	pl.releaseEndpointInventoryFreshScanSlot()
}

func TestEnsureEndpointInventorySourcesAllowed(t *testing.T) {
	if err := ensureEndpointInventorySourcesAllowed([]string{"dpkg", "apk"}, []string{"dpkg"}); err != nil {
		t.Fatal(err)
	}

	err := ensureEndpointInventorySourcesAllowed([]string{"dpkg"}, []string{"rpm"})
	if !errors.Is(err, errEndpointInventorySourceDisabled) {
		t.Fatalf("err = %v, want errEndpointInventorySourceDisabled", err)
	}
}

func TestEndpointInventoryCommandConfigUsesStatusPaths(t *testing.T) {
	dir := t.TempDir()
	spoolPath := filepath.Join(dir, "custom-spool", "latest.json")

	pl := &PushLoop{
		server: &Server{
			config: &ServerConfig{
				AgentID: "agent-1",
				EndpointInventory: &EndpointInventoryStatusConfig{
					ConfigPath:  filepath.Join(dir, "missing-config.json"),
					SpoolPath:   spoolPath,
					CacheDir:    filepath.Join(dir, "cache"),
					ProfilePath: filepath.Join(dir, "missing-profile.json"),
					TmpDir:      filepath.Join(dir, "tmp"),
				},
			},
		},
	}

	cfg, err := pl.endpointInventoryCommandConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.SpoolDir != filepath.Dir(spoolPath) {
		t.Fatalf("spool dir = %q, want %q", cfg.SpoolDir, filepath.Dir(spoolPath))
	}
	if cfg.CacheDir != filepath.Join(dir, "cache") {
		t.Fatalf("cache dir = %q", cfg.CacheDir)
	}
}
