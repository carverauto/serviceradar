// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Restart-checkpoint persistence: resolve checkpoint/liveness settings from the
//! parsed config, atomically write and re-warm the engine's per-series state.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use crate::addon::lock_engine;
use crate::config::{AddonConfig, CheckpointSettings, DEFAULT_SCORING_STALE_AFTER_NS};
use crate::engine::{DetectorEngine, EngineCheckpoint};

/// Resolve checkpoint behavior from the parsed config: a blank/absent path
/// disables checkpointing; `checkpoint_max_age_secs` overrides the staleness bound.
pub(crate) fn resolve_checkpoint_settings(config: &AddonConfig) -> CheckpointSettings {
    let mut settings = CheckpointSettings::default();

    if let Some(path) = config
        .checkpoint_path
        .as_ref()
        .map(|p| p.trim())
        .filter(|p| !p.is_empty())
    {
        settings.path = Some(PathBuf::from(path));
    }

    if let Some(secs) = config.checkpoint_max_age_secs {
        settings.max_age_ns = secs.saturating_mul(1_000_000_000);
    }

    settings
}

pub(crate) fn resolve_scoring_stale_after_ns(config: &AddonConfig) -> u64 {
    config
        .scoring_stale_after_secs
        .map(|secs| secs.max(1).saturating_mul(1_000_000_000))
        .unwrap_or(DEFAULT_SCORING_STALE_AFTER_NS)
}

/// Atomically persist the engine's per-series checkpoint: write a sibling `.tmp`
/// then rename over the target so a crash mid-write never leaves a torn file.
/// Best-effort — any error is swallowed (the add-on keeps running, just without a
/// fresh checkpoint).
pub(crate) fn write_checkpoint(engine: &Arc<Mutex<DetectorEngine>>, path: &Path) {
    let checkpoint = {
        let engine = lock_engine(engine);
        engine.export_checkpoint()
    };

    let Ok(json) = serde_json::to_vec(&checkpoint) else {
        return;
    };

    let tmp = path.with_extension("tmp");
    if std::fs::write(&tmp, &json).is_ok() {
        let _ = std::fs::rename(&tmp, path);
    }
}

/// Re-warm the engine from an on-disk checkpoint. A missing file (first run) or a
/// corrupt/unparseable file is ignored — the add-on cold-starts rather than
/// failing — so checkpointing can never wedge startup.
pub(crate) fn load_checkpoint(engine: &Arc<Mutex<DetectorEngine>>, path: &Path, max_age_ns: u64) {
    let Ok(data) = std::fs::read(path) else {
        return;
    };
    let Ok(checkpoint) = serde_json::from_slice::<EngineCheckpoint>(&data) else {
        return;
    };

    let now = now_unix_nano();
    lock_engine(engine).restore_checkpoint(checkpoint, now, max_age_ns);
}

/// Wall-clock now in unix nanoseconds, for the restart staleness bound. Saturates
/// to 0 before the epoch (never panics).
pub(crate) fn now_unix_nano() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
}
