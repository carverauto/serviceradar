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

//! Edge onboarding library for ServiceRadar Rust checkers.
//!
//! This crate provides edge onboarding functionality for Rust-based checkers,
//! mirroring the Go `pkg/edgeonboarding` package. It supports:
//!
//! - mTLS bootstrap via token and Core API
//! - Offline bundle loading from files
//! - Deployment type detection (Docker, Kubernetes, bare-metal)
//! - Configuration generation for sysmon checker
//!
//! # Example
//!
//! ```rust,no_run
//! use edge_onboarding::{try_onboard, ComponentType};
//!
//! fn main() -> Result<(), Box<dyn std::error::Error>> {
//!     // Attempt onboarding from environment variables
//!     if let Some(result) = try_onboard(ComponentType::Checker)? {
//!         println!("Onboarded! Config path: {}", result.config_path);
//!         println!("SPIFFE ID: {:?}", result.spiffe_id);
//!     } else {
//!         println!("No onboarding token found, using traditional config");
//!     }
//!     Ok(())
//! }
//! ```

pub use types::bundle::{install_mtls_bundle, load_bundle_from_path, MtlsBundle};
pub use types::config_generator::generate_checker_config;
pub use types::deployment::{detect_deployment, DeploymentType};
pub use types::download::{download_package, PackageResponse};
pub use errors::{Error, Result};
pub use types::token::{encode_token, parse_token, TokenPayload};

pub mod errors;
pub mod types;
pub mod traits;

pub use types::config_types::checker_config::CheckerConfig;


use std::env;
use std::fs;
use std::path::PathBuf;
use types::{bundle, config_types};
pub use types::component_type::ComponentType;
pub use types::mtls_bootstrap_config::MtlsBootstrapConfig;
pub use types::onboarding_result::OnboardingResult;
pub use types::config_types::security_config::SecurityConfig;
pub use types::config_types::filesystem_config::FilesystemConfig;
pub use types::security_mode::SecurityMode;

/// Try to perform edge onboarding based on environment variables.
///
/// Checks for:
/// - `ONBOARDING_TOKEN`: The edgepkg-v1 token
/// - `CORE_API_URL`: Optional Core API base URL (fallback if not in token)
/// - `KV_ENDPOINT`: Required for SPIRE-based onboarding
///
/// Returns:
/// - `Ok(Some(result))` if onboarding was performed
/// - `Ok(None)` if no onboarding token is set (use traditional config)
/// - `Err(...)` if onboarding was attempted but failed
pub fn try_onboard(component_type: ComponentType) -> Result<Option<OnboardingResult>> {
    let token = env::var("ONBOARDING_TOKEN").ok();
    let core_api_url = env::var("CORE_API_URL").ok();

    // If no token, return None to use traditional config
    let token = match token {
        Some(t) if !t.trim().is_empty() => t,
        _ => return Ok(None),
    };

    tracing::info!(
        component_type = component_type.as_str(),
        "Onboarding token detected - starting edge onboarding"
    );

    // Detect deployment type
    let deployment_type = detect_deployment();
    tracing::debug!(?deployment_type, "Detected deployment type");

    // Determine storage path based on deployment type
    let storage_path = get_storage_path(&deployment_type, component_type);
    let cert_dir = storage_path.join("certs");

    // Parse token
    let payload = parse_token(&token, None, core_api_url.as_deref())?;
    tracing::debug!(package_id = %payload.package_id, "Parsed onboarding token");

    // Download package from Core API
    let package = download_package(&payload)?;
    tracing::info!(
        package_id = %package.package_id,
        "Downloaded onboarding package"
    );

    // Install mTLS bundle if present
    let security_config = if let Some(ref bundle) = package.mtls_bundle {
        fs::create_dir_all(&cert_dir).map_err(|e| Error::Io {
            path: cert_dir.display().to_string(),
            source: e,
        })?;

        let installed = install_mtls_bundle(bundle, &cert_dir, "sysmon")?;
        tracing::info!(cert_dir = %cert_dir.display(), "Installed mTLS certificates");
        Some(installed)
    } else {
        None
    };

    // Generate checker config
    let config = generate_checker_config(&package, security_config.as_ref(), &deployment_type)?;
    let config_data = serde_json::to_vec_pretty(&config)?;

    // Write config file
    let config_dir = storage_path.join("config");
    fs::create_dir_all(&config_dir).map_err(|e| Error::Io {
        path: config_dir.display().to_string(),
        source: e,
    })?;

    let config_path = config_dir.join(component_type.config_filename());
    fs::write(&config_path, &config_data).map_err(|e| Error::Io {
        path: config_path.display().to_string(),
        source: e,
    })?;

    tracing::info!(
        config_path = %config_path.display(),
        "Wrote generated configuration"
    );

    Ok(Some(OnboardingResult {
        config_path: config_path.display().to_string(),
        config_data,
        spiffe_id: package.downstream_spiffe_id.clone(),
        package_id: package.package_id.clone(),
        deployment_type,
        cert_dir: cert_dir.display().to_string(),
    }))
}

