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

//! Tests for configuration generation.

use edge_onboarding::{
    generate_checker_config, DeploymentType, PackageResponse, SecurityConfig, SecurityMode,
};

#[test]
fn test_generate_checker_config_defaults() {
    let package = PackageResponse {
        package_id: "pkg-123".to_string(),
        component_type: "checker".to_string(),
        checker_kind: "sysmon".to_string(),
        checker_config_json: None,
        parent_id: Some("agent-1".to_string()),
        component_id: Some("sysmon-1".to_string()),
        label: Some("Test Sysmon".to_string()),
        site: None,
        downstream_spiffe_id: None,
        mtls_bundle: None,
        join_token: None,
        bundle_pem: None,
    };

    let config = generate_checker_config(&package, None, &DeploymentType::BareMetal).unwrap();

    assert_eq!(config.listen_addr, "0.0.0.0:50083");
    assert_eq!(config.poll_interval, 30);
    assert_eq!(config.partition, Some("sysmon-1".to_string()));
    assert_eq!(config.filesystems.len(), 1);
}

#[test]
fn test_generate_checker_config_with_overlay() {
    let package = PackageResponse {
        package_id: "pkg-123".to_string(),
        component_type: "checker".to_string(),
        checker_kind: "sysmon".to_string(),
        checker_config_json: Some(
            r#"{"listen_addr": "0.0.0.0:50110", "poll_interval": 60}"#.to_string(),
        ),
        parent_id: None,
        component_id: None,
        label: None,
        site: None,
        downstream_spiffe_id: None,
        mtls_bundle: None,
        join_token: None,
        bundle_pem: None,
    };

    let config = generate_checker_config(&package, None, &DeploymentType::Docker).unwrap();

    assert_eq!(config.listen_addr, "0.0.0.0:50110");
    assert_eq!(config.poll_interval, 60);
}

#[test]
fn test_security_config_serialization() {
    let security = SecurityConfig {
        mode: Some(SecurityMode::Mtls),
        tls_enabled: Some(true),
        cert_dir: Some("/etc/certs".to_string()),
        cert_file: Some("client.pem".to_string()),
        key_file: Some("client-key.pem".to_string()),
        ca_file: Some("ca.pem".to_string()),
        client_ca_file: None,
        trust_domain: None,
        workload_socket: None,
        server_spiffe_id: None,
    };

    let json = serde_json::to_string(&security).unwrap();
    assert!(json.contains(r#""mode":"mtls""#));
    assert!(!json.contains("client_ca_file")); // None should be skipped
}
