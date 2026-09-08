// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use std::sync::{Arc, Mutex};

use crate::checkpoint::{load_checkpoint, write_checkpoint};
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
