/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

//! Pure helpers behind the wait strategies.
//!
//! They are public so that the test suite under `tests/` can exercise them directly. Each
//! one is a plain function over its inputs and runs no command of its own.

/// Builds the curl arguments used for the health check.
///
/// `--fail` is what makes the status code count. Without it curl exits successfully for any
/// response it managed to retrieve, so a 503 from a service that is up but not yet ready
/// reads as readiness and the strategy degrades to "the port answered". With it curl exits
/// 22 for any status of 400 or above.
///
/// `--show-error` keeps the reason on stderr despite `--silent`, and the body is discarded
/// because only the status matters here.
pub fn build_curl_args(health_url: &str) -> Vec<String> {
    vec![
        "--fail".to_string(),
        "--silent".to_string(),
        "--show-error".to_string(),
        "--output".to_string(),
        "/dev/null".to_string(),
        health_url.to_string(),
    ]
}

/// Returns whether either captured stream contains the expected output.
///
/// `docker logs` keeps stdout and stderr apart rather than interleaving them, and a great
/// many services report readiness on stderr, in particular anything built on glog. Searching
/// stdout alone means those services can never match and the strategy can only time out.
pub fn streams_contain(stdout: &[u8], stderr: &[u8], expected_output: &str) -> bool {
    String::from_utf8_lossy(stdout).contains(expected_output)
        || String::from_utf8_lossy(stderr).contains(expected_output)
}
