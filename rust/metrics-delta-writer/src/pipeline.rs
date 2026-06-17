// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Decode `MetricBatch` protobuf payloads into flattened [`MetricRow`]s.

use prost::Message;
use serviceradar_metric_proto::MetricBatch;

use crate::sink::MetricRow;

/// Decode one encoded `serviceradar.metric.v1.MetricBatch` into flattened rows,
/// one per metric point. `tenant_id` is stamped on every row as the leading
/// partition dimension under the instance-per-tenant model.
pub fn batch_to_rows(tenant_id: &str, payload: &[u8]) -> crate::Result<Vec<MetricRow>> {
    let batch = MetricBatch::decode(payload)?;
    let resource = batch.resource.unwrap_or_default();

    let mut rows = Vec::new();
    for metric in batch.metrics {
        for point in metric.points {
            rows.push(MetricRow {
                tenant_id: tenant_id.to_owned(),
                agent_id: resource.agent_id.clone(),
                gateway_id: resource.gateway_id.clone(),
                partition: resource.partition.clone(),
                metric_name: metric.name.clone(),
                unit: metric.unit.clone(),
                series_identity_hint: point.series_identity_hint.clone(),
                value: point.value,
                observed_at_unix_nano: point.observed_at_unix_nano,
            });
        }
    }
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serviceradar_metric_proto::{Metric, MetricBatch, MetricPoint, MetricResource};

    #[test]
    fn decodes_points_into_rows() {
        let batch = MetricBatch {
            schema_version: "serviceradar.metric.v1".to_owned(),
            resource: Some(MetricResource {
                agent_id: "agent-1".to_owned(),
                gateway_id: "gw-1".to_owned(),
                partition: "default".to_owned(),
                ..Default::default()
            }),
            metrics: vec![Metric {
                name: "cpu.usage".to_owned(),
                unit: "percent".to_owned(),
                points: vec![
                    MetricPoint {
                        value: 1.0,
                        observed_at_unix_nano: 10,
                        series_identity_hint: "s1".to_owned(),
                        ..Default::default()
                    },
                    MetricPoint {
                        value: 2.0,
                        observed_at_unix_nano: 20,
                        series_identity_hint: "s2".to_owned(),
                        ..Default::default()
                    },
                ],
                ..Default::default()
            }],
            ..Default::default()
        };
        let encoded = batch.encode_to_vec();

        let rows = batch_to_rows("tenant-1", &encoded).expect("decode");

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].tenant_id, "tenant-1");
        assert_eq!(rows[0].agent_id, "agent-1");
        assert_eq!(rows[0].partition, "default");
        assert_eq!(rows[0].metric_name, "cpu.usage");
        assert_eq!(rows[0].series_identity_hint, "s1");
        assert_eq!(rows[1].value, 2.0);
        assert_eq!(rows[1].observed_at_unix_nano, 20);
    }
}