/// Perform mTLS bootstrap using CLI flags.
///
/// This is an alternative to `try_onboard` for explicit mTLS bootstrap
/// via command-line flags (e.g., `--mtls --token <TOKEN> --host <HOST>`).
pub fn mtls_bootstrap(cfg: &MtlsBootstrapConfig) -> Result<OnboardingResult> {
    let deployment_type = detect_deployment();
    let storage_path = get_storage_path(&deployment_type, ComponentType::Checker);

    let cert_dir = cfg
        .cert_dir
        .as_ref()
        .map(PathBuf::from)
        .unwrap_or_else(|| storage_path.join("certs"));

    let service_name = cfg.service_name.as_deref().unwrap_or("sysmon");

    // If bundle path is provided, load from file
    if let Some(ref bundle_path) = cfg.bundle_path {
        let bundle = bundle::load_bundle_from_path(bundle_path)?;
        fs::create_dir_all(&cert_dir).map_err(|e| Error::Io {
            path: cert_dir.display().to_string(),
            source: e,
        })?;

        let security = install_mtls_bundle(&bundle, &cert_dir, service_name)?;
        let config = generate_checker_config_mtls(&security, &deployment_type);
        let config_data = serde_json::to_vec_pretty(&config)?;

        let config_dir = storage_path.join("config");
        fs::create_dir_all(&config_dir).map_err(|e| Error::Io {
            path: config_dir.display().to_string(),
            source: e,
        })?;

        let config_path = config_dir.join("checker.json");
        fs::write(&config_path, &config_data).map_err(|e| Error::Io {
            path: config_path.display().to_string(),
            source: e,
        })?;

        return Ok(OnboardingResult {
            config_path: config_path.display().to_string(),
            config_data,
            spiffe_id: None,
            package_id: String::new(),
            deployment_type,
            cert_dir: cert_dir.display().to_string(),
        });
    }

    // Otherwise, fetch from Core API using token
    let payload = parse_token(&cfg.token, None, cfg.host.as_deref())?;
    let package = download_package(&payload)?;

    let bundle = package.mtls_bundle.as_ref().ok_or(Error::BundleMissing)?;

    fs::create_dir_all(&cert_dir).map_err(|e| Error::Io {
        path: cert_dir.display().to_string(),
        source: e,
    })?;

    let security = install_mtls_bundle(bundle, &cert_dir, service_name)?;
    let config = generate_checker_config(&package, Some(&security), &deployment_type)?;
    let config_data = serde_json::to_vec_pretty(&config)?;

    let config_dir = storage_path.join("config");
    fs::create_dir_all(&config_dir).map_err(|e| Error::Io {
        path: config_dir.display().to_string(),
        source: e,
    })?;

    let config_path = config_dir.join("checker.json");
    fs::write(&config_path, &config_data).map_err(|e| Error::Io {
        path: config_path.display().to_string(),
        source: e,
    })?;

    Ok(OnboardingResult {
        config_path: config_path.display().to_string(),
        config_data,
        spiffe_id: package.downstream_spiffe_id,
        package_id: package.package_id,
        deployment_type,
        cert_dir: cert_dir.display().to_string(),
    })
}

/// Get storage path based on deployment type.
fn get_storage_path(deployment_type: &DeploymentType, component_type: ComponentType) -> PathBuf {
    match deployment_type {
        DeploymentType::Docker => {
            PathBuf::from("/var/lib/serviceradar").join(component_type.as_str())
        }
        DeploymentType::Kubernetes => {
            PathBuf::from("/var/lib/serviceradar").join(component_type.as_str())
        }
        DeploymentType::BareMetal => {
            PathBuf::from("/var/lib/serviceradar").join(component_type.as_str())
        }
    }
}

/// Generate a minimal checker config for mTLS-only bootstrap (no package).
fn generate_checker_config_mtls(
    security: &SecurityConfig,
    _deployment_type: &DeploymentType,
) -> CheckerConfig {
    CheckerConfig {
        listen_addr: "0.0.0.0:50083".to_string(),
        security: Some(security.clone()),
        poll_interval: 30,
        filesystems: vec![config_types::filesystem_config::FilesystemConfig {
            name: "/".to_string(),
            fs_type: "ext4".to_string(),
            monitor: true,
        }],
        partition: None,
        zfs: None,
        process_monitoring: None,
    }
}
