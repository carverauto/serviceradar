// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Environment configuration (via `envy`).

use serde::Deserialize;

fn default_nats_url() -> String {
    "nats://127.0.0.1:4222".to_owned()
}
fn default_stream() -> String {
    "metrics".to_owned()
}
fn default_durable() -> String {
    "serviceradar-metrics-delta-writer".to_owned()
}
fn default_filter_subject() -> String {
    "metrics.>".to_owned()
}
fn default_pull_batch() -> usize {
    256
}
fn default_flush_rows() -> usize {
    50_000
}
fn default_flush_interval_ms() -> u64 {
    5_000
}

/// Runtime configuration. All fields are read from the environment with
/// conservative defaults so a local run needs only `DELTA_TABLE_URI` and
/// `TENANT_ID`.
#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    /// NATS URL (env: `NATS_URL`).
    #[serde(default = "default_nats_url")]
    pub nats_url: String,
    /// JetStream stream holding raw metric batches (env: `STREAM`).
    #[serde(default = "default_stream")]
    pub stream: String,
    /// Durable pull-consumer name (env: `DURABLE`). Intentionally separate from
    /// the EventWriter and anomaly durables so this writer owns its own cursor
    /// and lag.
    #[serde(default = "default_durable")]
    pub durable: String,
    /// Subject filter on the metrics stream (env: `FILTER_SUBJECT`).
    #[serde(default = "default_filter_subject")]
    pub filter_subject: String,
    /// Max messages per pull fetch (env: `PULL_BATCH`).
    #[serde(default = "default_pull_batch")]
    pub pull_batch: usize,
    /// Tenant identifier; becomes the leading Delta partition and object-store
    /// prefix under the instance-per-tenant model (env: `TENANT_ID`).
    #[serde(default)]
    pub tenant_id: String,
    /// Delta table URI, for example `s3://bucket/<tenant>/metrics`
    /// (env: `DELTA_TABLE_URI`).
    #[serde(default)]
    pub delta_table_uri: String,
    /// Flush when this many buffered rows accumulate (env: `FLUSH_ROWS`).
    #[serde(default = "default_flush_rows")]
    pub flush_rows: usize,
    /// Flush at least this often regardless of buffer fill
    /// (env: `FLUSH_INTERVAL_MS`).
    #[serde(default = "default_flush_interval_ms")]
    pub flush_interval_ms: u64,
}

impl Config {
    /// Load configuration from the process environment.
    pub fn from_env() -> anyhow::Result<Self> {
        Ok(envy::from_env::<Self>()?)
    }
}
