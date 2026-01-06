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

//! Integration tests for edge_onboarding crate.

use edge_onboarding::{
    try_onboard, ComponentType, DeploymentType, MtlsBootstrapConfig, OnboardingResult,
    SecurityConfig, SecurityMode,
};

#[test]
fn test_component_type_as_str() {
    assert_eq!(ComponentType::Gateway.as_str(), "gateway");
    assert_eq!(ComponentType::Agent.as_str(), "agent");
    assert_eq!(ComponentType::Checker.as_str(), "checker");
    assert_eq!(ComponentType::Sync.as_str(), "sync");
}

#[test]
fn test_component_type_config_filename() {
    assert_eq!(ComponentType::Gateway.config_filename(), "gateway.json");
    assert_eq!(ComponentType::Agent.config_filename(), "agent.json");
    assert_eq!(ComponentType::Checker.config_filename(), "checker.json");
    assert_eq!(ComponentType::Sync.config_filename(), "sync.json");
}

#[test]
fn test_try_onboard_no_token() {
    // Clear the env var if set
    std::env::remove_var("ONBOARDING_TOKEN");

    // Should return None when no token is present
    let result = try_onboard(ComponentType::Checker).unwrap();
    assert!(result.is_none());
}

#[test]
fn test_try_onboard_empty_token() {
    std::env::set_var("ONBOARDING_TOKEN", "");

    let result = try_onboard(ComponentType::Checker).unwrap();
    assert!(result.is_none());

    std::env::remove_var("ONBOARDING_TOKEN");
}

#[test]
fn test_try_onboard_whitespace_token() {
    std::env::set_var("ONBOARDING_TOKEN", "   ");

    let result = try_onboard(ComponentType::Checker).unwrap();
    assert!(result.is_none());

    std::env::remove_var("ONBOARDING_TOKEN");
}

#[test]
fn test_mtls_bootstrap_config_fields() {
    let cfg = MtlsBootstrapConfig {
        token: "edgepkg-v1:abc".to_string(),
        host: Some("http://localhost:8090".to_string()),
        bundle_path: None,
        cert_dir: Some("/tmp/certs".to_string()),
        service_name: Some("sysmon".to_string()),
    };

    assert_eq!(cfg.token, "edgepkg-v1:abc");
    assert_eq!(cfg.host.as_deref(), Some("http://localhost:8090"));
    assert!(cfg.bundle_path.is_none());
    assert_eq!(cfg.cert_dir.as_deref(), Some("/tmp/certs"));
    assert_eq!(cfg.service_name.as_deref(), Some("sysmon"));
}

#[test]
fn test_onboarding_result_fields() {
    let result = OnboardingResult {
        config_path: "/etc/config/checker.json".to_string(),
        config_data: vec![1, 2, 3],
        spiffe_id: Some("spiffe://example.com/service".to_string()),
        package_id: "pkg-123".to_string(),
        deployment_type: DeploymentType::Docker,
        cert_dir: "/etc/certs".to_string(),
    };

    assert_eq!(result.config_path, "/etc/config/checker.json");
    assert_eq!(result.config_data, vec![1, 2, 3]);
    assert_eq!(
        result.spiffe_id,
        Some("spiffe://example.com/service".to_string())
    );
    assert_eq!(result.package_id, "pkg-123");
    assert_eq!(result.deployment_type, DeploymentType::Docker);
    assert_eq!(result.cert_dir, "/etc/certs");
}

#[test]
fn test_security_config_default() {
    let config = SecurityConfig::default();
    assert!(config.tls_enabled.is_none());
    assert!(config.mode.is_none());
    assert!(config.cert_dir.is_none());
}

#[test]
fn test_security_mode_default() {
    let mode = SecurityMode::default();
    assert_eq!(mode, SecurityMode::None);
}
