// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use addon_sdk::metric_pb::{Metric, MetricPoint, MetricResource};

use super::support::entry;
use crate::identity::{attested_tags, safe_component, series_key_for};

#[test]
fn attested_tags_merges_metric_and_point_with_point_winning() {
    let metric = Metric {
        tags: vec![
            entry("source_zone", "rack-a"),
            entry("sensor", "metric-default"),
        ],
        ..Default::default()
    };
    let point = MetricPoint {
        attributes: vec![entry("sensor", "cpu0"), entry("core_id", "0")],
        ..Default::default()
    };

    let tags = attested_tags(&metric, &point);

    assert_eq!(
        tags.get("source_zone").and_then(|v| v.as_str()),
        Some("rack-a")
    );
    assert_eq!(tags.get("core_id").and_then(|v| v.as_str()), Some("0"));
    // point.attributes wins on a key collision so the per-core/per-mount
    // dimension central reconstructs matches what the point carried.
    assert_eq!(tags.get("sensor").and_then(|v| v.as_str()), Some("cpu0"));
}

#[test]
fn attested_tags_skips_empty_keys() {
    let metric = Metric {
        tags: vec![entry("", "ignored")],
        ..Default::default()
    };
    assert!(attested_tags(&metric, &MetricPoint::default()).is_empty());
}

#[test]
fn edge_series_key_encodes_partition_and_hint_boundaries() {
    let metric = Metric {
        name: "cpu.usage".to_string(),
        metric_type: "sysmon.cpu".to_string(),
        ..Default::default()
    };
    let point = MetricPoint {
        series_identity_hint: "host:a|core:0".to_string(),
        ..Default::default()
    };

    let first = MetricResource {
        partition: "prod:east".to_string(),
        ..Default::default()
    };
    let second = MetricResource {
        partition: "prod".to_string(),
        ..Default::default()
    };
    let second_point = MetricPoint {
        series_identity_hint: "east|host:a|core:0".to_string(),
        ..Default::default()
    };

    let first_key = series_key_for(&first, &metric, &point);
    let second_key = series_key_for(&second, &metric, &second_point);

    assert_ne!(first_key, second_key);
    assert!(first_key.contains(&safe_component("partition", "prod:east")));
    assert!(first_key.contains(&safe_component("hint", "host:a|core:0")));
    assert!(!first_key.contains("prod:east"));
    assert!(!first_key.contains("host:a|core:0"));
}
