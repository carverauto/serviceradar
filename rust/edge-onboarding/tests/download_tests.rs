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

//! Tests for package download functionality.
//!
//! Note: The `ensure_scheme` function is internal to the download module.
//! These tests focus on the public API behavior.

use edge_onboarding::{download_package, Error, TokenPayload};

#[test]
fn test_download_package_requires_core_url() {
    let payload = TokenPayload {
        package_id: "pkg-123".to_string(),
        download_token: "dl-456".to_string(),
        core_url: None,
    };

    let result = download_package(&payload);
    assert!(matches!(result, Err(Error::CoreApiHostRequired)));
}

#[test]
fn test_download_package_with_empty_host() {
    let payload = TokenPayload {
        package_id: "pkg-123".to_string(),
        download_token: "dl-456".to_string(),
        core_url: Some("".to_string()),
    };

    let result = download_package(&payload);
    assert!(matches!(result, Err(Error::CoreApiHostRequired)));
}

// Note: Full download tests require a running Core API server
// and are better suited for integration/E2E tests.
