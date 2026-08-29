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
	"os"
	"path/filepath"
	"slices"
	"testing"

	"gopkg.in/yaml.v3"
)

// The ranges the shipped on-prem appliance manifests declare. Link-local
// (169.254.0.0/16) is deliberately absent: an appliance that fell back to an
// APIPA address is not a destination anyone configured.
//
//nolint:gochecknoglobals
var onPremApplianceAllowedNetworks = []string{
	"10.0.0.0/8",
	"172.16.0.0/12",
	"192.168.0.0/16",
	"100.64.0.0/10",
}

type shippedPluginManifest struct {
	Version      string   `yaml:"version"`
	Capabilities []string `yaml:"capabilities"`
	Permissions  struct {
		AllowedDomains  []string `yaml:"allowed_domains"`
		AllowedNetworks []string `yaml:"allowed_networks"`
		AllowedPorts    []int    `yaml:"allowed_ports"`
	} `yaml:"permissions"`
}

func wasmPluginManifestPath(plugin, manifest string) string {
	return filepath.Join("..", "..", "cmd", "wasm-plugins", plugin, manifest)
}

func readShippedPluginManifest(t *testing.T, path string) shippedPluginManifest {
	t.Helper()

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}

	var manifest shippedPluginManifest
	if err := yaml.Unmarshal(raw, &manifest); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}

	return manifest
}

// An appliance reached by literal private IP is denied unless its manifest
// declares allowed_networks, because allowsHTTPHost refuses to expand an
// allowed_domains wildcard into a network permission. The demo UniFi Protect
// controller at 192.168.1.1 failed exactly this way with host error -2.
func TestOnPremApplianceManifestsDeclareAllowedNetworks(t *testing.T) {
	t.Parallel()

	manifests := []string{
		wasmPluginManifestPath("unifi-protect", "plugin.yaml"),
		wasmPluginManifestPath("unifi-protect", "plugin.stream.yaml"),
		wasmPluginManifestPath("axis", "plugin.yaml"),
		wasmPluginManifestPath("axis", "plugin.stream.yaml"),
		wasmPluginManifestPath("opentext-nom", "plugin.yaml"),
		wasmPluginManifestPath("awx", "plugin.yaml"),
		wasmPluginManifestPath("awx", "plugin.inventory_sync.yaml"),
	}

	for _, path := range manifests {
		t.Run(filepath.Base(filepath.Dir(path))+"/"+filepath.Base(path), func(t *testing.T) {
			t.Parallel()

			manifest := readShippedPluginManifest(t, path)
			if !slices.Equal(manifest.Permissions.AllowedNetworks, onPremApplianceAllowedNetworks) {
				t.Fatalf("allowed_networks = %v, want %v",
					manifest.Permissions.AllowedNetworks, onPremApplianceAllowedNetworks)
			}

			permissions := pluginPermissions{
				AllowedDomains:  manifest.Permissions.AllowedDomains,
				AllowedNetworks: manifest.Permissions.AllowedNetworks,
				AllowedPorts:    manifest.Permissions.AllowedPorts,
			}
			permissions.normalize()

			for _, host := range []string{"10.1.2.3", "172.16.4.5", "192.168.1.1", "100.64.0.7"} {
				if !permissions.allowsHTTPHost(host) {
					t.Fatalf("allowsHTTPHost(%q) = false, want true", host)
				}
			}
			if permissions.allowsHTTPHost("169.254.0.1") {
				t.Fatal("allowsHTTPHost(\"169.254.0.1\") = true, want false for link-local")
			}
			if permissions.allowsHTTPHost("203.0.113.10") {
				t.Fatal("allowsHTTPHost(\"203.0.113.10\") = true, want false for a public literal")
			}
		})
	}
}

// The AWX bridge's token arrives per dispatch, so a scheduled run_check can only
// report `api_token is required`. action-only:v1 is what keeps it off a runner.
// The inventory sync is a genuine scheduled check and must stay on one.
func TestAWXManifestsScopeActionOnlyToTheBridge(t *testing.T) {
	t.Parallel()

	bridge := readShippedPluginManifest(t, wasmPluginManifestPath("awx", "plugin.yaml"))
	if !slices.Contains(bridge.Capabilities, pluginCapabilityActionOnly) {
		t.Fatalf("awx plugin.yaml capabilities = %v, want %q", bridge.Capabilities, pluginCapabilityActionOnly)
	}

	inventorySync := readShippedPluginManifest(t, wasmPluginManifestPath("awx", "plugin.inventory_sync.yaml"))
	if slices.Contains(inventorySync.Capabilities, pluginCapabilityActionOnly) {
		t.Fatalf("awx plugin.inventory_sync.yaml must not declare %q", pluginCapabilityActionOnly)
	}
}
