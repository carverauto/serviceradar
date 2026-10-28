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

use edge_onboarding::{ComponentType, SecurityConfig, SecurityMode, try_onboard};
use std::sync::{Mutex, OnceLock};

const ONBOARDING_TOKEN_ENV: &str = "ONBOARDING_TOKEN";

fn env_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

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
    let _guard = env_lock().lock().unwrap();
    // Clear the env var if set
    // SAFETY: `env_lock` serialises every test in this binary that touches
    // ONBOARDING_TOKEN, so no other thread can read the environment concurrently.
    unsafe {
        std::env::remove_var(ONBOARDING_TOKEN_ENV);
    }

    // Should return None when no token is present
    let result = try_onboard(ComponentType::Checker).unwrap();
    assert!(result.is_none());
}

#[test]
fn test_try_onboard_empty_token() {
    let _guard = env_lock().lock().unwrap();
    // SAFETY: as above; `env_lock` is held for the duration of the test.
    unsafe {
        std::env::set_var(ONBOARDING_TOKEN_ENV, "");
    }

    let result = try_onboard(ComponentType::Checker).unwrap();
    assert!(result.is_none());

    // SAFETY: as above; still holding `env_lock`.
    unsafe {
        std::env::remove_var(ONBOARDING_TOKEN_ENV);
    }
}

#[test]
fn test_try_onboard_whitespace_token() {
    let _guard = env_lock().lock().unwrap();
    // SAFETY: as above; `env_lock` is held for the duration of the test.
    unsafe {
        std::env::set_var(ONBOARDING_TOKEN_ENV, "   ");
    }

    let result = try_onboard(ComponentType::Checker).unwrap();
    assert!(result.is_none());

    // SAFETY: as above; still holding `env_lock`.
    unsafe {
        std::env::remove_var(ONBOARDING_TOKEN_ENV);
    }
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
