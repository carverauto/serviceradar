// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The metric row shape and the pluggable Delta sink.

/// One flattened metric sample destined for the Delta table. The Delta schema
/// (task 3.2) partitions by tenant / source / day / `hash(series)`; this struct
/// is the in-memory pre-encoding shape produced by [`crate::pipeline`].
#[derive(Debug, Clone, PartialEq)]
pub struct MetricRow {
    pub tenant_id: String,
    pub agent_id: String,
    pub gateway_id: String,
    pub partition: String,
    pub metric_name: String,
    pub unit: String,
    pub series_identity_hint: String,
    pub value: f64,
    pub observed_at_unix_nano: u64,
}

/// A destination for batches of [`MetricRow`]. The production implementation
/// (task 3.1) writes Delta files via the `deltalake` crate; [`LoggingSink`] is
/// the compile-time placeholder.
///
/// Implementations MUST be all-or-nothing per `write_batch` call so the caller
/// can ack the corresponding JetStream messages only after a durable write.
pub trait DeltaSink {
    /// Write a batch of rows durably.
    fn write_batch(
        &self,
        rows: Vec<MetricRow>,
    ) -> impl std::future::Future<Output = crate::Result<()>> + Send;
}

/// Placeholder sink: logs the row count instead of writing Delta. Lets the
/// NATS -> decode -> row pipeline run end to end before the real sink lands.
#[derive(Debug, Default, Clone)]
pub struct LoggingSink;

impl DeltaSink for LoggingSink {
    async fn write_batch(&self, rows: Vec<MetricRow>) -> crate::Result<()> {
        // TODO(add-delta-metrics-lakehouse task 3.1): encode `rows` into an Arrow
        // RecordBatch and append to the Delta table at `config.delta_table_uri`
        // via the `deltalake` writer, partitioned per task 3.2.
        tracing::info!(
            rows = rows.len(),
            "delta write (LoggingSink placeholder — no Delta dependency yet)"
        );
        Ok(())
    }
}
