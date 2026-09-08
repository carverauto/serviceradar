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
	"runtime"
	"strings"
)

const (
	linuxOS                  = "linux"
	deploymentTypeBareMetal  = "bare-metal"
	deploymentTypeContainer  = "container"
	deploymentTypeDocker     = "docker"
	deploymentTypeKubernetes = "kubernetes"
	deploymentTypeLXC        = "lxc"
)

type deploymentRuntimeProbe struct {
	getenv     func(string) string
	pathExists func(string) bool
	readFile   func(string) ([]byte, error)
}

func deploymentHelloLabels() map[string]string {
	return map[string]string{
		"deployment_type": detectDeploymentType(),
	}
}

func detectDeploymentType() string {
	return detectDeploymentTypeWithProbe(deploymentRuntimeProbe{
		getenv: os.Getenv,
		pathExists: func(path string) bool {
			_, err := os.Stat(path)
			return err == nil
		},
		readFile: os.ReadFile,
	})
}

func detectDeploymentTypeWithProbe(probe deploymentRuntimeProbe) string {
	switch {
	case isKubernetesRuntime(probe):
		return deploymentTypeKubernetes
	case isDockerRuntime(probe):
		return deploymentTypeDocker
	case isLXCRuntime(probe):
		return deploymentTypeLXC
	case isGenericContainerRuntime(probe):
		return deploymentTypeContainer
	default:
		return deploymentTypeBareMetal
	}
}

func isKubernetesRuntime(probe deploymentRuntimeProbe) bool {
	if probe.getenv != nil && probe.getenv("KUBERNETES_SERVICE_HOST") != "" {
		return true
	}

	return probe.pathExists != nil && probe.pathExists("/var/run/secrets/kubernetes.io/serviceaccount/token")
}

func isDockerRuntime(probe deploymentRuntimeProbe) bool {
	if probe.pathExists != nil && probe.pathExists("/.dockerenv") {
		return true
	}

	if data, err := readDeploymentRuntimeFile(probe, "/proc/1/cgroup"); err == nil {
		content := string(data)
		if strings.Contains(content, "docker") || strings.Contains(content, "containerd") {
			return true
		}
	}

	return probe.getenv != nil && strings.EqualFold(strings.TrimSpace(probe.getenv("container")), "docker")
}

func isLXCRuntime(probe deploymentRuntimeProbe) bool {
	if probe.getenv != nil && isLXCContainerValue(probe.getenv("container")) {
		return true
	}

	if data, err := readDeploymentRuntimeFile(probe, "/run/systemd/container"); err == nil &&
		isLXCContainerValue(string(data)) {
		return true
	}

	if data, err := readDeploymentRuntimeFile(probe, "/proc/1/cgroup"); err == nil &&
		cgroupIdentifiesLXC(string(data)) {
		return true
	}

	if data, err := readDeploymentRuntimeFile(probe, "/proc/1/environ"); err == nil &&
		isLXCContainerValue(procEnvironValue(data, "container")) {
		return true
	}

	return false
}

func isGenericContainerRuntime(probe deploymentRuntimeProbe) bool {
	if probe.pathExists != nil && probe.pathExists("/run/.containerenv") {
		return true
	}

	if probe.getenv != nil && strings.TrimSpace(probe.getenv("container")) != "" {
		return true
	}

	if data, err := readDeploymentRuntimeFile(probe, "/run/systemd/container"); err == nil &&
		strings.TrimSpace(string(data)) != "" {
		return true
	}

	if data, err := readDeploymentRuntimeFile(probe, "/proc/1/environ"); err == nil &&
		strings.TrimSpace(procEnvironValue(data, "container")) != "" {
		return true
	}

	if data, err := readDeploymentRuntimeFile(probe, "/proc/1/cgroup"); err == nil {
		content := strings.ToLower(string(data))
		return strings.Contains(content, "libpod") ||
			strings.Contains(content, "/machine.slice/machine-") ||
			strings.Contains(content, "kubepods")
	}

	return false
}

func readDeploymentRuntimeFile(probe deploymentRuntimeProbe, path string) ([]byte, error) {
	if probe.readFile == nil {
		return nil, os.ErrNotExist
	}

	return probe.readFile(path)
}

func isLXCContainerValue(value string) bool {
	value = strings.ToLower(strings.TrimSpace(value))
	return value == deploymentTypeLXC || strings.HasPrefix(value, deploymentTypeLXC+"-") ||
		strings.HasPrefix(value, deploymentTypeLXC+".")
}

func cgroupIdentifiesLXC(content string) bool {
	content = strings.ToLower(content)
	return strings.Contains(content, "/lxc/") ||
		strings.Contains(content, "lxc.payload") ||
		strings.Contains(content, "machine-lxc")
}

func procEnvironValue(content []byte, key string) string {
	prefix := key + "="
	for entry := range strings.SplitSeq(string(content), "\x00") {
		if strings.HasPrefix(entry, prefix) {
			return strings.TrimPrefix(entry, prefix)
		}
	}

	return ""
}

func supportsHostNetworkVisibility(goos, deploymentType string) bool {
	return goos == linuxOS && deploymentType == deploymentTypeBareMetal
}

// supportsNativeAddonHosting reports whether this agent installs native add-ons at
// all. Installing a systemd-supervised one means writing unit files into the host's
// system unit dir and enabling them through the root-owned agent-updater, which a
// containerized agent does not have -- and applyAddonAssignments already refuses the
// whole set on such a host, whatever the supervision model.
//
// Reported so the control plane stops treating a container as a viable target. A
// silent target is not harmless: rollouts default to tolerated_failures: 0, so one
// container that can never report add-on health ages out at candidate_health_timeout
// and fails the rollout for every bare-metal host in the fleet.
func supportsNativeAddonHosting(goos, deploymentType string) bool {
	return goos == linuxOS && deploymentType == deploymentTypeBareMetal
}

func runtimeSupportsNativeAddonHosting() bool {
	return supportsNativeAddonHosting(runtime.GOOS, detectDeploymentType())
}

func runtimeSupportsHostNetworkVisibility() bool {
	return supportsHostNetworkVisibility(runtime.GOOS, detectDeploymentType())
}

func (p *PushLoop) hostSupportsNetworkVisibility() bool {
	if p != nil && p.hostNetworkVisibilitySupported != nil {
		return p.hostNetworkVisibilitySupported()
	}

	return runtimeSupportsHostNetworkVisibility()
}
