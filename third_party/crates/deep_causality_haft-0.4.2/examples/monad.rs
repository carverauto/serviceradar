/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_haft::{Bifunctor, Functor, Monad};
use deep_causality_haft::{OptionWitness, ResultUnboundWitness, ResultWitness};

// ============================================================================
// Domain Types: Configuration System
// ============================================================================

fn main() {
    println!("=== DeepCausality HKT: Monad Pattern (Configuration Pipeline) ===\n");

    // ------------------------------------------------------------------------
    // Step 1: The "Happy Path" Pipeline (Monad)
    //
    // ENGINEERING VALUE:
    // Loading configuration involves multiple dependent steps that can fail:
    // Read File -> Parse JSON -> Validate Fields.
    //
    // Using the Monad pattern (`bind`), we chain these steps into a linear pipeline.
    // If ANY step fails, the error propagates automatically, skipping subsequent steps.
    // This eliminates nested `if let Ok(...)` or `match` hell.
    // ------------------------------------------------------------------------
    println!("--- 1. Monadic Pipeline: Load -> Parse -> Validate ---");

    // Mock: Simulate reading a file
    let read_config_file = || -> Result<String, ConfigError> {
        Ok("host=localhost;port=8080;timeout=5000".to_string())
    };

    // Step 1: Parse (String -> RawConfig)
    let parse_config = |content: String| -> Result<RawConfig, ConfigError> {
        // Mock parsing logic
        if content.contains("host=") {
            Ok(RawConfig {
                host: "localhost".to_string(),
                port: "8080".to_string(),
                timeout_ms: Some(5000),
            })
        } else {
            Err(ConfigError::ParseError("Invalid format".to_string()))
        }
    };

    // Step 2: Validate (RawConfig -> ValidatedConfig)
    let validate_config = |raw: RawConfig| -> Result<ValidatedConfig, ConfigError> {
        let port = raw
            .port
            .parse::<u16>()
            .map_err(|_| ConfigError::ValidationError("Invalid port".to_string()))?;

        if port < 1024 {
            return Err(ConfigError::ValidationError(
                "Port must be > 1024".to_string(),
            ));
        }

        Ok(ValidatedConfig {
            host: raw.host,
            port,
            timeout_ms: raw.timeout_ms.unwrap_or(3000), // Default timeout
        })
    };

    // EXECUTE PIPELINE
    // Note: We use ResultWitness to treat Result as a Monad
    let result = ResultWitness::bind(read_config_file(), |content| {
        ResultWitness::bind(parse_config(content), validate_config)
    });

    match result {
        Ok(config) => println!("✅ Configuration Loaded: {:#?}", config),
        Err(e) => println!("❌ Configuration Failed: {:?}", e),
    }

    // ------------------------------------------------------------------------
    // Step 2: Optional Values (Functor & Applicative)
    //
    // ENGINEERING VALUE:
    // Configuration often has optional fields. You want to apply transformations
    // (like converting units) ONLY if the value exists, without unwrapping.
    //
    // Functor (`fmap`) lets you modify the value inside `Option` safely.
    // ------------------------------------------------------------------------
    println!("\n--- 2. Optional Fields: Safe Transformation ---");

    let raw_timeout = Some(5000_u64); // 5000ms

    // Transformation: Convert ms to seconds
    let to_seconds = |ms: u64| ms as f64 / 1000.0;

    // Apply transformation safely
    let timeout_secs = OptionWitness::fmap(raw_timeout, to_seconds);

    println!("Raw Timeout (ms): {:?}", raw_timeout);
    println!("Processed Timeout (s): {:?}", timeout_secs);
    assert_eq!(timeout_secs, Some(5.0));

    // ------------------------------------------------------------------------
    // Step 3: Error Recovery (Bifunctor)
    //
    // ENGINEERING VALUE:
    // Sometimes you want to recover from errors or normalize them for the UI.
    // Bifunctor lets you map the Error channel independently of the Success channel.
    // ------------------------------------------------------------------------
    println!("\n--- 3. Error Handling: Normalization ---");

    let failed_load: Result<ValidatedConfig, ConfigError> =
        Err(ConfigError::IoError("File not found".to_string()));

    // Map Success: Keep as is
    // Map Error: Convert to a user-friendly string code
    let ui_result = ResultUnboundWitness::bimap(
        failed_load,
        |c| c, // Identity for success
        |e| match e {
            ConfigError::IoError(_) => "ERR_IO",
            ConfigError::ParseError(_) => "ERR_PARSE",
            ConfigError::ValidationError(_) => "ERR_VALIDATION",
        },
    );

    println!("UI Result Code: {:?}", ui_result);
    assert_eq!(ui_result, Err("ERR_IO"));
}

#[derive(Debug, Clone, PartialEq)]
struct RawConfig {
    host: String,
    port: String,
    timeout_ms: Option<u64>,
}

#[derive(Debug, Clone, PartialEq)]
struct ValidatedConfig {
    host: String,
    port: u16,
    timeout_ms: u64,
}

#[derive(Debug, Clone, PartialEq)]
#[allow(clippy::enum_variant_names)]
enum ConfigError {
    IoError(String),
    ParseError(String),
    ValidationError(String),
}
