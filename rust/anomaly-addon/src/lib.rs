// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! ServiceRadar edge anomaly add-on (OpenSpec: `move-anomaly-detection-to-edge`).
//!
//! Runs co-located with `serviceradar-agent` as a native go-plugin sidecar. It
//! consumes the agent's local metric feed (`metric-feed:v1`), scores each sample
//! per series with the shared [`serviceradar_anomaly_core`] detector — the same
//! code path the central NIF uses, so verdicts are identical — and emits anomaly
//! verdicts upstream over the native telemetry stream (`native-telemetry:v1`).

pub mod engine;

mod addon;

pub use addon::AnomalyAddon;
