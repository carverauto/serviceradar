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

//! Tests for mTLS bundle handling.

use edge_onboarding::{install_mtls_bundle, load_bundle_from_path, Error, MtlsBundle};
use std::collections::HashMap;
use std::fs;
use tempfile::TempDir;

#[test]
fn test_install_mtls_bundle() {
    let temp_dir = TempDir::new().unwrap();
    let cert_dir = temp_dir.path();

    let bundle = MtlsBundle {
        ca_cert_pem: "-----BEGIN CERTIFICATE-----\nCA\n-----END CERTIFICATE-----".to_string(),
        client_cert: "-----BEGIN CERTIFICATE-----\nCLIENT\n-----END CERTIFICATE-----".to_string(),
        client_key: "-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----".to_string(),
        server_name: "test.local".to_string(),
        endpoints: HashMap::new(),
    };

    let security = install_mtls_bundle(&bundle, cert_dir, "test").unwrap();

    assert!(cert_dir.join("root.pem").exists());
    assert!(cert_dir.join("test.pem").exists());
    assert!(cert_dir.join("test-key.pem").exists());

    assert_eq!(security.cert_file, Some("test.pem".to_string()));
    assert_eq!(security.key_file, Some("test-key.pem".to_string()));
}

#[test]
fn test_load_bundle_from_dir() {
    let temp_dir = TempDir::new().unwrap();
    let dir = temp_dir.path();

    fs::write(dir.join("ca.pem"), "CA_CERT").unwrap();
    fs::write(dir.join("client.pem"), "CLIENT_CERT").unwrap();
    fs::write(dir.join("client-key.pem"), "CLIENT_KEY").unwrap();

    let bundle = load_bundle_from_path(dir.to_str().unwrap()).unwrap();

    assert_eq!(bundle.ca_cert_pem, "CA_CERT");
    assert_eq!(bundle.client_cert, "CLIENT_CERT");
    assert_eq!(bundle.client_key, "CLIENT_KEY");
}

#[test]
fn test_bundle_missing_fields() {
    let temp_dir = TempDir::new().unwrap();
    let cert_dir = temp_dir.path();

    let bundle = MtlsBundle {
        ca_cert_pem: String::new(),
        client_cert: "CERT".to_string(),
        client_key: "KEY".to_string(),
        server_name: String::new(),
        endpoints: HashMap::new(),
    };

    let result = install_mtls_bundle(&bundle, cert_dir, "test");
    assert!(matches!(result, Err(Error::BundleFieldMissing { .. })));
}
