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

//! Tests for deployment type detection.

use edge_onboarding::DeploymentType;

#[test]
fn test_deployment_type_as_str() {
    assert_eq!(DeploymentType::Docker.as_str(), "docker");
    assert_eq!(DeploymentType::Kubernetes.as_str(), "kubernetes");
    assert_eq!(DeploymentType::BareMetal.as_str(), "bare-metal");
}

// Note: Actual detection tests would require mocking the environment
// or running in actual Docker/K8s environments.
