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

//! mTLS bundle handling and installation.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use crate::config::SecurityConfig;
use crate::error::{Error, Result};

/// mTLS bundle containing certificates and keys.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MtlsBundle {
    /// CA certificate PEM.
    #[serde(default, alias = "ca_cert")]
    pub ca_cert_pem: String,

    /// Client certificate PEM.
    #[serde(default, alias = "client_cert_pem")]
    pub client_cert: String,

    /// Client private key PEM.
    #[serde(default, alias = "client_key_pem")]
    pub client_key: String,

    /// Server name for TLS verification.
    #[serde(default)]
    pub server_name: String,

    /// Service endpoints.
    #[serde(default)]
    pub endpoints: HashMap<String, String>,
}

/// Install mTLS bundle to the certificate directory.
///
/// Writes CA cert, client cert, and client key to the specified directory.
/// Returns a SecurityConfig with the paths set.
pub fn install_mtls_bundle(
    bundle: &MtlsBundle,
    cert_dir: &Path,
    service_name: &str,
) -> Result<SecurityConfig> {
    // Validate bundle fields
    if bundle.ca_cert_pem.trim().is_empty() {
        return Err(Error::BundleFieldMissing {
            field: "ca_cert_pem".to_string(),
        });
    }
    if bundle.client_cert.trim().is_empty() {
        return Err(Error::BundleFieldMissing {
            field: "client_cert".to_string(),
        });
    }
    if bundle.client_key.trim().is_empty() {
        return Err(Error::BundleFieldMissing {
            field: "client_key".to_string(),
        });
    }

    // Create cert directory if needed
    fs::create_dir_all(cert_dir).map_err(|e| Error::Io {
        path: cert_dir.display().to_string(),
        source: e,
    })?;

    // Write CA cert (0644)
    let ca_path = cert_dir.join("root.pem");
    write_file(&ca_path, &bundle.ca_cert_pem, 0o644)?;

    // Write client cert (0644)
    let cert_filename = format!("{}.pem", service_name);
    let cert_path = cert_dir.join(&cert_filename);
    write_file(&cert_path, &bundle.client_cert, 0o644)?;

    // Write client key (0600)
    let key_filename = format!("{}-key.pem", service_name);
    let key_path = cert_dir.join(&key_filename);
    write_file(&key_path, &bundle.client_key, 0o600)?;

    tracing::info!(
        cert_dir = %cert_dir.display(),
        "Installed mTLS certificates"
    );

    Ok(SecurityConfig {
        mode: Some(crate::config::SecurityMode::Mtls),
        tls_enabled: Some(true),
        cert_dir: Some(cert_dir.display().to_string()),
        cert_file: Some(cert_filename),
        key_file: Some(key_filename),
        ca_file: Some("root.pem".to_string()),
        client_ca_file: Some("root.pem".to_string()),
        trust_domain: None,
        workload_socket: None,
        server_spiffe_id: None,
    })
}

/// Load mTLS bundle from a file or directory.
///
/// Supports:
/// - JSON file with bundle structure
/// - Directory with ca.pem, client.pem, client-key.pem
pub fn load_bundle_from_path(path: &str) -> Result<MtlsBundle> {
    let path = Path::new(path);

    if !path.exists() {
        return Err(Error::Io {
            path: path.display().to_string(),
            source: std::io::Error::new(std::io::ErrorKind::NotFound, "bundle path not found"),
        });
    }

    if path.is_dir() {
        load_bundle_from_dir(path)
    } else if path.extension().and_then(|e| e.to_str()) == Some("json") {
        load_bundle_from_json(path)
    } else {
        Err(Error::UnsupportedBundleFormat)
    }
}

/// Load bundle from a directory containing PEM files.
fn load_bundle_from_dir(dir: &Path) -> Result<MtlsBundle> {
    let ca_path = dir.join("ca.pem");
    let cert_path = dir.join("client.pem");
    let key_path = dir.join("client-key.pem");

    let ca_cert_pem = fs::read_to_string(&ca_path).map_err(|e| Error::Io {
        path: ca_path.display().to_string(),
        source: e,
    })?;

    let client_cert = fs::read_to_string(&cert_path).map_err(|e| Error::Io {
        path: cert_path.display().to_string(),
        source: e,
    })?;

    let client_key = fs::read_to_string(&key_path).map_err(|e| Error::Io {
        path: key_path.display().to_string(),
        source: e,
    })?;

    Ok(MtlsBundle {
        ca_cert_pem,
        client_cert,
        client_key,
        server_name: String::new(),
        endpoints: HashMap::new(),
    })
}

/// Load bundle from a JSON file.
fn load_bundle_from_json(path: &Path) -> Result<MtlsBundle> {
    let data = fs::read_to_string(path).map_err(|e| Error::Io {
        path: path.display().to_string(),
        source: e,
    })?;

    let bundle: MtlsBundle = serde_json::from_str(&data)?;
    Ok(bundle)
}

/// Write a file with the specified permissions.
fn write_file(path: &Path, content: &str, mode: u32) -> Result<()> {
    fs::write(path, content).map_err(|e| Error::Io {
        path: path.display().to_string(),
        source: e,
    })?;

    let perms = fs::Permissions::from_mode(mode);
    fs::set_permissions(path, perms).map_err(|e| Error::Io {
        path: path.display().to_string(),
        source: e,
    })?;

    Ok(())
}
