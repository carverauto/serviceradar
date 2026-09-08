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
	"errors"
	"slices"
	"testing"
)

var errDeploymentProbeFileNotFound = errors.New("deployment probe file not found")

func TestDetectDeploymentTypeWithProbe(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		env      map[string]string
		files    map[string]string
		exists   map[string]bool
		expected string
	}{
		{
			name:     "bare metal",
			expected: deploymentTypeBareMetal,
		},
		{
			name:     "kubernetes environment",
			env:      map[string]string{"KUBERNETES_SERVICE_HOST": "10.96.0.1"},
			expected: deploymentTypeKubernetes,
		},
		{
			name:     "kubernetes service account",
			exists:   map[string]bool{"/var/run/secrets/kubernetes.io/serviceaccount/token": true},
			expected: deploymentTypeKubernetes,
		},
		{
			name:     "docker environment file",
			exists:   map[string]bool{"/.dockerenv": true},
			expected: deploymentTypeDocker,
		},
		{
			name:     "docker cgroup",
			files:    map[string]string{"/proc/1/cgroup": "0::/docker/abc123"},
			expected: deploymentTypeDocker,
		},
		{
			name:     "lxc process environment",
			env:      map[string]string{"container": "lxc"},
			expected: deploymentTypeLXC,
		},
		{
			name:     "systemd lxc marker",
			files:    map[string]string{"/run/systemd/container": "lxc\n"},
			expected: deploymentTypeLXC,
		},
		{
			name:     "proxmox lxc cgroup",
			files:    map[string]string{"/proc/1/cgroup": "0::/lxc.payload.agent-sr-test-pve04"},
			expected: deploymentTypeLXC,
		},
		{
			name:     "systemd machine lxc cgroup",
			files:    map[string]string{"/proc/1/cgroup": "0::/machine.slice/machine-lxc\\x2d104.scope"},
			expected: deploymentTypeLXC,
		},
		{
			name:     "init process lxc environment",
			files:    map[string]string{"/proc/1/environ": "HOME=/root\x00container=lxc\x00TERM=linux\x00"},
			expected: deploymentTypeLXC,
		},
		{
			name:     "podman container environment file",
			exists:   map[string]bool{"/run/.containerenv": true},
			expected: deploymentTypeContainer,
		},
		{
			name:     "podman process environment",
			env:      map[string]string{"container": "podman"},
			expected: deploymentTypeContainer,
		},
		{
			name:     "systemd nspawn marker",
			files:    map[string]string{"/run/systemd/container": "systemd-nspawn\n"},
			expected: deploymentTypeContainer,
		},
		{
			name:     "libpod cgroup",
			files:    map[string]string{"/proc/1/cgroup": "0::/user.slice/libpod-abc123.scope"},
			expected: deploymentTypeContainer,
		},
		{
			name:     "kubernetes cgroup without environment markers",
			files:    map[string]string{"/proc/1/cgroup": "0::/kubepods.slice/kubepods-burstable.slice/pod123"},
			expected: deploymentTypeContainer,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			probe := deploymentRuntimeProbe{
				getenv:     func(key string) string { return tt.env[key] },
				pathExists: func(path string) bool { return tt.exists[path] },
				readFile: func(path string) ([]byte, error) {
					content, ok := tt.files[path]
					if !ok {
						return nil, errDeploymentProbeFileNotFound
					}
					return []byte(content), nil
				},
			}

			if got := detectDeploymentTypeWithProbe(probe); got != tt.expected {
				t.Fatalf("detectDeploymentTypeWithProbe() = %q, want %q", got, tt.expected)
			}
		})
	}
}

