// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use std::sync::{Arc, Mutex};

use std::path::Path;

use crate::checkpoint::{load_checkpoint, resolve_checkpoint_settings_in, write_checkpoint};
use crate::config::AddonConfig;
use crate::engine::{DetectorEngine, EngineConfig, SeriesProfile};

#[test]
fn checkpoint_file_round_trip_atomic() {
    let path = std::env::temp_dir().join(format!("sr-anomaly-ckpt-{}.json", std::process::id()));
    let _ = std::fs::remove_file(&path);

    let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig::default())));
    {
        let mut e = engine.lock().unwrap();
        for i in 0..20 {
            e.evaluate(
                "s",
                100.0 + (i % 3) as f64,
                i as u64,
                SeriesProfile::default(),
            );
        }
    }

    write_checkpoint(&engine, &path);
    assert!(path.exists(), "checkpoint file must be written");
    // The atomic rename leaves no stray .tmp behind.
    assert!(!path.with_extension("tmp").exists());

    // A fresh engine re-warms from the file (huge max_age = nothing stale).
    let restored = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig::default())));
    load_checkpoint(&restored, &path, u64::MAX);
    assert_eq!(restored.lock().unwrap().series_count(), 1);

    // A missing file is a no-op (cold start), never an error.
    let _ = std::fs::remove_file(&path);
    let cold = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig::default())));
    load_checkpoint(&cold, &path, u64::MAX);
    assert_eq!(cold.lock().unwrap().series_count(), 0);
}

#[test]
fn checkpoint_path_defaults_to_the_agent_state_dir() {
    let config = AddonConfig::default();
    let settings = resolve_checkpoint_settings_in(
        &config,
        Some("/var/lib/serviceradar/agent/addons/anomaly/state"),
    );
    assert_eq!(
        settings.path.as_deref(),
        Some(Path::new(
            "/var/lib/serviceradar/agent/addons/anomaly/state/checkpoint.json"
        ))
    );
}

#[test]
fn explicit_checkpoint_path_wins_over_the_agent_state_dir() {
    let config: AddonConfig =
        serde_json::from_value(serde_json::json!({"checkpoint_path": "/srv/ckpt/anomaly.json"}))
            .expect("valid config");
    let settings =
        resolve_checkpoint_settings_in(&config, Some("/var/lib/agent/addons/anomaly/state"));
    assert_eq!(
        settings.path.as_deref(),
        Some(Path::new("/srv/ckpt/anomaly.json"))
    );
}

#[test]
fn checkpointing_stays_off_without_a_path_or_a_state_dir() {
    let config = AddonConfig::default();
    assert!(resolve_checkpoint_settings_in(&config, None).path.is_none());
    assert!(
        resolve_checkpoint_settings_in(&config, Some("   "))
            .path
            .is_none()
    );
}

#[test]
fn write_checkpoint_creates_a_missing_parent_directory() {
    let dir = std::env::temp_dir().join(format!("sr-anomaly-ckpt-dir-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let path = dir.join("nested").join("checkpoint.json");
    let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig::default())));
    write_checkpoint(&engine, &path);
    assert!(
        path.exists(),
        "checkpoint must be written under a freshly created parent"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
