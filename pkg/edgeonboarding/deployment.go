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

package edgeonboarding

import (
	"context"
	"errors"
	"os"
	"strings"
)

var (
	// ErrSPIREAddressResolutionNotImplemented is returned when SPIRE address resolution is attempted.
	ErrSPIREAddressResolutionNotImplemented = errors.New("not implemented: SPIRE address resolution")
)

// detectDeploymentType determines the deployment environment.
// It checks for:
// 1. User-specified deployment type in config
// 2. Kubernetes environment variables (KUBERNETES_SERVICE_HOST)
// 3. Docker environment (/.dockerenv file or cgroup)
// 4. Falls back to bare-metal
func (b *Bootstrapper) detectDeploymentType(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}

	// If already specified in config, use that
	if b.cfg.DeploymentType != "" {
		b.deploymentType = b.cfg.DeploymentType
		b.logger.Debug().
			Str("deployment_type", string(b.deploymentType)).
			Msg("Using deployment type from config")
		return nil
	}

	// Check for Kubernetes
	if isKubernetes() {
		b.deploymentType = DeploymentTypeKubernetes
		b.logger.Debug().Msg("Detected Kubernetes deployment")
		return nil
	}

	// Check for Docker
	if isDocker() {
		b.deploymentType = DeploymentTypeDocker
		b.logger.Debug().Msg("Detected Docker deployment")
		return nil
	}

	// Default to bare-metal
	b.deploymentType = DeploymentTypeBareMetal
	b.logger.Debug().Msg("Detected bare-metal deployment")

	return nil
}

// isKubernetes checks if running in a Kubernetes cluster.
func isKubernetes() bool {
	// Kubernetes sets this environment variable in all pods
	if os.Getenv("KUBERNETES_SERVICE_HOST") != "" {
		return true
	}

	// Check for service account token (mounted in all pods)
	if _, err := os.Stat("/var/run/secrets/kubernetes.io/serviceaccount/token"); err == nil {
		return true
	}

	return false
}

// isDocker checks if running in a Docker container.
func isDocker() bool {
	// Check for .dockerenv file
	if _, err := os.Stat("/.dockerenv"); err == nil {
		return true
	}

	// Check cgroup for docker
	if data, err := os.ReadFile("/proc/1/cgroup"); err == nil {
		content := string(data)
		if strings.Contains(content, "docker") || strings.Contains(content, "containerd") {
			return true
		}
	}

	// Check for container environment variable (often set by Docker)
	if os.Getenv("container") == "docker" {
		return true
	}

	return false
}

// getAddressForDeployment returns the appropriate address for the given service
// based on the deployment type.
// For example:
// - Docker: Use LoadBalancer IPs (can't resolve k8s DNS)
// - Kubernetes: Use service DNS names
// - Bare-metal: Use configured addresses
func (b *Bootstrapper) getAddressForDeployment(serviceName, defaultAddr string) string {
	// TODO: Implement address resolution based on deployment type
	// This will look up addresses from package metadata based on deployment type

	switch b.deploymentType {
	case DeploymentTypeDocker:
		// Docker deployments accessing k8s services need LoadBalancer IPs
		// These should be in the package metadata
		b.logger.Debug().
			Str("service", serviceName).
			Str("deployment_type", "docker").
			Msg("Using LoadBalancer IP for service (Docker deployment)")

	case DeploymentTypeKubernetes:
		// Kubernetes can use DNS names
		b.logger.Debug().
			Str("service", serviceName).
			Str("deployment_type", "kubernetes").
			Msg("Using DNS name for service (Kubernetes deployment)")

	case DeploymentTypeBareMetal:
		// Bare-metal uses configured addresses
		b.logger.Debug().
			Str("service", serviceName).
			Str("deployment_type", "bare-metal").
			Msg("Using configured address for service (bare-metal deployment)")
	}

	return defaultAddr
}

// getSPIREAddressesForDeployment returns SPIRE server addresses based on deployment type.
func (b *Bootstrapper) getSPIREAddressesForDeployment() (address string, port string, err error) {
	// TODO: Extract SPIRE addresses from package metadata
	// For Docker: Use LoadBalancer IP
	// For Kubernetes: Use service DNS
	// For Bare-metal: Use configured address

	// For now, return placeholder
	return "", "", ErrSPIREAddressResolutionNotImplemented
}