func TestHostNetworkVisibilityCapabilityEligibility(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name           string
		goos           string
		deploymentType string
		supported      bool
	}{
		{name: "linux host", goos: "linux", deploymentType: deploymentTypeBareMetal, supported: true},
		{name: "lxc", goos: "linux", deploymentType: deploymentTypeLXC},
		{name: "generic container", goos: "linux", deploymentType: deploymentTypeContainer},
		{name: "docker", goos: "linux", deploymentType: deploymentTypeDocker},
		{name: "kubernetes", goos: "linux", deploymentType: deploymentTypeKubernetes},
		{name: "macOS", goos: "darwin", deploymentType: deploymentTypeBareMetal},
		{name: "windows", goos: "windows", deploymentType: deploymentTypeBareMetal},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			if got := supportsHostNetworkVisibility(tt.goos, tt.deploymentType); got != tt.supported {
				t.Fatalf("supportsHostNetworkVisibility(%q, %q) = %t, want %t", tt.goos, tt.deploymentType, got, tt.supported)
			}

			capabilities := agentCapabilities(agentCapabilityOptions{
				hostNetworkVisibilitySupported:          tt.supported,
				hostNetworkVisibilityFingerprintEnabled: true,
			})
			if got := slices.Contains(capabilities, capabilityHostNetworkVisibility); got != tt.supported {
				t.Fatalf("base host-network-visibility capability present = %t, want %t: %#v", got, tt.supported, capabilities)
			}
			if !slices.Contains(capabilities, capabilityHostNetworkVisibilityFingerprintEnabled) {
				t.Fatalf("runtime fingerprint status missing on unsupported deployment: %#v", capabilities)
			}
		})
	}
}

func TestUnsupportedDeploymentRetainsFingerprintUnavailableStatus(t *testing.T) {
	t.Parallel()

	capabilities := agentCapabilities(agentCapabilityOptions{})
	if slices.Contains(capabilities, capabilityHostNetworkVisibility) {
		t.Fatalf("unsupported deployment advertised base capability: %#v", capabilities)
	}
	if !slices.Contains(capabilities, capabilityHostNetworkVisibilityFingerprintUnavailable) {
		t.Fatalf("unsupported deployment omitted unavailable fingerprint status: %#v", capabilities)
	}
	if got := hostNetworkVisibilityFingerprintStatus(capabilities); got != capabilityStatusUnavailable {
		t.Fatalf("fingerprint status = %q, want %q", got, capabilityStatusUnavailable)
	}
}

// A containerized agent installs no native add-on at all, so only a bare-metal Linux
// agent may advertise that it hosts them. The capability is reported as an explicit
// available/unavailable pair so the control plane never has to infer it, and never
// silently treats a container as a viable rollout target.
func TestNativeAddonHostCapabilityEligibility(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name           string
		goos           string
		deploymentType string
		supported      bool
	}{
		{name: "linux host", goos: "linux", deploymentType: deploymentTypeBareMetal, supported: true},
		{name: "lxc", goos: "linux", deploymentType: deploymentTypeLXC},
		{name: "generic container", goos: "linux", deploymentType: deploymentTypeContainer},
		{name: "docker", goos: "linux", deploymentType: deploymentTypeDocker},
		{name: "kubernetes", goos: "linux", deploymentType: deploymentTypeKubernetes},
		{name: "macOS", goos: "darwin", deploymentType: deploymentTypeBareMetal},
		{name: "windows", goos: "windows", deploymentType: deploymentTypeBareMetal},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			if got := supportsNativeAddonHosting(tt.goos, tt.deploymentType); got != tt.supported {
				t.Fatalf("supportsNativeAddonHosting(%q, %q) = %t, want %t",
					tt.goos, tt.deploymentType, got, tt.supported)
			}

			capabilities := agentCapabilities(agentCapabilityOptions{nativeAddonHost: tt.supported})

			if got := slices.Contains(capabilities, capabilityAddonNativeHost); got != tt.supported {
				t.Fatalf("%q capability present = %t, want %t: %#v",
					capabilityAddonNativeHost, got, tt.supported, capabilities)
			}

			if got := slices.Contains(capabilities, capabilityAddonNativeHostUnavailable); got == tt.supported {
				t.Fatalf("%q capability present = %t, want %t: %#v",
					capabilityAddonNativeHostUnavailable, got, !tt.supported, capabilities)
			}
		})
	}
}
