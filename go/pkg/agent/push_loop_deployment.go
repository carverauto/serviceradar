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
	"strings"
)

// getAgentCapabilities returns the list of capabilities this agent supports.
func deploymentHelloLabels() map[string]string {
	return map[string]string{
		"deployment_type": detectDeploymentType(),
	}
}

func detectDeploymentType() string {
	switch {
	case isKubernetesRuntime():
		return "kubernetes"
	case isDockerRuntime():
		return "docker"
	default:
		return "bare-metal"
	}
}

func isKubernetesRuntime() bool {
	if os.Getenv("KUBERNETES_SERVICE_HOST") != "" {
		return true
	}

	_, err := os.Stat("/var/run/secrets/kubernetes.io/serviceaccount/token")
	return err == nil
}

func isDockerRuntime() bool {
	if _, err := os.Stat("/.dockerenv"); err == nil {
		return true
	}

	if data, err := os.ReadFile("/proc/1/cgroup"); err == nil {
		content := string(data)
		if strings.Contains(content, "docker") || strings.Contains(content, "containerd") {
			return true
		}
	}

	return os.Getenv("container") == "docker"
}
