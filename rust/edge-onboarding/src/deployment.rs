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

//! Deployment type detection.
//!
//! Detects whether the service is running in Docker, Kubernetes, or bare-metal.

use std::env;
use std::fs;
use std::path::Path;

/// Deployment environment type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeploymentType {
    /// Running in a Docker container.
    Docker,
    /// Running in a Kubernetes pod.
    Kubernetes,
    /// Running on bare-metal or a VM.
    BareMetal,
}

impl DeploymentType {
    pub fn as_str(&self) -> &'static str {
        match self {
            DeploymentType::Docker => "docker",
            DeploymentType::Kubernetes => "kubernetes",
            DeploymentType::BareMetal => "bare-metal",
        }
    }
}

/// Detect the deployment type.
///
/// Checks for:
/// 1. Kubernetes environment variables and service account token
/// 2. Docker environment file and cgroup
/// 3. Falls back to bare-metal
pub fn detect_deployment() -> DeploymentType {
    if is_kubernetes() {
        return DeploymentType::Kubernetes;
    }

    if is_docker() {
        return DeploymentType::Docker;
    }

    DeploymentType::BareMetal
}

/// Check if running in a Kubernetes cluster.
fn is_kubernetes() -> bool {
    // Kubernetes sets this environment variable in all pods
    if env::var("KUBERNETES_SERVICE_HOST").is_ok() {
        return true;
    }

    // Check for service account token (mounted in all pods)
    if Path::new("/var/run/secrets/kubernetes.io/serviceaccount/token").exists() {
        return true;
    }

    false
}

/// Check if running in a Docker container.
fn is_docker() -> bool {
    // Check for .dockerenv file
    if Path::new("/.dockerenv").exists() {
        return true;
    }

    // Check cgroup for docker/containerd
    if let Ok(data) = fs::read_to_string("/proc/1/cgroup") {
        if data.contains("docker") || data.contains("containerd") {
            return true;
        }
    }

    // Check for container environment variable
    if env::var("container").ok().as_deref() == Some("docker") {
        return true;
    }

    false
}
